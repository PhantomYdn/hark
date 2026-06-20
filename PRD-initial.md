# Product Requirements Document (PRD)

## Product: Hark
**Version:** 1.0 (MVP)
**Date:** 2026-06-12
**Author:** TBD

---

## 1. Overview

Hark is a native macOS command-line utility, shipped as a single Swift binary, that captures audio from physical input sources (microphones) and from the system itself — all system audio or the output of specific applications — using Core Audio process taps (macOS 14.4+). No third-party virtual audio driver (e.g., BlackHole) is required. Recordings are saved locally and serve as the foundation for downstream audio processing workflows, most notably automatic speech-to-text transcription.

The tool strictly follows Unix/Linux design patterns, treating audio as a stream that can be manipulated, piped, and extended by other command-line programs. The primary goal is to provide a simple, scriptable, and composable replacement for GUI-based audio recording, enabling users to automate meeting recordings, create transcription pipelines, or build custom audio-processing chains without leaving the terminal.

---

## 2. Objectives & Success Criteria

| Objective | Success Criteria |
|-----------|------------------|
| Enable reliable capture of both microphone and system/app audio (e.g., Zoom, Teams) on macOS without third-party drivers | Users can record their voice and the counterparty's audio simultaneously with < 200 ms latency drift, measured as offset between mic and system tracks over a 60-minute dual-source recording |
| Provide a Unix-compatible interface that integrates with standard pipes, redirections, and signal handling | All audio data can be streamed via stdout; the CLI responds to SIGINT/SIGTERM by gracefully closing the output file |
| Simplify the transcription pipeline | Output files (WAV, M4A, FLAC, MP3, Opus) can be directly fed to `whisper.cpp`, Fabric AI, or cloud-based transcription services without extra conversion |
| Minimise dependencies and footprint | The tool is shipped as a single Swift binary requiring only macOS baseline frameworks (CoreAudio, AudioToolbox, AVFoundation); no third-party audio driver installation |
| Follow the "do one thing well" philosophy | Each CLI command performs exactly one task (list devices, list apps, record, convert, etc.); complex workflows are built by chaining these commands |

---

## 3. Target Audience

- **Software developers** who want to automate meeting recordings or build audio-enabled scripts.
- **Data scientists / ML engineers** who need a reliable way to collect audio corpora and pipe them into transcription models.
- **Power users & system administrators** comfortable with the terminal who require a lightweight, scriptable recording tool.
- **Open-source contributors** who can extend the tool by adding new output formats or post-processing hooks.

---

## 4. Features

### 4.1 MVP Features (v1.0)

| # | Feature | Priority | Description |
|---|---------|----------|-------------|
| 1 | Device & application enumeration | P0 | List all input/output audio devices (UID, name, channels, sample rates) and running applications capturable via process taps (name, bundle ID, PID). JSON output for scripting. |
| 2 | Audio capture from any single source | P0 | Record from a specified input device (built-in microphone, USB headset). Configurable sample rate, bit-depth, and channel count. Falls back to default input device. |
| 3 | System & per-app audio capture (Core Audio taps) | P0 | Capture all system audio (`--system`), specific application(s) (`--app`, repeatable), or everything except listed apps (`--exclude-app`). Mixed mic + system capture via `--mix`. |
| 4 | File output — native formats | P0 | Save to WAV (PCM), M4A/AAC, or FLAC using native CoreAudio encoders. |
| 5 | Stream-mode operation | P0 | Output raw audio samples to stdout (e.g., `hark record | ffmpeg ...`); accept audio from stdin for transcoding/transcription. |
| 6 | Signal handling & graceful shutdown | P0 | On SIGINT (Ctrl+C) or SIGTERM, finalise the output file header so it remains playable. |
| 7 | File output — additional formats | P1 | MP3 (statically linked LAME) and Ogg/Opus (statically linked libopus/libogg). All output formats verified compatible with major transcription tools (whisper.cpp, Fabric AI, cloud APIs). |
| 8 | Time-based chunking | P1 | Split recordings into sequential files by duration (`--split duration=SEC`). |
| 9 | Transcription integration | P1 | `transcribe` sub-command that pipes recorded audio directly to a local transcription engine (e.g., `whisper.cpp`), avoiding temporary files when desired. |
| 10 | Silence-based splitting | P2 | Split on continuous silence exceeding a configurable threshold (`--split silence=SEC`). |
| 11 | Basic metadata embedding | P2 | Store recording start time, source name, and sample rate in WAV INFO, MP4, or ID3 tags. |

