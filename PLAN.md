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
- [x] Implement `--mix`: mix microphone into system/app capture
- [x] Handle tap lifecycle: create on start, destroy on stop; finalise recording cleanly and report on stderr if tapped app quits mid-recording (PRD §6.2)
- [x] Handle "System Audio Recording" TCC permission: detect denial, emit actionable error; document prompt/approval flow incl. terminal-attributed permission for unbundled CLI (PRD §7 Security, Open Q4) — see docs/permissions.md; denial yields silent zeroed buffers, detected via SilenceDetector warning
- [x] Validate latency drift < 200 ms between mic and system tracks over a 60-minute dual-source recording (PRD §2) — measured −46 ms/hour (PASS, 4x inside budget; 24 ping pairs over 58.4 min, Scripts/drift-analyze.py)
- [x] Integration tests: per-app capture isolation (excluded app audio absent from recording) — Scripts/e2e-app-isolation.sh (Goertzel-based, 120x suppression verified)

## Phase 3: Formats, Chunking & Conversion (PRD M3)

- [x] Implement M4A/AAC output via native CoreAudio encoder (P0)
- [x] Implement FLAC output via native CoreAudio encoder (P0) — note: OS encoder silently corrupts files < 4608 frames; guarded with a clear error
- [x] Implement format selection: extension-based detection (`.wav`, `.m4a`, `.flac`, `.mp3`, `.opus`) plus `--format` override
- [ ] Implement MP3 output via statically linked LAME (P1) — deferred: vendor LAME as SwiftPM C target in a dedicated session; `.mp3` currently exits 69
- [ ] Implement Ogg/Opus output via statically linked libopus/libogg (P1) — deferred; preferred approach: native `kAudioFormatOpus` encoder + hand-written Ogg muxer (zero deps); `.opus` currently exits 69
- [x] Implement `--split duration=SEC`: sequential files (`name_001`, `name_002`, …) with correctly flushed headers (P1)
- [x] Implement `--split silence=SEC` with configurable dBFS threshold (`--silence-threshold`, default −50); each chunk independently playable, no audio dropped (P2, US04)
- [x] Implement `aural convert`: format conversion reusing CoreAudio codecs (PRD §6.1) — verified by lossless tone roundtrips (wav→m4a→wav, wav→flac→wav)
- [x] Implement `aural info`: print duration, sample rate, channels, metadata; read support for WAV, AIFF, CAF, M4A, FLAC
- [x] Implement metadata embedding: WAV INFO chunk (ICRD/ISFT/INAM) — MP4 atoms and ID3v2 deferred with their formats (P2)
- [ ] Verify all output formats are accepted as-is by `whisper.cpp`, Fabric AI, and at least one cloud transcription API (PRD §6.4) — whisper.cpp ✓ (e2e-transcribe.sh: wav/m4a/flac all transcribed); Fabric AI + cloud API checks still need network/API keys

### Pending live verification (capture permissions were reset mid-session; needs GUI access)

> Commands updated to the unified root-verb syntax (see Phase 4.5).

- [ ] Re-grant TCC: Microphone for the terminal (System Settings → Privacy & Security → Microphone) and System Audio Recording (Screen & System Audio Recording → "+" → terminal, restart terminal)
- [ ] `aural --duration 2 -a x.m4a` and `x.flac` — live encoded capture (afinfo check)
- [ ] `aural --duration 5 --split duration=2 -a x.wav` — 3 chunks, each playable
- [ ] Live `--split silence` smoke with real audio
- [ ] Re-run `Scripts/e2e-app-isolation.sh` (should still pass)
- [ ] `aural -a - --duration 10 | aural -i -` — the literal US03 mic pipeline
- [ ] `aural -d <mic-UID> --duration 5 -t -` while speaking — live mic → transcript on stdout
- [ ] `aural --duration 5 -a x.m4a -t x.srt` while speaking — combined record + transcribe in one pass

## Phase 4: Transcription Pipeline (PRD M4)

