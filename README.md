<p align="center">
  <img src="assets/banner.svg" alt="hark — capture and transcribe macOS audio from a single native CLI" width="760">
</p>

<p align="center">
  <a href="https://github.com/PhantomYdn/hark/actions/workflows/ci.yml"><img src="https://github.com/PhantomYdn/hark/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/PhantomYdn/hark/releases"><img src="https://img.shields.io/github/v/release/PhantomYdn/hark?sort=semver&color=3B82F6" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/macOS-14.4%2B-black?logo=apple" alt="macOS 14.4+">
  <img src="https://img.shields.io/badge/Swift-6-orange?logo=swift&logoColor=white" alt="Swift 6">
  <a href="https://github.com/PhantomYdn/hark/releases"><img src="https://img.shields.io/github/downloads/PhantomYdn/hark/total?color=2DD4BF" alt="Downloads"></a>
  <a href="https://github.com/PhantomYdn/hark/stargazers"><img src="https://img.shields.io/github/stars/PhantomYdn/hark?style=social" alt="Star hark"></a>
</p>

<p align="center">
  <img src="assets/demo.gif" alt="hark in action: list devices, transcribe a file, transcode, show config" width="820">
</p>

**`hark`** is the verb — *"listen and transcribe."* It captures your microphone,
all system audio, or specific apps on macOS and turns it into a transcript —
from a single native Swift binary, no drivers, no Electron, no network calls by
default. It's built the **Unix way**: do one thing well, one input → the outputs
you name, and clean stdin/stdout streaming that composes with `ffmpeg`, `sox`,
and your shell. Transcribe on-device with your pick of engines — whisper.cpp,
Apple Speech, WhisperKit, or Parakeet.

```sh
hark                                        # live mic → transcript on stdout
hark --system --mix -a meeting.m4a -t meeting.srt   # record a call, keep audio + subtitles
hark -i recording.m4a                       # transcribe a file
```

