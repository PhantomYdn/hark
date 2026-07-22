# Hark - Implementation Plan

> Source: [PRD.md](PRD.md) (v1.0 MVP, 2026-06-12). Phases map to PRD §9 milestones.

## Incoming

> Unscheduled items. Add new work here; `/plan` will triage on next run.

## Phase 1: Project Foundation & Core Capture (PRD M1)

- [x] Initialize git repository with `.gitignore` for Swift/SwiftPM
- [x] Create SwiftPM package with modular targets: `DeviceManager`, `TapEngine`, `Encoders`, `CLI` (PRD §7 Maintainability)
- [x] Add `swift-argument-parser` dependency and scaffold subcommand structure: `devices`, `apps`, `record`, `transcribe`, `convert`, `info` with `-h/--help` and `-v/--verbose`
- [x] Implement `hark devices`: enumerate AudioDeviceIDs via CoreAudio (UID, name, channels, sample rates), exclude inactive devices, `--list-inputs`/`--list-outputs`
- [x] Implement `hark apps`: list running applications capturable via process taps (name, bundle ID, PID)
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
- [x] Implement `hark convert`: format conversion reusing CoreAudio codecs (PRD §6.1) — verified by lossless tone roundtrips (wav→m4a→wav, wav→flac→wav)
- [x] Implement `hark info`: print duration, sample rate, channels, metadata; read support for WAV, AIFF, CAF, M4A, FLAC
- [x] Implement metadata embedding: WAV INFO chunk (ICRD/ISFT/INAM) — MP4 atoms and ID3v2 deferred with their formats (P2)
- [ ] Verify all output formats are accepted as-is by `whisper.cpp`, Fabric AI, and at least one cloud transcription API (PRD §6.4) — whisper.cpp ✓ (e2e-transcribe.sh: wav/m4a/flac all transcribed); Fabric AI + cloud API checks still need network/API keys

### Pending live verification (capture permissions were reset mid-session; needs GUI access)

> Commands updated to the unified root-verb syntax (see Phase 4.5). Automated by
> `Scripts/verify-live.sh` — grant Microphone + System Audio Recording to the
> terminal, then run it; it PASS/FAILs each item below.

- [ ] Re-grant TCC: Microphone for the terminal (System Settings → Privacy & Security → Microphone) and System Audio Recording (Screen & System Audio Recording → "+" → terminal, restart terminal)
- [ ] `hark --duration 2 -a x.m4a` and `x.flac` — live encoded capture (afinfo check)
- [ ] `hark --duration 5 --split duration=2 -a x.wav` — 3 chunks, each playable
- [ ] Live `--split silence` smoke with real audio
- [ ] Re-run `Scripts/e2e-app-isolation.sh` (should still pass)
- [ ] `hark -a - --duration 10 | hark -i -` — the literal US03 mic pipeline
- [ ] `hark -d <mic-UID> --duration 5 -t -` while speaking — live mic → transcript on stdout
- [ ] `hark --duration 5 -a x.m4a -t x.srt` while speaking — combined record + transcribe in one pass

## Phase 4: Transcription Pipeline (PRD M4)

- [x] Implement `hark transcribe -i <file>`: batch transcription of an audio file (any readable format, normalized to 16 kHz mono internally)
- [x] Implement `-i -` stdin mode: read raw audio from stdin (WAV-stream sniffing + raw PCM flags); staged via temp file internally (US03)
- [x] Implement source input mode: record from device UID in memory, pipe to engine, output text to stdout — live mic check pending TCC re-grant
- [x] Implement `--engine whisper` (default): invoke system-installed whisper binary (`whisper-cli`/`whisper-cpp` on PATH, `HARK_WHISPER_BIN` override)
- [x] Implement `--model`, `--language`, `--output-format txt|srt|json` flags (model fallback: `$HARK_WHISPER_MODEL`) — note: `--output-format` renamed `--transcript-format` in the Phase 4.5 redesign
- [x] Missing-engine UX: clear error with installation instructions (`brew install whisper-cpp`) (PRD §6.6); missing model gets a HuggingFace download line
- [x] Pass engine STDERR through for debugging; propagate non-zero exit codes through pipelines (US03) — verified: whisper exit 3 propagated
- [x] End-to-end test: pipe-to-transcript verified permission-free via Scripts/e2e-transcribe.sh (say-synthesized speech; WAV + raw-PCM pipes); the literal mic variant `record --stdout | transcribe -i -` is on the pending-live list

## Phase 4.5: Unified Root Verb — CLI Redesign (PRD §6.1, §6.6)