- [x] Implement `aural transcribe -i <file>`: batch transcription of an audio file (any readable format, normalized to 16 kHz mono internally)
- [x] Implement `-i -` stdin mode: read raw audio from stdin (WAV-stream sniffing + raw PCM flags); staged via temp file internally (US03)
- [x] Implement source input mode: record from device UID in memory, pipe to engine, output text to stdout — live mic check pending TCC re-grant
- [x] Implement `--engine whisper` (default): invoke system-installed whisper binary (`whisper-cli`/`whisper-cpp` on PATH, `AURAL_WHISPER_BIN` override)
- [x] Implement `--model`, `--language`, `--output-format txt|srt|json` flags (model fallback: `$AURAL_WHISPER_MODEL`) — note: `--output-format` renamed `--transcript-format` in the Phase 4.5 redesign
- [x] Missing-engine UX: clear error with installation instructions (`brew install whisper-cpp`) (PRD §6.6); missing model gets a HuggingFace download line
- [x] Pass engine STDERR through for debugging; propagate non-zero exit codes through pipelines (US03) — verified: whisper exit 3 propagated
- [x] End-to-end test: pipe-to-transcript verified permission-free via Scripts/e2e-transcribe.sh (say-synthesized speech; WAV + raw-PCM pipes); the literal mic variant `record --stdout | transcribe -i -` is on the pending-live list

## Phase 4.5: Unified Root Verb — CLI Redesign (PRD §6.1, §6.6)

> `aural` itself becomes the verb ("listen and transcribe"). One input (live by
> default, or `-i FILE/-`), outputs you name (`-a` audio, `-t` transcript, `-` =
> stdout); naming none transcribes to stdout. The `record`, `transcribe`, and
> `convert` subcommands are removed; `devices`/`apps`/`info` remain.

### Change 1 — Restructure + docs (parser, engines, doc sweep)

