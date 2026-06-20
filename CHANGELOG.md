# Changelog

All notable changes to Hark are documented here. The format is loosely based on
[Keep a Changelog](https://keepachangelog.com/), and the project aims to follow
[Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-06-20

First public beta. A native macOS CLI (single Swift binary) that captures
microphone and system/per-app audio, saves transcription-friendly recordings,
transcribes them, and composes into Unix pipelines.

### Capture
- Live capture from the default/`-d` microphone, all system audio (`--system`),
  specific apps (`--app`, repeatable), or everything except some (`--exclude-app`).
- `--mix` to combine the microphone with a system/app capture (clock-synced).
- Two interchangeable backends — ScreenCaptureKit (macOS 15+) and Core Audio
  process taps (macOS 14.4+, headless) — via `--capture-backend auto|sckit|coreaudio`.
- `--duration`, `--split duration=SEC|silence=SEC`, configurable rate/bits/channels.

### Formats
- Audio output to WAV, M4A, FLAC, MP3 (vendored LAME), and Opus; `--format` override.
- WAV streaming on stdout (`-a -`) and raw PCM (`--raw`) for pipelines.
- `hark -i IN -a OUT` transcodes between formats; `hark info <file>` inspects them.

### Transcription
- Engines via `--engine`: `whisper` (whisper.cpp, default), `apple`
  (Speech.framework, on-device), `whisperkit` and `parakeet` (CoreML, Apple Silicon).
- `--language` (auto-detect by default), `--translate`, transcript output as
  `.txt`/`.srt`/`.json` (`-t`), near-real-time live transcription.

### Speaker labeling
- `--speakers` (`--diarize`): source attribution (You/Others) and acoustic
  diarization (`Speaker N`), live (streaming LS-EEND) or offline; Apple-Silicon-first.

### Interactive & remote control
- `--interactive`: minimal terminal UI with space=pause/resume, Enter=finish;
  the live transcript shows on screen and is concurrently saved when `-t FILE`
  is named.
- `--remote-control [host:]port`: loopback HTTP/JSON control agent
  (start/stop/pause/resume/status) with a Tampermonkey Google-Meet reference
  userscript. See docs/remote-control.md.

### Configuration & UX
- Settings resolve flag › `$HARK_*` › `~/.hark/config.json` › built-in default;
  `hark config show/set/unset/path`. `hark models list/download` manages models.
- `-C/--directory` base directory for relative artifact paths; startup status on
  stderr; POSIX exit codes.

### Examples
- `examples/` recipe scripts: `hark-meeting`, `hark-note`, `hark-dictate`.

### Notes
- Requires macOS 14.4+. The prebuilt binary is Apple Silicon (arm64); Intel users
  build from source. The `whisper` engine needs an external whisper.cpp binary.
- This beta binary is not yet notarized; install via Homebrew (no Gatekeeper
  prompt) or remove the quarantine attribute on a direct download.

[0.1.0]: https://github.com/PhantomYdn/hark/releases/tag/v0.1.0