### 4.2 Post-MVP Features (Future)

- **Daemon/agent mode**: launchd-managed background service for scheduled and unattended recording, with IPC for client commands.
- **Silence-based voice activity detection** for trimming.
- **Real-time streaming** to a network socket or HTTP endpoint.
- **Multi-channel mapping** (e.g., separate tracks for mic and system audio).
- **Plugin system** to inject custom DSP filters (EQ, noise suppression) as middleware.
- **Configuration profiles** to store default sources, formats, and transcription settings.
- **Cloud transcription backends** (Deepgram, Google) selectable via a flag.

---

## 5. User Stories

### US01 — Quick voice notes
As a **developer**, I want to quickly capture my microphone input for five minutes and save it as an MP3, so that I can review my spoken notes later without opening Audacity.
- Acceptance Criteria:
  - [ ] `hark record -t 300 -o notes.mp3` records from the default input device without specifying a device UID
  - [ ] Recording stops automatically after 300 seconds with exit code 0
  - [ ] Resulting file plays correctly in QuickTime/`afplay` and duration is 300 s ± 1 s

### US02 — Record a meeting without echo
As a **developer**, I want to record the audio from an ongoing Zoom call without echoing my own voice, so that I can later transcribe the meeting and extract action items.
- Acceptance Criteria:
  - [ ] `hark apps` lists the running Zoom process with its bundle ID
  - [ ] `hark record --app us.zoom.xos -o call.m4a` captures only Zoom's output audio
  - [ ] The user's own microphone is not captured unless `--mix` is explicitly given
  - [ ] First-run macOS "System Audio Recording" permission prompt and approval flow is documented

### US03 — Zero-touch transcription pipeline
As a **data engineer**, I want to pipe recorded audio directly to a speech-to-text engine, so that I can build a fully automated transcription pipeline with zero manual steps.
- Acceptance Criteria:
  - [ ] `hark record -t 60 --stdout | hark transcribe -i -` produces transcript text on stdout
  - [ ] No temporary files are created in stream mode
  - [ ] A failure in the transcription engine propagates a non-zero exit code through the pipeline

### US04 — Manageable chunks
As a **power user**, I want to split a long recording into chunks based on silence, so that I can easily manage large audio files and focus on important segments.
- Acceptance Criteria:
  - [ ] `--split silence=1.5` produces sequentially numbered files (`name_001.wav`, `name_002.wav`, …)
  - [ ] Each chunk is independently playable with a valid, finalised header
  - [ ] The silence detection threshold (dBFS) is configurable

### US05 — Unattended compliance recording
As a **sysadmin**, I want to install the tool via Homebrew and have it run in a crontab, so that I can automatically record every team stand-up for compliance.
- Acceptance Criteria:
  - [ ] `brew install hark` installs a working, signed binary
  - [ ] Once the TCC permission is granted, recording runs unattended from cron/launchd without GUI interaction
  - [ ] Exit codes and stderr logging are suitable for cron-based monitoring and alerting

### US06 — Script-parseable enumeration
- [ ] As an **ML researcher**, I want to list all available audio devices and capturable applications in a script-parseable format, so that I can write robust automation that adapts to different machine setups.
- Acceptance Criteria:
  - [ ] `hark devices --json` outputs valid JSON with UID, name, channel count, and sample rates
  - [ ] `hark apps --json` outputs valid JSON with name, bundle ID, and PID
  - [ ] Commands exit 0 with an empty array when nothing is found

### US07 — Focused app capture
As a **developer**, I want to capture audio from one specific app while excluding others, so that my recording contains no notification sounds or unrelated audio.
- Acceptance Criteria:
  - [ ] `--app` is repeatable to include multiple applications in one capture
  - [ ] `--exclude-app` captures all system audio except the listed applications
  - [ ] Notification sounds from excluded apps are absent from the resulting recording

---

## 6. Functional Requirements

### 6.1 CLI Commands & Flags

```
hark {devices|apps|record|transcribe|convert|info} [OPTIONS]
```

**`hark devices`**
- `--list-inputs` / `--list-outputs`
- `--json` : output in JSON for scripting.

**`hark apps`**
- List running applications whose audio can be captured via process taps.
- Output: application name, bundle ID, PID.
- `--json` : output in JSON for scripting.

