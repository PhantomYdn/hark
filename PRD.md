# Product Requirements Document (PRD)

## Product: Hark
**Version:** 1.0 (MVP)
**Date:** 2026-06-12
**Author:** Ilya Naryzhnyy

---

## 1. Overview

Hark is a native macOS command-line utility, shipped as a single Swift binary, that captures audio from physical input sources (microphones) and from the system itself — all system audio or the output of specific applications — using Core Audio process taps (macOS 14.4+) or ScreenCaptureKit (macOS 15+), selectable per the environment. No third-party virtual audio driver (e.g., BlackHole) is required. Recordings are saved locally and serve as the foundation for downstream audio processing workflows, most notably automatic speech-to-text transcription.

The tool strictly follows Unix/Linux design patterns, treating audio as a stream that can be manipulated, piped, and extended by other command-line programs. The primary goal is to provide a simple, scriptable, and composable replacement for GUI-based audio recording, enabling users to automate meeting recordings, create transcription pipelines, or build custom audio-processing chains without leaving the terminal.

Beyond batch and pipe usage, Hark can run **interactively** — a minimal terminal UI that shows the live transcript and accepts pause/resume/stop from the keyboard — and as an on-demand **remote-control agent** that external programs (including browser userscripts) drive over a local HTTP/JSON API to decide when, what, and where to record.

---

## 2. Objectives & Success Criteria

| Objective | Success Criteria |
|-----------|------------------|
| Enable reliable capture of both microphone and system/app audio (e.g., Zoom, Teams) on macOS without third-party drivers | Users can record their voice and the counterparty's audio simultaneously with < 200 ms latency drift, measured as offset between mic and system tracks over a 60-minute dual-source recording |
| Provide a Unix-compatible interface that integrates with standard pipes, redirections, and signal handling | All audio data can be streamed via stdout; the CLI responds to SIGINT/SIGTERM by gracefully closing the output file |
| Simplify the transcription pipeline | Output files (WAV, M4A, FLAC, MP3, Opus) can be directly fed to `whisper.cpp`, Fabric AI, or cloud-based transcription services without extra conversion |
| Minimise dependencies and footprint | The tool is shipped as a single Swift binary requiring only macOS baseline frameworks (CoreAudio, AudioToolbox, AVFoundation); no third-party audio driver installation |
| Follow the "do one thing well" philosophy | The root verb captures/transcribes/transcodes via composable flags; small utility subcommands inspect the environment (list devices, list apps, file info); complex workflows are built by chaining invocations through stdin/stdout |
| Make live capture observable and externally controllable | Starting a capture prints the resolved engine/model/source/format/outputs to stderr; `--interactive` exposes pause/resume, mic mute/unmute, transcript yank-to-clipboard, and stop at the keyboard; `--remote-control` lets an external script start/stop/pause/query a recording via the documented HTTP API with a round-trip < 200 ms |

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
| 3 | System & per-app audio capture | P0 | Capture all system audio (`--system`), specific application(s) (`--app`, repeatable), or everything except listed apps (`--exclude-app`). Mixed mic + system capture via `--mix`. Two interchangeable backends — ScreenCaptureKit (macOS 15+, GUI session) and Core Audio process taps (macOS 14.4+, headless-capable) — selected with `--capture-backend` (default auto); see §6.2. |
| 4 | File output — native formats | P0 | Save to WAV (PCM), M4A/AAC, or FLAC using native CoreAudio encoders. |
| 5 | Stream-mode operation | P0 | Stream a WAV container to stdout with `-a -` (e.g., `hark -a - \| ffmpeg ...`), or headerless PCM with `--raw`; accept audio from stdin (`-i -`) for transcoding/transcription. |
| 6 | Signal handling & graceful shutdown | P0 | On SIGINT (Ctrl+C) or SIGTERM, finalise the output file header so it remains playable. |
| 7 | File output — additional formats | P1 | MP3 (vendored libmp3lame) and Ogg/Opus (native CoreAudio encoder + hand-written Ogg muxer, zero deps). All output formats verified compatible with major transcription tools (whisper.cpp, Fabric AI, cloud APIs). |
| 8 | Time-based chunking | P1 | Split recordings into sequential files by duration (`--split duration=SEC`). |
| 9 | Transcription integration | P1 | Transcription is built into the root verb: any input (live capture or `-i` file/stream) can be transcribed by a local engine (e.g., `whisper.cpp`) via `-t/--transcript`. Audio and transcript can be produced in the same run (`-a rec.m4a -t notes.srt`); naming no output transcribes to stdout. |
| 12 | Live transcription | P1 | During live capture, emit the transcript incrementally — as close to runtime as possible — by segmenting the stream on natural pauses and transcribing each segment as it completes (true streaming is post-MVP). |
| 13 | Multi-language & translation | P1 | Transcribe ~99 languages with a multilingual model via `--language CODE` or auto-detect (`--language auto`, default); `--translate` emits English from any spoken language (engines that support it). `hark models list/download` manages local models. |
| 14 | Pluggable transcription engines | P2 | Select the engine with `--engine`: `whisper` (whisper.cpp, default), `apple` (native Speech.framework, no extra deps), `whisperkit` (CoreML, on-device, multilingual + translate). Capabilities (auto-detect, translate, model semantics) vary and are validated. |
| 10 | Silence-based splitting | P2 | Split on continuous silence exceeding a configurable threshold (`--split silence=SEC`). |
| 11 | Basic metadata embedding | P2 | Store recording start time, source name, and sample rate in WAV INFO, MP4, or ID3 tags. |
| 15 | Speaker attribution by source (You vs Others) | P1 | When two sources are captured (`--mix`, or `--system`/`--app` + mic), keep the microphone and system audio as separate **internal** tracks and tag each transcript segment with its source ("You" = mic, "Others" = system). Deterministic and exact — no ML, no model download. This replaces the unreliable single-mixed-stream heuristic. |
| 16 | Acoustic speaker diarization | P1 | Separate anonymous speakers ("Speaker 1/2…") within a single stream using FluidAudio CoreML models (on-device, Apple Neural Engine). Offline mode (batch `-i`, most accurate) and streaming mode (live capture). |
| 17 | VAD-based live segmentation | P1 | Replace amplitude/silence-threshold segment cutting with Silero VAD (FluidAudio) for stable speech/pause boundaries at runtime; graceful fallback to the existing amplitude method when VAD models are unavailable. Feeds both transcription and the speaker pipeline. |
| 18 | Combined source-split + per-source diarization | P2 | Label You (mic) plus each distinct remote participant (diarize the system track) so multi-party calls resolve both sides at once. |
| 19 | Named speaker identification (enrolled voiceprints) | Post-MVP | Match voices to named people via stored speaker embeddings; enrollment + a local voiceprint store (FluidAudio embedding extraction). |
| 20 | Working directory for artifacts | P1 | A base directory for resolving **relative** input/output paths (`-i`, `-a`, `-t`, and `--split` outputs), defaulting to the current working directory and overridable via `--directory`/`-C`, `$HARK_DIRECTORY`, or config `directory`. Absolute paths and `-` (stdin/stdout) are unaffected; the directory must exist. Foundation for headless/remote operation (see §4.2). |
| 21 | Startup status summary | P1 | On capture start, print a concise status block to stderr — engine, model, language, source/device, capture backend, format, output destinations, speaker mode, VAD, and any duration limit. Shown when stderr is a TTY or with `-v`; suppressed when stderr is redirected so pipelines/cron stay clean. Never written to stdout. See §6.8. |
| 22 | Interactive mode | P1 | `--interactive`: a minimal terminal UI for live capture — a status header, the live transcript, and single-key controls (**space** = pause/resume, **m** = mute/unmute the mic, **y** = yank the transcript to the clipboard, **Enter** = finish; Ctrl-C also stops). The live transcript is always shown on screen; naming `-t FILE`/`-a FILE` concurrently persists the transcript/audio to those files. **Pause excludes the paused interval** from both audio and transcript (a true gap, so output is shorter than wall-clock); **mute** silences only the microphone (timeline preserved — distinct from pause), and **yank** copies the full session transcript so far to the system clipboard. Requires a controlling TTY; incompatible with stdout (`-`) streaming and with `--remote-control`. See §6.9. |
| 23 | Remote-control agent | P1 | `hark --remote-control [ADDR]` runs Hark as a control agent (no immediate capture) exposing an **HTTP/JSON API over TCP** — bound to loopback by default, or to an explicit `interface:port`. External scripts choose **when** (start/stop/pause/resume), **what** (sources/format/engine/model), and **where** (output paths resolved under the working `directory`). Documented wire protocol (no bundled client) plus a Tampermonkey Google-Meet reference userscript. See §6.10. |

