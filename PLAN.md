# Aural - Implementation Plan

> Source: [PRD.md](PRD.md) (v1.0 MVP, 2026-06-12). Phases map to PRD §9 milestones.

## Incoming

> Unscheduled items. Add new work here; `/plan` will triage on next run.

## Phase 1: Project Foundation & Core Capture (PRD M1)

- [x] Initialize git repository with `.gitignore` for Swift/SwiftPM
- [x] Create SwiftPM package with modular targets: `DeviceManager`, `TapEngine`, `Encoders`, `CLI` (PRD §7 Maintainability)
- [x] Add `swift-argument-parser` dependency and scaffold subcommand structure: `devices`, `apps`, `record`, `transcribe`, `convert`, `info` with `-h/--help` and `-v/--verbose`
- [x] Implement `aural devices`: enumerate AudioDeviceIDs via CoreAudio (UID, name, channels, sample rates), exclude inactive devices, `--list-inputs`/`--list-outputs`
- [x] Implement `aural apps`: list running applications capturable via process taps (name, bundle ID, PID)
- [x] Add `--json` output mode to `devices` and `apps`; exit 0 with empty array when nothing found (US06)
- [x] Implement mic recording to WAV: default input device fallback, `-d/--device`, `-r/--rate`, `-b/--bits`, `-c/--channels`, `-t/--duration` (US01)
- [x] Implement SIGINT/SIGTERM handling: finalise WAV header so file remains playable (PRD §7 Reliability)
- [x] Implement stdout streaming: raw PCM when `-o` omitted, `--stdout` with streamable WAV header; verify interop with `ffmpeg`/`sox` (header verified by manual RIFF parse; ffmpeg/sox not installed locally — re-verify in CI)
- [x] Implement `--no-output` dry-run mode
- [x] Define and document exit codes (0 success, non-zero documented failures)
- [x] Unit tests: device enumeration, WAV writer header correctness, argument parsing

## Phase 2: System & App Audio via Core Audio Taps (PRD M2)

- [x] Implement `TapEngine` using `CATapDescription` / `AudioHardwareCreateProcessTap` (macOS 14.4+)
- [x] Implement `--system`: global process tap capturing all system audio
- [x] Implement `--app ID` (repeatable): capture specific application(s) by bundle ID or PID (US02, US07)
- [x] Implement `--exclude-app ID` (repeatable): capture all system audio except listed apps (US07)
- [ ] Implement `--mix`: mix microphone into system/app capture
- [ ] Handle tap lifecycle: create on start, destroy on stop; finalise recording cleanly and report on stderr if tapped app quits mid-recording (PRD §6.2)
- [ ] Handle "System Audio Recording" TCC permission: detect denial, emit actionable error; document prompt/approval flow incl. terminal-attributed permission for unbundled CLI (PRD §7 Security, Open Q4)
- [ ] Validate latency drift < 200 ms between mic and system tracks over a 60-minute dual-source recording (PRD §2)
- [ ] Integration tests: per-app capture isolation (excluded app audio absent from recording)

## Phase 3: Formats, Chunking & Conversion (PRD M3)

- [ ] Implement M4A/AAC output via native CoreAudio encoder (P0)
- [ ] Implement FLAC output via native CoreAudio encoder (P0)
- [ ] Implement format selection: extension-based detection (`.wav`, `.m4a`, `.flac`, `.mp3`, `.opus`) plus `--format` override
- [ ] Implement MP3 output via statically linked LAME (P1)
- [ ] Implement Ogg/Opus output via statically linked libopus/libogg (P1)
- [ ] Implement `--split duration=SEC`: sequential files (`name_001`, `name_002`, …) with correctly flushed headers (P1)
- [ ] Implement `--split silence=SEC` with configurable dBFS threshold; each chunk independently playable (P2, US04)
- [ ] Implement `aural convert`: format conversion reusing CoreAudio codecs (PRD §6.1)
- [ ] Implement `aural info`: print duration, sample rate, channels, metadata; read support for WAV, AIFF, CAF, M4A, FLAC
- [ ] Implement metadata embedding: WAV INFO chunk, MP4 atoms for M4A, ID3v2 for MP3 (P2)
- [ ] Verify all output formats are accepted as-is by `whisper.cpp`, Fabric AI, and at least one cloud transcription API (PRD §6.4)

## Phase 4: Transcription Pipeline (PRD M4)

- [ ] Implement `aural transcribe -i <file>`: batch transcription of an audio file
- [ ] Implement `-i -` stdin mode: read raw audio from stdin, no temporary files (US03)
- [ ] Implement source input mode: record from device UID in memory, pipe to engine, output text to stdout
- [ ] Implement `--engine whisper` (default): invoke system-installed whisper binary
- [ ] Implement `--model`, `--language`, `--output-format txt|srt|json` flags
- [ ] Missing-engine UX: clear error with installation instructions (`brew install whisper-cpp`) (PRD §6.6)
- [ ] Pass engine STDERR through for debugging; propagate non-zero exit codes through pipelines (US03)
- [ ] End-to-end test: `aural record -t 60 --stdout | aural transcribe -i -` produces transcript

## Phase 5: Release Engineering & Public Beta (PRD M5)

- [ ] Set up GitHub Actions CI: build, unit/integration tests on macOS 14.4+ runners
- [ ] Code signing and notarization so TCC permission flows work cleanly (PRD §7 Installability)
- [ ] Create Homebrew formula; verify `brew install aural` end-to-end (US05)
- [ ] Write man page following POSIX utility conventions
- [ ] Write README: install, TCC permission setup, usage examples, exit codes
- [ ] Provide example scripts: meeting recording, transcription pipeline, cron/launchd setup
- [ ] Validate unattended operation from cron/launchd after TCC grant (US05)
- [ ] Reliability test: 24-hour continuous recording produces valid file on SIGINT/SIGTERM (PRD §7)
- [ ] Performance validation: < 3% CPU on Apple Silicon at 16 kHz mono; buffering < 100 ms (PRD §7)
- [ ] Release automation: GitHub Releases with binary artifacts; tag v1.0.0-beta
- [ ] Fill PRD Author field and re-review acceptance criteria US01–US07 against implementation

## Future

> Nice-to-have items outside current scope.

- [ ] Daemon/agent mode: launchd-managed background service for scheduled recording with IPC (PRD §4.2)
- [ ] Crash resilience for hard kills: periodic header flush vs `aural repair` subcommand (parked — PRD Open Q1)
- [ ] Opt-in telemetry mechanism for crash-free-rate KPI (PRD Open Q3)
- [ ] Real-time streaming to network socket or HTTP endpoint
- [ ] Multi-channel mapping: separate tracks for mic and system audio
- [ ] Plugin system for custom DSP filters (EQ, noise suppression)
- [ ] Configuration profiles for default sources, formats, transcription settings
- [ ] Cloud transcription backends (Deepgram, Google) via `--engine cloud`
- [ ] Silence-based voice activity detection for trimming
