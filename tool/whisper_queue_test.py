#!/usr/bin/env python3
"""Exercise the bundled Whisper engine, including a ten-recording warm queue.

Uses public repository fixtures and a pinned multilingual tiny model, never the
microphone or app settings. Encoder call counts detect redundant work without
flaky timing thresholds. --model also permits testing a production-sized model.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import statistics
import subprocess
import tempfile
import time
import urllib.request
import wave

ROOT = Path(__file__).resolve().parent.parent
MODEL_SHA = 'be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21'
MODEL_URL = 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin'


def test_model():
    path = ROOT / 'build/test-models/ggml-tiny.bin'
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        temporary = path.with_suffix('.download')
        urllib.request.urlretrieve(MODEL_URL, temporary)
        temporary.replace(path)
    if hashlib.sha256(path.read_bytes()).hexdigest() != MODEL_SHA:
        raise RuntimeError('Whisper test model checksum mismatch')
    return path


def inference(port, file):
    boundary = 'tsukiko-queue-regression'
    body = b''
    for name, value in [('response_format', 'json'), ('language', 'auto'), ('temperature_inc', '0')]:
        body += (f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n').encode()
    body += (f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="audio.wav"\r\nContent-Type: audio/wav\r\n\r\n').encode()
    body += file.read_bytes() + f'\r\n--{boundary}--\r\n'.encode()
    request = urllib.request.Request(f'http://127.0.0.1:{port}/inference', data=body,
                                    headers={'Content-Type': f'multipart/form-data; boundary={boundary}'})
    with urllib.request.urlopen(request, timeout=120) as response:
        return json.load(response)['text'].strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cli', type=Path, required=True)
    parser.add_argument('--server', type=Path, required=True)
    parser.add_argument('--model', type=Path)
    args = parser.parse_args()
    model = args.model or test_model()
    fixtures = [ROOT / f'test/fixtures/{name}.wav' for name in ('ru_smoke', 'ru_terms', 'ru_near_homophones')]
    # Freeze stochastic temperature fallback for repeatability in this test.
    base = ['-m', str(model), '-t', '2', '-ng', '-nt', '-mc', '0', '-bs', '5', '-bo', '5', '-nf']
    with tempfile.TemporaryDirectory(prefix='tsukiko-whisper-queue-') as tmp:
        tmp = Path(tmp)
        # A long request must encode every subsequent window, even after reuse.
        long = tmp / 'long.wav'
        with wave.open(str(fixtures[0]), 'rb') as source:
            frames = source.readframes(source.getnframes())
            with wave.open(str(long), 'wb') as target:
                target.setparams(source.getparams())
                target.writeframes(frames * 13)
        def cli(file, language, offset=0, context=0):
            output = tmp / 'transcript'
            result = subprocess.run([str(args.cli.resolve()), *base, '-l', language,
                                     '-ot', str(offset), '-ac', str(context), '-f', str(file), '-otxt', '-of', str(output)],
                                    capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=180)
            if result.returncode:
                raise RuntimeError(result.stderr)
            counts = re.findall(r'encode time\s*=.*?/\s*(\d+) runs', result.stderr)
            if not counts:
                raise AssertionError('Missing encoder timing counters')
            return int(counts[-1]), output.with_suffix('.txt').read_text(encoding='utf-8')
        auto_count, auto_text = cli(fixtures[0], 'auto')
        fixed_count, fixed_text = cli(fixtures[0], 'ru')
        assert auto_count == fixed_count == 1, (auto_count, fixed_count)
        assert auto_text == fixed_text and auto_text.strip(), 'Reuse changed the transcript'
        offset_count, _ = cli(fixtures[0], 'auto', 100)
        assert offset_count == 2, 'Nonzero seek must not reuse the first window'
        context_count, _ = cli(fixtures[0], 'auto', context=750)
        assert context_count == 2, 'Different audio context must encode again'
        long_auto, long_text = cli(long, 'auto')
        long_fixed, fixed_long_text = cli(long, 'ru')
        assert long_auto == long_fixed and long_auto > 1, (long_auto, long_fixed)
        assert long_text == fixed_long_text, 'Subsequent windows changed'
        print(f'Encoder checks: short={auto_count}, offset={offset_count}, long={long_auto}', flush=True)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        log_path = tmp / 'server.log'
        with log_path.open('w', encoding='utf-8') as log:
            process = subprocess.Popen([str(args.server.resolve()), *base, '-l', 'auto',
                                        '--host', '127.0.0.1', '--port', str(port)], stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 90
                while True:
                    try:
                        with socket.create_connection(('127.0.0.1', port), timeout=.1):
                            break
                    except OSError:
                        if process.poll() is not None or time.monotonic() > deadline:
                            raise RuntimeError('Test server failed to start')
                        time.sleep(.05)
                durations = []
                for i in range(10):
                    file = fixtures[i % len(fixtures)]
                    start = time.monotonic()
                    text = inference(port, file)
                    durations.append(round((time.monotonic() - start) * 1000))
                    assert text, (i, file.name, 'Empty result')
                    if file == fixtures[0]:
                        assert text == auto_text.strip(), 'Cross-recording state leaked'
                    # Tiny mishears the rare vocabulary in the other fixtures;
                    # its beam ties can differ slightly even in the stock engine.
                    assert process.poll() is None, 'Server restarted inside queue'
                print(f'Warm FIFO: 10 results, one process; median {statistics.median(durations)} ms', flush=True)
            finally:
                process.terminate()
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        if os.name != 'nt':  # Windows TerminateProcess does not run signal cleanup.
            counts = re.findall(r'encode time\s*=.*?/\s*(\d+) runs', log_path.read_text())
            assert counts and int(counts[-1]) == 10, counts
    print('Whisper queue regression: all checks passed')


if __name__ == '__main__':
    main()