> ⭐ If hark saves you time, please [star it](https://github.com/PhantomYdn/hark) —
> stars help it qualify for a tap-free `brew install`.

## Use cases

Several of these pipe hark straight into
**[fabric-ai](https://github.com/danielmiessler/Fabric)** — hark turns sound into
text, fabric turns text into summaries, action items, and insights
(`brew install fabric-ai`).

**Watch live captions while you record** — see the transcript stream in your
terminal and save it to a file at the same time (pause, mute, or yank as you go).

```sh
hark --interactive --system --mix -t meeting.txt
```

**Summarize a meeting with AI** — capture the call + your mic, then let fabric
write the notes, decisions, and action items.

```sh
hark --system --mix -t - | fabric-ai -p summarize_meeting
```

**Hands-free notes for your Google Meet calls** — a browser userscript drives
hark's remote-control agent: it starts a recording when you join a call and stops
when you leave, naming the file from the meeting title. Zero clicks (record with
everyone's consent — see [Legal & responsible use](#legal--responsible-use)).

```sh
hark --remote-control 8473 -C ~/Recordings   # then add the Tampermonkey script (docs/remote-control.md)
```

**Dictate straight to your clipboard** — speak, get text, paste anywhere.

```sh
hark --engine apple -t - | pbcopy
```

**Mine a talk or podcast for insights** — pull the key ideas, quotes, and
references out of any recording.

```sh
hark -i podcast.mp3 -t - | fabric-ai -p extract_wisdom
```

**Capture a quick voice memo** — timestamped audio + transcript in one shot.

```sh
hark -a memo.m4a -t memo.txt
```

**Transcribe a file to subtitles or JSON** — any format in, `.srt`/`.json` out.

```sh
hark -i lecture.m4a -t lecture.srt
```

**Label who said what** — separate your mic from the call (You / Others), plus
per-voice `Speaker N`.

```sh
hark --system --mix --speakers -t meeting.srt
```

More copy-and-adapt wrappers live in [examples/](examples/) — including
`hark-meeting`, which records a call and runs it through fabric-ai for you.

> [!NOTE]
> **Status: pre-1.0 beta.** Core capture, transcoding, and transcription work;
> packaging polish is ongoing. See [PLAN.md](PLAN.md) and [CHANGELOG.md](CHANGELOG.md).

## Why hark

- **One native binary.** Pure Swift + Core Audio. No BlackHole, no virtual
  devices, no background apps — `brew install` and go.
- **Capture anything.** The microphone, **all system audio** (`--system`),
  **specific apps** (`--app`), or **everything except** some apps
  (`--exclude-app`) — and optionally **mix in your mic** (`--mix`) for meetings.
- **Live transcription.** Text streams as you speak, with a choice of engines:
  local `whisper.cpp`, on-device Apple Speech, WhisperKit, or Parakeet.
- **Know who spoke.** `--speakers` labels turns by source (`You`/`Others`) and by
  voice (`Speaker 1..N`) using on-device CoreML — no cloud.
- **Private by default.** Everything runs on-device; no telemetry, no network
  calls unless you download a model.
- **Built for pipelines.** `-a -` streams WAV to stdout, transcripts go to
  stdout, diagnostics to stderr — composes with `ffmpeg`, `sox`, and friends.
- **Unattended-ready.** Auto-recovers from screen lock / sleep / device changes,
  `--keep-awake`, durations, splitting, and a remote-control HTTP agent.

## Contents

- [Requirements](#requirements)
- [Install](#install)
- [Quick start](#quick-start)
- [Usage](#usage)
- [Transcription engines](#transcription-engines)
- [Speaker labels](#speaker-labels)
- [Interactive mode](#interactive-mode)
- [Remote control](#remote-control)
- [Models](#models)
- [Configuration](#configuration)
- [Permissions](#permissions)
- [Pipelines](#pipelines)
- [Recipes](#recipes)
- [Development](#development)
- [Project documents](#project-documents)
- [Legal & responsible use](#legal--responsible-use)
- [License](#license)

## Requirements

- **macOS 14.4 (Sonoma) or later** — required for the Core Audio process-tap
  API. Apple Silicon and Intel.
- The optional **ScreenCaptureKit** backend (`--capture-backend sckit`) needs
  **macOS 15 (Sequoia) or later**; on 14.x hark uses the Core Audio backend
  automatically.
- For the `whisper` engine: a whisper.cpp binary on `PATH`
  (`brew install whisper-cpp`) and a ggml model.
- For the `apple` engine: the Speech Recognition permission (granted on first
  use). No model download.

## Install

### Homebrew (Apple Silicon)

```sh
brew tap PhantomYdn/hark https://github.com/PhantomYdn/hark
brew install hark
```

This installs the prebuilt arm64 binary and the man page, and pulls in
`whisper-cpp` for the default engine. Homebrew downloads aren't quarantined, so
no Gatekeeper steps are needed.

> Some Homebrew setups prompt you to trust a third-party tap — run `brew tap` as
> above (and `brew trust phantomydn/hark` if asked). The fully-qualified name
> `phantomydn/hark/hark` also works.

### Build from source (Intel, or to hack on it)

With the Swift toolchain (Swift 6 / Xcode 16):

```sh
git clone https://github.com/PhantomYdn/hark.git hark && cd hark
make build                      # or: swift build -c release
cp .build/release/hark /usr/local/bin/hark
```

### Direct binary download

The arm64 binary is also attached to each
[GitHub Release](https://github.com/PhantomYdn/hark/releases). It is **signed
(Developer ID) and notarized**, so it passes Gatekeeper on download — no `xattr`
workaround needed. The stable signature also means privacy grants persist across
upgrades instead of resetting on each new binary.

Then set up an on-device transcription model:

```sh
hark models download parakeet:v3 --default   # on-device CoreML; sets engine=parakeet
```

Parakeet runs fully on-device (Apple Silicon) and needs no extra tools. Prefer
whisper.cpp — or on Intel — instead? Use
`brew install whisper-cpp && hark models download base.en --default`.

## Quick start

```sh
hark                                  # live mic -> transcript on stdout (Ctrl+C to stop)
hark -i recording.m4a                 # transcribe a file -> stdout
hark -a rec.m4a                       # record only (no transcript)
hark -a rec.m4a -t notes.txt          # record + transcribe to files
hark -i in.wav -a out.flac            # transcode between formats
```

## Usage

`hark` takes **one input** and writes the **outputs you name**; naming no
output transcribes to stdout.

| | Pick one input | Name the outputs |
|---|---|---|
| **default** | system default microphone | transcript on stdout |
| **flags** | `-d` device · `--system` · `--app` · `--exclude-app` · `--mix` · `-i` file/stdin | `-a` audio · `-t` transcript (`-` = stdout) |

```sh
hark --app com.apple.Music -a song.m4a       # capture one app
hark --system --exclude-app com.zoom.xos -t -  # everything but Zoom → stdout
hark -i talk.wav -a talk.mp3 -t talk.srt      # transcode + subtitle a file
hark --duration 30 --split silence=2 -a memo.wav  # split on 2s of silence
```

<details>
<summary><b>Full flag, environment & config reference →</b></summary>

The complete input/output tables, capture/timing flags, interruption recovery,
working-directory handling, and the configuration matrix live in
**[docs/reference.md](docs/reference.md)**. Run `hark --help` for the canonical
list and `hark help <subcommand>` for a subcommand's options.

</details>

## Transcription engines

Select with `-e/--engine` (default `whisper`). All engines accept any readable
input; it is normalized to 16 kHz mono internally.

| Engine | Runtime | Languages | Auto-detect | Translate→EN | Notes |
|--------|---------|-----------|-------------|--------------|-------|
| `whisper` (default) | whisper.cpp binary | ~99 | yes (`--language auto`) | yes | needs a non-`.en` model for non-English |
| `apple` | native `Speech.framework` (no deps) | ~50 locales | no (uses the locale) | no | on-device; plain-text only in batch |
| `whisperkit` | WhisperKit CoreML | ~99 | yes | yes | Apple-Silicon-first; models auto-download |
| `parakeet` | FluidAudio CoreML | 25 European (v3) / English (v2) | yes | no | Apple-Silicon-first; `--model v2`/`v3` |
| `cloud` | post-MVP | — | — | — | — |

- `whisper` is found on `PATH` (`whisper-cli`/`whisper-cpp`, and `whisper-server`
  for resident live transcription) or via `$HARK_WHISPER_BIN` /
  `$HARK_WHISPER_SERVER_BIN`. Disable the server with `$HARK_WHISPER_SERVER=0`.
- `apple` needs the Speech Recognition permission and runs entirely on-device.
  Batch transcription writes plain text; for `.srt`/`.json` from a file, use
  another engine. Live `.srt`/`.json` works with any engine.
- `whisperkit` and `parakeet` are CoreML engines (Apple Silicon only). They
  download their models from Hugging Face on first use, then run fully on-device.
  `parakeet` auto-detects its language (`--language` is ignored) and cannot
  translate.

## Speaker labels

`--speakers` (alias `--diarize`) labels each transcript segment with who spoke,
two ways that combine:

- **Source attribution** — in a meeting capture (`--mix` with `--system`/`--app`),
  your microphone is labeled **`You`** and the call audio **`Others`**.
  Deterministic, no model, works on Intel and headless.
- **Acoustic diarization** — distinct voices within a stream are separated into
  **`Speaker 1`, `Speaker 2`, …** using on-device CoreML models (Apple Silicon).

By default a meeting is labeled **`You` + `Speaker 1..N`**. Use
`--speaker-mode source` for the cheap `You`/`Others` split with no diarization.

```sh
# Live meeting: You + Speaker 1/2/… in real time
hark --system --mix --speakers -t meeting.srt

# Accurate offline pass (transcript written when you stop)
hark --system --mix --speakers --diarize-engine offline -t meeting.srt

# Diarize a recording (everyone becomes Speaker N — "You" is live-only)
hark -i meeting.wav --speakers -t out.json
```

The label appears per format: txt `Speaker 1: …`, srt `[Speaker 1] …`, json a
`"speaker"` field. **Acoustic diarization is Apple-Silicon-only** (on Intel,
diarized modes fall back to `You`/`Others`); the first use downloads a CoreML
model — pre-fetch with `hark models download fluidaudio:diarizer`. See the
[full flag table](docs/reference.md#speaker-labels) for `--speaker-mode`,
`--diarize-engine`, `--max-speakers`, `--speaker-threshold`, and
`--speaker-labels`.

## Interactive mode

`--interactive` runs a live capture in a minimal terminal UI: the transcript
streams to the terminal, a startup status line shows the resolved
engine/source/format, and single keys control the session:

- **space** — pause / resume (the paused interval is **not** recorded)
- **m** — mute / unmute the microphone (shown only when a mic is in the capture;
  only the mic is silenced — system audio keeps recording and the timeline is
  preserved)
- **y** — yank: copy the transcript captured so far to the clipboard (local only)
- **Enter** — finish and finalise the file (Ctrl-C also stops)

```sh
hark --interactive --system --mix -a meeting.m4a            # watch the transcript live
hark --interactive --system --mix -a meeting.m4a -t meeting.txt  # …and persist it
```

Interactive mode needs a real terminal (stdin + stdout are a TTY) and can't be
combined with `-i` or stdout output (`-a -`/`-t -`).

## Remote control

**Let your browser drive recording.** `hark --remote-control [host:]port` runs
Hark as a control **agent** (no capture on launch), exposing a small HTTP/JSON
API so a script — or a browser userscript — can start/pause/resume/stop/query a
recording. The headline use: a **Tampermonkey userscript for hands-free notes on
your Google Meet calls** — it `POST`s `/start` when you join a call (filename
derived from the meeting title) and `/stop` when you leave, with no clicks
(record with everyone's consent — see
[Legal & responsible use](#legal--responsible-use)). The ready-to-use script and
full API reference are in [docs/remote-control.md](docs/remote-control.md).

```sh
hark --remote-control 8473 -C ~/Recordings   # loopback agent, recordings under ~/Recordings
hark --remote-control                          # bind 127.0.0.1 on the configured port (default 8473)

curl -s -X POST http://127.0.0.1:8473/start \
  -d '{"system":true,"mix":true,"audio":"call.m4a","transcript":"call.srt"}'
curl -s http://127.0.0.1:8473/status
curl -s -X POST http://127.0.0.1:8473/mute     # silence only the mic (mix capture)
curl -s -X POST http://127.0.0.1:8473/unmute
curl -s -X POST http://127.0.0.1:8473/stop
```

Bound to loopback by default; a non-loopback bind requires `$HARK_REMOTE_TOKEN`.
The address is optional: omit it to bind loopback on the `remote-control-port`
config key (default `8473`; also `$HARK_REMOTE_CONTROL_PORT`).

**Run it as a background service.** If you installed via Homebrew, `brew services
start hark` runs the agent as a per-user LaunchAgent (auto-starts at login) so the
userscript can reach it without keeping a terminal open. It binds the
`remote-control-port` config key and writes recordings under the `directory`
config key — set both with `hark config`. See
[docs/remote-control.md](docs/remote-control.md#running-as-a-service-brew-services).

## Models

Whisper ggml models live in `~/.hark/models` as `ggml-<name>.bin`; whisperkit
and parakeet CoreML models are cached by their SDKs (and shown by `models list`).

```sh
hark models list                    # installed models, all engines; default marked *
hark models list --available        # downloadable catalog, with an ENGINE column

# Download names are engine-tagged: bare = whisper ggml, prefix = CoreML engine
hark models download large-v3-turbo            # whisper ggml
hark models download whisperkit:large-v3-v20240930_626MB
hark models download parakeet:v3               # or parakeet:v2 (English-only)
hark models download fluidaudio:diarizer       # speaker diarization (--speakers)
```

The first whisper model you download becomes the default. `--default` makes any
model the default; for whisperkit/parakeet it also sets the engine.

## Configuration

Most defaults resolve **flag › environment (`$HARK_*`) › config
(`~/.hark/config.json`) › built-in**. Every setting has a flag, a `$HARK_*` env
var, and a config key.

```sh
hark config set engine apple
hark config set speaker-mode source
hark config show                        # every setting, its value, and its SOURCE
hark config path                        # where the JSON file lives
```

The config file is plain JSON and hand-editable. The complete settings matrix
(every key, flag, env var, and default) is in
**[docs/reference.md](docs/reference.md#configuration--environment)**.

## Permissions

macOS gates microphone, system-audio, and speech recognition behind TCC. The
release binary is signed and notarized, so grants persist across upgrades; for a
shell-launched CLI, macOS may still attribute these prompts to the **terminal**
that launches `hark`.

System/app capture has two backends, selected by `--capture-backend` (default
`auto`, or `$HARK_CAPTURE`):

- **`coreaudio`** — Core Audio process tap. Needs the narrower **System Audio
  Recording** permission and works headless (cron/launchd/SSH), macOS 14.4+.
- **`sckit`** — ScreenCaptureKit (`SCStream`, macOS 15+). Needs the broader
  **Screen Recording** permission and a graphical login session.

See [docs/permissions.md](docs/permissions.md) for the exact System Settings
paths, the system-audio "+" flow, and notes for tmux/screen.

## Pipelines

```sh
hark -a - --duration 10 | ffmpeg -i - out.mp3   # stream live WAV into ffmpeg
hark -a - | hark -i -                            # record on one machine, transcribe on another
hark -t notes.txt --system & tail -f notes.txt   # follow a live transcript
```

`hark` follows POSIX conventions: audio/transcripts on stdout, diagnostics on
stderr (`-v` for detail), and a non-zero engine exit code propagates through the
pipeline. SIGINT/SIGTERM finalize the current file so it stays playable. See the
[exit codes](docs/reference.md#exit-codes) table for the `sysexits(3)` mapping.

## Recipes

Copy-and-adapt `zsh` wrappers for common workflows live in
[`examples/`](examples/) — `hark-meeting` (interactive system+mic capture →
audio + transcript, then a fabric-ai summary), `hark-note` (quick voice memo),
and `hark-dictate` (speak → clipboard). See [examples/README.md](examples/README.md).

## Development

```sh
make build      # swift build
make test       # swift test (with a CLT Testing.framework path workaround)
make release    # swift build -c release
make demo       # render the README demo GIF (needs: brew install vhs ffmpeg)
```

Modular SwiftPM targets: `DeviceManager`, `TapEngine`, `Encoders`, `CLI`. Many
integration tests are gated on optional tools (whisper.cpp, a model, `say`,
Speech authorization) and skip cleanly when absent. Contributions welcome — see
[CONTRIBUTING.md](.github/CONTRIBUTING.md).

## Project documents

- [PRD.md](PRD.md) — product requirements
- [PLAN.md](PLAN.md) — phased implementation plan and status
- [docs/reference.md](docs/reference.md) — full flag, environment & config reference
- [docs/permissions.md](docs/permissions.md) — TCC permission setup
- [docs/remote-control.md](docs/remote-control.md) — remote-control HTTP API
- [docs/legal.md](docs/legal.md) — export classification & responsible use
- [CHANGELOG.md](CHANGELOG.md) — release notes

## Legal & responsible use

hark records audio, so **whether a given recording is lawful is up to you.**
Recording-consent rules vary by jurisdiction — some places require **all-party
consent**, and recorded voice can be personal data under the GDPR. Make sure you
have consent and a legal basis before recording calls, meetings, or other people.

hark is built to make that easy to do right: capture is **consent-gated by macOS
permissions** (it can't record covertly), everything runs **on-device**, and
there's **no telemetry and no network access by default**. On the export side,
hark contains no proprietary cryptography — only ancillary OS-provided TLS for
opt-in downloads — and is self-classified **EAR99** as publicly-available open
source. Details and the full classification note are in
**[docs/legal.md](docs/legal.md)** (informational, not legal advice).

## License

[MIT](LICENSE) © Ilya Naryzhnyy. Bundled third-party components are listed in
[NOTICES](NOTICES); MP3 output uses libmp3lame (LGPL-2.1).