> `hark` itself becomes the verb ("listen and transcribe"). One input (live by
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
- [x] **Persistent engine (model-resident):** `WhisperServerEngine` launches `whisper-server` once (model loaded a single time) and transcribes each segment over a loopback (127.0.0.1) HTTP POST to `/inference`; `SegmentTranscriber` protocol abstracts CLI vs server. Auto-selected when `whisper-server` is on PATH (override `HARK_WHISPER_SERVER_BIN`); disable with `HARK_WHISPER_SERVER=0`. Falls back to per-segment `whisper-cli` if the server is absent or fails to start — transcription is never blocked by the optimization. Free-port via bind-to-0; readiness via TCP-connect (model loaded once listening); server stdout/stderr suppressed unless verbose; terminated on finalize.
- [x] Tests: `StreamSegmenter` boundaries/clock (5), `LiveTranscriptWriter` srt/json/txt (4), server discovery + free-port + multipart body (5), whisper-gated live integration (segmenter→whisper→writer) and server-loopback integration (both skip without engine/model). `make test` green — 97 tests, 27 suites
- [ ] Live-capture e2e of the segmenter (real mic/system) — on the pending-live list; the live PATH can't be exercised permission-free through the binary (covered offline by the integration tests feeding PCM directly)

## Phase 6: Multi-Engine & Multi-Language Transcription (PRD M6)

> Adds language coverage and selectable recognition engines behind `--engine`.
> Default engine stays `whisper`; existing behavior unchanged.

### Phase 6.0 — PRD & plan (docs first)

- [x] PRD: FR rows 13–14, §6.1 flags + `hark models`, §6.6 engine matrix, §7 NFR, §9 M6, §4.2
- [x] docs/permissions.md: Speech Recognition section

### Phase 6.1 — Engine abstraction + multilingual `whisper` (no new deps)

- [x] `TranscriptionBackend` protocol + `EngineCapabilities`/`EngineSpec` descriptor; batch (`TranscribeEngine`) and live (`LiveTranscriber`) both drive `WhisperCLIBackend`/`WhisperServerEngine` through it; live server-vs-CLI selection moved to `TranscriptionEngine.makeLive`
- [x] `--language auto` default + `--language CODE`; `--translate` (whisper-cli `-tr`; server form field `translate=true` — note: whisper.cpp server uses `translate`, not `task`, verified against server.cpp); capability validation rejects unsupported combos (e.g. `--translate` on `apple`); `apple`/`whisperkit` are known-but-not-implemented (run-time exit 69), `cloud` post-MVP
- [x] Named-model resolution via `ModelRegistry` (`base.en`/`large-v3-turbo` → `~/.hark/models/ggml-*.bin`, full paths pass through); warns when a `.en` model gets a non-English `--language`/`--translate`
- [x] `hark models list` (+`--json`, current default marked `*`) / `hark models list --available` (downloadable catalog + installed/current) / `hark models download <name>` (ggml from HF `ggerganov/whisper.cpp`; only network path, opt-in; `--force` re-download; `--default` sets the config default, first download auto-adopts)
- [x] Config file `~/.hark/config.json` (`Configuration` Codable, kebab-case keys) + `hark config show/set/unset/path` (typed validation; `set` captures `-`-prefixed values verbatim); `current`/`*` marker reflects env›config
- [x] Config defaults for `model`/`engine`/`language`/`translate`/`silence-threshold`/`device`, each resolved flag › env (`$HARK_*`) › config › built-in via `ResolvedSettings`; merged-value validation catches env/config-driven conflicts; `--no-translate` overrides a configured default; malformed env values are usage errors
- [x] Tests: arg building (auto/translate ordering), server multipart `translate`/`response_format`, capability/EngineSpec + resolve rejection, model name/path resolution + `.en` warning + `models list`; whisper-gated chain still green (118 tests, 29 suites)
- [x] Help strings refreshed (`--engine`/`--language`/`--translate`/`--model`); PRD §6.1/§6.6 already specced in Phase 6.0; PLAN ticked. README usage examples deferred to Phase 5 (README is a Phase 5 deliverable)
- [x] True multilingual e2e — gated Swift test: German `say` clip transcribed (de) and run through `--translate` via a local multilingual model; skips without a non-`.en` model / German voice. Verified with `large-v3-turbo` (note: turbo transcribes but does not translate, so the English-content assertion is gated to non-turbo models)

### Phase 6.2 — `apple` engine (native Speech.framework, zero deps)

- [x] `AppleSpeechBackend` via `SFSpeechURLRecognitionRequest` (`requiresOnDeviceRecognition`, no network); whole-file batch + per-segment live (resident recognizer). Backend resolution generalized: `TranscriptionEngine.preflight/makeBatch/makeLive` dispatch whisper vs apple; the `.en` warning moved into the whisper branch
- [x] Speech authorization (prompt-if-undetermined via run-loop-pumped wait; denied → exit 77) + `NSSpeechRecognitionUsageDescription` in Info.plist; `Speech.framework` autolinks. docs/permissions.md already covers terminal-attributed TCC
- [x] Locale mapping (`de`→`de-DE`, `auto`→current via `supportedLocales()`); `--translate` rejected (capability); batch srt/json rejected (plain-text only), live srt/json still works via Hark's segment timestamps; on-device-unavailable → actionable error
- [x] Tests: locale mapping + capability/format guards (pure); gated on-device integration (skips unless Speech authorized + `say`). `make test` green — 155 tests, 34 suites. Verified live: `hark -i clip --engine apple` transcribes on-device, srt batch rejected, `$HARK_ENGINE=apple` selects it
- [x] `EngineSpec` apple → implemented; `--engine` help updated; PRD §6.6 apple notes; PLAN ticked

### Phase 6.3 — `whisperkit` engine (SwiftPM dep)

- [x] Add `argmaxinc/argmax-oss-swift` (product `WhisperKit`, always-on dep); `WhisperKitBackend` loads the model once (resident) into `~/.hark/models/whisperkit`; shared async→sync bridge (`RunLoopBridge`) + `UncheckedSendableBox`
- [x] `DecodingOptions(task:language:detectLanguage:skipSpecialTokens:)`; srt/json from `TranscriptionResult.segments`; residual special tokens stripped; `hark models list` shows the WhisperKit cache
- [x] Arch gate: clear error on Intel (`Platform.requireAppleSilicon`); whisper/apple unaffected; dispatch generalized in `preflight/makeBatch/makeLive`
- [x] Tests: languageCode/clean + TranscriptFormatting + coreMLModels (pure); env-gated integration (`HARK_TEST_WHISPERKIT=1`). Verified live: `hark -i clip --engine whisperkit --model tiny` transcribes on-device, srt/json clean

### Phase 6.4 — `parakeet` engine (FluidAudio CoreML)

- [x] NVIDIA Parakeet via `FluidInference/FluidAudio` (CoreML/ANE); `ParakeetBackend` loads models once (resident actor), `AsrManager.transcribe(url, decoderState:)`
- [x] European-multilingual (v3, 25 languages) + English-only (v2 via `--model v2`); autoDetect, no `--language` selection (warned/ignored), `--translate` rejected (capability)
- [x] srt/json built from `ASRResult.tokenTimings` (grouped into cues); arch gate (Apple-Silicon-only); FluidAudio manages its own cache (`~/Library/Application Support/FluidAudio/Models` — it ignores a custom dir when models already exist), which `hark models list` reads and shows
- [x] Tests: version mapping + language notice + token-timing→cues (pure); EngineSpec; env-gated integration (`HARK_TEST_PARAKEET=1`). `make test` green — 171 tests, 41 suites. Verified live: `hark -i clip --engine parakeet` transcribes on-device, srt cues, --translate rejected, models list shows the cache
- [x] Engine-tagged model management for the CoreML engines: `ModelCatalog` parses `whisperkit:<variant>` / `parakeet:v2|v3` (bare = whisper ggml); `hark models list --available` gains an ENGINE column covering all engines; `hark models download <name>` dispatches per engine (whisper ggml / `WhisperKit.download` / `AsrModels.download`), with `--default` also setting `config.engine` for whisperkit/parakeet. Verified live: `download whisperkit:base`, `download parakeet:v3 --default`. 177 tests, 42 suites

## Phase 5: Release Engineering & Public Beta (PRD M5)

> Resequenced to run after the engine work (Phase 6): signing, notarization,
> Homebrew, and release automation must account for the CoreML engine
> dependencies (binary size / arch).

- [x] Set up GitHub Actions CI: build + test on a macOS 14 (Apple-Silicon) runner with the Swift 6 toolchain (`.github/workflows/ci.yml`); gated integration tests skip without their tools so the suite stays green
- [x] Write man page following POSIX utility conventions (`man/hark.1`; renders clean under mandoc)
- [x] Write README: install, TCC permission setup, usage examples, engines, config/env precedence, exit codes (`README.md`)
- [x] Add `LICENSE` (MIT) and expand `NOTICES` with the statically-linked SwiftPM deps (Apache-2.0/MIT) alongside the vendored LGPL LAME; `CHANGELOG.md` for v0.1.0
- [x] Provide example scripts: `examples/hark-meeting` (interactive system+mic → audio + transcript → fabric-ai summary), `hark-note`, `hark-dictate` (cron/launchd recipe deferred to the daemon work — see Future)
- [x] `examples/README.md` indexes the recipes (table + Install + Prerequisites incl. system-audio TCC → docs/permissions.md) and `README.md` links to it; `hark-meeting` = interactive `--system --mix --speakers` → `<date>-slug.{mp3,txt}` then `fabric-ai -p summarize_meeting` → `.md`; `hark-note` (mic memo), `hark-dictate` (mic → `pbcopy`)
- [x] Release automation: tag-triggered `.github/workflows/release.yml` builds `swift build -c release`, packages the arm64 binary + man/LICENSE/NOTICES, publishes a GitHub Release, and auto-bumps `Formula/hark.rb` (url+sha256)
- [x] Homebrew (one-repo tap): `Formula/hark.rb` binary formula (`depends_on whisper-cpp`, arm64); `brew tap PhantomYdn/hark <url> && brew install hark`. Bare `brew install hark` (homebrew-core) deferred — needs notability + a stable release
- [x] Fill PRD Author field (Ilya Naryzhnyy); acceptance criteria US01–US07 reviewed against the implementation (capture/transcode/engines/diarization/interactive/remote-control all shipped; live-capture e2e steps remain TCC/GUI-gated on the pending-live list)
- [x] Code signing + notarization: tag-triggered Developer ID signing (hardened runtime + `hark.entitlements` audio-input/speech-recognition, identifier `dev.hark.cli`, Team `8UW9J44QNB`) and `notarytool` notarization in `release.yml` — secrets-driven, imports the cert + Apple intermediate into a throwaway keychain, fails the release on any non-`Accepted` status (45m timeout, timeout-safe). The published v0.1.0 binary is signed + notarized; README/permissions/CHANGELOG updated (dropped the `xattr` note)

### Post-beta (deferred from v0.1.0)

> Need a hardware soak/measure session or GUI/TCC that CI can't provide.
> Tracked here so the beta isn't blocked on them.

- [ ] Submit to homebrew-core for bare `brew install hark` (after notability + a stable, non-beta release)
- [ ] Dedicated `PhantomYdn/homebrew-hark` formula-only tap repo so `brew tap` doesn't clone the whole project tree; needs a cross-repo push token for the release workflow's formula auto-bump (default `GITHUB_TOKEN` can't push to another repo)
- [ ] Validate unattended operation from cron/launchd after TCC grant (US05)
- [ ] Reliability test: 24-hour continuous recording produces valid file on SIGINT/SIGTERM (PRD §7)
- [ ] Performance validation: < 3% CPU on Apple Silicon at 16 kHz mono; buffering < 100 ms (PRD §7)

## Phase 7: Hybrid system capture (ScreenCaptureKit + Core Audio)

> Bug: `hark --system --mix` only captured the mic while system audio was
> playing — the Core Audio aggregate is clocked by the process tap, which idles
> when nothing plays, so the IOProc (and the mic sub-device) stop. Fix +
> modernize with a dual-backend design. Default engine/capture behavior is
> otherwise unchanged.

- [x] PRD/docs: §6.2 two-backend model + `--capture-backend`; §7 Compatibility/Security (Screen Recording vs System Audio Recording, headless); docs/permissions.md both flows; min OS stays 14.4 (SCKit gated on 15+)
- [x] Step 1 — Core Audio tap fix (Option A): make the **microphone the aggregate's clock master** for `--mix` (was the tap), pin nominal rate to max(tap, mic); continuous mic capture regardless of system activity, headless-safe. This alone fixes the reported bug (commit `d42aba5`)
- [x] Step 2 — `ScreenCaptureSession` (`@available(macOS 15)`): `SCStream` system/app audio via `SCContentFilter` (system/`--app`/`--exclude-app`), `.audio` → `CMSampleBuffer` → `PCMStreamConverter`; Screen Recording permission helper; reachable via `--capture-backend sckit` (commit `f9d5c37`)
- [x] Step 3 — SCKit integrated mic + `--mix`: `captureMicrophone`/`microphoneCaptureDeviceID` + `.microphone` output; app-level mixer (`StreamMixing.sum`) summing synchronized system+mic (commit `f9d5c37`)
- [x] Step 4 — `--capture-backend auto|sckit|coreaudio` (+ `$HARK_CAPTURE`); auto prefers SCKit when (macOS 15 ∧ Screen Recording ∧ display present, via `ScreenCaptureSession.isAvailable()` — preflight, never prompts) else notify + fall back to Core Audio (commit `f9d5c37`). Note: selection is preflight-based; a runtime SCKit start failure after auto-selecting it surfaces an error rather than retrying Core Audio (rare grant-but-no-GUI case) — deferred
- [~] Step 5 — docs/tests: [x] README/man (`--capture-backend`, both permissions, `$HARK_CAPTURE`, headless note); [x] unit tests (`StreamMixingTests`, CLI backend resolution/validation); [x] `Scripts/verify-live.sh` step [6] covers both backends (sckit perm/headless → SKIP). Pending (needs Screen Recording grant + GUI): [ ] sckit end-to-end audio live test; [ ] re-run the 60-min mic/system drift validation for both `--mix` paths
- [x] `hark apps` stays HAL-based (headless-friendly); the SCKit backend maps bundle id/PID → `SCRunningApplication` internally (`ScreenCaptureSession.match`)

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
- [x] PRD §6.7/§7 reconciled to the implemented VAD behavior (default-on on Apple Silicon, Silero model fetched on first live run, opt-out `HARK_VAD=0`, amplitude fallback)
- [ ] PRD §6.1 reconciliation: `--speakers` flag + `--speaker-mode` (vs the drafted `--speakers[=mode]`)
- [ ] docs/permissions.md: diarization/VAD need **no new TCC** (operate on already-captured audio) but fetch FluidAudio CoreML models from Hugging Face on first use
- [ ] README/man deferred to 8.7 (kept with the feature's other user-facing docs)

### Phase 8.1 — VAD-based live segmentation (the runtime fix; no labels yet)

- [x] `SpeechSegmenter` protocol so the amplitude boundary can be swapped; `StreamSegmenter` conforms (`SpeechSegmenter`/`VadSegmenter` in `VadSegmenter.swift`)
- [x] `VadSegmenter`: single consumer `Task` over an unbounded `AsyncStream`; unpack→mono→resample(16k)→4096-sample windows→full streaming state machine (`speechStart`/`speechEnd`), maxWindow/minSegment/leading-trim; sample-accurate byte-clock timestamps
- [x] `VoiceActivityStream` abstraction + `FluidVadClassifier` (FluidAudio `VadManager.processStreamingChunk`, model loaded once)
- [x] `SpeechSegmenterFactory`: VAD by default on Apple Silicon (first-run download), graceful fallback to the amplitude method on Intel / load failure; `HARK_VAD=0` to force-disable; `--silence-threshold` stays the fallback knob
- [x] Wired into `LiveTranscriber` behind the abstraction (`LiveTranscriber.swift:51`)
- [x] Tests: `VadSegmenterTests` (synthetic `ScriptedVAD` — boundary/clock/max/min/trailing-flush) + gated `HARK_TEST_VAD=1` real-model integration; existing live e2e pinned to `HARK_VAD=0`
- [ ] Live-capture e2e of the VAD segmenter (real mic/system) — on the pending-live list (covered offline by the synthetic + gated tests)
- [x] **Quiet-audio hardening** (diagnosed from `Tests/ManualTests/test3.mp3`, where a quiet phrase peaking ~−45 dBFS was dropped at the VAD gate): lowered the default VAD threshold 0.85→0.5, added `--vad-threshold 0..1`, and per-segment peak normalization (`GainNormalizer`, +20 dB cap, target −3 dBFS) before the engine — recording untouched, `HARK_GAIN=off` to disable. Gated test replays the recording and confirms the quiet region now segments at 0.5

### Phase 8.2 — Speaker label data model + output formats

- [x] Added optional `speaker` to `TranscriptCue` (`EngineSupport.swift`) and the live/batch JSON `Segment` structs (`LiveTranscriptWriter.jsonLine`, `TranscriptFormatting.render`) — nil omits the key (encodeIfPresent), so default output is byte-identical
- [x] Render labels: txt `You: …`/`Speaker 1: …`; srt `[Speaker 1] text` (valid SRT); json `"speaker"` field — in both `TranscriptFormatting.render` and `LiveTranscriptWriter.append`
- [x] Added `--speakers` (alias `--diarize`) + `--speaker-mode auto|source|acoustic` + `--speaker-labels "You,Others"` to `Hark.swift`; validation (mode/labels require `--speakers`; `source` needs two sources; labels must be a pair). Note: implemented as a `--flag` + `--speaker-mode` rather than `--speakers[=mode]` (ArgumentParser has no optional-value options); PRD §6.1 to be reconciled in 8.0
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
- [x] Tests: `SpeakerLabeling.normalize` + `SpeakerNumbering` (pure), `BatchDiarization.merge` ordering, resolver-overrides-fixed-label, catalog parse, env-gated integration (`HARK_TEST_DIARIZE=1`)

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

- [x] `ModelCatalog` parses/lists `fluidaudio:diarizer` / `fluidaudio:vad`; `hark models download` dispatches to FluidAudio loaders (`SpeakerDiarizer.download` / `FluidVadClassifier.downloadModel`); never adopted as the transcription default; `list --available` shows them ("speaker pipeline")
- [x] `hark models list` (local) shows the FluidAudio cache correctly: `FluidAudioCache.engine(forBundle:)` classifies each bundle (`*parakeet*` → parakeet; `silero-vad`/`speaker-diarization` → fluidaudio), and `coreMLModels` flags the configured CoreML default as `current` (so `parakeet-tdt-0.6b-v3` gets `*`); a no-default hint prints when nothing resolves
- [x] **Model-load UX fix:** VAD loads once per process (shared static `VadManager`, shared across the two source-attribution streams; per-stream state); cached loads are silent (`Log.verbose`), with a one-time `downloading … (first use)` notice only on a real fetch — replacing the misleading per-run "preparing … (first run may download)" notice. (FluidAudio's own INFO logging is DEBUG-only; release stderr is clean.)
- [x] **Config parity + `config show` redesign** (declarative settings registry): every meaningful parameter is now flag↔`$HARK_*`↔config with `ResolvedSettings` precedence (flag › env › config › default). New config keys: `capture-backend`, `rate`/`bits`/`channels`, `vad`, `vad-threshold`, `gain`, `speakers`, `speaker-mode`, `speaker-labels`, `diarize-engine`, `max-speakers`, `speaker-threshold`. Bool flags are now three-state (`--vad/--no-vad`, `--gain/--no-gain`, `--speakers/--no-speakers`) so config can supply a default. `hark config show` lists **all** settings with VALUE + SOURCE (`default`/`config`/`env`); `--json` → `{key:{value,source}}`. `Setting`/`TypedSetting` registry (`Settings.swift`) drives show/set/unset/resolve from one descriptor per key
- [x] **`config show` DESCRIPTION column**: each setting carries a one-sentence `summary` in the registry; `config show` renders it as a fourth column and `--json` gains a `description` field per key
- [x] Tests: catalog parse (`fluidaudio:` tags + `available()` coverage)
- [x] Leaf-subcommand `--help`: the broad symptom was a zsh test artifact (an unquoted `$var` holding `"models list"` is passed as one argument, so hark shows root help) — `hark models list --help` etc. work directly (also helped by the argument-parser 1.8.2 bump). The one real case, `hark config set --help`, was swallowed by `.captureForPassthrough` (used for `-40` values); fixed via `ConfigSet.isHelpRequest` → `CleanExit.helpRequest`. Stale man BUGS note removed.
- [x] First-use download visibility at capture start: every auto-downloading backend prints a default-level `downloading … (first use)` notice before fetching (`ParakeetBackend`, `WhisperKitBackend`, `Diarization`, `EENDDiarizer`, `FluidVadClassifier`); cached loads stay silent. (whisper, the default, doesn't auto-fetch — a missing model gives a clear HF download hint.)

### Phase 8.7 — Validation & user-facing docs

- [ ] NFR: live label latency (tentative ≤1s, final ≤2s), streaming RTF<1 on Apple Silicon (PRD §7)
- [ ] Diarization DER on a reference clip set; segmentation-stability check (fewer spurious cuts than the amplitude method) — PRD §8
- [x] Docs: README "Speaker labels" section (flags table + examples + caveats) + `fluidaudio:` model rows + `HARK_VAD`; man `SPEAKER LABELING` section + `HARK_VAD` + examples (mandoc clean); docs/permissions.md diarization/VAD note (no new TCC, first-use model fetch); corrected the stale `--speakers`/`--diarize-engine` `--help` strings (no longer say "planned")
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
- [x] Fixed broken-pipe on exit: `LiveTranscriptWriter.append` wrapped EPIPE in `HarkError`, defeating `isBrokenPipe`; now propagated raw so transcript-to-stdout `Ctrl+C` is graceful (no spurious "transcript write failed")
- [x] Gated `say` ground-truth test (`SayDiarizationTests`, `HARK_TEST_DIARIZE=1`): single speaker stays one, two distinct voices separate with a stable 1:1 mapping — validates the zero-config default end-to-end (minus TCC capture)
- [ ] Real-call e2e (TCC capture front-end) remains on the pending-live list; streaming RTF measured ≪ 1 (≈0.01) via the harness

## Phase 9: Working directory for artifacts (PRD Feature 20 / §6.1)

> A git-`-C`-style base directory for resolving **relative** artifact paths,
> defaulting to the process CWD. Foundation for headless/remote operation.

- [x] Add the `directory` config setting: registry entry (`Configuration`/`Settings`) with a `config show` summary/DESCRIPTION; env var `$HARK_DIRECTORY`; `ResolvedSettings` precedence flag › env › config › CWD
- [x] Add the `--directory`/`-C PATH` root option (ArgumentParser); validate the path is an existing directory (usage error otherwise; never auto-create) — `ResolvedSettings.applyWorkingDirectory`
- [x] Resolve **relative** root-verb artifact paths against the working directory — `-i`, `-a`, `-t`, and `--split` outputs — leaving absolute paths, `-` (stdin/stdout), and Hark's own state (`~/.hark/…` config + models) untouched. Subcommand positionals (e.g. `info <file>`) keep using the process CWD for now
- [x] Add the precedence-table row to `config show` + PRD §6.1 precedence table (working directory → `--directory`/`-C` › `$HARK_DIRECTORY` › `directory` › CWD)
- [x] Tests: precedence resolution (flag/env/config/default); missing-directory usage error (`ResolvedSettingsTests.directoryResolves…`/`applyWorkingDirectoryValidatesExistence`)
- [x] Docs: README (`-C/--directory`, `$HARK_DIRECTORY`, config key `directory`) + man (`--directory`, `HARK_DIRECTORY`); noted as the remote-control foundation (done alongside Phase 10.4)

## Phase 10: Status, Interactive & Remote Control (PRD M8, §6.8–§6.10)

> Adds an at-a-glance startup status (§6.8), an interactive live-capture UI with
> pause(gap)/resume/stop (§6.9), and an on-demand remote-control agent exposing a
> control-only HTTP/JSON API (§6.10). Depends on M4 (live transcription, done)
> and Phase 9 (working directory) — the agent resolves output "where" under the
> working `directory`, so Phase 9 lands first. Reuses existing patterns: stderr
> `Log`/`isatty` (TranscribeEngine.swift:87), `ResolvedSettings`, the
> `CaptureEngine.run` capture loop + `SignalWatcher`, and loopback-HTTP know-how
> from `WhisperServerEngine`. The HTTP server is the embedded FlyingFox SwiftPM
> dependency (statically linked; nothing for users to install).

### Phase 10.0 — Spec & docs (PRD first)

- [x] PRD §6.8/§6.9/§6.10 + FR rows 21–23, §4.2 reconcile, US09–11, §7 NFR, §8 metrics, §9 M8, §10 Open Qs (Q9 resolved-into-scope, Q10 pause×split)
- [x] PRD §6.10 revision: replaced the `/recordings/{id}` REST design with **flat single-session control verbs** (`POST /start|/stop|/pause|/resume`, `GET /status`); single active session (parallel `/start` rejected); API is **control + status only** — never serves transcript/audio content (artifacts retrieved from the working `directory`)
- [x] Add the FlyingFox SwiftPM dep to Package.swift (FlyingFox + FlyingSocks, embedded/static; nothing for users to install); MIT recorded in NOTICES
- [ ] README/man deferred to 10.4 (kept with the feature's other user-facing docs)

### Phase 10.1 — Startup status summary (§6.8)

- [x] `StartupStatus` renderer (`StartupStatus.swift`): concise block from `ResolvedSettings` + resolved source/outputs (engine, model, language/translate, source + capture backend, format rate/bits/channels, output destinations, speaker mode, VAD, duration/split) via `Hark.liveStatusText`
- [x] Visibility gating: `StartupStatus.shouldShow` shows on stderr when `isatty(STDERR_FILENO)`, always with `-v`, suppressed when stderr is redirected; written via stderr only (never stdout)
- [x] Wire into `runLiveInput` before capture starts (after `makeCapture`); existing `Log.verbose("source: …")` lines kept
- [x] Tests: field rendering (present/omitted) + gating decision (`StartupStatusTests`)

### Phase 10.2 — Capture-control core + interactive mode (§6.9)

- [x] Capture-control core (`CaptureControl.swift`): `CaptureEngine.run` gains an optional `control`; pause drops chunks in both the mixed IO callback and `onSourceAudio` (true gap, no `--duration` budget consumed); `stop()` wakes the wait loop alongside `SignalWatcher`
- [x] Pause omits audio AND transcript: paused chunks never reach the sinks/segmenter, so the byte-clock gaps automatically for both the recording and the transcript
- [x] `--interactive` flag + validation: live-only (rejects `-i`) and rejects `-a -`; runtime TTY guard in `runLiveInput` (stdin+stdout must be a TTY); record-only `--interactive` forces the transcript to the terminal (`resolveOutputs`)
- [x] Terminal cbreak mode (termios, VMIN=0/VTIME=1) with guaranteed restore on stop/deinit; single-key reader (**space**=pause/resume, **Enter**=finish; Ctrl-C still stops) — `InteractiveSession.swift`
- [x] Minimal TTY UI: status header (10.1) on stderr + live transcript on stdout (rendered even without `-t`) + control hints/notices on stderr (no pinned footer, per decision)
- [x] Tests: `CaptureControl` state machine (pause→resume→stop, idempotent, late stop-handler), `--interactive` accept/reject combos, interactive output resolution (`InteractiveTests`)
- [x] Interactive screen-echo: when the transcript is persisted to a file, mirror each finalized segment (plain text + speaker label) to the on-screen UI so live captions always show — `LiveTranscriber.screenEcho` wired from the single, source-attributed, and single-diarized live paths (`Hark.swift:694/790/796/848`, `LiveTranscriber.swift:197`)
- [ ] Live-capture e2e of interactive pause/resume/stop (real mic/system) — on the pending-live list (can't run permission-free)

### Phase 10.3 — Remote-control agent (§6.10)

- [x] `--remote-control [host:]port` flag (`RemoteControlAgent`): parse `[host:]port`, loopback default (conventional port 8473); modal (starts agent, no immediate capture); launch capture flags become per-session defaults; mutually exclusive with `--interactive`/`-i`
- [x] FlyingFox HTTP server bound to the resolved IPv4 address; loopback default; refuse non-loopback bind without `$HARK_REMOTE_TOKEN`; bearer-token check per request when a token is configured; prints bound address to stderr; graceful SIGINT/SIGTERM shutdown
- [x] `RemoteSessionManager` (single active session): `POST /start` while one is active → `409 Conflict`; control verbs act on the current session; capture driven via the 10.2 `CaptureControl`; outputs resolved under the working directory; full parity (`StartRequest.makeCommand` = launch defaults + overrides → same `Hark.executeLive` pipeline, incl. `--speakers`)
- [x] Endpoints (flat, control + status only — never serve file content): `GET /status` (state/elapsed/output paths); `POST /start` (JSON body mirrors CLI flags/outputs over launch defaults, e.g. `{"transcript":"notes.txt","audio":"rec.m4a","system":true}`) → `{id,state,audio,transcript}`; `POST /stop`; `POST /pause`; `POST /resume`
- [x] Error mapping: HarkError/exit codes → HTTP status (permission→403, bad params→400, engine/model missing→404/422, busy→409, transcription→422) with JSON `{error}`
- [x] Tests: address+token parsing, `StartRequest.makeCommand` overrides/validation, single-session 409 + lifecycle (`RemoteSessionManager`), exit-code→HTTP mapping (`RemoteControlTests`); verified live via curl (status/start/pause/resume/stop, 401/403/409/400/404, real mic capture)
- [ ] Live-capture e2e of agent-driven start/stop with system audio + speakers (real meeting) — on the pending-live list

### Phase 10.4 — Userscript reference & user-facing docs

- [x] `docs/remote-control.md`: HTTP API reference (endpoints, JSON shapes, status codes, token/auth, loopback default, single-session rule, control-only scope)
- [x] Tampermonkey Google-Meet reference userscript (in `docs/remote-control.md`): detects call join/leave on `meet.google.com`, `GM_xmlhttpRequest` to the loopback agent (`POST /start` on join with a filename from meeting title + date, `POST /stop` on leave/unload)
- [x] README "Interactive mode" + "Remote control" sections + `-C/--directory` + `directory` config row; man page `--interactive`/`--remote-control`/`--directory` + `HARK_DIRECTORY`/`HARK_REMOTE_TOKEN` + examples (mandoc lint clean)
- [x] docs/permissions.md: agent needs no new TCC (same capture permissions); listener is loopback-only by default

### Phase 10.5 — Validation

- [x] NFR (§7): API control round-trip measured ~0.5–1.5 ms on loopback (≪ 200 ms target); pause/resume takes effect within one capture buffer (drop-on-paused). Live speaker-label latency unchanged from Phase 8
- [ ] Metric (§8): Tampermonkey recipe records + names a Meet call end-to-end (gated/manual — needs a browser + Meet)
- [x] Gated steps added to `Scripts/verify-live.sh`: [7] interactive non-TTY guard, [8] remote-control start/409/stop lifecycle (mic-permission → SKIP). Interactive keypress e2e + agent-with-system remain manual (pending-live)
- [x] Resolve Open Q10 (pause × `--split`): pause drops chunks → gap within the current chunk, no new file; deterministic test `CaptureControlIntegrationTests.pausedAudioIsDropped`

### Phase 10.6 — Interactive mic mute & transcript yank (§6.9, US12)

> Two new single-key controls in the `--interactive` UI: **m** mutes/unmutes the
> microphone (silences only the mic — timeline preserved, distinct from pause's
> gap), **y** yanks the full session transcript so far to the system clipboard.
> Interactive-only; remote-control parity deferred (Future). Builds on the
> Phase 10.2 capture-control core + `InteractiveSession` key reader.

- [x] `CaptureControl` gains a `muted` flag + `toggleMute()` (independent of pause/stop, cleared on stop); mic mute **zeroes** the mic samples rather than dropping chunks, so the timeline is preserved (mixed `-a` keeps system audio; mic-only records silence)
- [x] Apply mute at the mic-ingest point via a new `MicMutableCaptureSession` protocol (`micMuted: () -> Bool`): `MicCaptureSession` zeroes its converted PCM; `SystemCaptureSession` switches the main mix to `StreamMixer.systemBuffer` (system-only) and zeroes the `.microphone` source; `ScreenCaptureSession` zeroes the mic before `drainMix` + the `.microphone` tee. `CaptureEngine.run` wires `{ control.isMuted }` for all paths; the system/`.system` path is untouched
- [x] In-memory transcript accumulator (`TranscriptLog`): every finalized caption (plain text, with speaker label when `--speakers` is active) appends to a shared session buffer fed by the single, source-attributed, and single-diarized `LiveTranscriber`s — independent of `screenEcho`
- [x] Clipboard writer: `ClipboardWriter` protocol + `SystemClipboard` (NSPasteboard, falling back to `pbcopy`); tests use a fake
- [x] `InteractiveSession` key handling: **m** → `control.toggleMute()` + stderr notice ("microphone muted/unmuted"); **y** → copy buffer + notice ("transcript copied to clipboard (N lines)"), empty buffer → "nothing to copy yet" (clipboard left unchanged)
- [x] Controls hint + mic awareness: `hasMic` (mic-only or `--mix`) passed into `InteractiveSession`; the **m** hint shows only when a mic is present; with no mic, pressing **m** prints "no microphone in this capture" and does nothing. **y** is in the hint unconditionally
- [x] Help/docs: `--interactive` help string + README "Interactive mode" + man page controls list updated with **m**/**y** (mandoc clean); `examples/hark-meeting` header; CHANGELOG Unreleased; yank noted as local-clipboard-only
- [x] Tests: `CaptureControl` mute toggle (independent of pause; cleared on stop); `TranscriptLog` accumulation; `ClipboardWriter` fake copy + empty-buffer no-op; hint visibility / no-mic notice; `InteractiveSession.handleKey` dispatch for space/m/y/Enter. `make test` green — 281 tests, 74 suites
- [ ] Live-capture e2e of interactive mute + yank (real mic) — pending-live list (keypress path can't run permission-free; mic-zeroing in the OS sessions can't run without TCC)

### Phase 10.7 — Remote-control agent as a managed service (`brew services`)

> Run the on-demand agent (10.3) under launchd via a Homebrew `service` block, so
> `brew services start hark` keeps it always-on for the browser userscript (US11)
> without an open terminal — a **per-user LaunchAgent** (login/GUI session;
> supports mic + ScreenCaptureKit + Core Audio; auto-start at login, **no
> auto-restart by default**). Adds a persisted `remote-control-port` config key
> (default 8473) so the agent launches without an explicit address. The cron-style
> scheduler + logout-survival LaunchDaemon stays in Future. PRD §4.2, §6.1, §6.10,
> §7 Installability, US11.

- [x] Add the `remote-control-port` config setting (default 8473) — synced across `ConfigKey` (`Settings.swift`), `Configuration.settings` registry + field + `CodingKeys` (`Configuration.swift`), `ResolvedSettings` (resolve `?? 8473` + memberwise init), and the exhaustive `switch ConfigKey` + `.with(...)` test helper; env `$HARK_REMOTE_CONTROL_PORT` auto-derived; integer validation 1–65535; `config show` description. Verified live: `config show/set/unset`, range error
- [x] Make `--remote-control`'s value optional: ArgumentParser can't carry an optional option-value (and rejects `[String]?`), so `Hark.main()` normalizes argv — a value-less `--remote-control` (last token or followed by another option) gets an empty-string sentinel; dispatch binds loopback on the resolved `remote-control-port` for the sentinel, an explicit `[host:]port` still wins. Preserves `hark --remote-control 8473`/`:8473`/`0.0.0.0:8473` + `--interactive`/`-i` exclusivity. Verified live: bare → 8473, env → 7000, config → 9100, explicit → 9999
- [x] Add a `service do … end` block to `Formula/hark.rb`: `run [opt_bin/"hark", "--remote-control", "--no-keep-awake"]`, `run_type :immediate`, **no `keep_alive`** (crash/bad-start stays visible, not relaunched in a hidden loop), `log_path`/`error_log_path` → `var/log/hark-remote.log`. `brew style` clean. Port/dir/engine come from `hark config`
- [x] Tests: `ConfigurationTests.roundTripsAllKeys` covers the new key (count invariants auto-pass); `ResolvedSettingsTests.remoteControlPortFollowsEnvConfigDefault` (default › config › env, range error, env-name map); `RemoteControlFlagTests` (argv normalizer + bare/explicit parse). `make test` green — 286 tests, 75 suites
- [x] Docs: `docs/remote-control.md` "Running as a service (`brew services`)" section (start/stop/restart, log path, config port/dir, per-user-vs-logout, no-KeepAlive rationale + opt-in, `--no-keep-awake`); README "Remote control" note; man page (`--remote-control` optional value, `HARK_REMOTE_CONTROL_PORT`, `brew services` example); CHANGELOG Unreleased
- [x] TCC-under-launchd validation (live, macOS 26.4.1): the LaunchAgent-spawned signed `hark` captures — the **mic prompt attributes directly to hark** and works; **system/app audio needs a manual grant to the hark binary** in Screen & System Audio Recording (no prompt for CLIs; both `sckit` and `coreaudio` then work under the service); parakeet transcription + speaker labels work; grants are **path-recorded against the versioned Cellar path** (re-grant may be needed after upgrades). Resolves PRD Open Q4. Found: launchd on macOS 26 loads but does not spawn newly-bootstrapped user agents mid-session (any binary, any API — RunAtLoad/KeepAlive only take effect from the next login; BTM disposition enabled/allowed, so not BTM); first `brew services start` needs one `launchctl kickstart` → formula caveats + `keep_alive true` (crash resilience) added in 10.9
- [ ] Auto-start at login re-verified after a real logout/login (pending-live — needs a session restart)

### Phase 10.8 — Remote-control mute/unmute parity (§6.10, US12)

> Expose the interactive mic mute (§6.9) over the agent as explicit, idempotent
> `POST /mute` / `/unmute`, a `muted` field in `GET /status`, and an optional
> `muted` in `POST /start`. The capture core already mutes correctly for
> agent-driven sessions (Phase 10.6 `CaptureControl` + `MicMutableCaptureSession`),
> so this is API-exposure only — no new TCC permission; the brew-services agent
> (10.7) inherits it. Mute is orthogonal to pause (silences only the mic; timeline
> preserved) and requires a mic in the capture (else `422`). Transcript yank stays
> interactive-only (the API never serves transcript content). Builds on 10.3 + 10.6.

- [x] Extract `Hark.capturesMicrophone` (mic-only or `--mix`) from the `hasMic` expression in `runLiveInput`; reuse it there and to gate the agent's mute verbs
- [x] `CaptureControl.mute()`/`unmute()` — explicit idempotent setters beside `toggleMute()` (return whether changed; no-op once stopped)
- [x] `RemoteSessionManager`: `Snapshot` gains `hasMic` + `muted`; `mute()`/`unmute()` guard active session (404) and reject no-mic via new `AgentError.noMicrophone` (422); `begin(hasMic:muted:)` starts muted when requested (422 if no mic)
- [x] `StartRequest.muted: Bool?` (agent-handled, not a CLI flag); agent computes `hasMic = command.capturesMicrophone`, registers `POST /mute|/unmute`, threads `muted` into `StartedResponse`/`ActionResponse`/`StatusResponse.Session`, maps `noMicrophone → 422`
- [x] Tests: `CaptureControl.mute/unmute` idempotency; session-manager mute/unmute lifecycle + idempotency, 404 with no session, 422 no-mic, `/start {muted:true}` (and 422 no-mic); `capturesMicrophone` source combos. `make test` green — 292 tests, 76 suites. Live curl: `/mute`/`/unmute` routed, no-session → 404 JSON
- [x] Docs: `docs/remote-control.md` endpoints + status codes (422 no-mic) + status/`start` JSON `muted`; README curl note; CHANGELOG Unreleased; PRD §6.10 endpoints + §4.2 deferred bullet retired + US12 criterion
- [x] Reference Meet userscript extracted to `examples/hark-meet.user.js` (Tampermonkey header + `@version`/`@downloadURL`/`@updateURL` for one-click install + self-update) and mirrors the Meet mic toggle to the agent **one-way** (Meet → hark): `MutationObserver` on the mic button (`data-is-muted`/aria-label heuristic) + 2s poll fallback, initial state via `POST /start {muted}`, guarded by `hasMic` (skips `/mute` when the capture has no mic → avoids `422`). `docs/remote-control.md` now links the file instead of inlining it; `examples/README.md` row + Tampermonkey install note; PRD US11/US12/§6.10 + CHANGELOG updated
- [x] Live e2e of agent-driven `/mute`/`/unmute` with a real `--mix` recording: exercised against the brew-services agent (macOS 26) — mute/unmute mid-capture flip `muted` while `state` stays `recording`, speaker-labeled transcript produced (strict audible-gap listening check not performed)
- [ ] Live e2e of the Meet userscript in a real call: verify the `data-is-muted`/aria-label selector reads the mic state and that toggling in Meet mirrors to the recording (gated/manual — needs a browser + Meet)

### Phase 10.9 — Brew-service hardening & agent fixes (0.4.1)

> Outcome of validating 10.7/10.8 live on macOS 26: three agent bugs, a
> zero-byte-capture blind spot, and two service-delivery fixes (formula
> `keep_alive` + kickstart caveat). PRD §4.2/§6.10/US11/Open Q4 updated.

- [x] `harkVersion` single source of truth (`Hark.swift`): used by `CommandConfiguration(version:)`, the WAV-metadata `software` tag, and the agent's `GET /status` (was a stale hardcoded "0.1.0"); release bumps now edit one constant; `VersionTests` guards drift
- [x] `GET /status` reports the parsed bound address (`127.0.0.1:8473`) instead of the raw `[host:]port` value (a bare `--remote-control` used to show just `"8473"`)
- [x] Clean SIGTERM/SIGINT shutdown: `server.stop()` makes `server.run()` throw (kqueue EBADF), which was misreported as "could not start … port already in use?" with a non-zero exit on every `brew services stop`; a `shuttingDown` flag now suppresses the post-stop error and the agent exits 0 (correct launchd semantics, prereq for `keep_alive`)
- [x] All-silence warning also fires for zero-byte captures (`CaptureEngine`): a permission-less tap under launchd delivered no bytes at all, so the `totalBytes > 0` guard silenced the TCC hint exactly when it was needed; now fires for ≥2s captures with no signal and mentions the background-service grant path
- [x] Formula: `keep_alive true` (crash resilience; relaunches throttled + logged) and `caveats` documenting the macOS 26 first-start `launchctl kickstart` nudge and the system-audio grant
- [x] Docs: permissions.md background-service section; remote-control.md service section rewrite; PRD §4.2/§6.10/US11 + Open Q4 resolved; CHANGELOG
- [ ] Post-release verification: `brew upgrade hark` → grants survive the Cellar path change? (path-recorded TCC entries) — document the outcome; auto-start after logout/login

## Phase 11: Legal & Export-Compliance Docs (PRD §7 Legal & Compliance)

> Docs-only hygiene prompted by an external "assess it from the legal
> standpoint" review (export/import controls, encryption registration). No code,
> no filings. Self-classification: ancillary crypto only (OS TLS + transitively
> linked `swift-crypto`), publicly-available open source → EAR99 / not a
> controlled encryption item; capture is TCC-consent-gated, not interception
> software. (Informational, not legal advice.)

- [x] PRD: §7 NFR **Legal & Compliance** row + §10 assumption (export/encryption classification deferred TSU notification)
- [ ] `docs/legal.md`: export classification (Note 4 ancillary exclusion + publicly-available open-source carve-out, EAR99 self-class), encryption import/registration regimes (bind in-country importers, not OSS publication), surveillance/interception (TCC-gated, overt, on-device — not intrusion software), responsible-use / recording-consent (user's responsibility; no network by default, no telemetry)
- [ ] README: "Legal & responsible use" section (before License) + link to `docs/legal.md`
- [ ] Light tone pass on surveillance-adjacent phrasing (keep features; frame around consented note-taking)
- [ ] (Deferred) Optional one-time BIS/NSA **TSU** encryption-notification email — out of scope unless a non-ancillary crypto dep or a commercial/import channel lands (PRD §10 Open Q11)

## Future

> Nice-to-have items outside current scope.

- [ ] Scheduled/unattended daemon: *schedule* recordings (cron-style) and survive logout via a system LaunchDaemon (Core Audio backend, headless), extending the Phase 10.7 brew-services LaunchAgent (PRD §4.2)
- [ ] Crash resilience for hard kills: periodic header flush vs `hark repair` subcommand (parked — PRD Open Q1)
- [ ] Opt-in telemetry mechanism for crash-free-rate KPI (PRD Open Q3)
- [ ] Real-time streaming to network socket or HTTP endpoint
- [ ] Multi-channel mapping: separate tracks for mic and system audio
- [ ] Plugin system for custom DSP filters (EQ, noise suppression)
- [ ] Configuration profiles for default sources, formats, transcription settings
- [ ] Cloud transcription backends (Deepgram, Google) via `--engine cloud`
- [ ] Silence-based voice activity detection for trimming
- [ ] Named speaker identification: voiceprint enrollment + local speaker store (FluidAudio embeddings) (PRD §4.2 / Open Q5)
- [ ] Overlapping-speech handling / per-word speaker assignment (PRD Open Q6)
- [ ] Cross-host & authenticated remote control beyond the loopback default (token/TLS, allow-lists) (PRD §4.2 / Open Q9 — base agent is Phase 10)
