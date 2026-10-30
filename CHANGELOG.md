# Changelog

All notable changes to Hark are documented here. The format is loosely based on
[Keep a Changelog](https://keepachangelog.com/), and the project aims to follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed
- Dependencies updated: WhisperKit (argmax-oss-swift) 0.18 → 1.1.1,
  FluidAudio 0.15 → 0.18, FlyingFox 0.26 → 0.27. WhisperKit 1.x vendors its
  Hugging Face plumbing, dropping six transitive packages (swift-transformers,
  swift-jinja, swift-crypto, swift-asn1, swift-collections, yyjson).
- FluidAudio is linked with only its `Diarizer` trait (no TTS / NeMo text
  normalization), keeping the release binary at ~15 MB instead of ~28 MB.
- Building from source now needs Swift 6.2+ (Xcode 26+); the binary still
  runs on macOS 14.4+.

## [0.4.3] - 2026-09-17

### Fixed
- A capture that can't reach the audio stream — most often a missing or stale
  "System Audio Recording" grant — could block forever in the Core Audio
  teardown, taking the whole recording with it. Stopping is now bounded
  (`$HARK_TEARDOWN_TIMEOUT`, default 5 s): hark reports the problem and
  finalizes the outputs anyway, so the audio captured so far stays playable.
  Late chunks arriving from the audio thread during teardown are dropped instead
  of racing the sinks being finalized.
- The remote-control agent handled such a capture badly: because captures share
  one serial queue and `POST /stop` marks the session `stopped` optimistically,
  the next `POST /start` returned `201` and then never recorded, while
  `GET /status` still showed `stopped` with `error: null` — the agent looked
  healthy but was dead. Now a stop that doesn't complete within
  `$HARK_STOP_TIMEOUT` (default 10 s) marks the session `failed` with an
  explanatory error, and a `POST /start` behind a stuck worker is refused with
  `409` instead of being silently accepted. Agent shutdown notes a
  still-finishing capture in the service log.

### Documentation
- PRD §6.1 documented `--speakers[=auto|source|acoustic]`, which the binary
  rejects; it now describes the shipped `--speakers` + `--speaker-mode` pair (the
  example too). Feature 11 is marked WAV-only with MP4/ID3 deferred, Feature 14
  gains the shipped `parakeet` engine, and a new §9 milestone row covers the
  output-protection and reliability work.
- PRD §5 acceptance criteria are ticked where a test, verification script, or
  recorded live run demonstrates the behaviour (28 of 64), with a header
  defining what a checked box means; the rest stay open as TCC/GUI/soak-gated or
  not-yet-built.
- PLAN: the legal-docs phase is closed (it shipped in 0.4.0), stale placeholders
  resolved, and new phases added for this fix and for the unbuilt PRD M9
  (interactive shortcuts + combined agent).
- man page gains a `RESPONSIBLE USE` section plus `HARK_TEARDOWN_TIMEOUT` and
  `HARK_STOP_TIMEOUT`; `docs/reference.md` documents bounded teardown;
  `docs/remote-control.md` documents wedged-capture semantics.

## [0.4.2] - 2026-09-16

### Added
- Existing output files are protected instead of silently clobbered. Before
  capture starts — before permission prompts and model loading — Hark checks
  every file the run would write (audio, transcript, `--split` chunk set) and
  applies the new `--if-exists ask|error|overwrite|unique` (also
  `$HARK_IF_EXISTS`, config `if-exists`). The whole invocation is one artifact
  set: a single decision covers every output, and `unique` picks one suffix that
  is free for all of them, so an audio/transcript pair stays aligned
  (`rec-1.m4a` + `rec-1.txt`). New exit code **73** (`EX_CANTCREAT`) for a
  refusal or a cancelled prompt.
- `POST /start` on the remote-control agent accepts `ifExists` and defaults to
  `unique`, so an API-driven session never blocks on a prompt and never
  overwrites a previous recording; the response and `GET /status` report the
  paths actually being written. An `ifExists: "error"` collision maps to `409`.
- Naming the input as an output (`-i rec.wav -a rec.wav`), pointing `-a` and
  `-t` at the same file, or writing to a directory are now clear errors instead
  of a corrupt or cryptic result.

### Changed
- **Behaviour change:** a run whose output file already exists no longer
  overwrites it. On a terminal you are asked (`[o]verwrite  [u]nique
  [c]ancel`); off a terminal (cron, pipes, `hark | …`) the run refuses with exit
  73. Restore the old behaviour globally with `hark config set if-exists
  overwrite`, or per-run with `--if-exists overwrite`. To accumulate
  transcripts, append in the shell: `hark -t - >> notes.txt`.
- `examples/hark-meeting` now picks the next free `-N` name itself when a
  meeting with the same name was already recorded today (so the summary step
  still finds the transcript), and both it and `examples/hark-note` pass
  `--if-exists error` so a collision is a loud failure rather than a prompt or a
  rename behind the script's back.
- `examples/hark-meeting` now asks which fabric pattern to summarize with,
  instead of always using `summarize_meeting`. The prompt is an `fzf` picker over
  the installed patterns with the pattern's own text in a preview pane
  (`fabric-ai --readpattern`), and it runs *after* the recording — so the choice
  can be made having heard how the meeting went. Behaviour change: leaving
  `$FABRIC_PATTERN` unset now prompts rather than silently defaulting; set it
  (e.g. `FABRIC_PATTERN=summarize_meeting`) to keep the old non-interactive
  behaviour. Falls back to `summarize_meeting` whenever the picker can't or
  shouldn't run: no `fzf` installed (with a hint on stderr), stdin not a
  terminal (silently, so cron/CI stay quiet), or the picker cancelled with Esc.
  `fzf` is an optional dependency — the recipe still works without it.

### Fixed
- The WAV, MP3, Opus, and live-transcript writers created their output with
  `FileManager.createFile` and then opened it with a `FileHandle`, which does
  **not** truncate — so if the create step failed, new data was written over an
  existing file's stale trailing bytes, yielding a corrupt hybrid. They now use
  a single `open(2)` with `O_CREAT|O_TRUNC`.
- `examples/hark-meeting --help` printed a stray blank line and `set -euo
  pipefail` after the header, because it extracted a hardcoded line range. It
  now stops at the first non-comment line, so the header can grow freely.
- `examples/hark-meeting` now saves and restores the terminal's `stty` state
  around the recording. Hark restores cbreak mode itself on the normal paths,
  but if it is killed before installing its signal handler (e.g. Ctrl-C during a
  first-run model download) the terminal was left with no echo, which would also
  have broken the new pattern picker.

## [0.4.1] - 2026-07-22

### Fixed
- The remote-control agent's `GET /status` reported a stale hardcoded version
  (`0.1.0`) — it now reports the real hark version, from a new single-source
  `harkVersion` constant (also used by `--version` and the WAV-metadata tag).
- `GET /status` reported the raw `--remote-control` value as `address` (a bare
  flag showed just `"8473"`); it now reports the parsed bound address
  (`127.0.0.1:8473`).
- A clean SIGTERM/SIGINT stop of the agent was misreported as
  "remote-control server could not start … (is the port already in use?)" and
  exited non-zero — every `brew services stop` logged a bogus fatal error. The
  agent now shuts down silently and exits 0.
- The "captured only silence" TCC warning never fired when a permission-less
  system tap delivered no bytes at all (the exact background-service failure
  mode, which produced header-only files with no visible error). It now also
  fires for zero-byte captures (≥ 2 s) and mentions granting the permission to
  the hark binary itself for background (brew-services) use.

### Changed
- The Homebrew service now sets launchd `KeepAlive` (a crashed agent is
  relaunched, throttled and logged; a clean stop stays stopped), and the
  formula prints caveats for macOS 26: launchd does not spawn a
  newly-bootstrapped agent mid-session, so the first `brew services start`
  needs one `launchctl kickstart gui/$(id -u)/homebrew.mxcl.hark` (or a
  re-login).

### Documentation
- Validated the brew-services agent end-to-end under launchd on macOS 26 (mic +
  system audio + transcription + mute API) and documented the TCC story:
  permissions attribute directly to the hark binary; system audio needs a
  one-time manual grant (and may need re-granting after upgrades — grants are
  path-recorded against the versioned Cellar path). New "Background service"
  section in docs/permissions.md; service section rewritten in
  docs/remote-control.md; PRD Open Q4 resolved.

## [0.4.0] - 2026-07-22

### Added
- `docs/legal.md`: export classification (ancillary-cryptography exclusion and
  the publicly-available open-source carve-out → EAR99 self-classification),
  encryption import/registration regimes, why TCC-gated overt capture is not
  interception/intrusion software, and responsible-use / recording-consent
  notes. Linked from a new README "Legal & responsible use" section. (Shipped in
  this release; the entry was missed at the time.)
- Remote-control mic mute parity: the agent now exposes `POST /mute` and
  `POST /unmute` (idempotent; silence only the mic, timeline preserved — distinct
  from `/pause`), `GET /status` reports a `muted` field, and `POST /start` accepts
  `{"muted": true}` to begin muted. Muting a capture with no microphone returns
  `422`. The transcript yank stays interactive-only.
- The remote-control agent can run as a background service via Homebrew:
  `brew services start hark` runs it as a per-user LaunchAgent (auto-starts at
  login). The service binds the new `remote-control-port` config key (default
  `8473`, also `$HARK_REMOTE_CONTROL_PORT`) and runs with `--no-keep-awake`. No
  launchd `KeepAlive` on purpose — a crash or bad start stays down and visible
  rather than relaunching in a hidden loop. See
  [docs/remote-control.md](docs/remote-control.md#running-as-a-service-brew-services).
- `--remote-control` now takes an **optional** value: omit it to bind loopback on
  the configured `remote-control-port` (an explicit `[host:]port` still wins).
- The reference Google Meet userscript now ships as a standalone file,
  [`examples/hark-meet.user.js`](examples/hark-meet.user.js) (Tampermonkey
  one-click install + self-update), and **mirrors your Meet mic mute to the
  recording** one-way (Meet → hark): it starts with `muted` matching Meet's
  state at join, then `POST /mute`/`/unmute` as you toggle — near-instant via a
  DOM observer with a 2s poll fallback. `docs/remote-control.md` now links the
  file instead of embedding it.

## [0.3.0] - 2026-06-26

### Added
- Two interactive controls (`--interactive`): **m** mutes/unmutes the
  microphone — only the mic is silenced, so any system audio keeps recording and
  the timeline is preserved (distinct from pause, which omits the interval); the
  hint shows it only when a mic is in the capture. **y** yanks the transcript
  captured so far to the system clipboard (local only, no network).

### Fixed
- The VAD segmenter no longer deadlocks the Swift cooperative thread pool, which
  could stall live transcription (and hung CI).

### Documentation
- Overhauled the README (hero banner, demo GIF, use cases including fabric-ai
  pipelines, star CTA), added `docs/reference.md` and community-health files, and
  switched the direct-binary onboarding default to on-device Parakeet v3.

## [0.2.1] - 2026-06-24

### Fixed
- Live transcription no longer drops whole turns. The segmenter only transcribed
  Silero-VAD-detected speech and discarded everything else, so quiet or
  overlapping speech (e.g. remote participants picked up over a room mic) was
  lost — on a real 57-minute meeting ~a third of the words the same recognizer
  captures from the whole file were missing. The segmenter now covers the entire
  timeline (the VAD only chooses clean cut points; a max-window cut covers
  speech it misses), skipping only true silence. Measured coverage on that
  meeting rose from ~65% to ~80% of the whole-file baseline.
- A single segment that fails to transcribe no longer aborts the rest of the
  transcript; the failure is logged and that segment skipped (only a closed
  output pipe stops capture).

## [0.2.0] - 2026-06-23

### Added
- Capture now **auto-recovers from interruptions** (screen lock, display/system
  sleep, device/route change). A stall watchdog notices when the stream stops
  delivering audio and restarts the microphone, system-tap, or ScreenCaptureKit
  session, resuming automatically — previously a lock/sleep killed capture and
  the transcript silently stopped. Tunable via `$HARK_STALL_SECONDS` and
  `$HARK_RECOVER_TIMEOUT` (a bounded clean-stop fallback, off by default), or
  disable with `$HARK_NO_RECOVER`.
- `--keep-awake` / `--no-keep-awake` (also `$HARK_KEEP_AWAKE` and
  `hark config set keep-awake`): keep the machine awake while recording so idle
  sleep can't interrupt a long capture. Off by default; in `--interactive` it
  also keeps the display on.

### Fixed
- Live transcription no longer drops words or whole phrases on longer
  recordings. The VAD segmenter resampled each captured chunk independently
  (a fresh converter per chunk), so the 16 kHz clock that drives segment
  boundaries drifted from the captured audio and the error accumulated over
  time — progressively misaligning, clipping, and eventually dropping late
  turns. The segmenter now resamples the stream through one continuous resampler
  and slices each turn directly from that 16 kHz buffer by sample index (a
  single clock), and feeds whisper the already-16 kHz audio without a second
  resample.

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
- The release binary is signed (Developer ID) and notarized, so it passes
  Gatekeeper; its stable code identity keeps privacy grants across upgrades.

[0.4.1]: https://github.com/PhantomYdn/hark/releases/tag/v0.4.1
[0.4.0]: https://github.com/PhantomYdn/hark/releases/tag/v0.4.0
[0.3.0]: https://github.com/PhantomYdn/hark/releases/tag/v0.3.0
[0.2.1]: https://github.com/PhantomYdn/hark/releases/tag/v0.2.1
[0.2.0]: https://github.com/PhantomYdn/hark/releases/tag/v0.2.0
[0.1.0]: https://github.com/PhantomYdn/hark/releases/tag/v0.1.0