**`hark record [SOURCE] -o <output_file> [OPTIONS]`**

Source selection (exactly one mode; mic capture is the default):
- `-d, --device UID` : input device UID (defaults to system default input).
- `--system` : capture all system audio via a global process tap.
- `--app ID` : capture a specific application's audio by bundle ID or PID (repeatable).
- `--exclude-app ID` : capture all system audio except the listed application(s) (repeatable).
- `--mix` : additionally mix the microphone (default or `-d` device) into a system/app capture.

Output & format:
- `-o, --output PATH` : output file path; extension determines format (`.wav`, `.m4a`, `.flac`, `.mp3`, `.opus`). If omitted, output to stdout.
- `--format f` : force format `wav`, `m4a`, `flac`, `mp3`, `opus`.
- `-r, --rate Hz` : sample rate (default 44100).
- `-b, --bits 16|24|32` (default 16).
- `-c, --channels 1|2` (default based on source).
- `-t, --duration SEC` : stop recording after SEC seconds.
- `--split duration=SEC` : start a new file every SEC seconds (filename with sequence).
- `--split silence=SEC` : split on silence exceeding SEC seconds (configurable dBFS threshold).
- `--no-output` : run in "dry-run" mode, no file written (useful for testing).
- `--stdout` : force raw PCM output to stdout (implied if no `-o`).

**`hark transcribe -i <input_file|-|source> [OPTIONS]`**
- `-i, --input PATH|"-"|UID` : file path, `-` for stdin, or a device UID to capture and transcribe on the fly.
- `-e, --engine whisper|cloud` : transcription engine (default `whisper`).
- `--model PATH` : path to Whisper model.
- `--language en` : specify language.
- `--output-format txt|srt|json` : transcription output format.
- Integration: if a device UID is given, record in memory, pipe to engine, output text to stdout.

**`hark convert -i <input> -o <output> [OPTIONS]`**
- Simple format conversion (WAV → M4A, FLAC → MP3, etc.) reusing CoreAudio codecs where available.

**`hark info -i <input>`**
- Print duration, sample rate, channels, and metadata of an audio file.

All commands accept `-h, --help` and `-v, --verbose`.

### 6.2 Source Handling

- Use CoreAudio APIs to enumerate AudioDeviceIDs; automatically exclude inactive devices.
- Use Core Audio process taps (`CATapDescription` / `AudioHardwareCreateProcessTap`, macOS 14.4+) for system and per-app capture; no virtual audio driver required.
- Tap lifecycle: taps are created at recording start and destroyed on stop; if a tapped application quits mid-recording, the recording finalises cleanly and reports it on stderr.
- Fallback to default input device when no source flag is given with `record`.

### 6.3 Streaming & Pipes

- `record` without `-o` outputs raw 16-bit PCM (WAV header when piped to file) or a streamable WAV container (if `--stdout` is used with header). The stream must play nicely with `ffmpeg`, `sox`, and other tools.
- `transcribe` with `-i -` reads raw audio from stdin, handling on-the-fly transcription.
- Exit code 0 on success, non-zero on failure (explicit error codes documented).

### 6.4 Format Support

- Read: WAV, AIFF, CAF, M4A, FLAC.
- Write (P0): WAV (PCM), M4A/AAC, FLAC — native CoreAudio encoders.
- Write (P1): MP3 (statically linked LAME), Ogg/Opus (statically linked libopus/libogg).
- All write formats must be accepted as-is by major transcription tools: `whisper.cpp`, Fabric AI, OpenAI/cloud transcription APIs.
- Metadata: WAV INFO chunk, MP4 metadata atoms for M4A, ID3v2 for MP3.

### 6.5 Chunking & Splitting

- Time-based: `--split duration=300` creates `meeting_001.wav`, `meeting_002.wav`, …
- Silence-based: `--split silence=1.5` triggers a new file after 1.5 seconds of continuous silence (configurable threshold).
- Both modes must flush the file header correctly and continue recording.

### 6.6 Transcription Integration

- When using `transcribe` with a source, the audio capture runs synchronously; transcription begins after recording ends, or in streaming mode if engine supports it (v1 does not require streaming transcription, just batch post-processing).
- If `--engine whisper`, call the system-installed `whisper` binary; if not found, provide a clear error message with installation instructions (e.g., `brew install whisper-cpp`).
- STDERR from the transcription engine is passed through for debugging.

