#!/usr/bin/env python3
"""Воспроизводимый локальный стресс-тест tsukiko; записи и отчёты вне Git.

Примеры:
  python3 tool/asr_stress.py run --phase baseline
  python3 tool/asr_stress.py run --phase all
  python3 tool/asr_stress.py api
  python3 tool/asr_stress.py report
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request
import wave
import random


ROOT = Path(__file__).resolve().parents[1]
RECORDS = ROOT / "records"
OUTPUT = RECORDS / ".asr-eval"
MODELS = Path.home() / "Library/Application Support/app.yuko.tsukiko/models"
SETTINGS = MODELS.parent / "settings.json"
ENGINE = ROOT / "macos/Engine"
WHISPER = ENGINE / "tsukiko-recognizer"
NEMO = ENGINE / "nemo/bin/nemo-speech"
VAD = MODELS / "ggml-silero-v5.1.2.bin"
TERMS = ("ФИТУ", "БГУИР")
FILLER = "Обсуждаем обычные занятия, расписание, аудиторию и учебный проект. "


def engine_versions():
    whisper_source = ROOT / "build/engine/whisper.cpp-1.9.3"
    try:
        whisper = subprocess.check_output(
            ["git", "-C", str(whisper_source), "rev-parse", "HEAD"], text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        whisper = "unknown"
    try:
        nemo = subprocess.check_output([str(NEMO), "--version"], text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        nemo = "unknown"
    return {"whisper": whisper, "nemo": nemo}


def settings():
    return json.loads(SETTINGS.read_text()) if SETTINGS.exists() else {}


def files():
    return sorted(RECORDS.glob("*.m4a"))


def challenge_clips():
    # Короткие окна, в которых один фактор можно проверить быстро. Метки
    # «сказано» предварительные до ручной правки владельца записей.
    specs = (
        ("Солнечная улица 2.m4a", "fitu_spoken", 6, 16, 1, 0),
        ("Солнечная улица 2.m4a", "similar_words", 16, 34, 0, 0),
        ("Солнечная улица 3.m4a", "bguir_spoken", 0, 12, 0, 1),
        ("Солнечная улица 3.m4a", "fitu_spoken", 27, 40, 1, 1),
        ("Солнечная улица 4.m4a", "unrelated_speech", 0, 30, 0, 0),
        ("Солнечная улица 5.m4a", "terms_spoken", 225, 248, 1, 1),
    )
    folder = OUTPUT / "challenges"
    folder.mkdir(parents=True, exist_ok=True)
    result = []
    manifest = {}
    for filename, label, start, end, fitu, bguir in specs:
        source = RECORDS / filename
        if not source.exists():
            continue
        target = folder / f"{digest([filename, start, end])}-{label}.wav"
        if not target.exists():
            subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y",
                            "-ss", str(start), "-i", str(source), "-t", str(end - start),
                            "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", str(target)],
                           check=True)
        result.append(target)
        manifest[str(target)] = {"source": str(source), "from": start * 1000,
                                 "to": end * 1000, "label": label,
                                 "expected": {"fitu": fitu, "bguir": bguir},
                                 "provisional": True}
    for label in ("ru_smoke", "ru_near_homophones", "ru_terms"):
        target = ROOT / "test/fixtures" / f"{label}.wav"
        with wave.open(str(target)) as sample:
            duration_ms = round(sample.getnframes() / sample.getframerate() * 1000)
        result.append(target)
        manifest[str(target)] = {"source": str(target), "from": 0,
                                 "to": duration_ms, "label": label,
                                 "expected": {"fitu": 1 if label == "ru_terms" else 0,
                                              "bguir": 1 if label == "ru_terms" else 0},
                                 "provisional": False}
    (folder / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
    return result


def models():
    return sorted(p for p in MODELS.iterdir()
                  if p.suffix in (".bin", ".gguf") and "silero" not in p.name)


def digest(value):
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True).encode()).hexdigest()[:16]


def footprint_mb(pid):
    try:
        result = subprocess.run(["footprint", "-p", str(pid)], capture_output=True,
                                text=True, timeout=15)
        match = re.search(r"phys_footprint:\s*(\d+)\s*MB", result.stdout)
        return int(match.group(1)) if match else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def model_kind(model):
    return "nemo" if model.suffix == ".gguf" else "whisper"


def supports_prompt(model):
    return "parakeet-tdt" not in model.name.lower()


def prompt_variants():
    return {
        "none": "",
        "current": settings().get("prompt", ""),
        "fitu": "ФИТУ",
        "bguir": "БГУИР",
        "both": "ФИТУ, БГУИР",
        "split_terms": "ФИТУ, БГУИР",
        "phonetic": "фиту, бгуир",
        "spelling_and_sound": "ФИТУ, фиту, БГУИР, бгуир",
        "expanded": "ФИТУ — факультет информационных технологий и управления; БГУИР — Белорусский государственный университет информатики и радиоэлектроники",
        "distractors": "ФИТУ, БГУИР, фото, фигура, будильник, библиотека",
        "style": "Записанный текст оформлен по правилам русского языка: с запятыми и точками.",
    }


def compile_tokenizer():
    source = ROOT / "build/engine/whisper.cpp-1.9.3"
    binary = OUTPUT / "asr-prompt-tokens"
    if binary.exists() and binary.stat().st_mtime > (ROOT / "tool/asr_prompt_tokens.cpp").stat().st_mtime:
        return binary
    build = source / "build"
    if not (build / "src/libwhisper.a").exists():
        raise RuntimeError("Нужна локальная сборка whisper.cpp: ./tool/engine.sh")
    cmd = ["c++", "-std=c++17", "-O2", "-I" + str(source / "include"),
           "-I" + str(source / "ggml/include"), str(ROOT / "tool/asr_prompt_tokens.cpp"),
           str(build / "src/libwhisper.a"), str(build / "ggml/src/libggml.a"),
           str(build / "ggml/src/libggml-cpu.a"),
           str(build / "ggml/src/ggml-blas/libggml-blas.a"),
           str(build / "ggml/src/ggml-metal/libggml-metal.a"),
           str(build / "ggml/src/libggml-base.a"), "-framework", "Accelerate",
           "-framework", "Foundation", "-framework", "Metal", "-framework", "MetalKit",
           "-o", str(binary)]
    subprocess.run(cmd, check=True, cwd=ROOT)
    return binary


class Tokenizer:
    def __init__(self, model):
        self.process = subprocess.Popen([str(compile_tokenizer()), str(model)],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, text=True, bufsize=1)
        first = self.process.stdout.readline().split()
        if len(first) != 2 or first[0] != "budget":
            raise RuntimeError("Токенизатор не загрузил модель")
        self.budget = int(first[1])

    def count(self, prompt):
        self.process.stdin.write(prompt.replace("\n", " ") + "\n")
        self.process.stdin.flush()
        return int(self.process.stdout.readline())

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=30)


def saturated_prompt(tokenizer, fraction, position):
    target = "ФИТУ, БГУИР"
    desired = round(tokenizer.budget * fraction)
    text = ""
    while tokenizer.count(text + target) < desired:
        text += FILLER
    words = text.split()
    if position == "start":
        return target + " " + text
    if position == "middle":
        middle = len(words) // 2
        return " ".join(words[:middle] + [target] + words[middle:])
    return text + " " + target


def make_jobs(phase, repetitions, audios=None, selected_models=None):
    jobs = []
    audios = audios if audios is not None else files()
    selected_models = selected_models if selected_models is not None else models()
    for model in selected_models:
        kind = model_kind(model)
        tokenizer = Tokenizer(model) if kind == "whisper" else None
        try:
            for audio in audios:
                if phase in ("baseline", "all"):
                    prompts = prompt_variants() if supports_prompt(model) else {"none": ""}
                    for label, prompt in prompts.items():
                        if kind == "whisper" and label == "split_terms":
                            continue
                        for repeat in range(repetitions):
                            jobs.append(dict(phase="baseline", model=str(model), audio=str(audio),
                                             label=label, prompt=prompt, repeat=repeat, lang="auto", extra=[]))
                if kind == "whisper":
                    if phase in ("saturation", "all"):
                        for fraction in (.25, .5, 1, 1.5, 2):
                            for position in ("start", "middle", "end"):
                                prompt = saturated_prompt(tokenizer, fraction, position)
                                for repeat in range(repetitions):
                                    jobs.append(dict(phase="saturation", model=str(model), audio=str(audio),
                                                     label=f"{fraction:g}-{position}", prompt=prompt,
                                                     repeat=repeat, lang="auto", extra=[]))
                    if phase in ("repetition", "all"):
                        for term in TERMS:
                            for count in (1, 2, 4, 8, 16):
                                for repeat in range(repetitions):
                                    jobs.append(dict(phase="repetition", model=str(model), audio=str(audio),
                                                     label=f"{term}-{count}", prompt=", ".join([term] * count),
                                                     repeat=repeat, lang="auto", extra=[]))
                    if phase in ("knobs", "all"):
                        variants = {
                            "ru": ("ru", []), "be": ("be", []),
                            "beam1": ("auto", ["-bs", "1", "-bo", "1"]),
                            "beam8": ("auto", ["-bs", "8", "-bo", "8"]),
                            "no_fallback": ("auto", ["-nf"]),
                            "temperature": ("auto", ["-tp", "0.2"]),
                            "no_speech_03": ("auto", ["-nth", "0.3"]),
                            "no_speech_08": ("auto", ["-nth", "0.8"]),
                            "logprob_075": ("auto", ["-lpt", "-0.75"]),
                            "logprob_125": ("auto", ["-lpt", "-1.25"]),
                            "no_carry": ("auto", []),
                            "carry_terms": ("auto", []),
                        }
                        if VAD.exists():
                            for threshold in (.3, .5, .7):
                                variants[f"vad_{threshold:g}"] = ("auto", ["--vad", "-vm", str(VAD), "-vt", str(threshold)])
                        for label, (lang, extra) in variants.items():
                            for repeat in range(repetitions):
                                jobs.append(dict(phase="knobs", model=str(model), audio=str(audio),
                                                 label=label,
                                                 prompt="ФИТУ, БГУИР" if label in ("no_carry", "carry_terms") else "",
                                                 repeat=repeat, lang=lang, extra=extra))
                elif phase in ("knobs", "all"):
                    for lang in ("ru", "be"):
                        for repeat in range(repetitions):
                            jobs.append(dict(phase="knobs", model=str(model), audio=str(audio),
                                             label=lang, prompt="", repeat=repeat, lang=lang, extra=[]))
            if tokenizer:
                for job in jobs:
                    if job["model"] == str(model):
                        job["prompt_tokens"] = tokenizer.count(job["prompt"])
                        job["prompt_budget"] = tokenizer.budget
            model_stat = model.stat()
            for job in jobs:
                if job["model"] == str(model):
                    job["model_size"] = model_stat.st_size
                    job["model_mtime_ns"] = model_stat.st_mtime_ns
        finally:
            if tokenizer:
                tokenizer.close()
    yield from jobs


def wav_for(audio):
    cache = OUTPUT / "wav"
    cache.mkdir(parents=True, exist_ok=True)
    wav = cache / (digest([str(audio), audio.stat().st_size, audio.stat().st_mtime_ns]) + ".wav")
    if not wav.exists():
        subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-i", str(audio),
                        "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", str(wav)], check=True)
    return wav


def invoke(job, wav, outbase):
    model = Path(job["model"])
    kind = model_kind(model)
    if kind == "whisper":
        cmd = [str(WHISPER), "-m", str(model), "-l", job["lang"], "-t", "4", "-pp",
               "-mc", "0", "-of", str(outbase), "-oj"]
        if job["prompt"]:
            if job["label"] != "no_carry":
                cmd.append("--carry-initial-prompt")
            cmd += ["--prompt", job["prompt"]]
        cmd += job["extra"] + [str(wav)]
    else:
        cmd = [str(NEMO), "transcribe", str(wav), "--no-warmup", "--model", str(model),
               "--format", "json", "--output", str(outbase) + ".json", "--force"]
        if job["lang"] != "auto":
            cmd += ["--language", job["lang"]]
        if job["prompt"] and supports_prompt(model):
            phrases = (job["prompt"].split(", ") if job["label"] == "split_terms"
                       else [job["prompt"]])
            for phrase in phrases:
                cmd += ["--speech-context", phrase]
            cmd += ["--speech-context-boost", "3"]
    start = time.monotonic()
    try:
        p = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        peak_kb = 0
        while p.poll() is None:
            ps = subprocess.run(["ps", "-o", "rss=", "-p", str(p.pid)], capture_output=True, text=True)
            if ps.stdout.strip().isdigit():
                peak_kb = max(peak_kb, int(ps.stdout.strip()))
            time.sleep(.5)
            if time.monotonic() - start > 1800:
                p.kill()
                break
        stderr = p.communicate()[1][-12000:]
        code = p.returncode
    except OSError as e:
        code, stderr, peak_kb = -1, str(e), 0
    return cmd, code, stderr, round(time.monotonic() - start, 3), peak_kb


class Postprocessor:
    def __init__(self):
        self.p = subprocess.Popen(["dart", "run", "tool/asr_postprocess.dart"], cwd=ROOT,
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, text=True, bufsize=1)

    def process(self, kind, raw, vocabulary):
        self.p.stdin.write(json.dumps({"engine": kind, "raw": raw,
                                       "vocabulary": vocabulary}, ensure_ascii=False) + "\n")
        self.p.stdin.flush()
        return json.loads(self.p.stdout.readline())

    def effective_prompt(self, base, vocabulary):
        return self.process("prompt", base, vocabulary)["prompt"]

    def close(self):
        self.p.stdin.close()
        self.p.wait(timeout=30)


def command_run(args):
    OUTPUT.mkdir(parents=True, exist_ok=True)
    rawdir = OUTPUT / "raw"
    rawdir.mkdir(exist_ok=True)
    resultfile = OUTPUT / "runs.jsonl"
    done = set()
    if resultfile.exists():
        for line in resultfile.read_text().splitlines():
            try:
                previous = json.loads(line)
                if previous.get("exit_code") == 0 and not previous.get("processed", {}).get("error"):
                    done.add(previous["id"])
            except (ValueError, KeyError):
                pass
    vocabulary = settings().get("vocabulary", [])
    versions = engine_versions()
    post = Postprocessor()
    completed = 0
    server = None
    server_model = None
    port = None
    server_cmd = None
    try:
        audios = challenge_clips() if args.clips else files()
        if args.clip_label:
            manifest = json.loads((OUTPUT / "challenges/manifest.json").read_text())
            audios = [a for a in audios if manifest.get(str(a), {}).get("label") in args.clip_label]
        if not audios:
            raise RuntimeError("Нет фрагментов, подходящих под --clip-label")
        chosen = [m for m in models() if not args.model or any(name in m.name for name in args.model)]
        if not chosen:
            raise RuntimeError("Нет моделей, подходящих под --model")
        for job in make_jobs(args.phase, args.repeats, audios, chosen):
            if args.backend == "server" and job["label"] == "split_terms":
                continue
            identity = {k: v for k, v in job.items() if k not in (
                "prompt_tokens", "prompt_budget", "model_size", "model_mtime_ns")}
            if args.backend == "server":
                identity["backend"] = "server"
            jobid = digest(identity)
            if jobid in done:
                continue
            if args.limit and completed >= args.limit:
                break
            wav = wav_for(Path(job["audio"]))
            kind = model_kind(Path(job["model"]))
            if args.backend == "server":
                if server_model != job["model"]:
                    stop_server(server)
                    if kind == "whisper":
                        server, port, server_cmd = start_whisper_server(Path(job["model"]))
                    else:
                        server, port, server_cmd = start_nemo_server(Path(job["model"]))
                    server_model = job["model"]
                start = time.monotonic()
                try:
                    if kind == "whisper":
                        raw = server_request(port, wav, server_fields(job))
                    else:
                        fields = {"response_format": "verbose_json",
                                  "automatic_punctuation": "true"}
                        if job["lang"] != "auto":
                            fields["language"] = job["lang"]
                        if job["prompt"] and supports_prompt(Path(job["model"])):
                            fields["prompt"] = job["prompt"]
                        raw = server_request(port, wav, fields, "/v1/audio/transcriptions")
                    code, error = 0, ""
                except Exception as e:
                    raw, code, error = "", 1, str(e)
                seconds = round(time.monotonic() - start, 3)
                peak_kb = 0
                physical_mb = footprint_mb(server.pid)
                cmd = server_cmd
                shaped = raw
                if raw and kind == "whisper":
                    try:
                        shaped = cli_shape_from_verbose(raw)
                    except (ValueError, TypeError) as e:
                        shaped = ""
                        error = f"Ошибка JSON сервера: {e}"
                        code = 1
            else:
                stop_server(server)
                server, server_model = None, None
                with tempfile.TemporaryDirectory(prefix="tsukiko-asr-") as tmp:
                    cmd, code, error, seconds, peak_kb = invoke(job, wav, Path(tmp) / "output")
                    path = Path(tmp) / "output.json"
                    raw = path.read_text() if path.exists() else ""
                shaped = raw
                physical_mb = None
            if raw:
                (rawdir / f"{jobid}.json").write_text(raw)
            processed = post.process(kind, shaped, vocabulary) if shaped else {}
            # Не дублируем гигантскую подсказку в каждой записи отчёта.
            public_job = {k: v for k, v in job.items() if k != "prompt"}
            row = {"id": jobid, **public_job, "prompt": job["prompt"],
                   "prompt_characters": len(job["prompt"]), "command": cmd,
                   "engine_version": versions[kind],
                   "backend": args.backend,
                   "exit_code": code, "stderr_tail": error,
                   "seconds": seconds, "peak_rss_kb": peak_kb,
                   "physical_footprint_mb": physical_mb,
                   "raw_path": str(rawdir / f"{jobid}.json") if raw else None,
                   "processed": processed}
            with resultfile.open("a") as output:
                output.write(json.dumps(row, ensure_ascii=False) + "\n")
            if code == 0 and not processed.get("error"):
                done.add(jobid)
            completed += 1
            print(f"{completed}: {Path(job['model']).name} {Path(job['audio']).name} "
                  f"{job['phase']}/{job['label']} #{job['repeat'] + 1}: {code}, {seconds}s", flush=True)
    finally:
        stop_server(server)
        post.close()


def command_api(args):
    OUTPUT.mkdir(parents=True, exist_ok=True)
    key = settings().get("apiKey", "")
    if not key:
        raise RuntimeError("Локальное API не настроено")
    headers = {"Authorization": "Bearer " + key}
    endpoint = "http://127.0.0.1:8756/transcribe"
    status_req = urllib.request.Request("http://127.0.0.1:8756/status", headers=headers)
    status = json.load(urllib.request.urlopen(status_req, timeout=5))
    (OUTPUT / "api-status.json").write_text(json.dumps({
        "version": status.get("version"), "engine": status.get("engine"),
        "options": status.get("options"), "queue": status.get("queue")},
        ensure_ascii=False, indent=2))
    copies = OUTPUT / "api-input"
    copies.mkdir(exist_ok=True)
    completed = 0
    for repeat in range(args.repeats):
        for audio in files():
            if args.limit and completed >= args.limit:
                return
            # API связывает готовую работу с путём файла. Своя копия гарантирует
            # новый проход даже если оригинал уже есть в пользовательской очереди.
            target = copies / f"{digest([str(audio), audio.stat().st_mtime_ns, repeat])}-{audio.name}"
            if not target.exists():
                shutil.copyfile(audio, target)
            req = urllib.request.Request(endpoint, data=json.dumps({"file": str(target)}).encode(),
                                         headers={**headers, "Content-Type": "application/json"})
            started = time.monotonic()
            result = json.load(urllib.request.urlopen(req, timeout=30))
            states = [result.get("state")]
            while not result.get("done"):
                if time.monotonic() - started > 1800:
                    result = {"state": "timeout", "detail": "Ожидание API более 1800 секунд"}
                    break
                time.sleep(1)
                url = endpoint + "?" + urllib.parse.urlencode({"id": str(target), "wait": 30, "format": "txt"})
                result = json.load(urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=40))
                states.append(result.get("state"))
                if result.get("state") in ("failed", "cancelled"):
                    break
            with (OUTPUT / "api.jsonl").open("a") as f:
                f.write(json.dumps({"audio": str(audio), "api_input": str(target),
                                    "repeat": repeat, "states": states,
                                    "seconds": round(time.monotonic() - started, 3),
                                    "result": result}, ensure_ascii=False) + "\n")
            print(f"API: {audio.name}: {result.get('state', 'done')}", flush=True)
            completed += 1


def command_report(_args):
    path = OUTPUT / "runs.jsonl"
    if not path.exists():
        print("Пока нет прогонов")
        return
    rows = [json.loads(x) for x in path.read_text().splitlines() if x.strip()]
    groups = {}
    for row in rows:
        key = (Path(row["model"]).name, row["phase"], row["label"])
        group = groups.setdefault(key, {"count": 0, "failures": 0, "seconds": 0,
                                        "fitu": 0, "bguir": 0, "replacements": 0})
        group["count"] += 1
        group["failures"] += row["exit_code"] != 0 or bool(row["processed"].get("error"))
        group["seconds"] += row["seconds"]
        segments = row["processed"].get("final", [])
        text = " ".join(s["text"] for s in segments).lower()
        group["fitu"] += len(re.findall(r"(?<!\w)(?:фиту|fitu)(?!\w)", text))
        group["bguir"] += len(re.findall(r"(?<!\w)(?:бгуир|bguir)(?!\w)", text))
        group["replacements"] += sum(len(s["replacements"]) for s in segments)
    for key, result in sorted(groups.items()):
        print(" | ".join(key), json.dumps(result, ensure_ascii=False))
    print("Всего:", len(rows), "прогонов")


def edit_distance(a, b):
    old = list(range(len(b) + 1))
    for i, item in enumerate(a, 1):
        new = [i]
        for j, other in enumerate(b, 1):
            new.append(min(new[-1] + 1, old[j] + 1,
                           old[j - 1] + (item != other)))
        old = new
    return old[-1]


def normalize_words(text):
    return re.findall(r"[\w]+", text.casefold(), re.UNICODE)


def reference_for(audio):
    audio = Path(audio)
    candidates = [RECORDS / "references" / (audio.stem + ".txt")]
    if audio.parent == ROOT / "test/fixtures":
        candidates.insert(0, audio.with_suffix(".txt"))
    return next((p.read_text() for p in candidates if p.exists()), None)


def stage_texts(row):
    processed = row.get("processed", {})
    clean = " ".join(s["text"] for s in processed.get("cleaned", []))
    final = " ".join(s["text"] for s in processed.get("final", []))
    raw_path = row.get("raw_path")
    if not raw_path:
        return "", clean, final
    try:
        data = json.loads(Path(raw_path).read_text())
    except (OSError, ValueError):
        return "", clean, final
    if model_kind(Path(row["model"])) == "whisper":
        name = "segments" if row.get("backend") == "server" else "transcription"
        raw = " ".join(s.get("text", "") for s in data.get(name, []))
    else:
        raw = data.get("text", "")
    return raw, clean, final


def term_count(text, key):
    variants = r"(?:фиту|fitu)" if key == "fitu" else r"(?:бгуир|bguir)"
    return len(re.findall(r"(?<!\w)" + variants + r"(?!\w)", text, re.I))


def command_markdown(_args):
    path = OUTPUT / "runs.jsonl"
    rows = [json.loads(x) for x in path.read_text().splitlines()] if path.exists() else []
    out = ["# Проверка распознавания tsukiko", "",
           f"Всего прогонов: {len(rows)}. Эталонные тексты читаются из `records/references/*.txt`.",
           "Без выверенного эталона количество терминов является наблюдением, а не оценкой ошибок.", "",
           "| Модель | Условие | Прогонов | Ошибок процесса | Среднее время, с | ФИТУ | БГУИР | WER* | CER* |",
           "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    groups = {}
    for row in rows:
        key = (Path(row["model"]).name, row.get("backend", "cli"), row["phase"], row["label"])
        g = groups.setdefault(key, {"count": 0, "fail": 0, "seconds": 0.0,
                                    "fitu": 0, "bguir": 0, "wer": [], "cer": []})
        g["count"] += 1
        g["fail"] += row["exit_code"] != 0 or bool(row["processed"].get("error"))
        g["seconds"] += row["seconds"]
        text = " ".join(x["text"] for x in row["processed"].get("final", []))
        g["fitu"] += len(re.findall(r"(?<!\w)(?:фиту|fitu)(?!\w)", text, re.I))
        g["bguir"] += len(re.findall(r"(?<!\w)(?:бгуир|bguir)(?!\w)", text, re.I))
        reference = reference_for(row["audio"])
        if reference is not None:
            truth, guess = normalize_words(reference), normalize_words(text)
            if truth:
                g["wer"].append(edit_distance(truth, guess) / len(truth))
            true_chars = "".join(truth)
            guess_chars = "".join(guess)
            if true_chars:
                g["cer"].append(edit_distance(true_chars, guess_chars) / len(true_chars))
    for key, g in sorted(groups.items()):
        label = f"{key[1]}/{key[2]}/{key[3]}"
        wer = f"{sum(g['wer']) / len(g['wer']):.3f}" if g["wer"] else "—"
        cer = f"{sum(g['cer']) / len(g['cer']):.3f}" if g["cer"] else "—"
        out.append(f"| {key[0]} | {label} | {g['count']} | {g['fail']} | "
                   f"{g['seconds']/g['count']:.1f} | {g['fitu']} | {g['bguir']} | {wer} | {cer} |")
    manifest_file = OUTPUT / "challenges/manifest.json"
    manifest = json.loads(manifest_file.read_text()) if manifest_file.exists() else {}
    scores = {}
    for row in rows:
        case = manifest.get(row["audio"])
        if not case or row.get("phase") != "baseline" or row.get("exit_code") != 0:
            continue
        key = (Path(row["model"]).name, row.get("backend", "cli"), row["label"])
        score = scores.setdefault(key, {"runs": 0, "hits": 0, "misses": 0,
                                        "extra": 0, "seconds": 0.0})
        score["runs"] += 1
        score["seconds"] += row["seconds"]
        final_text = " ".join(s["text"] for s in row["processed"].get("final", []))
        for term in ("fitu", "bguir"):
            expected = case["expected"][term]
            observed = term_count(final_text, term)
            score["hits"] += min(expected, observed)
            score["misses"] += max(0, expected - observed)
            score["extra"] += max(0, observed - expected)
    out += ["", "## Счёт по коротким фрагментам", "",
            "Метки произнесённых терминов в личных записях предварительные. "
            "Лишние появления считаются относительно отмеченного количества.", "",
            "| Модель | Путь | Подсказка | Прогонов | Узнано | Пропущено | Лишних | Время, с |",
            "| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |"]
    for key, score in sorted(scores.items()):
        out.append(f"| {key[0]} | {key[1]} | {key[2]} | {score['runs']} | "
                   f"{score['hits']} | {score['misses']} | {score['extra']} | "
                   f"{score['seconds']/score['runs']:.2f} |")
    deviations = []
    for row in rows:
        case = manifest.get(row["audio"])
        if not case:
            continue
        text = " ".join(s["text"] for s in row["processed"].get("final", []))
        for key, pattern in (("fitu", r"(?<!\w)(?:фиту|fitu)(?!\w)"),
                             ("bguir", r"(?<!\w)(?:бгуир|bguir)(?!\w)")):
            observed = len(re.findall(pattern, text, re.I))
            expected = case["expected"][key]
            if (expected == 0 and observed) or (expected and observed == 0):
                deviations.append((row, case, key, observed, expected))
    out += ["", "*WER/CER рассчитываются только для файлов с исправленным текстом. Для коротких",
            "диагностических фрагментов нужны отдельные эталоны по имени клипа.", "",
            "## Отклонения на предварительно размеченных фрагментах", "",
            f"Найдено: {len(deviations)}. Разметка пока требует проверки владельцем записей."]
    for row, case, key, observed, expected in deviations[:100]:
        raw_text, clean_text, _ = stage_texts(row)
        raw_count = term_count(raw_text, key)
        clean_count = term_count(clean_text, key)
        cause = ("очистка" if raw_count != clean_count
                 else "словарь" if clean_count != observed else "модель")
        out.append(f"- `{row['id']}` — {Path(row['model']).name}, {row['phase']}/{row['label']}, "
                   f"{key}: ожидалось ≥{expected}, сырой/очищенный/итоговый "
                   f"{raw_count}/{clean_count}/{observed}, этап «{cause}»; "
                   f"[запись](<{case['source']}>) {case['from']/1000:g}–{case['to']/1000:g} с")
    out += ["",
            "## Ошибки процесса", ""]
    failures = [r for r in rows if r["exit_code"] != 0 or r["processed"].get("error")]
    if failures:
        for r in failures:
            out.append(f"- `{r['id']}` — {Path(r['model']).name}, {Path(r['audio']).name}, "
                       f"{r['phase']}/{r['label']}, код {r['exit_code']}; {r['stderr_tail'][-250:]}")
    else:
        out.append("Ошибок процесса пока нет.")
    out += ["", "## Путь к подробностям", "",
            "`runs.jsonl` содержит параметры, команды, время, память, очищенные сегменты,",
            "каждую замену и путь к исходному JSON движка. Все времена сегментов — в миллисекундах."]
    target = OUTPUT / "report.md"
    target.write_text("\n".join(out) + "\n")
    print(target)


def command_reprocess(_args):
    path = OUTPUT / "runs.jsonl"
    if not path.exists():
        raise RuntimeError("Сначала запустите прогоны моделей")
    current = settings().get("vocabulary", [])
    enabled = [dict(item) for item in current]
    canonical = [dict(item) for item in current]
    for item in enabled:
        if item.get("phrase", "").upper() in TERMS:
            item["enabled"] = True
    for item in canonical:
        if item.get("phrase", "").upper() in TERMS:
            item["enabled"] = True
            item["replacement"] = item["phrase"].upper()
    if not any(item.get("phrase", "").upper() == "ФИТУ" for item in enabled):
        enabled.append({"id": "asr-fitu", "phrase": "ФИТУ", "replacement": "ФИТУ",
                        "enabled": True, "isPriority": False})
        canonical.append({"id": "asr-fitu", "phrase": "ФИТУ", "replacement": "ФИТУ",
                          "enabled": True, "isPriority": False})
    post = Postprocessor()
    out = OUTPUT / "postprocess.jsonl"
    try:
        with out.open("w") as f:
            for line in path.read_text().splitlines():
                row = json.loads(line)
                if not row.get("raw_path"):
                    continue
                raw = Path(row["raw_path"]).read_text()
                kind = model_kind(Path(row["model"]))
                if kind == "whisper" and row.get("backend") == "server":
                    raw = cli_shape_from_verbose(raw)
                variants = {
                    "off": post.process(kind, raw, []),
                    "current": post.process(kind, raw, current),
                    "existing_enabled": post.process(kind, raw, enabled),
                    "canonical_terms": post.process(kind, raw, canonical),
                }
                f.write(json.dumps({"id": row["id"], "variants": variants}, ensure_ascii=False) + "\n")
    finally:
        post.close()
    print(f"Словарные варианты: {out}")


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def server_request(port, wav, fields=None, endpoint="/inference"):
    fields = fields or {"response_format": "json", "language": "auto"}
    boundary = "tsukiko_asr_stress"
    parts = []
    for name, value in fields.items():
        parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n")
    prefix = ("".join(parts) +
              f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"test.wav\"\r\n"
              "Content-Type: audio/wav\r\n\r\n").encode()
    suffix = f"\r\n--{boundary}--\r\n".encode()
    body = prefix + wav.read_bytes() + suffix
    req = urllib.request.Request(f"http://127.0.0.1:{port}{endpoint}", data=body,
                                 headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    return urllib.request.urlopen(req, timeout=900).read().decode()


def start_whisper_server(model, no_timestamps=False, vad=False):
    port = free_port()
    cmd = [str(ENGINE / "tsukiko-dictation"), "-m", str(model), "-l", "auto",
           "-t", "4", "--host", "127.0.0.1", "--port", str(port),
           "-bs", "5", "-bo", "5", "-mc", "0"]
    if no_timestamps:
        cmd.append("-nt")
    if VAD.exists():
        cmd += ["-vm", str(VAD)]
        if vad:
            cmd.append("--vad")
    server = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    start = time.monotonic()
    while time.monotonic() - start < 120:
        if server.poll() is not None:
            raise RuntimeError(f"Сервер завершился: {server.returncode}")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=.5):
                return server, port, cmd
        except OSError:
            time.sleep(.5)
    server.kill()
    server.wait()
    raise TimeoutError("Сервер не поднялся за 120 секунд")


def stop_server(server):
    if server is None:
        return
    server.terminate()
    try:
        server.wait(timeout=5)
    except subprocess.TimeoutExpired:
        server.kill()
        server.wait()


def start_nemo_server(model):
    port = free_port()
    cmd = [str(NEMO), "serve", "--asr-model", str(model), "--host", "127.0.0.1",
           "--port", str(port), "--max-upload-mb", "4096", "--no-ui", "--no-warmup",
           "--asr.batching.enabled=false"]
    server = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    start = time.monotonic()
    while time.monotonic() - start < 120:
        if server.poll() is not None:
            raise RuntimeError(f"NeMo-сервер завершился: {server.returncode}")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=.5):
                return server, port, cmd
        except OSError:
            time.sleep(.5)
    server.kill()
    server.wait()
    raise TimeoutError("NeMo-сервер не поднялся за 120 секунд")


def server_fields(job):
    fields = {"response_format": "verbose_json", "language": job["lang"],
              "max_context": "0", "token_timestamps": "false",
              "carry_initial_prompt": str(job["label"] != "no_carry").lower()}
    if job["prompt"]:
        fields["prompt"] = job["prompt"]
    extra = job["extra"]
    mapping = {"-bs": "beam_size", "-bo": "best_of", "-tp": "temperature",
               "-nth": "no_speech_thold", "-lpt": "logprob_thold", "-vt": "vad_threshold"}
    for i, arg in enumerate(extra):
        if arg in mapping:
            fields[mapping[arg]] = extra[i + 1]
    if "-nf" in extra:
        fields["temperature_inc"] = "0"
    if "--vad" in extra:
        fields["vad"] = "true"
    return fields


def cli_shape_from_verbose(raw):
    data = json.loads(raw)
    return json.dumps({"result": {"language": data.get("language", "?")},
                       "transcription": [
                           {"offsets": {"from": round(s.get("start", 0) * 1000),
                                        "to": round(s.get("end", 0) * 1000)},
                            "text": s.get("text", "")}
                           for s in data.get("segments", [])]}, ensure_ascii=False)


def command_dictation(args):
    OUTPUT.mkdir(parents=True, exist_ok=True)
    rawdir = OUTPUT / "raw"
    rawdir.mkdir(exist_ok=True)
    post = Postprocessor()
    vocabulary = settings().get("vocabulary", [])
    versions = engine_versions()
    dictation_file = SETTINGS.parent / "dictation.json"
    dictation_settings = json.loads(dictation_file.read_text()) if dictation_file.exists() else {}
    variants = {"none": "", "current": dictation_settings.get("prompt", ""),
                "terms": "ФИТУ, БГУИР", "phonetic": "фиту, бгуир"}
    variants["bounded_current"] = post.effective_prompt(variants["current"], vocabulary)
    completed = 0
    try:
        chosen_models = [m for m in models() if not args.model or args.model in m.name]
        chosen_audios = [a for a in files() if not args.audio or args.audio in a.name]
        for model in chosen_models:
            kind = model_kind(model)
            token_counts = {}
            budget = None
            if kind == "whisper":
                tokenizer = Tokenizer(model)
                try:
                    budget = tokenizer.budget
                    token_counts = {name: tokenizer.count(prompt) for name, prompt in variants.items()}
                finally:
                    tokenizer.close()
            for label, prompt in variants.items():
                if args.variant and label not in args.variant:
                    continue
                if kind == "nemo" and prompt and not supports_prompt(model):
                    continue
                if kind == "whisper":
                    server, port, cmd = start_whisper_server(model, no_timestamps=True,
                                                             vad=VAD.exists())
                else:
                    server, port, cmd = start_nemo_server(model)
                try:
                    for audio in chosen_audios:
                        wav = wav_for(audio)
                        job = {"model": str(model), "audio": str(audio), "label": label,
                               "prompt": prompt, "mode": "dictation"}
                        jobid = digest(job)
                        started = time.monotonic()
                        try:
                            fields = {"response_format": "json", "language": "auto"}
                            if kind == "nemo":
                                fields["automatic_punctuation"] = "true"
                            if prompt:
                                fields["prompt"] = prompt
                                if kind == "whisper":
                                    fields["carry_initial_prompt"] = "true"
                            raw = server_request(port, wav, fields,
                                                 "/inference" if kind == "whisper" else "/v1/audio/transcriptions")
                            code, error = 0, ""
                        except Exception as e:
                            raw, code, error = "", 1, str(e)
                        seconds = round(time.monotonic() - started, 3)
                        if raw:
                            (rawdir / f"{jobid}.json").write_text(raw)
                        processed = post.process("dictation", raw, vocabulary) if raw else {}
                        row = {"id": jobid, **job, "command": cmd,
                               "engine_version": versions[kind],
                               "model_size": model.stat().st_size,
                               "prompt_tokens": token_counts.get(label),
                               "prompt_budget": budget,
                               "raw_path": str(rawdir / f"{jobid}.json") if raw else None,
                               "processed": processed, "seconds": seconds,
                               "physical_footprint_mb": footprint_mb(server.pid),
                               "exit_code": code, "error": error}
                        with (OUTPUT / "dictation.jsonl").open("a") as f:
                            f.write(json.dumps(row, ensure_ascii=False) + "\n")
                        print(f"Диктовка: {model.name} {label} {audio.name}: {code}, {seconds}s", flush=True)
                        completed += 1
                        if args.limit and completed >= args.limit:
                            return
                finally:
                    stop_server(server)
    finally:
        post.close()


def synthetic_wavs():
    fixture = OUTPUT / "synthetic"
    fixture.mkdir(parents=True, exist_ok=True)
    yield "ru_smoke", ROOT / "test/fixtures/ru_smoke.wav"
    yield "ru_near_homophones", ROOT / "test/fixtures/ru_near_homophones.wav"
    yield "ru_terms", ROOT / "test/fixtures/ru_terms.wav"
    random.seed(42)
    for label, length, mode in (("silence", 45, "silence"),
                                ("noise", 10, "noise"),
                                ("clipped", 10, "clipped")):
        path = fixture / f"{label}.wav"
        if not path.exists():
            with wave.open(str(path), "wb") as out:
                out.setnchannels(1)
                out.setsampwidth(2)
                out.setframerate(16000)
                data = bytearray()
                for _ in range(length * 16000):
                    value = 0 if mode == "silence" else random.randint(-9000, 9000)
                    if mode == "clipped":
                        value = 32767 if value >= 0 else -32768
                    data += value.to_bytes(2, "little", signed=True)
                out.writeframes(data)
        yield label, path
    with wave.open(str(ROOT / "test/fixtures/ru_terms.wav")) as source:
        speech = source.readframes(source.getnframes())
        rate = source.getframerate()
    for label, transform in (
        ("clipped_speech", lambda value: max(-32768, min(32767, value * 12))),
        ("speech_with_noise", lambda value: max(-32768, min(32767, value + random.randint(-1800, 1800)))),
    ):
        path = fixture / f"{label}.wav"
        if not path.exists():
            pcm = bytearray()
            for i in range(0, len(speech), 2):
                value = int.from_bytes(speech[i:i + 2], "little", signed=True)
                pcm += transform(value).to_bytes(2, "little", signed=True)
            with wave.open(str(path), "wb") as out:
                out.setnchannels(1)
                out.setsampwidth(2)
                out.setframerate(rate)
                out.writeframes(pcm)
        yield label, path
    silence = b"\0\0" * rate
    composed = {
        "long_pause": speech + silence * 35 + speech,
        "window_boundary": silence * 29 + speech + silence * 29 + speech,
        "repeated_speech": (speech + silence) * 8,
    }
    for label, pcm in composed.items():
        path = fixture / f"{label}.wav"
        if not path.exists():
            with wave.open(str(path), "wb") as out:
                out.setnchannels(1)
                out.setsampwidth(2)
                out.setframerate(rate)
                out.writeframes(pcm)
        yield label, path
    damaged = fixture / "truncated.wav"
    damaged.write_bytes((fixture / "noise.wav").read_bytes()[:100])
    yield "truncated", damaged
    invalid = fixture / "invalid.wav"
    invalid.write_bytes(b"not audio")
    yield "invalid", invalid


def command_crash(_args):
    OUTPUT.mkdir(parents=True, exist_ok=True)
    versions = engine_versions()
    for label, wav in synthetic_wavs():
        for model in models():
            job = {"model": str(model), "audio": str(wav), "lang": "auto",
                   "prompt": "", "extra": [], "label": label}
            with tempfile.TemporaryDirectory(prefix="tsukiko-crash-") as tmp:
                cmd, code, error, seconds, peak = invoke(job, wav, Path(tmp) / "out")
                rawfile = Path(tmp) / "out.json"
                raw = rawfile.read_text() if rawfile.exists() else ""
            row = {"id": digest(job), **job, "command": cmd,
                   "engine_version": versions[model_kind(model)],
                   "model_size": model.stat().st_size, "exit_code": code,
                   "stderr_tail": error, "seconds": seconds, "peak_rss_kb": peak,
                   "raw": raw}
            with (OUTPUT / "crash.jsonl").open("a") as f:
                f.write(json.dumps(row, ensure_ascii=False) + "\n")
            print(f"Аварийный тест: {model.name} {label}: {code}, {seconds}s", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    run = commands.add_parser("run")
    run.add_argument("--phase", choices=("baseline", "saturation", "repetition", "knobs", "all"), default="all")
    run.add_argument("--repeats", type=int, default=3)
    run.add_argument("--limit", type=int, default=0, help="Ограничить новый прогон для быстрой проверки")
    run.add_argument("--clips", action="store_true", help="Короткие проблемные фрагменты вместо целых записей")
    run.add_argument("--clip-label", action="append", help="Проверять только фрагменты с этим ярлыком")
    run.add_argument("--backend", choices=("cli", "server"), default="cli",
                     help="Whisper через разовый CLI или прогретый сервер")
    run.add_argument("--model", action="append", help="Ограничить список моделей по части имени")
    api = commands.add_parser("api")
    api.add_argument("--limit", type=int, default=0)
    api.add_argument("--repeats", type=int, default=1)
    commands.add_parser("report")
    commands.add_parser("markdown")
    commands.add_parser("reprocess")
    dictation = commands.add_parser("dictation")
    dictation.add_argument("--limit", type=int, default=0)
    dictation.add_argument("--model", help="Часть имени модели")
    dictation.add_argument("--audio", help="Часть имени записи")
    dictation.add_argument("--variant", action="append", help="Ограничить вариант подсказки")
    commands.add_parser("crash")
    args = parser.parse_args()
    {"run": command_run, "api": command_api, "report": command_report,
     "markdown": command_markdown,
     "reprocess": command_reprocess,
     "dictation": command_dictation, "crash": command_crash}[args.command](args)


if __name__ == "__main__":
    main()
