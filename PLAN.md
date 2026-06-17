# Aural - Implementation Plan

> Source: [PRD.md](PRD.md) (v1.0 MVP, 2026-06-12). Phases map to PRD §9 milestones.

## Incoming

> Unscheduled items. Add new work here; `/plan` will triage on next run.

- [x] Leaf-subcommand `--help`: the broad symptom was a zsh test artifact (an unquoted `$var` holding `"models list"` is passed as one argument, so aural shows root help) — `aural models list --help` etc. work directly (also helped by the argument-parser 1.8.2 bump). The one real case, `aural config set --help`, was swallowed by `.captureForPassthrough` (used for `-40` values); fixed via `ConfigSet.isHelpRequest` → `CleanExit.helpRequest`. Stale man BUGS note removed.

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
- [x] Implement MP3 output (P1): vendored libmp3lame (encode-only) as the `CLame` SwiftPM C target with a minimal hand-written config.h; `Encoders.MP3FileWriter` (mono uses `lame_encode_buffer`, stereo the interleaved API; 24/32-bit down-converted to 16-bit). LGPL noted in NOTICES. Verified: aiff→mp3 mono/stereo round-trip transcribes correctly
- [x] Implement Ogg/Opus output (P1): native `kAudioFormatOpus` AudioConverter + hand-written `Encoders.OggMuxer` (page framing + Ogg CRC) and `OpusFileWriter` (zero external deps). Key fix: the input proc only reports 0 frames at finalize (a mid-stream 0 permanently flushes the encoder). Verified: aiff→opus mono/stereo (48 kHz and resampled) round-trips the full sentence; valid BOS/EOS Ogg/Opus pages
- [x] Implement `--split duration=SEC`: sequential files (`name_001`, `name_002`, …) with correctly flushed headers (P1)
- [x] Implement `--split silence=SEC` with configurable dBFS threshold (`--silence-threshold`, default −50); each chunk independently playable, no audio dropped (P2, US04)
- [x] Implement `aural convert`: format conversion reusing CoreAudio codecs (PRD §6.1) — verified by lossless tone roundtrips (wav→m4a→wav, wav→flac→wav)
- [x] Implement `aural info`: print duration, sample rate, channels, metadata; read support for WAV, AIFF, CAF, M4A, FLAC
- [x] Implement metadata embedding: WAV INFO chunk (ICRD/ISFT/INAM) — MP4 atoms and ID3v2 deferred with their formats (P2)
- [ ] Verify all output formats are accepted as-is by `whisper.cpp`, Fabric AI, and at least one cloud transcription API (PRD §6.4) — whisper.cpp ✓ (e2e-transcribe.sh: wav/m4a/flac all transcribed); Fabric AI + cloud API checks still need network/API keys

### Pending live verification (capture permissions were reset mid-session; needs GUI access)

> Commands updated to the unified root-verb syntax (see Phase 4.5). Automated by
> `Scripts/verify-live.sh` — grant Microphone + System Audio Recording to the
> terminal, then run it; it PASS/FAILs each item below.

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
- [x] True multilingual e2e — gated Swift test: German `say` clip transcribed (de) and run through `--translate` via a local multilingual model; skips without a non-`.en` model / German voice. Verified with `large-v3-turbo` (note: turbo transcribes but does not translate, so the English-content assertion is gated to non-turbo models)

### Phase 6.2 — `apple` engine (native Speech.framework, zero deps)