### 4.2 Post-MVP Features (Future)

- **Managed & scheduled launchd service** (building on the on-demand remote-control agent, §6.10):
  - **Supervised agent via `brew services`**: a Homebrew `service` block so `brew services start hark` installs a **per-user LaunchAgent** (login/GUI session) that auto-starts at login, keeping the agent available to the browser userscript (US11) without an open terminal. The bound port comes from the `remote-control-port` config key (default `8473`); engine/model/`directory` come from `hark config`. The service runs with `--no-keep-awake` and **no launchd `KeepAlive`** (a crash/bad start stays down and visible rather than relaunching in a hidden loop; auto-restart is an opt-in plist edit). (A per-user agent stops at logout.)
  - **Scheduled / unattended daemon**: extend it to *schedule* recordings (cron-style) and survive logout via a system LaunchDaemon (Core Audio backend, headless).
  Both depend on TCC consent landing on the signed `hark` binary under launchd (Open Q4).
- **Cross-host & authenticated remote control**: hardened auth and same-LAN/remote operation beyond the loopback default of §6.10 (token/TLS, allow-lists).
- **Silence-based voice activity detection** for trimming.
- **Real-time streaming** to a network socket or HTTP endpoint.
- **Multi-channel mapping** (e.g., separate tracks for mic and system audio).
- **Plugin system** to inject custom DSP filters (EQ, noise suppression) as middleware.
- **Configuration profiles** to store default sources, formats, and transcription settings.
- **Additional engines**: NVIDIA Parakeet (via FluidAudio CoreML); cloud backends (Deepgram, Google) selectable via `--engine`.
- **Named speaker identification**: voiceprint enrollment and a local speaker store, so diarized speakers resolve to named people across recordings (FluidAudio speaker embeddings).
- **Overlapping-speech handling**: per-word speaker assignment and crosstalk resolution when two speakers talk simultaneously.

---

## 5. User Stories

### US01 — Quick voice notes
As a **developer**, I want to quickly capture my microphone input for five minutes and save it to a file, so that I can review my spoken notes later without opening Audacity.
- Acceptance Criteria:
  - [ ] `hark -a notes.m4a --duration 300` records from the default input device without specifying a device UID (and writes no transcript, since only `-a` is named)
  - [ ] Recording stops automatically after 300 seconds with exit code 0
  - [ ] Resulting file plays correctly in QuickTime/`afplay` and duration is 300 s ± 1 s

### US02 — Record a meeting without echo
As a **developer**, I want to record the audio from an ongoing Zoom call without echoing my own voice, so that I can later transcribe the meeting and extract action items.
- Acceptance Criteria:
  - [ ] `hark apps` lists the running Zoom process with its bundle ID
  - [ ] `hark --app us.zoom.xos -a call.m4a` captures only Zoom's output audio
  - [ ] The user's own microphone is not captured unless `--mix` is explicitly given
  - [ ] First-run macOS "System Audio Recording" permission prompt and approval flow is documented

### US03 — Zero-touch transcription pipeline
As a **data engineer**, I want to capture audio and get a transcript with zero manual steps, so that I can build a fully automated transcription pipeline.
- Acceptance Criteria:
  - [ ] `hark --duration 60 -t -` captures from the default mic and produces transcript text on stdout in one step
  - [ ] The equivalent pipeline `hark -a - --duration 60 | hark -i -` produces the same transcript text on stdout
  - [ ] A failure in the transcription engine propagates a non-zero exit code through the pipeline

### US04 — Manageable chunks
As a **power user**, I want to split a long recording into chunks based on silence, so that I can easily manage large audio files and focus on important segments.
- Acceptance Criteria:
  - [ ] `hark --split silence=1.5 -a name.wav` produces sequentially numbered files (`name_001.wav`, `name_002.wav`, …)
  - [ ] Each chunk is independently playable with a valid, finalised header
  - [ ] The silence detection threshold (dBFS) is configurable

### US05 — Unattended compliance recording
As a **sysadmin**, I want to install the tool via Homebrew and have it run in a crontab, so that I can automatically record every team stand-up for compliance.
- Acceptance Criteria:
  - [ ] `brew install hark` installs a working, signed binary
  - [ ] Once the TCC permission is granted, recording runs unattended from cron/launchd without GUI interaction
  - [ ] Exit codes and stderr logging are suitable for cron-based monitoring and alerting

### US06 — Script-parseable enumeration
As an **ML researcher**, I want to list all available audio devices and capturable applications in a script-parseable format, so that I can write robust automation that adapts to different machine setups.
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

### US08 — Know who said what
As a **developer**, I want my meeting transcript to label who said each line — me versus the call, and distinct remote speakers — so that I can produce accurate minutes and attribute action items.
- Acceptance Criteria:
  - [ ] `hark --system --mix --speakers -t mtg.srt` tags each cue with a speaker label (e.g. `You`, `Speaker 1`)
  - [ ] Lines spoken into my microphone are labeled distinctly from the call audio (deterministic source attribution, not a guess)
  - [ ] `hark --system --mix --speakers -t mtg.json` includes a `speaker` field on every segment
  - [ ] Diarization runs fully on-device; the first run may download CoreML models, after which it is offline
  - [ ] During live capture, speaker labels appear close to runtime (streaming), not only after the call ends

### US09 — Interactive recording with a break
As a **developer**, I want to record interactively and pause during a break, so that the break is not part of the recording and I can stop cleanly when done.
- Acceptance Criteria:
  - [ ] `hark --interactive -a notes.m4a` shows a status header and the live transcript, and accepts single-key controls
  - [ ] `hark --interactive -a notes.m4a -t notes.txt` shows the live transcript on screen **while** concurrently writing `notes.m4a` and `notes.txt`
  - [ ] Pressing **space** pauses; the paused interval is absent from both `notes.m4a` and the transcript (a true gap), and **space** again resumes
  - [ ] Pressing **Enter** (or Ctrl-C) stops and finalises the file so it remains playable (same guarantee as Ctrl+C)
  - [ ] When stdout is not a TTY (or `-a -`/`-t -` is requested), `--interactive` exits with a clear usage error; the terminal is restored on exit and on SIGINT/SIGTERM

### US10 — Know what's running before I speak
As a **power user**, I want Hark to tell me which engine, model, and source it's using when a capture starts, so that I can catch a misconfiguration before recording a whole meeting.
- Acceptance Criteria:
  - [ ] Starting a live capture in a terminal prints a status block to stderr (engine, model, language, source/device, capture backend, format, outputs, speaker mode, VAD, duration)
  - [ ] The status block is suppressed when stderr is redirected/piped, and always shown with `-v`
  - [ ] The status block is never written to stdout (it does not corrupt `-a -`/`-t -` streams)

### US11 — Browser-driven meeting capture
As a **knowledge worker**, I want my browser to start and stop Hark automatically around Google Meet calls, so that every meeting is recorded and named without my intervention.
- Acceptance Criteria:
  - [ ] `hark --remote-control` starts an agent listening on loopback and prints its address; it does not begin capturing on its own
  - [ ] A Tampermonkey userscript (shipped as a reference at `examples/hark-meet.user.js`) calls `POST /start` when a Meet call is joined, with a filename derived from the meeting title and date, and `POST /stop` when the call ends
  - [ ] The recording is written under the agent's working `directory`; `GET /status` reports the session's state, elapsed time, and output paths (the API never serves the transcript/audio content itself)
  - [ ] A second `POST /start` while a recording is active is rejected with `409 Conflict` (single active session)
  - [ ] With a non-loopback bind address, the agent refuses to start unless a token (`$HARK_REMOTE_TOKEN`) is configured, and rejects unauthenticated requests
  - [ ] `brew services start hark` runs the agent as a login LaunchAgent on the configured `remote-control-port` (default 8473); it is reachable by the userscript after login without a manual terminal start

