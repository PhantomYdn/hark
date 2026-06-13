# Product Requirements Document (PRD)

## Product: Aural
**Version:** 1.0 (MVP)
**Date:** 2026-06-12
**Author:** TBD

---

## 1. Overview

Aural is a native macOS command-line utility, shipped as a single Swift binary, that captures audio from physical input sources (microphones) and from the system itself — all system audio or the output of specific applications — using Core Audio process taps (macOS 14.4+). No third-party virtual audio driver (e.g., BlackHole) is required. Recordings are saved locally and serve as the foundation for downstream audio processing workflows, most notably automatic speech-to-text transcription.

The tool strictly follows Unix/Linux design patterns, treating audio as a stream that can be manipulated, piped, and extended by other command-line programs. The primary goal is to provide a simple, scriptable, and composable replacement for GUI-based audio recording, enabling users to automate meeting recordings, create transcription pipelines, or build custom audio-processing chains without leaving the terminal.

---

## 2. Objectives & Success Criteria

| Objective | Success Criteria |
|-----------|------------------|
| Enable reliable capture of both microphone and system/app audio (e.g., Zoom, Teams) on macOS without third-party drivers | Users can record their voice and the counterparty's audio simultaneously with < 200 ms latency drift, measured as offset between mic and system tracks over a 60-minute dual-source recording |
| Provide a Unix-compatible interface that integrates with standard pipes, redirections, and signal handling | All audio data can be streamed via stdout; the CLI responds to SIGINT/SIGTERM by gracefully closing the output file |
| Simplify the transcription pipeline | Output files (WAV, M4A, FLAC, MP3, Opus) can be directly fed to `whisper.cpp`, Fabric AI, or cloud-based transcription services without extra conversion |
| Minimise dependencies and footprint | The tool is shipped as a single Swift binary requiring only macOS baseline frameworks (CoreAudio, AudioToolbox, AVFoundation); no third-party audio driver installation |
| Follow the "do one thing well" philosophy | The root verb captures/transcribes/transcodes via composable flags; small utility subcommands inspect the environment (list devices, list apps, file info); complex workflows are built by chaining invocations through stdin/stdout |

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
| 5 | Stream-mode operation | P0 | Stream a WAV container to stdout with `-a -` (e.g., `aural -a - \| ffmpeg ...`), or headerless PCM with `--raw`; accept audio from stdin (`-i -`) for transcoding/transcription. |
| 6 | Signal handling & graceful shutdown | P0 | On SIGINT (Ctrl+C) or SIGTERM, finalise the output file header so it remains playable. |
| 7 | File output — additional formats | P1 | MP3 (statically linked LAME) and Ogg/Opus (statically linked libopus/libogg). All output formats verified compatible with major transcription tools (whisper.cpp, Fabric AI, cloud APIs). |
| 8 | Time-based chunking | P1 | Split recordings into sequential files by duration (`--split duration=SEC`). |
| 9 | Transcription integration | P1 | Transcription is built into the root verb: any input (live capture or `-i` file/stream) can be transcribed by a local engine (e.g., `whisper.cpp`) via `-t/--transcript`. Audio and transcript can be produced in the same run (`-a rec.m4a -t notes.srt`); naming no output transcribes to stdout. |
| 12 | Live transcription | P1 | During live capture, emit the transcript incrementally — as close to runtime as possible — by segmenting the stream on natural pauses and transcribing each segment as it completes (true streaming is post-MVP). |
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
As a **developer**, I want to quickly capture my microphone input for five minutes and save it to a file, so that I can review my spoken notes later without opening Audacity.
- Acceptance Criteria:
  - [ ] `aural -a notes.m4a --duration 300` records from the default input device without specifying a device UID (and writes no transcript, since only `-a` is named)
  - [ ] Recording stops automatically after 300 seconds with exit code 0
  - [ ] Resulting file plays correctly in QuickTime/`afplay` and duration is 300 s ± 1 s

### US02 — Record a meeting without echo
As a **developer**, I want to record the audio from an ongoing Zoom call without echoing my own voice, so that I can later transcribe the meeting and extract action items.
- Acceptance Criteria:
  - [ ] `aural apps` lists the running Zoom process with its bundle ID
  - [ ] `aural --app us.zoom.xos -a call.m4a` captures only Zoom's output audio
  - [ ] The user's own microphone is not captured unless `--mix` is explicitly given
  - [ ] First-run macOS "System Audio Recording" permission prompt and approval flow is documented