- [x] `AppleSpeechBackend` via `SFSpeechURLRecognitionRequest` (`requiresOnDeviceRecognition`, no network); whole-file batch + per-segment live (resident recognizer). Backend resolution generalized: `TranscriptionEngine.preflight/makeBatch/makeLive` dispatch whisper vs apple; the `.en` warning moved into the whisper branch
- [x] Speech authorization (prompt-if-undetermined via run-loop-pumped wait; denied → exit 77) + `NSSpeechRecognitionUsageDescription` in Info.plist; `Speech.framework` autolinks. docs/permissions.md already covers terminal-attributed TCC
- [x] Locale mapping (`de`→`de-DE`, `auto`→current via `supportedLocales()`); `--translate` rejected (capability); batch srt/json rejected (plain-text only), live srt/json still works via Aural's segment timestamps; on-device-unavailable → actionable error
- [x] Tests: locale mapping + capability/format guards (pure); gated on-device integration (skips unless Speech authorized + `say`). `make test` green — 155 tests, 34 suites. Verified live: `aural -i clip --engine apple` transcribes on-device, srt batch rejected, `$AURAL_ENGINE=apple` selects it
- [x] `EngineSpec` apple → implemented; `--engine` help updated; PRD §6.6 apple notes; PLAN ticked

### Phase 6.3 — `whisperkit` engine (SwiftPM dep)

- [x] Add `argmaxinc/argmax-oss-swift` (product `WhisperKit`, always-on dep); `WhisperKitBackend` loads the model once (resident) into `~/.aural/models/whisperkit`; shared async→sync bridge (`RunLoopBridge`) + `UncheckedSendableBox`
- [x] `DecodingOptions(task:language:detectLanguage:skipSpecialTokens:)`; srt/json from `TranscriptionResult.segments`; residual special tokens stripped; `aural models list` shows the WhisperKit cache
- [x] Arch gate: clear error on Intel (`Platform.requireAppleSilicon`); whisper/apple unaffected; dispatch generalized in `preflight/makeBatch/makeLive`
- [x] Tests: languageCode/clean + TranscriptFormatting + coreMLModels (pure); env-gated integration (`AURAL_TEST_WHISPERKIT=1`). Verified live: `aural -i clip --engine whisperkit --model tiny` transcribes on-device, srt/json clean

### Phase 6.4 — `parakeet` engine (FluidAudio CoreML)

- [x] NVIDIA Parakeet via `FluidInference/FluidAudio` (CoreML/ANE); `ParakeetBackend` loads models once (resident actor), `AsrManager.transcribe(url, decoderState:)`
- [x] European-multilingual (v3, 25 languages) + English-only (v2 via `--model v2`); autoDetect, no `--language` selection (warned/ignored), `--translate` rejected (capability)
- [x] srt/json built from `ASRResult.tokenTimings` (grouped into cues); arch gate (Apple-Silicon-only); FluidAudio manages its own cache (`~/Library/Application Support/FluidAudio/Models` — it ignores a custom dir when models already exist), which `aural models list` reads and shows
- [x] Tests: version mapping + language notice + token-timing→cues (pure); EngineSpec; env-gated integration (`AURAL_TEST_PARAKEET=1`). `make test` green — 171 tests, 41 suites. Verified live: `aural -i clip --engine parakeet` transcribes on-device, srt cues, --translate rejected, models list shows the cache
- [x] Engine-tagged model management for the CoreML engines: `ModelCatalog` parses `whisperkit:<variant>` / `parakeet:v2|v3` (bare = whisper ggml); `aural models list --available` gains an ENGINE column covering all engines; `aural models download <name>` dispatches per engine (whisper ggml / `WhisperKit.download` / `AsrModels.download`), with `--default` also setting `config.engine` for whisperkit/parakeet. Verified live: `download whisperkit:base`, `download parakeet:v3 --default`. 177 tests, 42 suites

## Phase 5: Release Engineering & Public Beta (PRD M5)

> Resequenced to run after the engine work (Phase 6): signing, notarization,
> Homebrew, and release automation must account for the CoreML engine
> dependencies (binary size / arch).