### US12 — Mute and grab the transcript on the fly
As a **developer in a live meeting**, I want to mute my mic and copy the running transcript without stopping the recording, so that I can have a side conversation and paste notes elsewhere mid-call.
- Acceptance Criteria:
  - [ ] In `hark --interactive --mix -a mtg.m4a`, pressing **m** mutes only the microphone — the system/call audio keeps recording — and **m** again unmutes; the recording timeline has no gap
  - [ ] In a mic-only `hark --interactive`, pressing **m** records silence for the muted interval (output length still matches wall-clock), distinct from **space** pause which omits the interval
  - [ ] When the capture has no microphone (e.g. `--system` without `--mix`), the **m** control is hidden; pressing **m** prints a brief notice and does nothing
  - [ ] Pressing **y** copies the full transcript captured so far to the system clipboard (plain text, with speaker labels when `--speakers` is active) and prints a confirmation on stderr
  - [ ] Pressing **y** before anything is transcribed shows a brief "nothing to copy" notice and leaves the clipboard unchanged
  - [ ] Over the remote-control API (§6.10), `POST /mute`/`/unmute` toggle the active session's mic the same way (timeline preserved, idempotent), `GET /status` reports the `muted` flag, and a capture with no microphone returns `422`; transcript yank is interactive-only (the API never serves transcript content)
  - [ ] The reference Google Meet userscript (§6.10) mirrors the Meet mic toggle to the agent **one-way** (Meet → hark): it starts the recording with `muted` matching Meet's state at join, then `POST /mute`/`/unmute` as you toggle in Meet (only when the capture has a mic); hark never drives Meet's mic

---

## 6. Functional Requirements

### 6.1 CLI Commands & Flags

`hark` itself is the verb — "listen and transcribe." It takes one input (live capture by default, or an existing file/stream via `-i`) and writes the outputs you name. Utility subcommands cover inspection and setup.

```
hark [INPUT] [OUTPUTS] [OPTIONS]        # capture / transcribe / convert
hark devices | apps | info              # inspection utilities
hark models | config                    # model + default management
```

**Input — pick one (default: system default microphone):**
- *(no flag)* : live capture from the default input device.
- `-d, --device UID` : live capture from a specific input device.
- `--system` : live capture of all system audio (via the selected capture backend, see §6.2).
- `--app ID` : live capture of a specific application (bundle ID or PID; repeatable).
- `--exclude-app ID` : live capture of all system audio except the listed application(s) (repeatable).
- `--mix` : additionally mix the microphone (default or `-d` device) into a system/app capture.
- `-i, --input PATH|"-"` : read an existing audio file, or `-` for stdin, instead of live capture. Mutually exclusive with the live flags above.

**Outputs — name what you want to keep; `-` means stdout:**
- `-a, --audio PATH|"-"` : write audio. The file extension picks the format (`.wav`, `.m4a`, `.flac`, `.mp3`, `.opus`); `-` streams a WAV container to stdout.
- `-t, --transcript PATH|"-"` : write a transcript. The file extension picks the format (`.txt`, `.srt`, `.json`); `-` writes text to stdout.
- *(no output flag)* : transcribe to stdout (the default verb).
- At most one output may be `-` — stdout carries a single stream.

**Working directory:**
- `--directory, -C PATH` : base directory for resolving **relative** artifact paths (`-i`, `-a`, `-t`, split outputs). Absolute paths and `-` (stdin/stdout) are unaffected. Defaults to the process CWD; also `$HARK_DIRECTORY` or config `directory`. A non-existent directory is a usage error (Hark never creates it).

**Capture format & timing (live capture):**
- `-r, --rate Hz` : sample rate (live default 44100; file convert defaults to the source rate).
- `-b, --bits 16|24|32` : bit depth (live default 16; convert defaults to the source depth).
- `-c, --channels 1|2` : channel count (default based on the source, capped at 2).
- `--duration SEC` : stop live capture after SEC seconds (otherwise Ctrl+C).
- `--split duration=SEC` / `--split silence=SEC` : split the audio file into sequentially numbered chunks (requires `-a FILE`; silence threshold via `--silence-threshold` dBFS).
- `--capture-backend auto|sckit|coreaudio` : system/app capture backend (default `auto`, or `$HARK_CAPTURE`); see §6.2.

**Format overrides & transcription:**
- `--format wav|m4a|flac|mp3|opus` : force the audio format, overriding the extension.
- `--transcript-format txt|srt|json` : force the transcript format, overriding the extension.
- `-e, --engine whisper|apple|whisperkit` : recognition engine (default `whisper`; `cloud` is post-MVP). Capabilities vary — see §6.6.
- `--model NAME|PATH` : engine-specific model selector. `whisper`: ggml path or short name (`large-v3-turbo`); `whisperkit`: a WhisperKit model name (`large-v3-v20240930_626MB`); `apple`: ignored (OS assets). whisper precedence: `--model` › `$HARK_WHISPER_MODEL` › config `model` (`hark config` / `~/.hark/config.json`).
- `--language CODE` : spoken language (e.g. `de`); `auto` (default) detects it where the engine supports detection.
- `--translate` : output English regardless of the spoken language (whisper/whisperkit only).
- `--raw` : with `-a -`, stream headerless raw PCM to stdout instead of a WAV container.

