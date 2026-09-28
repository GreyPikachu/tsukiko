# Tsukiko Architecture

This document outlines the architecture, layer separation, data flow, and runtime mechanics of Tsukiko across macOS and Windows.

---

## Multi-Engine Single Process Model

Tsukiko executes as a single application process hosting multiple isolated Flutter runtime engines, each running in its own Dart isolate and driving an independent window:

| Engine | Entry Point | View / Role | Lifecycle |
| :--- | :--- | :--- | :--- |
| **Main Window** | `main()` | File queue, transcript inspector, export dialogs | Launched on startup; can be hidden/closed |
| **Panel / Menu Bar** | `panelMain()` | Status bar popover, dictation trigger | Started at launch; persistent throughout session |
| **Settings** | `settingsMain()` | Application settings, model management, vocabulary | Created on first open (`⌘,` / `Ctrl+,`) |
| **HUD (Windows)** | `hudMain()` | Native non-activating floating waveform HUD | Created dynamically when recording |

> On macOS, the floating recording HUD is implemented in native SwiftUI (`RecordingHUD.swift`) to ensure a non-activating floating window that never steals keyboard focus from target applications.

### Inter-Isolate Communication

Dart isolates do not share linear memory. They communicate through two distinct channels:
1. **Settings Bus**: Persistent preferences stored in `settings.json` with an atomic file queue.
2. **Native Notification Bridge**: When one window modifies settings, it invokes `settingsChanged` over the `MethodChannel`. The native platform layer broadcasts a `reload` event to all other engine channels.

---

## Architectural Boundaries

Tsukiko strictly separates platform-dependent logic from platform-agnostic business logic:

### 1. `lib/platform/os.dart` — Operating System Abstraction

All operating system interactions that differ at the Dart level are abstracted behind the `Os` contract:

```
lib/platform/os.dart          Abstract contract (class Os) + dynamic instance selection
lib/platform/os_macos.dart    macOS: ps, pgrep, afconvert, open, ~/Library
lib/platform/os_windows.dart  Windows: tasklist, ffmpeg, explorer, %APPDATA%
```

Key platform implementations:

| Capability | macOS Implementation | Windows Implementation |
| :--- | :--- | :--- |
| **Process Inspection** | `pgrep -f` / `ps -axo` | `tasklist` / WMI |
| **Audio Container Decoding** | System `afconvert` | Bundled `ffmpeg.exe` |
| **File Manager Integration** | `open -R` | `explorer /select,` |
| **Application Data Path** | `~/Library/Application Support/app.yuko.tsukiko` | `%APPDATA%\app.yuko.tsukiko` |
| **Process Termination** | `kill` / `SIGTERM` | `TerminateProcess` / `taskkill` |
| **Modifiers** | `⌘`, `⌥`, `⇧` | `Ctrl`, `Alt`, `Shift` |

### 2. `lib/platform/bridge.dart` — Native Interop Boundary

Global keyboard shortcut interception, microphone capture, text injection, and status items run entirely via platform channels:

```
bridge.dart              Dart side of the channel (portable)
macos/Runner/*.swift     macOS native layer (Dictation.swift, TrayPanel.swift, RecordingHUD.swift)
windows/runner/*.cpp     Windows native layer (dictation_bridge.cpp, flutter_window.cpp)
```

Platform mapping:

| Subsystem | macOS | Windows |
| :--- | :--- | :--- |
| **Menu Bar / Tray** | `NSStatusItem` + `TrayPanel` | `Shell_NotifyIcon` + `PanelWindow` |
| **Global Hotkey** | `CGEventTap` | `WH_KEYBOARD_LL` (low-level hook) |
| **Text Insertion** | Accessibility API | `SendInput` (synthesized keystrokes) |
| **Audio Capture** | `AVAudioRecorder` | `miniaudio` (WASAPI) |
| **Hardware GPU** | Apple Silicon Metal | Vulkan SDK / CPU fallback |

---

## Headless CLI Tool: `tsukiko-transcribe`

In addition to the GUI engines, Tsukiko bundles a standalone CLI utility:
- Built via `dart compile exe` from `lib/cli/transcribe.dart`.
- Designed for scripts, automation, and terminal AI coding assistants (Claude Code, Antigravity, Codex).
- **Zero GUI dependency**: `core/whisper.dart`, `core/transcript.dart`, and `platform/os*.dart` are compiled completely without `package:flutter`.

```sh
# macOS
/Applications/Tsukiko.app/Contents/Helpers/tsukiko-transcribe recording.m4a --model medium --lang en

# Windows
"C:\Program Files\Tsukiko\helpers\tsukiko-transcribe.exe" recording.m4a --model medium --lang en
```

### Smart Routing
When Tsukiko desktop is running, `tsukiko-transcribe` automatically routes transcription tasks to the desktop application's worker queue via local IPC (`127.0.0.1:8756`). If the GUI is closed, it executes autonomously and writes output to `stdout`.

---

## Project Structure

```
lib/
  main.dart                  Application entry points (main, panelMain, settingsMain)

  platform/                  System isolation
    os.dart                  Operating system contract
    os_macos.dart            macOS implementation
    os_windows.dart          Windows implementation
    bridge.dart              MethodChannel bridge to native Swift/C++

  core/                      Domain logic (pure Dart, decoupled from Flutter UI)
    labels.dart              Localization keys and format identifiers
    text.dart                Pluralization, durations, language names
    library.dart             File organization and storage
    models.dart              Model discovery, validation, downloading
    whisper.dart             whisper-cli runner options
    whisper_server.dart      whisper-server streaming process management
    transcript.dart          Transcript parsers, segment data, and format renderers
    settings.dart            Settings persistence
    wakeword/                Acoustic feature extraction (MFCC), DTW, and KWS

  features/                  Feature-based UI modules
    api/                     Local HTTP/WebSocket API server (127.0.0.1:8756)
    dictation/               Dictation cubit, floating HUD, and system-wide insertion
    queue/                   Batch processing queue, player, and export sheets
    settings/                Settings window and voice calibration dialogs

  design/                    Design tokens, shared widgets, and Tsukiko mascot
```

---

## State Management

State management is built on `package:bloc`:

| Engine | State Owner | Rationale |
| :--- | :--- | :--- |
| **Main Window** | `QueueBloc` | Event-driven `Bloc` with concurrency transforms (`droppable`) |
| **Panel / Menu Bar** | `DictationCubit` | Direct actions, predictable state machine |
| **Settings** | `SettingsCubit` | Clean key-value preference updates |

- **State is immutable**: UI rebuilds are driven by value comparisons.
- **Services are decoupled**: Background processes (`WhisperServer`, `Process`) are managed outside state objects and injected via constructors for reliable unit testing.

---

## Memory and Model Lifecycle

Model weights (`1.5 GB+`) represent the heaviest resource in memory. Tsukiko employs three rules to minimize memory consumption:

1. **Persistent Streaming Server**: `whisper-server` keeps the active dictation model in memory between spoken phrases, ensuring near-instantaneous hot dictation (<500ms).
2. **Orphan Cleanup**: On startup and exit, running background helper processes are tracked via server marks and PID files to ensure zero dangling helper processes.
3. **Model Yielding**: Batch queue processing and streaming dictation share the loaded model dynamically. When dictation is triggered during batch transcription, the batch task pauses, yields the engine to the user's voice input, and resumes automatically once dictation finishes.