- [x] Set up GitHub Actions CI: build + test on a macOS 14 (Apple-Silicon) runner with the Swift 6 toolchain (`.github/workflows/ci.yml`); gated integration tests skip without their tools so the suite stays green
- [ ] Code signing and notarization so TCC permission flows work cleanly (PRD §7 Installability)
- [ ] Create Homebrew formula; verify `brew install aural` end-to-end (US05)
- [x] Write man page following POSIX utility conventions (`man/aural.1`; renders clean under mandoc)
- [x] Write README: install, TCC permission setup, usage examples, engines, config/env precedence, exit codes (`README.md`)
- [ ] Provide example scripts: meeting recording, transcription pipeline, cron/launchd setup
- [ ] Validate unattended operation from cron/launchd after TCC grant (US05)
- [ ] Reliability test: 24-hour continuous recording produces valid file on SIGINT/SIGTERM (PRD §7)
- [ ] Performance validation: < 3% CPU on Apple Silicon at 16 kHz mono; buffering < 100 ms (PRD §7)
- [ ] Release automation: GitHub Releases with binary artifacts; tag v1.0.0-beta
- [ ] Fill PRD Author field and re-review acceptance criteria US01–US07 against implementation

## Phase 7: Hybrid system capture (ScreenCaptureKit + Core Audio)

> Bug: `aural --system --mix` only captured the mic while system audio was
> playing — the Core Audio aggregate is clocked by the process tap, which idles
> when nothing plays, so the IOProc (and the mic sub-device) stop. Fix +
> modernize with a dual-backend design. Default engine/capture behavior is
> otherwise unchanged.

- [x] PRD/docs: §6.2 two-backend model + `--capture-backend`; §7 Compatibility/Security (Screen Recording vs System Audio Recording, headless); docs/permissions.md both flows; min OS stays 14.4 (SCKit gated on 15+)
- [x] Step 1 — Core Audio tap fix (Option A): make the **microphone the aggregate's clock master** for `--mix` (was the tap), pin nominal rate to max(tap, mic); continuous mic capture regardless of system activity, headless-safe. This alone fixes the reported bug (commit `d42aba5`)
- [x] Step 2 — `ScreenCaptureSession` (`@available(macOS 15)`): `SCStream` system/app audio via `SCContentFilter` (system/`--app`/`--exclude-app`), `.audio` → `CMSampleBuffer` → `PCMStreamConverter`; Screen Recording permission helper; reachable via `--capture-backend sckit` (commit `f9d5c37`)
- [x] Step 3 — SCKit integrated mic + `--mix`: `captureMicrophone`/`microphoneCaptureDeviceID` + `.microphone` output; app-level mixer (`StreamMixing.sum`) summing synchronized system+mic (commit `f9d5c37`)
- [x] Step 4 — `--capture-backend auto|sckit|coreaudio` (+ `$AURAL_CAPTURE`); auto prefers SCKit when (macOS 15 ∧ Screen Recording ∧ display present, via `ScreenCaptureSession.isAvailable()` — preflight, never prompts) else notify + fall back to Core Audio (commit `f9d5c37`). Note: selection is preflight-based; a runtime SCKit start failure after auto-selecting it surfaces an error rather than retrying Core Audio (rare grant-but-no-GUI case) — deferred
- [~] Step 5 — docs/tests: [x] README/man (`--capture-backend`, both permissions, `$AURAL_CAPTURE`, headless note); [x] unit tests (`StreamMixingTests`, CLI backend resolution/validation); [x] `Scripts/verify-live.sh` step [6] covers both backends (sckit perm/headless → SKIP). Pending (needs Screen Recording grant + GUI): [ ] sckit end-to-end audio live test; [ ] re-run the 60-min mic/system drift validation for both `--mix` paths
- [x] `aural apps` stays HAL-based (headless-friendly); the SCKit backend maps bundle id/PID → `SCRunningApplication` internally (`ScreenCaptureSession.match`)

## Phase 8: Speaker Recognition & Runtime Segmentation (PRD M7, §6.7)