- [x] Root command with input/output flag groups; `record`/`transcribe`/`convert` folded in and removed
- [x] Extract `CaptureEngine` (multi-sink live capture core) and `TranscribeEngine` (normalize → whisper → transcript write; stdin staging)
- [x] Default-output rule: name none → `-t -`; `-a -` → WAV stream; `--raw -a -` → headerless PCM; `--no-output` hidden dry-run
- [x] Validation: one input mode (`-i` ⊥ live flags), ≤1 stdout, `--split` needs `-a FILE`, `--raw` needs `-a -`, `--duration`/`--split` live-only
- [x] `-t` repurposed to `--transcript`; duration moved to long-only `--duration`; `--output-format` → `--transcript-format`
- [x] Transcoding via `-i in -a out` replaces `convert`; combined `-a`+`-t` in one pass
- [x] `info` takes a positional `<file>` (frees `-i` for the root's input flag)
- [x] Update parser/output-resolution tests (`make test` green — 80 tests, 23 suites)
- [x] Doc sweep: PRD §6.1/§6.3/§6.6 + FR table + US01–US04; scripts, docs/permissions.md, help strings
- [x] Verified offline: convert roundtrips, file/stdin/both transcription, `-a - | -i -` pipeline (whisper.cpp + base.en)

### Change 2 — Near-runtime live transcription

- [x] `LiveTranscriptWriter` (file + stdout, live-append): `.txt` lines, `.srt` numbered cues with sample-accurate timestamps, `.json` JSON-lines — written unbuffered so `tail -f` follows
- [x] `StreamSegmenter`: cut on `pauseSeconds` of silence (reuses `peakAmplitude`/`--silence-threshold`) with a `maxWindowSeconds` cap; pure-silence windows dropped (clock advances, no engine spawn)
- [x] `LiveTranscriber` (AudioSink): tee live PCM → segmenter → serial per-segment whisper worker → live append; engine/model resolved up front (fail fast); engine errors surfaced post-capture with exit-code mapping; broken-pipe = graceful
- [x] `WhisperEngine.transcribe(quietStderr:)` so per-segment calls don't flood stderr (verbose keeps passthrough)
- [x] Wire `LiveTranscriber` into `runLiveInput` (replaces batch-at-end; file-input transcription keeps whisper's native srt/json)
- [x] **Persistent engine (model-resident):** `WhisperServerEngine` launches `whisper-server` once (model loaded a single time) and transcribes each segment over a loopback (127.0.0.1) HTTP POST to `/inference`; `SegmentTranscriber` protocol abstracts CLI vs server. Auto-selected when `whisper-server` is on PATH (override `AURAL_WHISPER_SERVER_BIN`); disable with `AURAL_WHISPER_SERVER=0`. Falls back to per-segment `whisper-cli` if the server is absent or fails to start — transcription is never blocked by the optimization. Free-port via bind-to-0; readiness via TCP-connect (model loaded once listening); server stdout/stderr suppressed unless verbose; terminated on finalize.
- [x] Tests: `StreamSegmenter` boundaries/clock (5), `LiveTranscriptWriter` srt/json/txt (4), server discovery + free-port + multipart body (5), whisper-gated live integration (segmenter→whisper→writer) and server-loopback integration (both skip without engine/model). `make test` green — 97 tests, 27 suites
- [ ] Live-capture e2e of the segmenter (real mic/system) — on the pending-live list; the live PATH can't be exercised permission-free through the binary (covered offline by the integration tests feeding PCM directly)

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

## Phase 6: Multi-Engine & Multi-Language Transcription (PRD M6)

> Adds language coverage and selectable recognition engines behind `--engine`.
> Default engine stays `whisper`; existing behavior unchanged.

### Phase 6.0 — PRD & plan (docs first)

- [x] PRD: FR rows 13–14, §6.1 flags + `aural models`, §6.6 engine matrix, §7 NFR, §9 M6, §4.2
- [x] docs/permissions.md: Speech Recognition section

### Phase 6.1 — Engine abstraction + multilingual `whisper` (no new deps)

- [x] `TranscriptionBackend` protocol + `EngineCapabilities`/`EngineSpec` descriptor; batch (`TranscribeEngine`) and live (`LiveTranscriber`) both drive `WhisperCLIBackend`/`WhisperServerEngine` through it; live server-vs-CLI selection moved to `TranscriptionEngine.makeLive`
- [x] `--language auto` default + `--language CODE`; `--translate` (whisper-cli `-tr`; server form field `translate=true` — note: whisper.cpp server uses `translate`, not `task`, verified against server.cpp); capability validation rejects unsupported combos (e.g. `--translate` on `apple`); `apple`/`whisperkit` are known-but-not-implemented (run-time exit 69), `cloud` post-MVP
- [x] Named-model resolution via `ModelRegistry` (`base.en`/`large-v3-turbo` → `~/.aural/models/ggml-*.bin`, full paths pass through); warns when a `.en` model gets a non-English `--language`/`--translate`
- [x] `aural models list` (+`--json`, current default marked `*`) / `aural models list --available` (downloadable catalog + installed/current) / `aural models download <name>` (ggml from HF `ggerganov/whisper.cpp`; only network path, opt-in; `--force` re-download; `--default` sets the config default, first download auto-adopts)
- [x] Config file `~/.aural/config.json` (`Configuration` Codable, kebab-case keys) + `aural config show/set/unset/path` (typed validation; `set` captures `-`-prefixed values verbatim); `current`/`*` marker reflects env›config
- [x] Config defaults for `model`/`engine`/`language`/`translate`/`silence-threshold`/`device`, each resolved flag › env (`$AURAL_*`) › config › built-in via `ResolvedSettings`; merged-value validation catches env/config-driven conflicts; `--no-translate` overrides a configured default; malformed env values are usage errors
- [x] Tests: arg building (auto/translate ordering), server multipart `translate`/`response_format`, capability/EngineSpec + resolve rejection, model name/path resolution + `.en` warning + `models list`; whisper-gated chain still green (118 tests, 29 suites)
- [x] Help strings refreshed (`--engine`/`--language`/`--translate`/`--model`); PRD §6.1/§6.6 already specced in Phase 6.0; PLAN ticked. README usage examples deferred to Phase 5 (README is a Phase 5 deliverable)
- [ ] True multilingual e2e (non-English speech → translate, multilingual model) — gated/pending a local multilingual model + live TCC; covered offline only for English via the whisper-gated chain

### Phase 6.2 — `apple` engine (native Speech.framework, zero deps)

- [ ] `AppleSpeechBackend` via `SFSpeechURLRecognitionRequest` (on-device); per-segment live + whole-file batch
- [ ] Speech authorization + `NSSpeechRecognitionUsageDescription` in Info.plist; terminal-attributed TCC docs
- [ ] Locale mapping (`de`→`de-DE`), `supportedLocales()` validation; reject `--translate`
- [ ] Tests: locale mapping, capability errors; gated integration (Speech permission; likely local-only)

### Phase 6.3 — `whisperkit` engine (SwiftPM dep)

- [ ] Add `argmaxinc/argmax-oss-swift` (product `WhisperKit`); `WhisperKitBackend` loads model once (resident), transcribes segments
- [ ] `DecodingOptions(task:language:)`; async→sync bridge; model auto-download; `aural models` lists WhisperKit cache
- [ ] Arch gate: clear error on Intel; keep whisper/apple working
- [ ] Tests: gated integration (tiny model download); revisit notarization/Homebrew + binary size (links to Phase 5)

### Phase 6.4 — `parakeet` (deferred)

- [ ] NVIDIA Parakeet via FluidAudio (CoreML); European-multilingual; no translate — schedule separately

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
