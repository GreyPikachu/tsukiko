# Short dictation queue latency

The October 4, 2026 recording burst used one warm large-v3-turbo server for the
whole queue. Model unloading happened 180 seconds after the last result, so it
was not causing the delay. Each successful paste also kept the FIFO worker
waiting for a 450 ms clipboard cooldown before starting the next recognition.

Two changes remove avoidable work:

- Language detection already encodes the first audio window. Reuse its encoder
  output for transcription within the same `whisper_full_with_state` call,
  only when the audio context matches and the transcription starts at zero.
  Later windows, offsets and explicit languages follow the normal path.
- Apply the clipboard cooldown before the next clipboard change, allowing the
  next recognition to run while the receiving application consumes the paste.
  Pastes and automatic/manual dictation copies share a FIFO reservation.

The model, beam search, audio context, prompt handling and FIFO order remain
unchanged. No encoder state is reused between recordings.

## Measurement

Apple M5, large-v3-turbo, Metal, four CPU threads, auto language, beam/best-of 5,
no timestamps, max context 0, Silero VAD. Each executable ran one warm-up and
three repetitions of four public fixtures; four explicit-Russian requests
served as controls. Times are HTTP inference latency, not recording duration.
The one-second fixture is seconds 0.2–1.2 of `ru_smoke.wav`.

| Fixture | Previous median | Updated median |
| --- | ---: | ---: |
| One-second excerpt | 2,133 ms | 1,265 ms |
| `ru_smoke.wav` | 2,311 ms | 1,394 ms |
| `ru_terms.wav` | 2,272 ms | 1,333 ms |
| `ru_near_homophones.wav` | 2,243 ms | 1,390 ms |
| All 12 auto-language requests | 2,278 ms | 1,347.5 ms |

The aggregate median fell by 40.8%. All 16 measured transcripts matched the
previous executable. For 17 requests including warm-up, the encoder count fell
from 30 to 17. Clipboard cooldown is excluded from these times; removing it
from the recognition path saves an additional idle gap between queued results.
Absolute performance depends on the machine and model.

## Regression checks

`tool/whisper_queue_test.py` runs in both distribution workflows against the
actual bundled CLI and server using a checksum-pinned multilingual tiny model
on CPU. It checks encoder counts for short, offset, changed-context and long
recordings, compares short/long transcripts with explicit-language controls,
and sends ten different fixture requests through one warm server. Timing is
reported, without a machine-dependent pass/fail threshold. Stochastic fallback
is disabled only for these regression fixtures. The production benchmark above
uses the ordinary application options.

Run locally after building the engine:

```sh
python3 tool/whisper_queue_test.py \
  --cli macos/Engine/tsukiko-recognizer \
  --server macos/Engine/tsukiko-dictation
```

Flutter tests cover five/ten-item FIFO queues, cancellation, changing indicator
style during dictation, clipboard fallback, paste/copy serialization, failed
paste recovery and starting the next recognition during a paste cooldown.
Native Swift/C++ geometry tests cover the 372-point empty panel, the 420-point
queue/editor panel, preserved center and placement/scale persistence.