**Speaker recognition (diarization) — see §6.7:**
- `--speakers[=auto|source|acoustic]` (alias `--diarize`) : label transcript segments by speaker. `auto` (the value when the flag is given bare) attributes the microphone side by source ("You") and diarizes the system/single stream acoustically ("Speaker 1/2…"); `source` labels by capture source only (needs two sources); `acoustic` runs acoustic diarization only. Off by default.
- `--max-speakers N` : cap/hint for the **offline/batch** acoustic-clustering diarizer (bounded by the diarizer model's capacity; no effect on the streaming EEND diarizer; see §6.7).
- `--speaker-threshold 0..1` : **offline/batch** clustering sensitivity (default ~0.65; lower splits speakers more readily, higher merges them). No effect on the streaming EEND diarizer.
- `--diarize-engine auto|streaming|offline` : pick the diarizer (default `auto` → streaming **(LS-EEND)** for live capture, offline for `-i` files).
- `--speaker-labels "You,Others"` : rename the source-attribution labels (default `You,Others`).

**Interactive & remote control (§6.8–§6.10):**
- `--interactive` : run live capture in a minimal terminal UI (status header + live transcript + single-key controls: **space** pause/resume, **m** mute/unmute the mic, **y** yank the transcript to the clipboard, **Enter** finish; Ctrl-C also stops). Pause omits the paused interval from the outputs; mute silences only the mic (timeline preserved); yank copies the transcript so far to the system clipboard. Requires a controlling TTY; mutually exclusive with `-` (stdout) outputs and with `--remote-control`. (Modal flag — not a persisted config key.)
- `--remote-control [[host:]port]` : start Hark as a control **agent** instead of capturing immediately, serving an HTTP/JSON API over TCP. The value is **optional**: omitted, it binds **loopback** on the configured `remote-control-port` (default `8473`); a bare port or an empty host binds loopback on that port (e.g. `8473` or `:8473`); `0.0.0.0:8473` or a specific IPv4 binds elsewhere. Any other capture/transcription flags given at launch become the per-session **defaults** for recordings started via the API. Non-loopback binds require `$HARK_REMOTE_TOKEN`. (Agent **mode** is modal — not persisted; the **port** it binds is the persisted `remote-control-port` config key, so a `brew services`-managed agent can launch without an explicit address.)

**Examples:**
```
hark                                       # live mic, transcript -> stdout
hark -i recording.m4a                       # transcribe a file -> stdout
hark -a rec.m4a                             # record only (no transcription)
hark -a rec.m4a -t notes.txt                # record + transcribe to files
hark --system --mix -a mtg.m4a -t mtg.srt   # capture a meeting, keep both
hark -i in.wav -a out.m4a                   # convert between formats
hark -a - | ffmpeg -i - ...                 # stream WAV into a pipe
hark -i talk.mp3 --language auto -t talk.srt        # detect language -> subtitles
hark --system --engine whisperkit --translate -t -  # any language -> English, live
hark --system --mix --speakers -t mtg.srt           # meeting w/ speaker labels (You / Speaker N)
hark -i mtg.wav --speakers=acoustic -t mtg.json     # diarize a recording -> labeled JSON
hark --interactive --system --mix -a mtg.m4a        # interactive meeting capture (pause/stop)
hark --remote-control 127.0.0.1:8080                # run the control agent on loopback:8080
```

**`hark devices`**
- `--list-inputs` / `--list-outputs`
- `--json` : output in JSON for scripting.

**`hark apps`**
- List running applications whose audio can be captured via process taps.
- Output: application name, bundle ID, PID.
- `--json` : output in JSON for scripting.

**`hark info <file>`**
- Print duration, sample rate, channels, and metadata of an audio file.
- `--json` : output in JSON for scripting.

**`hark models`**
- `list` : show installed models across engines (name, engine, size) and the active default (`*`).
- `list --available` : show the downloadable catalog across engines with an `ENGINE` column, language coverage, and installed/current status.
- `download <name>` : fetch a model. Names are engine-tagged: a bare ggml short name is a whisper model (`base.en`); CoreML engines use a prefix (`whisperkit:tiny`, `parakeet:v3`). whisper models land in `~/.hark/models`; whisperkit/parakeet delegate to their SDK caches. `--force` re-downloads. `--default` makes it the default: for whisper the first download is auto-adopted; for whisperkit/parakeet `--default` also sets `config.engine`.
- Applies to file-based engines (`whisper`, `whisperkit`, `parakeet`); `apple` uses OS-managed assets.
- `--json` on `list` for scripting.

**`hark config`** — persisted defaults in `~/.hark/config.json` (JSON; user-editable, kebab-case keys).
- `show` (default; `--json`) / `set <key> <value>` / `unset <key>` / `path`.
- Keys (kebab-case): `engine`, `model`, `language`, `translate`, `device`, `directory`, `capture-backend`, `rate`, `bits`, `channels`, `silence-threshold`, `vad`, `vad-threshold`, `gain`, `speakers`, `speaker-mode`, `speaker-labels`, `diarize-engine`, `max-speakers`, `speaker-threshold`, `remote-control-port`. Values are type-checked (e.g. `translate`/`vad`/`gain`/`speakers` boolean; `silence-threshold` negative; `engine` a known engine; `directory` an existing directory; `vad-threshold`/`speaker-threshold` in 0–1; `remote-control-port` an integer port `1–65535`); unknown keys are rejected. `hark config show` lists every setting with its value, source, and a one-line description. Values beginning with `-` are taken verbatim (e.g. `hark config set silence-threshold -40`).

**Defaults precedence (environment & configuration).** Each setting resolves in the order **flag › environment (`$HARK_*`) › config (`hark config`) › built-in default** (the order `hark config show` displays):

| Setting | Flag | Env var | Config key | Default |
|---------|------|---------|------------|---------|
| engine | `-e/--engine` | `$HARK_ENGINE` | `engine` | `whisper` |
| model | `--model` | `$HARK_WHISPER_MODEL` | `model` | (required) |
| language | `--language` | `$HARK_LANGUAGE` | `language` | `auto` |
| translate | `--translate`/`--no-translate` | `$HARK_TRANSLATE` | `translate` | `false` |
| input device | `-d/--device` | `$HARK_DEVICE` | `device` | system default input |
| working directory | `--directory`/`-C` | `$HARK_DIRECTORY` | `directory` | current working directory |
| capture backend | `--capture-backend` | `$HARK_CAPTURE` | `capture-backend` | `auto` |
| sample rate | `-r/--rate` | `$HARK_RATE` | `rate` | contextual (live 44100) |
| bit depth | `-b/--bits` | `$HARK_BITS` | `bits` | contextual (live 16) |
| channels | `-c/--channels` | `$HARK_CHANNELS` | `channels` | auto (source, ≤2) |
| silence threshold | `--silence-threshold` | `$HARK_SILENCE_THRESHOLD` | `silence-threshold` | `-50` |
| VAD | `--vad`/`--no-vad` | `$HARK_VAD` | `vad` | `true` |
| VAD threshold | `--vad-threshold` | `$HARK_VAD_THRESHOLD` | `vad-threshold` | `0.5` |
| gain | `--gain`/`--no-gain` | `$HARK_GAIN` | `gain` | `true` |
| speakers | `--speakers`/`--no-speakers` | `$HARK_SPEAKERS` | `speakers` | `false` |
| speaker mode | `--speaker-mode` | `$HARK_SPEAKER_MODE` | `speaker-mode` | `auto` |
| speaker labels | `--speaker-labels` | `$HARK_SPEAKER_LABELS` | `speaker-labels` | `You,Others` |
| diarize engine | `--diarize-engine` | `$HARK_DIARIZE_ENGINE` | `diarize-engine` | `auto` |
| max speakers | `--max-speakers` | `$HARK_MAX_SPEAKERS` | `max-speakers` | (unset) |
| speaker threshold | `--speaker-threshold` | `$HARK_SPEAKER_THRESHOLD` | `speaker-threshold` | `~0.65` |
| remote-control port | `--remote-control` (port part) | `$HARK_REMOTE_CONTROL_PORT` | `remote-control-port` | `8473` |

Model values (flag/env/config) may each be a ggml path or a short name resolved under `~/.hark/models`. Malformed env values (non-boolean `$HARK_TRANSLATE`, non-negative/non-numeric `$HARK_SILENCE_THRESHOLD`) are reported as usage errors.

**Working directory & path resolution.** All **relative** artifact paths — `-i`, `-a`, `-t`, and `--split` outputs — resolve against the working directory (`--directory`/`-C` › `$HARK_DIRECTORY` › config `directory` › process CWD). Absolute paths, `-` (stdin/stdout), and Hark's own state (`~/.hark/…` config and models) are unaffected. A non-existent directory is a usage error; Hark never creates it. This makes invocations reproducible regardless of the launcher's CWD and is the basis for the planned remote-control feature, where a controlling process/host points Hark at a shared artifact directory.

All invocations accept `-h, --help` and `-v, --verbose`.

> **Note on the root verb.** `hark` with no arguments starts live microphone capture and prints a transcript to stdout; full usage is available via `hark --help`. Naming no output transcribes to stdout, so the default behaviour matches the product's one-line description. Transcoding (`hark -i in -a out`) replaces the former `convert` subcommand, which has been removed.

### 6.2 Source Handling

- Use CoreAudio APIs to enumerate AudioDeviceIDs; automatically exclude inactive devices.
- **System/app capture uses one of two interchangeable backends** (both deliver the same packed-PCM stream); `--capture-backend auto|sckit|coreaudio` (default `auto`, or `$HARK_CAPTURE`) selects:
  - **`sckit` — ScreenCaptureKit** (`SCStream`, macOS 15+): captures system/app audio and, for `--mix`, the microphone in the same synchronized stream. Audio is delivered continuously (silence when idle), so `--mix` keeps recording the microphone even when no system audio is playing. Requires the **Screen Recording** TCC permission and a graphical login session (it cannot run headless / over SSH / as a LaunchDaemon).
  - **`coreaudio` — Core Audio process taps** (`CATapDescription` / `AudioHardwareCreateProcessTap`, macOS 14.4+): no virtual audio driver. Uses a private aggregate device; for `--mix` the **microphone is the aggregate's clock master** so capture runs continuously regardless of system-audio activity. Requires the narrower **System Audio Recording** permission and **works headless** (cron/launchd/SSH).
  - **`auto`** prefers `sckit` when available (macOS 15+, a GUI session is present, and Screen Recording is granted) and otherwise falls back to `coreaudio`, printing a one-line notice on stderr. Headless and macOS 14.x always use `coreaudio`.
- Tap/stream lifecycle: created at capture start and torn down on stop; if a tapped application quits mid-capture, the capture finalises cleanly and reports it on stderr.
- Fallback to the default input device when no source flag is given.

### 6.3 Streaming & Pipes

- `-a -` streams a self-describing WAV container to stdout (unknown-length header); `--raw` switches it to headerless 16-bit PCM. The stream must play nicely with `ffmpeg`, `sox`, and other tools.
- `-i -` reads audio from stdin (a WAV stream is auto-detected; raw PCM is interpreted with `--input-rate/-bits/-channels`) for transcoding and/or transcription.
- Exactly one output may target stdout; the tool refuses combinations that would interleave two streams on stdout.
- Exit code 0 on success, non-zero on failure (explicit error codes documented).

### 6.4 Format Support

- Read: WAV, AIFF, CAF, M4A, FLAC.
- Write (P0): WAV (PCM), M4A/AAC, FLAC — native CoreAudio encoders.
- Write (P1): MP3 (vendored libmp3lame, encode-only — Sources/CLame, LGPL), Ogg/Opus (native `kAudioFormatOpus` encoder + hand-written Ogg muxer, zero external deps).
- All write formats must be accepted as-is by major transcription tools: `whisper.cpp`, Fabric AI, OpenAI/cloud transcription APIs.
- Metadata: WAV INFO chunk, MP4 metadata atoms for M4A, ID3v2 for MP3.

### 6.5 Chunking & Splitting

- Time-based: `--split duration=300` creates `meeting_001.wav`, `meeting_002.wav`, …
- Silence-based: `--split silence=1.5` triggers a new file after 1.5 seconds of continuous silence (configurable threshold).
- Both modes must flush the file header correctly and continue recording.

### 6.6 Transcription Integration

- Transcription is requested with `-t/--transcript` (or implied when no output flag is given). It applies uniformly to file input (`-i`), stdin (`-i -`), and live capture.
- Input is normalised internally to 16 kHz mono 16-bit WAV (the whisper.cpp requirement) before the engine runs; any readable input format is therefore accepted without prior conversion.
- For live capture, transcription should run as close to runtime as possible: the stream is segmented on natural pauses (with a maximum-window cap) and each segment is transcribed as it completes, appending to the destination. True streaming transcription is post-MVP; batch (transcribe-at-end) is the minimum acceptable behaviour for v1. **Segment boundaries are determined by voice-activity detection (VAD) when available** (Silero via FluidAudio — far more stable than a raw amplitude threshold), falling back to the `--silence-threshold` amplitude heuristic when VAD models are absent; see §6.7. When `--speakers` is active, the same segmentation feeds the speaker pipeline so each emitted segment carries a speaker label.
- When both `-a` and `-t` are given, audio and transcript are produced in the same capture pass.
- If `--engine whisper`, call a system-installed whisper.cpp binary (`whisper-cli`/`whisper-cpp` on `PATH`, or `$HARK_WHISPER_BIN`); if not found, provide a clear error with installation instructions (e.g., `brew install whisper-cpp`). The model comes from `--model` or `$HARK_WHISPER_MODEL`.
- Live transcription prefers a model-resident backend when `whisper-server` is available (`$HARK_WHISPER_SERVER_BIN` to override the path): the server is launched once on loopback (127.0.0.1) so the model loads a single time, and each segment is transcribed via a local HTTP request to its `/inference` endpoint. This is local IPC with Hark's own child process — not an external network call. It is disabled with `HARK_WHISPER_SERVER=0`, and Hark falls back to spawning `whisper-cli` per segment whenever the server is absent or fails to start, so transcription is never blocked by the optimization.
- STDERR from the transcription engine is passed through for debugging (suppressed for the high-volume per-segment live calls unless `-v`); a non-zero engine exit code propagates through the pipeline.
- Recognition uses a selectable engine (`--engine`, default `whisper`). All engines share one internal primitive — "transcribe a 16 kHz mono WAV (optionally translating) → text (+ optional timestamps)" — used by both batch and live paths.

| Engine | Runtime / deps | Languages | Auto-detect | Translate→EN | Model selection |
|--------|----------------|-----------|-------------|--------------|-----------------|
| `whisper` (default) | whisper.cpp CLI/server (external binary) | ~99 (multilingual model) | yes (`auto`) | yes | ggml path/short name; needs a non-`.en` model |
| `apple` | native `Speech.framework` (no deps) | ~50 locales | no (chosen/current locale) | no | OS-managed on-device assets |
| `whisperkit` | WhisperKit CoreML (SwiftPM dep) | ~99 | yes | yes | WhisperKit model name; auto-downloaded |
| `parakeet` | FluidAudio CoreML (SwiftPM dep) | 25 European (v3) / English (v2) | yes (auto) | no | `--model v2`/`v3`; auto-downloaded |

- An `.en` whisper model ignores `--language`; Hark warns when a non-English language is requested with such a model.
- `--translate` is rejected with a clear error on engines that don't support it (`apple`, `parakeet`).
- `apple` requires the macOS Speech Recognition TCC permission (docs/permissions.md) and on-device locale assets; it runs fully on-device (`requiresOnDeviceRecognition`, no network) and recognizes in one locale (`--language CODE` → locale, e.g. `de`→`de-DE`; `auto` uses the current locale). It produces plain text: batch (`-i`) rejects `--transcript-format srt|json` with a clear hint, while live `-t out.srt`/`.json` still works (timestamps come from Hark's segmenter).
- `whisperkit` and `parakeet` are Apple-Silicon-first (clear error on Intel) and load their CoreML model once, reused across live segments (model-resident, like the whisper-server backend). Both build `srt`/`json` from engine timings (whisperkit segments, parakeet token timings).
- `parakeet` auto-detects within its language set; a specific `--language` emits a notice and is ignored. `whisperkit` caches models under `~/.hark/models/whisperkit`; `parakeet` uses FluidAudio's managed cache (`~/Library/Application Support/FluidAudio/Models`). `hark models list` shows both.

### 6.7 Speaker Recognition & Diarization

Speaker labeling answers "who said what." It is **opt-in** via `--speakers`/`--diarize` (§6.1); without it, transcript output is unchanged. Two complementary mechanisms combine, because each is strong where the other is weak:

**a) Source attribution (deterministic, no ML).** When Hark already captures two distinct sources — `--mix`, or `--system`/`--app` with the microphone — the microphone (you) and the system audio (everyone on the call) are *inherently separate signals*. Today they are summed into one stream before transcription (`StreamMixer`/`StreamMixing`), which discards that separation and forces any "who spoke" decision onto an unreliable single-stream heuristic. Under `--speakers`, Hark **keeps the mic and system as separate internal tracks**, transcribes/segments each independently, and tags segments by origin: the mic side is labeled `You`, the system side `Others` (relabel with `--speaker-labels "You,Others"`). This is exact, cheap, headless-safe, and needs no model download. **The packaged audio output (`-a`) remains the mixed stream** by default; separate-track *audio* output is out of scope here (see §4.2 / Open Questions).

**b) Acoustic diarization (FluidAudio CoreML, on-device/ANE).** To resolve multiple distinct speakers *within* one stream — several remote participants on the system side, or a single-source/in-room recording — Hark uses FluidAudio's diarization models, reusing the dependency already linked for the `parakeet` engine (no new heavy dependency). Anonymous speakers are labeled `Speaker 1`, `Speaker 2`, …
   - **Offline mode** (default for `-i` file input, and for live capture with `--diarize-engine offline`): the most accurate pipeline (Pyannote Community-1 — segmentation + speaker embeddings + clustering). Runs over the whole recording; for live capture it records the stream(s) and diarizes at stop (transcript at end).
   - **Streaming mode** (default for live capture): real-time **end-to-end neural diarization** (FluidAudio **LS-EEND**, a long-form streaming EEND model). The diarizer ingests the system/single stream continuously and maintains a frame-level "who-spoke-when" **timeline** (~100 ms updates) that is independent of the ASR segmentation — so speaker turns are detected **by voice** (including mid-utterance changes and overlapping speech), not by silence. Each completed ASR segment is then attributed to the speaker who dominates its time window → `Speaker N`. Identity is held in the model's persistent streaming state across the whole session. This supersedes the earlier per-segment embedding-clustering approach, which collapsed distinct speakers when a VAD segment blended several voices.
   - `--diarize-engine auto|streaming|offline` overrides the mode. `--max-speakers N` and `--speaker-threshold` apply to the **offline/batch clustering** pipeline only; the streaming EEND model has no clustering threshold (its speaker capacity is fixed by the model, currently up to 10).