### US03 — Zero-touch transcription pipeline
As a **data engineer**, I want to capture audio and get a transcript with zero manual steps, so that I can build a fully automated transcription pipeline.
- Acceptance Criteria:
  - [ ] `aural --duration 60 -t -` captures from the default mic and produces transcript text on stdout in one step
  - [ ] The equivalent pipeline `aural -a - --duration 60 | aural -i -` produces the same transcript text on stdout
  - [ ] A failure in the transcription engine propagates a non-zero exit code through the pipeline

### US04 — Manageable chunks
As a **power user**, I want to split a long recording into chunks based on silence, so that I can easily manage large audio files and focus on important segments.
- Acceptance Criteria:
  - [ ] `aural --split silence=1.5 -a name.wav` produces sequentially numbered files (`name_001.wav`, `name_002.wav`, …)
  - [ ] Each chunk is independently playable with a valid, finalised header
  - [ ] The silence detection threshold (dBFS) is configurable

### US05 — Unattended compliance recording
As a **sysadmin**, I want to install the tool via Homebrew and have it run in a crontab, so that I can automatically record every team stand-up for compliance.
- Acceptance Criteria:
  - [ ] `brew install aural` installs a working, signed binary
  - [ ] Once the TCC permission is granted, recording runs unattended from cron/launchd without GUI interaction
  - [ ] Exit codes and stderr logging are suitable for cron-based monitoring and alerting

### US06 — Script-parseable enumeration
As an **ML researcher**, I want to list all available audio devices and capturable applications in a script-parseable format, so that I can write robust automation that adapts to different machine setups.
- Acceptance Criteria:
  - [ ] `aural devices --json` outputs valid JSON with UID, name, channel count, and sample rates
  - [ ] `aural apps --json` outputs valid JSON with name, bundle ID, and PID
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

`aural` itself is the verb — "listen and transcribe." It takes one input (live capture by default, or an existing file/stream via `-i`) and writes the outputs you name. Three utility subcommands remain for inspection.

```
aural [INPUT] [OUTPUTS] [OPTIONS]      # capture / transcribe / convert
aural devices | apps | info            # inspection utilities
```

**Input — pick one (default: system default microphone):**
- *(no flag)* : live capture from the default input device.
- `-d, --device UID` : live capture from a specific input device.
- `--system` : live capture of all system audio via a process tap.
- `--app ID` : live capture of a specific application (bundle ID or PID; repeatable).
- `--exclude-app ID` : live capture of all system audio except the listed application(s) (repeatable).
- `--mix` : additionally mix the microphone (default or `-d` device) into a system/app capture.
- `-i, --input PATH|"-"` : read an existing audio file, or `-` for stdin, instead of live capture. Mutually exclusive with the live flags above.

**Outputs — name what you want to keep; `-` means stdout:**
- `-a, --audio PATH|"-"` : write audio. The file extension picks the format (`.wav`, `.m4a`, `.flac`); `-` streams a WAV container to stdout.
- `-t, --transcript PATH|"-"` : write a transcript. The file extension picks the format (`.txt`, `.srt`, `.json`); `-` writes text to stdout.
- *(no output flag)* : transcribe to stdout (the default verb).
- At most one output may be `-` — stdout carries a single stream.

**Capture format & timing (live capture):**
- `-r, --rate Hz` : sample rate (live default 44100; file convert defaults to the source rate).
- `-b, --bits 16|24|32` : bit depth (live default 16; convert defaults to the source depth).
- `-c, --channels 1|2` : channel count (default based on the source, capped at 2).
- `--duration SEC` : stop live capture after SEC seconds (otherwise Ctrl+C).
- `--split duration=SEC` / `--split silence=SEC` : split the audio file into sequentially numbered chunks (requires `-a FILE`; silence threshold via `--silence-threshold` dBFS).