> Adds "who said what" (source attribution + acoustic diarization) and replaces
> the amplitude-only live segmenter ("delay in a sound") with VAD. Reuses the
> already-linked `FluidInference/FluidAudio` dependency (no new SwiftPM dep —
> only model assets). Opt-in via `--speakers`; default transcript output is
> unchanged. Diarization/VAD are Apple-Silicon-first; source attribution is
> platform-agnostic. Mirrors existing patterns: `ParakeetBackend` (FluidAudio
> load-once + `RunLoopBridge`), `ModelCatalog`/`ModelsCommand` (engine-tagged
> download), `Platform.requireAppleSilicon`, `TranscriptionEngine` dispatch.

### Phase 8.0 — Spec & docs (in progress; scope still being refined)

- [ ] PRD §6.7 + supporting edits drafted (FR rows 15–19, §4.2, US08, §6.1 flags, §6.6 VAD note, §7, §8, §9 M7, §10 Open Qs) — **under active review, not finalized**
- [x] PRD §6.7/§7 reconciled to the implemented VAD behavior (default-on on Apple Silicon, Silero model fetched on first live run, opt-out `AURAL_VAD=0`, amplitude fallback)
- [ ] PRD §6.1 reconciliation: `--speakers` flag + `--speaker-mode` (vs the drafted `--speakers[=mode]`)
- [ ] docs/permissions.md: diarization/VAD need **no new TCC** (operate on already-captured audio) but fetch FluidAudio CoreML models from Hugging Face on first use
- [ ] README/man deferred to 8.7 (kept with the feature's other user-facing docs)

### Phase 8.1 — VAD-based live segmentation (the runtime fix; no labels yet)

- [x] `SpeechSegmenter` protocol so the amplitude boundary can be swapped; `StreamSegmenter` conforms (`SpeechSegmenter`/`VadSegmenter` in `VadSegmenter.swift`)
- [x] `VadSegmenter`: single consumer `Task` over an unbounded `AsyncStream`; unpack→mono→resample(16k)→4096-sample windows→full streaming state machine (`speechStart`/`speechEnd`), maxWindow/minSegment/leading-trim; sample-accurate byte-clock timestamps
- [x] `VoiceActivityStream` abstraction + `FluidVadClassifier` (FluidAudio `VadManager.processStreamingChunk`, model loaded once)
- [x] `SpeechSegmenterFactory`: VAD by default on Apple Silicon (first-run download), graceful fallback to the amplitude method on Intel / load failure; `AURAL_VAD=0` to force-disable; `--silence-threshold` stays the fallback knob
- [x] Wired into `LiveTranscriber` behind the abstraction (`LiveTranscriber.swift:51`)
- [x] Tests: `VadSegmenterTests` (synthetic `ScriptedVAD` — boundary/clock/max/min/trailing-flush) + gated `AURAL_TEST_VAD=1` real-model integration; existing live e2e pinned to `AURAL_VAD=0`
- [ ] Live-capture e2e of the VAD segmenter (real mic/system) — on the pending-live list (covered offline by the synthetic + gated tests)
- [x] **Quiet-audio hardening** (diagnosed from `Tests/ManualTests/test3.mp3`, where a quiet phrase peaking ~−45 dBFS was dropped at the VAD gate): lowered the default VAD threshold 0.85→0.5, added `--vad-threshold 0..1`, and per-segment peak normalization (`GainNormalizer`, +20 dB cap, target −3 dBFS) before the engine — recording untouched, `AURAL_GAIN=off` to disable. Gated test replays the recording and confirms the quiet region now segments at 0.5

### Phase 8.2 — Speaker label data model + output formats

- [x] Added optional `speaker` to `TranscriptCue` (`EngineSupport.swift`) and the live/batch JSON `Segment` structs (`LiveTranscriptWriter.jsonLine`, `TranscriptFormatting.render`) — nil omits the key (encodeIfPresent), so default output is byte-identical
- [x] Render labels: txt `You: …`/`Speaker 1: …`; srt `[Speaker 1] text` (valid SRT); json `"speaker"` field — in both `TranscriptFormatting.render` and `LiveTranscriptWriter.append`
- [x] Added `--speakers` (alias `--diarize`) + `--speaker-mode auto|source|acoustic` + `--speaker-labels "You,Others"` to `Aural.swift`; validation (mode/labels require `--speakers`; `source` needs two sources; labels must be a pair). Note: implemented as a `--flag` + `--speaker-mode` rather than `--speakers[=mode]` (ArgumentParser has no optional-value options); PRD §6.1 to be reconciled in 8.0
- [x] No output change unless `--speakers` is set; with the label backends pending, `--speakers` surfaces a clear "planned — Phase 8.3/8.4" runtime error (exit 69)
- [x] Tests: label rendering for all three formats incl. missing speaker (default unchanged) + flag accept/reject combos

### Phase 8.3 — Source attribution (You vs Others), no ML

- [x] Multi-track capture: deliver mic and system as separate PCM streams while keeping the mixed stream for `-a`
  - [x] Core Audio: `StreamMixer` gains `systemBuffer`/`micBuffer` (tap-only and mic-only in tap layout); `SystemCaptureSession` converts each via per-source converters and emits via `onSourceAudio`
  - [x] ScreenCaptureKit: tees the already-separate `.audio`/`.microphone` outputs via `onSourceAudio` before `drainMix`
  - [x] `MultiTrackCaptureSession` protocol (`CaptureSource` .microphone/.system) in TapEngine
- [x] Route per-source PCM to per-source `LiveTranscriber`s sharing one engine (`SerializedBackend`) + one transcript writer, tagging mic=You / system=Others (`--speaker-labels`); `CaptureEngine.run(sourceSinks:)` routes + finalizes them
- [x] Mixed `-a` audio output unchanged; works headless and on Intel (no ML)
- [x] Tests: `StreamMixer` per-source extraction (synthetic buffer list), shared-writer label routing, `SpeakerLabels` parsing, flag accept/reject combos
- [ ] Live-capture e2e (real mic/system) — pending-live list (covered offline by the unit tests; capture path can't run permission-free)

### Phase 8.4 — Acoustic diarization via FluidAudio (Speaker N)

- [x] `--diarize-engine auto|streaming|offline` + `--max-speakers N` flags + validation (require `--speakers`); Apple-Silicon gate
- [x] Offline (batch `-i`): `SpeakerDiarizer` (FluidAudio `DiarizerManager`, model loaded once) + `BatchDiarization` — diarize, then transcribe each speaker span independently (engine-agnostic: reuses the shared transcribe-a-WAV primitive, so it works with whisper/whisperkit/parakeet/apple) → labeled cues. `SpeakerLabeling.normalize` numbers `Speaker N` by first appearance and merges adjacent same-speaker spans
- [x] First-use model download into FluidAudio's cache (RunLoopBridge pattern, like `ParakeetBackend`)
- [x] `--speaker-threshold 0..1` clustering-sensitivity knob (→ `DiarizerConfig.clusteringThreshold`); verified it splits a hard pair that merges at the default
- [x] **Streaming (live) diarization** — implemented via per-segment **embedding clustering** (`extractSpeakerEmbedding` + `SpeakerManager.assignSpeaker`), not LS-EEND: simpler, reuses the VAD segmentation. `StreamingDiarizer` + `ClusteringSpeakerResolver` assign `Speaker N` per live segment; `LiveTranscriber` gained an optional per-segment resolver
- [x] Tests: `SpeakerLabeling.normalize` + `SpeakerNumbering` (pure), `BatchDiarization.merge` ordering, resolver-overrides-fixed-label, catalog parse, env-gated integration (`AURAL_TEST_DIARIZE=1`)

### Phase 8.5 — Combined source-split + per-source diarization

- [x] `--speakers` (auto/acoustic) on a meeting: mic→`You` (constant) + system diarized → `You + Speaker 1..N`. `--speaker-mode source` keeps the cheap deterministic You/Others split
- [x] **Streaming** (`--diarize-engine streaming`, default live): real-time `Speaker N` via embedding clustering on the system (or single) stream
- [x] **Offline-live** (`--diarize-engine offline`): record mic+system to temp WAVs during capture; at stop, offline-diarize the system track (accurate) + force mic to `You`, merge cues by time → transcript at end (`runOfflineLive`)
- [x] Single-stream live acoustic (`--speakers` on mic-only / system-only) → `Speaker N`; the old "planned" guard is lifted. Intel downgrades to source-only/none with a notice
- [x] `--diarize-engine` resolution: `auto` → streaming (live) / offline (batch); `--max-speakers`, `--speaker-threshold` thread through both
- [x] Stable `Speaker N` namespace (first-appearance numbering); `You` is live-only (a mixed `-i` file → `Speaker N` for all, including you)
- [x] Tests: numbering/merge/resolver (pure + offline); verified live-style separation on a 2-voice clip via the raw-PCM pipeline
- [ ] Live-capture e2e of streaming diarization (real multi-party call) — pending-live list (can't run permission-free; offline 2-voice + unit tests cover the logic)

### Phase 8.6 — Model management & config

- [x] `ModelCatalog` parses/lists `fluidaudio:diarizer` / `fluidaudio:vad`; `aural models download` dispatches to FluidAudio loaders (`SpeakerDiarizer.download` / `FluidVadClassifier.downloadModel`); never adopted as the transcription default; `list --available` shows them ("speaker pipeline")
- [x] `aural models list` (local) shows the FluidAudio cache correctly: `FluidAudioCache.engine(forBundle:)` classifies each bundle (`*parakeet*` → parakeet; `silero-vad`/`speaker-diarization` → fluidaudio), and `coreMLModels` flags the configured CoreML default as `current` (so `parakeet-tdt-0.6b-v3` gets `*`); a no-default hint prints when nothing resolves
- [x] **Model-load UX fix:** VAD loads once per process (shared static `VadManager`, shared across the two source-attribution streams; per-stream state); cached loads are silent (`Log.verbose`), with a one-time `downloading … (first use)` notice only on a real fetch — replacing the misleading per-run "preparing … (first run may download)" notice. (FluidAudio's own INFO logging is DEBUG-only; release stderr is clean.)
- [x] **Config parity + `config show` redesign** (declarative settings registry): every meaningful parameter is now flag↔`$AURAL_*`↔config with `ResolvedSettings` precedence (flag › env › config › default). New config keys: `capture-backend`, `rate`/`bits`/`channels`, `vad`, `vad-threshold`, `gain`, `speakers`, `speaker-mode`, `speaker-labels`, `diarize-engine`, `max-speakers`, `speaker-threshold`. Bool flags are now three-state (`--vad/--no-vad`, `--gain/--no-gain`, `--speakers/--no-speakers`) so config can supply a default. `aural config show` lists **all** settings with VALUE + SOURCE (`default`/`config`/`env`); `--json` → `{key:{value,source}}`. `Setting`/`TypedSetting` registry (`Settings.swift`) drives show/set/unset/resolve from one descriptor per key
- [x] Tests: catalog parse (`fluidaudio:` tags + `available()` coverage)

### Phase 8.7 — Validation & user-facing docs

- [ ] NFR: live label latency (tentative ≤1s, final ≤2s), streaming RTF<1 on Apple Silicon (PRD §7)
- [ ] Diarization DER on a reference clip set; segmentation-stability check (fewer spurious cuts than the amplitude method) — PRD §8
- [x] Docs: README "Speaker labels" section (flags table + examples + caveats) + `fluidaudio:` model rows + `AURAL_VAD`; man `SPEAKER LABELING` section + `AURAL_VAD` + examples (mandoc clean); docs/permissions.md diarization/VAD note (no new TCC, first-use model fetch); corrected the stale `--speakers`/`--diarize-engine` `--help` strings (no longer say "planned")
- [ ] `Scripts/verify-live.sh`: add a gated `--system --mix --speakers` smoke step (perms/arch → SKIP)

### Phase 8.8 — Streaming diarization upgrade (LS-EEND, replacing per-segment clustering)

> Motivation: the per-segment embedding-clustering streaming diarizer (8.4) collapsed
> distinct speakers in real meetings — a single VAD segment routinely blends several
> voices, and the whole-segment all-ones-mask embedding (`extractSpeakerEmbedding`) is
> not discriminative, so the persistent fingerprint store merged everyone into
> `Speaker 1/2`. Lowering `--speaker-threshold` couldn't fix a non-discriminative
> embedding. Batch/offline (clean-frame masks) separated the same audio fine, proving
> embedding quality — not the threshold — was the bottleneck.

- [x] Lowered the offline/batch default clustering threshold (`DiarizationDefaults.clusteringThreshold = 0.65`, effective ~0.78 after FluidAudio's ×1.2) so `-i FILE --speakers` no longer collapses to one speaker; surfaced the real default in `config show`
- [x] Replace the live **streaming** diarizer with FluidAudio **LS-EEND** (long-form streaming end-to-end neural diarization): `EENDStreamingDiarizer` wraps `LSEENDDiarizer`, ingests the system/single stream continuously (`addAudio`/`process`), and maintains a frame-level `DiarizerTimeline` (~100 ms updates) independent of the ASR VAD segmentation — speaker turns detected by **voice** (incl. overlap), not silence
- [x] Decouple the live speaker resolver from ASR segments: `LiveSpeakerResolver.label(start:end:)` queries the timeline for the dominant speaker over a segment's time window (was per-segment WAV re-decode); thread segment `start`/`end` through `LiveTranscriber`
- [x] `TimelineDiarizerSink` (`AudioSink`) tees the `.system` PCM to the diarizer (off the capture IO thread); wire `.system` → `[diarizerSink, systemTranscriber]` in `runSourceAttributedLive`/`runSingleDiarizedLive`; finalize the session at stop
- [x] Retire the legacy live `StreamingDiarizer` + `ClusteringSpeakerResolver` (clustering stays for offline/batch); `--speaker-threshold`/`--max-speakers` are now offline/batch-only (no clustering knob in EEND)
- [x] Model plumbing: LS-EEND bundle in `FluidAudioCache`, `fluidaudio:streaming-diarizer` in `ModelCatalog`, download branch in `ModelDownloader`
- [x] **Variant selection** (`callhome` default): ranked LS-EEND variants on real recordings + `say`-synthesized ground truth. `callhome` (2-party single-channel telephone corpus — closest to a call mixed into one system stream) was the only variant correct on both a real 2-party conversation (2) and a real multi-party meeting (3), and perfect on synthetic 1- and 2-speaker cases; `ami` collapsed the 2-party case, `dihard3` under-split the meeting
- [x] Fixed broken-pipe on exit: `LiveTranscriptWriter.append` wrapped EPIPE in `AuralError`, defeating `isBrokenPipe`; now propagated raw so transcript-to-stdout `Ctrl+C` is graceful (no spurious "transcript write failed")
- [x] Gated `say` ground-truth test (`SayDiarizationTests`, `AURAL_TEST_DIARIZE=1`): single speaker stays one, two distinct voices separate with a stable 1:1 mapping — validates the zero-config default end-to-end (minus TCC capture)
- [ ] Real-call e2e (TCC capture front-end) remains on the pending-live list; streaming RTF measured ≪ 1 (≈0.01) via the harness

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
- [ ] Named speaker identification: voiceprint enrollment + local speaker store (FluidAudio embeddings) (PRD §4.2 / Open Q5)
- [ ] Overlapping-speech handling / per-word speaker assignment (PRD Open Q6)