**c) Combined.** With `--speakers` (auto/acoustic) and two sources, Hark attributes the mic side as `You` (deterministic) and diarizes the system side, yielding `You` plus `Speaker 1/2…` for the remote participants in one transcript — live (streaming) or as an accurate offline pass at stop. `You` is a live-only label (a single mixed `-i` file can't separate your voice — everyone is `Speaker N`).

**Runtime segmentation (the "delay in a sound" fix).** Live segmentation no longer relies solely on an amplitude/silence threshold. On Apple Silicon, **FluidAudio VAD (Silero) drives the speech/pause boundaries by default** (a full streaming state machine with hysteresis and speech padding; and, in streaming diarization, speaker-change turns also cut segments). The Silero CoreML model is fetched on the first live run (then fully local) — the one network-using exception on the default live path, opt out with `HARK_VAD=0`. The existing `--silence-threshold` amplitude method remains the graceful fallback on Intel or whenever the VAD model can't be loaded, so transcription is never blocked. This stabilizes both transcription boundaries and speaker turns at runtime.

**Output.** Speaker labels are carried in every transcript format:
  - `txt` : each line is prefixed `Speaker 1: …` / `You: …`.
  - `srt` : the speaker is prefixed in the cue text (`[Speaker 1] text`), keeping the file valid SRT.
  - `json` : every segment object gains a `"speaker"` field alongside `start`/`end`/`text`.

**Models & platform.**
  - Diarization/VAD CoreML models are managed through `hark models` (engine-tagged, e.g. `fluidaudio:diarizer`, `fluidaudio:vad`) and FluidAudio's own cache (`~/Library/Application Support/FluidAudio/Models`); `hark models list` shows them. They download from Hugging Face on first use (opt-in network, then fully local) — consistent with the `whisperkit`/`parakeet` engines and §7 Security & Privacy.
  - Acoustic diarization and VAD are **Apple-Silicon-first** (runtime-gated with a clear error on Intel, like `whisperkit`/`parakeet`). **Source attribution (a) has no such requirement** — it is pure stream routing and works everywhere `--mix` works, including headless. No new TCC permission is required (same captured audio).

### 6.8 Startup Status

- When a **live capture** starts, Hark prints a concise, human-readable status block to **stderr** summarising the resolved configuration: recognition engine, model, language (and `--translate`), input source/device (and capture backend for system/app), audio format (rate/bits/channels), output destinations (audio path/format, transcript path/format, or "stdout"), speaker mode, VAD on/off, and any `--duration`/`--split` limit.
- **Visibility:** shown by default when stderr is a TTY, and always with `-v`; **suppressed when stderr is not a TTY** (redirected/piped/cron) so machine pipelines stay clean. It is **never written to stdout** and therefore never corrupts `-a -`/`-t -` streams.
- It reuses already-resolved values (the same data `-v` logs today via `Log.verbose`), so it adds no new resolution work; it is a presentation layer over the existing settings resolution.

### 6.9 Interactive Mode

- `--interactive` runs a **live capture** in a minimal terminal UI on the controlling terminal: a status header (§6.8), the live transcript as it is produced (with speaker labels when `--speakers` is active), and status lines for control hints and pause/resume/stop notices (printed on stderr so they don't fight the transcript on stdout).
- **Controls (single keypress):** **space** toggles pause/resume; **m** toggles microphone mute/unmute; **y** yanks (copies) the transcript so far to the system clipboard; **Enter** finishes. Stop is equivalent to SIGINT (Ctrl-C also works) — capture is finalised so every output file remains playable. The **m** control is shown in the hint line only when a microphone is part of the capture.
- **Pause semantics:** pausing **suspends capture**; the paused interval is **not** written to any output (audio or transcript), producing a true gap. Consequently the output length is shorter than wall-clock by the total paused time. Resume continues appending. (Interaction with `--split` is noted in §10.)
- **Mute semantics (`m`):** muting silences **only the microphone** contribution; unlike pause it does **not** create a gap — the recording timeline is preserved. In a mixed capture (`--mix`, or `--system`/`--app` + mic) the system audio keeps recording normally while the mic side goes silent; in a mic-only capture the muted interval is recorded as silence (output length still matches wall-clock). While muted, the microphone (`You`) side produces no transcript. Mute and pause are independent toggles. The control applies only when a microphone is part of the capture; with no mic present the **m** hint is hidden, and pressing **m** prints a brief notice and does nothing.
- **Yank semantics (`y`):** copies the **full session transcript captured so far** to the **system clipboard** as plain text (including speaker labels when `--speakers` is active), replacing the clipboard contents; a short confirmation is printed on stderr. If nothing has been transcribed yet, a brief notice is shown and the clipboard is left unchanged. Yank is interactive-only (the remote-control API never serves transcript content, §6.10).
- **Requirements & exclusivity:** requires a controlling TTY (clear usage error otherwise). It is **mutually exclusive with stdout outputs** (`-a -`, `-t -`, `--raw`) because the UI owns the terminal, and with `--remote-control`. The live transcript is **always rendered in the UI** (on stdout) as it is produced — whether or not `-t` is named — and naming `-t FILE`/`-a FILE` **additionally persists** the transcript/audio to those files **at the same time** (the on-screen captions are plain text regardless of the file's format).
- **Terminal hygiene:** raw/cbreak mode and any alternate display state are **always restored on exit**, including on SIGINT/SIGTERM and on error.

### 6.10 Remote-Control Agent

- `hark --remote-control [[host:]port]` starts Hark as a long-running **control agent** that does **not** capture on its own; it serves a small HTTP/1.1 + JSON API over TCP and waits for commands. The value is **optional**: omitted, it binds **loopback `127.0.0.1`** on the configured `remote-control-port` (default **8473**); a bare port or empty host binds loopback on that port; `0.0.0.0:PORT` or a specific IPv4 binds elsewhere (IPv6 is not supported). The agent prints its bound address to stderr on start.
- **Running as a managed service:** the agent is a foreground, SIGTERM-clean process (it blocks until stopped and shuts down cleanly on SIGINT/SIGTERM), so launchd can supervise it via `brew services` — `brew services start hark` runs it as a **per-user LaunchAgent** that auto-starts at login. The bound port is the `remote-control-port` config key (default 8473); set capture/engine defaults with `hark config`. The service runs with `--no-keep-awake` and **no launchd `KeepAlive`** by default (auto-restart is an opt-in plist edit — a crash stays visible for debugging rather than relaunching in a throttled loop). See §4.2 and docs/remote-control.md. (Per-user agent; stops at logout — headless/scheduled operation is Post-MVP.)
- **Defaults from launch flags:** any capture/transcription flags supplied at launch (e.g. `--system --mix --engine whisperkit -C ~/Recordings`) become the **session defaults**; a `POST /start` body may override them.
- **Where:** output paths in a start request are resolved against the agent's working `directory` (Feature 20 / §6.1). Relative names (e.g. derived from a meeting title) are therefore written to a known, configured location; absolute paths are honoured as-is.
- **Endpoints — flat control verbs (one active session):**
  - `GET /status` — agent liveness, version, bind address, and the current session's state (`idle`/`recording`/`paused`), `muted` flag, elapsed time, and output paths.
  - `POST /start` — begin recording; an optional JSON body mirrors the CLI flags/outputs over the launch defaults (e.g. `{ "transcript": "notes.txt", "audio": "rec.m4a", "system": true }`), plus `muted` to begin with the mic muted. Returns the new state + resolved output paths.
  - `POST /pause` · `POST /resume` — pause/resume the active recording (pause uses the §6.9 gap semantics).
  - `POST /mute` · `POST /unmute` — mute/unmute the **microphone** of the active recording (§6.9 mute semantics: silences **only** the mic, the timeline is preserved — distinct from pause; orthogonal to `state`; idempotent). Requires a microphone in the capture (mic-only or `--mix`); on a system/app capture with no mic they return `422`. The transcript yank (`y`, §6.9) is **not** exposed — the API never serves transcript content.
  - `POST /stop` — stop and finalise the active recording.
- **Single active session:** the agent records **one session at a time**; a `POST /start` while a recording is active is rejected with `409 Conflict`. (Concurrent sessions are out of scope for now.)
- **Control + status only:** the API exposes **controls and status metadata only** — it **never serves transcript or audio content**. Produced artifacts are retrieved from the working `directory` over the filesystem, not the API.
- **Errors** map Hark's exit-code semantics onto HTTP status codes (e.g. permission denied → `403`, bad parameters → `400`, engine/model missing → `404`/`422`, already recording → `409`) with a JSON `{ "error": … }` body.
- **Security:** the listener is **loopback-only by default**, consistent with §7 "no external network calls by default" (it accepts local connections; it makes none). Binding to a **non-loopback** interface is explicit opt-in and **requires a bearer token** (`$HARK_REMOTE_TOKEN`, sent as `Authorization: Bearer …`); the agent **refuses to bind** to a non-loopback address without one. `--remote-control` is mutually exclusive with `--interactive` and with the immediate-capture/`-i` input modes.
- **Clients:** no client is bundled — the wire protocol is documented so any language can drive it (`curl`, scripts, browser userscripts). A **Tampermonkey Google-Meet reference userscript** ships at `examples/hark-meet.user.js`: it watches `meet.google.com`, calls `POST /start` on call-join with a filename derived from the meeting title + date, and `POST /stop` on call-end, using `GM_xmlhttpRequest` to the loopback agent. It also **mirrors the Meet mic mute** to the recording one-way (Meet → hark): initial `muted` state on `/start`, then `POST /mute`/`/unmute` as you toggle in Meet.

---

## 7. Non-Functional Requirements

| Category | Requirement |
|----------|-------------|
| **Performance** | Recording must use < 3% CPU on an Apple Silicon Mac (16 kHz mono); buffering delays < 100 ms. Live diarization (streaming) must keep up with real time (RTF < 1) on Apple Silicon and emit speaker labels close to runtime — a tentative label within ~1 s and a finalized one within ~2 s of a turn. Offline (`-i`) diarization is bounded by file length, not interactive. Source attribution (§6.7a) adds negligible overhead. Interactive (§6.9) and remote-control (§6.10) commands must take effect promptly — a control request is acknowledged within ~100 ms and pause/resume takes hold within one capture buffer. |
| **Reliability** | 24-hour continuous recording must produce a valid, non-corrupted file when terminated via SIGINT/SIGTERM. Resilience to hard kills (SIGKILL, power loss) is parked — see Open Questions. |
| **Usability** | CLI help and error messages are clear, include examples, and follow POSIX utility conventions. The startup status summary (§6.8) shows the resolved configuration on stderr without polluting stdout. Interactive mode (§6.9) uses single-key controls and **always restores the terminal** (raw/alternate-screen state) on exit, error, or signal. |
| **Compatibility** | macOS 14.4 (Sonoma) and later — required by the Core Audio process-tap API; both Intel and Apple Silicon. The ScreenCaptureKit capture backend additionally needs macOS 15+ and a graphical login session; on macOS 14.x or headless it falls back to the Core Audio tap (see §6.2). The `whisperkit` and `parakeet` engines, and **acoustic diarization / VAD (§6.7b)**, are Apple-Silicon-first (runtime-gated with a clear error on Intel); `whisper` and `apple` cover Intel. **Source attribution (§6.7a) is platform-agnostic** (pure stream routing) and works wherever `--mix` works, including headless. Interactive mode (§6.9) requires a controlling TTY (clear usage error otherwise); the status summary (§6.8) and the remote-control agent (§6.10) are platform-agnostic and run headless. |
| **Security & Privacy** | No external network calls by default; cloud transcription backends are opt-in and use HTTPS with user-provided API keys. (Live transcription may run a local `whisper-server` bound to loopback 127.0.0.1 for performance — IPC with Hark's own child process, never an external connection; disable with `HARK_WHISPER_SERVER=0`.) **The remote-control agent (§6.10) opens a TCP listener only when `--remote-control` is given; it binds loopback `127.0.0.1` by default (accepting local connections, making none — still no outbound calls). Binding to a non-loopback interface is explicit opt-in and requires a bearer token (`$HARK_REMOTE_TOKEN`); the agent refuses to bind otherwise.** System/app audio capture requires a TCC permission that depends on the backend (§6.2): the Core Audio tap uses the narrower "System Audio Recording" permission (and works headless); the ScreenCaptureKit backend requires the broader "Screen Recording" permission and a GUI session. Both are terminal-attributed for unbundled CLIs and their approval flows are documented. The `apple` engine uses the Speech Recognition TCC permission; `whisperkit` and `parakeet` download CoreML models from Hugging Face on first use (model fetch only, then fully local). Speaker diarization/VAD (§6.7) likewise fetch FluidAudio CoreML models from Hugging Face on first use, then run fully on-device, and require **no additional TCC permission** (they operate on already-captured audio). Note: live VAD segmentation is on by default on Apple Silicon, so its Silero model is fetched on the first live run — a deliberate, documented exception to "no network by default", opt out with `HARK_VAD=0`. Interactive yank-to-clipboard (`y`, §6.9) writes to the local system clipboard only — no network. |
| **Maintainability** | Single Swift binary built with SwiftPM; modular targets: `DeviceManager`, `TapEngine`, `Encoders`, `CLI`. Well-documented code. The CoreML engines add the `argmaxinc/argmax-oss-swift` (whisperkit) and `FluidInference/FluidAudio` (parakeet) SwiftPM dependencies, currently always linked (a lean/trait-gated build is a future option — they increase binary size). Speaker diarization and VAD (§6.7) reuse the already-linked `FluidInference/FluidAudio` dependency, so they add no new SwiftPM dependency (only additional model assets). |
| **Installability** | Distributed via Homebrew (`brew install hark`) and direct download from GitHub Releases; binary is signed and notarized so TCC permission flows work cleanly. The Homebrew formula provides a `service` block so the remote-control agent (§6.10) runs under launchd via `brew services start hark` (per-user LaunchAgent). |
| **Auditability** | All recorded file paths and durations are logged to STDERR when `-v` is enabled. |
| **Legal & Compliance** | Hark contains **no proprietary cryptography**; its only cryptographic use is *ancillary* — OS-provided TLS via `URLSession` for opt-in model downloads and the transitively-linked `swift-crypto` used by the CoreML/transformers plumbing — so it falls under the EAR **Note 4 to Category 5 Part 2** ancillary exclusion and the **publicly-available open-source** provisions (§734.3(b)(3) / §742.15(b) / §740.13(e)); self-classified **EAR99 / not a controlled encryption item**. Capture is **consent-gated by macOS TCC** (mic / System Audio Recording / Screen Recording) — overt, local, on-device — so Hark is **not** covert-interception or "intrusion software". Recording-consent law (wiretap / one- vs two-party consent / GDPR) is the **user's** responsibility; Hark makes no network calls by default and ships no telemetry. Encryption import/registration regimes (e.g. Russia FSB, China) bind in-country **importers/distributors of encryption products**, not the publication of open source. See **[docs/legal.md](docs/legal.md)**. (Informational, not legal advice.) |

---

## 8. Success Metrics (KPIs)

- **Adoption:** 1000 Homebrew installs within 3 months of public release.
- **Pipeline integration:** At least two open-source transcription projects (e.g., `whisper.cpp`, `faster-whisper`) officially list Hark as a recommended capture tool.
- **Reliability:** Crash-free session rate > 99.5%, measured via strictly opt-in telemetry (consistent with the "no network calls by default" security requirement; mechanism TBD — see Open Questions).
- **Community engagement:** Minimum 10 pull requests contributed from external developers within 6 months (discouraging feature bloat, but demonstrating extendability).
- **Source attribution accuracy:** ~100% — in a two-source capture, every segment is attributed to its true origin (mic vs system) because the routing is deterministic, not inferred.
- **Diarization quality:** Diarization Error Rate (DER) on a reference set (e.g. AMI-style meeting audio) within a documented target band for the chosen FluidAudio model; tracked offline so regressions are visible.
- **Runtime labeling latency:** ≥ 90% of live speaker labels finalized within ~2 s of the corresponding turn (per §7 Performance).
- **Segmentation stability:** VAD-based live segmentation produces measurably fewer spurious cuts than the amplitude-threshold method on a fixed test clip (the "delay in a sound" instability this feature targets).
- **Remote-control responsiveness:** API control commands (start/stop/pause/resume) round-trip in < 200 ms on loopback, and the shipped Tampermonkey Google-Meet recipe records + names a call end-to-end without manual steps.

---

## 9. Timeline & Milestones

| Milestone | Deliverables | Target | Dependencies |
|-----------|--------------|--------|--------------|
| **M1 – Core Capture** | Swift/SwiftPM project skeleton, device & app enumeration (`devices`, `apps`), mic recording to WAV, signal handling, stdout streaming | Week 1–2 | — |
| **M2 – System Audio** | Core Audio process taps: `--system`, `--app`, `--exclude-app`, `--mix`; TCC permission flow & docs | Week 3–4 | M1 |
| **M3 – Formats & Chunking** | M4A/FLAC output, MP3/Opus (static libs), time-based splitting, transcoding via `-i in -a out` | Week 5–6 | M1 |
| **M4 – Transcription MVP** | Root-verb transcription with local Whisper support; stdin/file/live input; combined `-a`+`-t` | Week 7 | M3 |
| **M5 – Polish & Release** | Code signing & notarization, Homebrew formula, man page, example scripts, CI/CD, public beta | Week 8–9 | M2, M3, M4 |
| **M6 – Engines & Languages** | Engine abstraction; multilingual + `--translate` + `--language auto` on whisper; `hark models`; `apple` (Speech.framework) and `whisperkit` (CoreML) engines | Post-M5 | M4 |
| **M7 – Speaker Recognition & Runtime Segmentation** | Source attribution (You/Others) via internal multi-track capture; acoustic diarization (FluidAudio, offline + streaming); VAD-based live segmentation; `--speakers`/`--diarize` flags; speaker labels in txt/srt/json; diarization/VAD models in `hark models` | Post-M6 | M4, M6 |
| **M8 – Status, Interactive & Remote Control** | Startup status summary (§6.8); `--interactive` minimal UI with pause(gap)/resume, mic mute/unmute, transcript yank-to-clipboard, stop (§6.9); `--remote-control` HTTP/JSON agent (§6.10) with start/stop/pause/resume/status, loopback default + token for non-loopback; working-directory path resolution for outputs; documented protocol + Tampermonkey Google-Meet reference userscript | Post-M7 | M4, Feature 20 (working directory) |
| **Post-MVP** | Scheduled/unattended launchd daemon, cross-host/authenticated remote control, streaming transcription, cloud backends, configuration profiles, named speaker identification (voiceprints), overlapping-speech handling | Ongoing | M5, M8 |

---

## 10. Open Questions & Assumptions

1. **Crash resilience (parked):** How should recordings survive hard kills (SIGKILL, power loss)? Candidates: periodic header flush every N seconds, or a `hark repair` subcommand for truncated files. Decision deferred.
2. **Whisper bundling:** Will the tool bundle a transcription engine or expect the user to install it separately? (Assumption: no bundling to keep the binary small; document external dependencies.)
3. **Telemetry mechanism:** What opt-in mechanism (if any) will measure the crash-free-rate KPI without violating the no-network-by-default principle?
4. **TCC for unbundled CLI:** Confirm the exact permission-attribution behaviour for a signed standalone binary vs. terminal-attributed permission, and document the recommended setup.
5. **Named speaker identification (deferred):** How should enrolled voiceprints be stored and matched (local embedding store, privacy, cross-recording identity), and what CLI surface (`hark speakers enroll`?) does it need? Deferred to Post-MVP.
6. **Overlapping speech:** The streaming EEND diarizer (LS-EEND) models overlap internally (independent per-speaker activity per frame), so its timeline can mark concurrent speakers. Hark still emits one label per ASR segment (the dominant speaker), because the ASR engine produces one text per segment; true per-word/overlap attribution (WhisperX-style word-level alignment) is deferred.
7. ~~**Diarization streaming model choice:** LS-EEND vs Sortformer~~ → **Resolved:** live streaming uses **LS-EEND** — FluidAudio's long-form streaming end-to-end neural diarizer — maintaining a continuous frame-level speaker timeline decoupled from the ASR VAD segmentation. This replaced the original per-segment embedding-clustering approach, which collapsed distinct speakers whenever a VAD segment blended several voices (the whole-segment embedding was not discriminative). Sortformer (4-speaker cap, steadier identities) remains a possible alternative. (FluidAudio model-download footprint of always-linking the diarization assets is still open.)
8. **Separate-track audio output:** Whether to expose the internal mic/system separation as user-facing audio output (e.g. dual files or L/R channels), beyond its use for transcript attribution. Currently scoped out (see §4.2).
11. **Export/encryption classification (assumption):** Hark's cryptographic use is assessed as *ancillary* (OS TLS + transitively-linked `swift-crypto`), self-classified **EAR99 / not a controlled encryption item** as publicly-available open source (§7 Legal & Compliance, docs/legal.md). A formal BIS/NSA **TSU notification** email is **deferred** unless a non-ancillary crypto dependency is added or a commercial/import distribution channel opens (which would also implicate in-country encryption import/registration regimes).
9. ~~**Remote control (deferred):** Transport/protocol, auth, and exposed operations are open.~~ → **Resolved into scope (M8, §6.10):** transport is **HTTP/1.1 + JSON over TCP**, loopback by default with `[interface:]port` override; operations are **flat control verbs** (`GET /status`, `POST /start|/pause|/resume|/stop`) over a **single active session** (control + status only — no content download); outputs resolve under the working `directory`; clients are external (documented protocol + a Tampermonkey Google-Meet reference userscript). **Still open:** hardened **non-loopback auth** beyond the bearer-token gate (TLS, allow-lists); and whether to later allow **concurrent sessions** (currently rejected with `409`). (Conventional loopback port resolved to **8473**.) Scheduled/unattended and cross-host control remain Post-MVP (§4.2).
10. ~~**Interactive pause × `--split` (§6.9):** force a chunk boundary on pause, or leave a gap inside the current chunk?~~ → **Resolved:** pause **drops captured chunks entirely**, so the byte-clock simply gaps — `--split` opens **no** new chunk while paused and the current chunk continues on resume. (Both interactive and the remote agent share this; the chunk boundary tracks captured audio, not wall-clock.)

### Resolved (2026-06-12)
- ~~Language/stack~~ → **Swift**, single binary, SwiftPM modular targets.
- ~~System audio without a virtual device~~ → **Core Audio process taps** (macOS 14.4+); BlackHole no longer required.
- ~~Product/binary naming~~ → **hark**.

---

**Document Status:** MVP implemented; v0.1.0 beta release.
**Next Steps:** Post-beta — code signing + notarization for direct downloads; long-run reliability (24 h) and CPU performance validation; homebrew-core submission for bare `brew install hark`; decide crash-resilience strategy (Open Question 1).