**Format overrides & transcription engine:**
- `--format wav|m4a|flac` : force the audio format, overriding the extension.
- `--transcript-format txt|srt|json` : force the transcript format, overriding the extension.
- `-e, --engine whisper|cloud` : transcription engine (default `whisper`; cloud is post-MVP).
- `--model PATH` : ggml Whisper model (default `$AURAL_WHISPER_MODEL`).
- `--language CODE` : spoken language (default: the model's default).
- `--raw` : with `-a -`, stream headerless raw PCM to stdout instead of a WAV container.

**Examples:**
```
aural                                       # live mic, transcript -> stdout
aural -i recording.m4a                       # transcribe a file -> stdout
aural -a rec.m4a                             # record only (no transcription)
aural -a rec.m4a -t notes.txt                # record + transcribe to files
aural --system --mix -a mtg.m4a -t mtg.srt   # capture a meeting, keep both
aural -i in.wav -a out.m4a                   # convert between formats
aural -a - | ffmpeg -i - ...                 # stream WAV into a pipe
```

**`aural devices`**
- `--list-inputs` / `--list-outputs`
- `--json` : output in JSON for scripting.

**`aural apps`**
- List running applications whose audio can be captured via process taps.
- Output: application name, bundle ID, PID.
- `--json` : output in JSON for scripting.

**`aural info <file>`**
- Print duration, sample rate, channels, and metadata of an audio file.
- `--json` : output in JSON for scripting.

All invocations accept `-h, --help` and `-v, --verbose`.

> **Note on the root verb.** `aural` with no arguments starts live microphone capture and prints a transcript to stdout; full usage is available via `aural --help`. Naming no output transcribes to stdout, so the default behaviour matches the product's one-line description. Transcoding (`aural -i in -a out`) replaces the former `convert` subcommand, which has been removed.

### 6.2 Source Handling

- Use CoreAudio APIs to enumerate AudioDeviceIDs; automatically exclude inactive devices.
- Use Core Audio process taps (`CATapDescription` / `AudioHardwareCreateProcessTap`, macOS 14.4+) for system and per-app capture; no virtual audio driver required.
- Tap lifecycle: taps are created at capture start and destroyed on stop; if a tapped application quits mid-capture, the capture finalises cleanly and reports it on stderr.
- Fallback to the default input device when no source flag is given.

### 6.3 Streaming & Pipes

- `-a -` streams a self-describing WAV container to stdout (unknown-length header); `--raw` switches it to headerless 16-bit PCM. The stream must play nicely with `ffmpeg`, `sox`, and other tools.
- `-i -` reads audio from stdin (a WAV stream is auto-detected; raw PCM is interpreted with `--input-rate/-bits/-channels`) for transcoding and/or transcription.
- Exactly one output may target stdout; the tool refuses combinations that would interleave two streams on stdout.
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

- Transcription is requested with `-t/--transcript` (or implied when no output flag is given). It applies uniformly to file input (`-i`), stdin (`-i -`), and live capture.
- Input is normalised internally to 16 kHz mono 16-bit WAV (the whisper.cpp requirement) before the engine runs; any readable input format is therefore accepted without prior conversion.
- For live capture, transcription should run as close to runtime as possible: the stream is segmented on natural pauses (with a maximum-window cap) and each segment is transcribed as it completes, appending to the destination. True streaming transcription is post-MVP; batch (transcribe-at-end) is the minimum acceptable behaviour for v1.
- When both `-a` and `-t` are given, audio and transcript are produced in the same capture pass.
- If `--engine whisper`, call a system-installed whisper.cpp binary (`whisper-cli`/`whisper-cpp` on `PATH`, or `$AURAL_WHISPER_BIN`); if not found, provide a clear error with installation instructions (e.g., `brew install whisper-cpp`). The model comes from `--model` or `$AURAL_WHISPER_MODEL`.
- Live transcription prefers a model-resident backend when `whisper-server` is available (`$AURAL_WHISPER_SERVER_BIN` to override the path): the server is launched once on loopback (127.0.0.1) so the model loads a single time, and each segment is transcribed via a local HTTP request to its `/inference` endpoint. This is local IPC with Aural's own child process — not an external network call. It is disabled with `AURAL_WHISPER_SERVER=0`, and Aural falls back to spawning `whisper-cli` per segment whenever the server is absent or fails to start, so transcription is never blocked by the optimization.
- STDERR from the transcription engine is passed through for debugging (suppressed for the high-volume per-segment live calls unless `-v`); a non-zero engine exit code propagates through the pipeline.

---

## 7. Non-Functional Requirements

| Category | Requirement |
|----------|-------------|
| **Performance** | Recording must use < 3% CPU on an Apple Silicon Mac (16 kHz mono); buffering delays < 100 ms. |
| **Reliability** | 24-hour continuous recording must produce a valid, non-corrupted file when terminated via SIGINT/SIGTERM. Resilience to hard kills (SIGKILL, power loss) is parked — see Open Questions. |
| **Usability** | CLI help and error messages are clear, include examples, and follow POSIX utility conventions. |
| **Compatibility** | macOS 14.4 (Sonoma) and later — required by the Core Audio process-tap API; both Intel and Apple Silicon. |
| **Security & Privacy** | No external network calls by default; cloud transcription backends are opt-in and use HTTPS with user-provided API keys. (Live transcription may run a local `whisper-server` bound to loopback 127.0.0.1 for performance — IPC with Aural's own child process, never an external connection; disable with `AURAL_WHISPER_SERVER=0`.) System/app audio capture requires the macOS "System Audio Recording" TCC permission; the prompt and approval flow (including terminal-attributed permission for unbundled CLIs) must be documented. |
| **Maintainability** | Single Swift binary built with SwiftPM; modular targets: `DeviceManager`, `TapEngine`, `Encoders`, `CLI`. Well-documented code. |
| **Installability** | Distributed via Homebrew (`brew install aural`) and direct download from GitHub Releases; binary is signed and notarized so TCC permission flows work cleanly. |
| **Auditability** | All recorded file paths and durations are logged to STDERR when `-v` is enabled. |

---

## 8. Success Metrics (KPIs)

- **Adoption:** 1000 Homebrew installs within 3 months of public release.
- **Pipeline integration:** At least two open-source transcription projects (e.g., `whisper.cpp`, `faster-whisper`) officially list Aural as a recommended capture tool.
- **Reliability:** Crash-free session rate > 99.5%, measured via strictly opt-in telemetry (consistent with the "no network calls by default" security requirement; mechanism TBD — see Open Questions).
- **Community engagement:** Minimum 10 pull requests contributed from external developers within 6 months (discouraging feature bloat, but demonstrating extendability).

---

## 9. Timeline & Milestones

| Milestone | Deliverables | Target | Dependencies |
|-----------|--------------|--------|--------------|
| **M1 – Core Capture** | Swift/SwiftPM project skeleton, device & app enumeration (`devices`, `apps`), mic recording to WAV, signal handling, stdout streaming | Week 1–2 | — |
| **M2 – System Audio** | Core Audio process taps: `--system`, `--app`, `--exclude-app`, `--mix`; TCC permission flow & docs | Week 3–4 | M1 |
| **M3 – Formats & Chunking** | M4A/FLAC output, MP3/Opus (static libs), time-based splitting, transcoding via `-i in -a out` | Week 5–6 | M1 |
| **M4 – Transcription MVP** | Root-verb transcription with local Whisper support; stdin/file/live input; combined `-a`+`-t` | Week 7 | M3 |
| **M5 – Polish & Release** | Code signing & notarization, Homebrew formula, man page, example scripts, CI/CD, public beta | Week 8–9 | M2, M3, M4 |
| **Post-MVP** | Daemon mode (launchd scheduled recording), silence VAD, streaming transcription, cloud backends, configuration profiles | Ongoing | M5 |

---

## 10. Open Questions & Assumptions

1. **Crash resilience (parked):** How should recordings survive hard kills (SIGKILL, power loss)? Candidates: periodic header flush every N seconds, or a `aural repair` subcommand for truncated files. Decision deferred.
2. **Whisper bundling:** Will the tool bundle a transcription engine or expect the user to install it separately? (Assumption: no bundling to keep the binary small; document external dependencies.)
3. **Telemetry mechanism:** What opt-in mechanism (if any) will measure the crash-free-rate KPI without violating the no-network-by-default principle?
4. **TCC for unbundled CLI:** Confirm the exact permission-attribution behaviour for a signed standalone binary vs. terminal-attributed permission, and document the recommended setup.

### Resolved (2026-06-12)
- ~~Language/stack~~ → **Swift**, single binary, SwiftPM modular targets.
- ~~System audio without a virtual device~~ → **Core Audio process taps** (macOS 14.4+); BlackHole no longer required.
- ~~Product/binary naming~~ → **aural**.

---

**Document Status:** Draft for review
**Next Steps:** Fill in Author field; review drafted acceptance criteria (US01–US07); decide crash-resilience strategy (Open Question 1).