---

## 7. Non-Functional Requirements

| Category | Requirement |
|----------|-------------|
| **Performance** | Recording must use < 3% CPU on an Apple Silicon Mac (16 kHz mono); buffering delays < 100 ms. |
| **Reliability** | 24-hour continuous recording must produce a valid, non-corrupted file when terminated via SIGINT/SIGTERM. Resilience to hard kills (SIGKILL, power loss) is parked — see Open Questions. |
| **Usability** | CLI help and error messages are clear, include examples, and follow POSIX utility conventions. |
| **Compatibility** | macOS 14.4 (Sonoma) and later — required by the Core Audio process-tap API; both Intel and Apple Silicon. |
| **Security & Privacy** | No network calls by default; cloud transcription backends are opt-in and use HTTPS with user-provided API keys. System/app audio capture requires the macOS "System Audio Recording" TCC permission; the prompt and approval flow (including terminal-attributed permission for unbundled CLIs) must be documented. |
| **Maintainability** | Single Swift binary built with SwiftPM; modular targets: `DeviceManager`, `TapEngine`, `Encoders`, `CLI`. Well-documented code. |
| **Installability** | Distributed via Homebrew (`brew install hark`) and direct download from GitHub Releases; binary is signed and notarized so TCC permission flows work cleanly. |
| **Auditability** | All recorded file paths and durations are logged to STDERR when `-v` is enabled. |

---

## 8. Success Metrics (KPIs)

- **Adoption:** 1000 Homebrew installs within 3 months of public release.
- **Pipeline integration:** At least two open-source transcription projects (e.g., `whisper.cpp`, `faster-whisper`) officially list Hark as a recommended capture tool.
- **Reliability:** Crash-free session rate > 99.5%, measured via strictly opt-in telemetry (consistent with the "no network calls by default" security requirement; mechanism TBD — see Open Questions).
- **Community engagement:** Minimum 10 pull requests contributed from external developers within 6 months (discouraging feature bloat, but demonstrating extendability).

---

## 9. Timeline & Milestones

| Milestone | Deliverables | Target | Dependencies |
|-----------|--------------|--------|--------------|
| **M1 – Core Capture** | Swift/SwiftPM project skeleton, device & app enumeration (`devices`, `apps`), mic recording to WAV, signal handling, stdout streaming | Week 1–2 | — |
| **M2 – System Audio** | Core Audio process taps: `--system`, `--app`, `--exclude-app`, `--mix`; TCC permission flow & docs | Week 3–4 | M1 |
| **M3 – Formats & Chunking** | M4A/FLAC output, MP3/Opus (static libs), time-based splitting, `convert` command | Week 5–6 | M1 |
| **M4 – Transcription MVP** | `transcribe` sub-command with local Whisper support; stdin/file/source input | Week 7 | M3 |
| **M5 – Polish & Release** | Code signing & notarization, Homebrew formula, man page, example scripts, CI/CD, public beta | Week 8–9 | M2, M3, M4 |
| **Post-MVP** | Daemon mode (launchd scheduled recording), silence VAD, streaming transcription, cloud backends, configuration profiles | Ongoing | M5 |

---

## 10. Open Questions & Assumptions

1. **Crash resilience (parked):** How should recordings survive hard kills (SIGKILL, power loss)? Candidates: periodic header flush every N seconds, or a `hark repair` subcommand for truncated files. Decision deferred.
2. **Whisper bundling:** Will the tool bundle a transcription engine or expect the user to install it separately? (Assumption: no bundling to keep the binary small; document external dependencies.)
3. **Telemetry mechanism:** What opt-in mechanism (if any) will measure the crash-free-rate KPI without violating the no-network-by-default principle?
4. **TCC for unbundled CLI:** Confirm the exact permission-attribution behaviour for a signed standalone binary vs. terminal-attributed permission, and document the recommended setup.

### Resolved (2026-06-12)
- ~~Language/stack~~ → **Swift**, single binary, SwiftPM modular targets.
- ~~System audio without a virtual device~~ → **Core Audio process taps** (macOS 14.4+); BlackHole no longer required.
- ~~Product/binary naming~~ → **hark**.

---

**Document Status:** Draft for review
**Next Steps:** Fill in Author field; review drafted acceptance criteria (US01–US07); decide crash-resilience strategy (Open Question 1).
