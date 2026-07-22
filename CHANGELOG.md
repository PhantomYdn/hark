# Changelog

All notable changes to Hark are documented here. The format is loosely based on
[Keep a Changelog](https://keepachangelog.com/), and the project aims to follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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
