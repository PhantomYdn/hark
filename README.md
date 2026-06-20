# hark

Capture audio and produce transcripts on macOS, from a single native Swift
binary. `hark` is the verb — "listen and transcribe": it takes one input
(your microphone by default, or system/per-app audio, or an existing file) and
writes the outputs you name (an audio file, a transcript, or a stream on
stdout). It is built for Unix-style pipelines and unattended use.

> Status: pre-1.0 beta. Core capture, transcoding, and transcription work;
> packaging (signing, Homebrew) is in progress. See [PLAN.md](PLAN.md).

## Features

- **Capture** the microphone, **all system audio** (`--system`), **specific
  apps** (`--app`), or **everything except** some apps (`--exclude-app`) via
  Core Audio process taps — and optionally **mix in the mic** (`--mix`).
- **Transcribe** with a selectable engine: `whisper` (local whisper.cpp,
  multilingual + translate) or `apple` (native on-device Speech.framework, no
  dependencies). Near-runtime live transcription segments the stream and emits
  text as you speak.
- **Formats**: write `.wav`, `.m4a`, `.flac`, `.mp3`, `.opus` audio and `.txt`, `.srt`, `.json`
  transcripts; **transcode** between formats (`hark -i in -a out`); **split**
  into chunks by duration or silence.
- **Streaming**: `-a -` writes a WAV (or raw PCM) stream to stdout; transcripts
  go to stdout by default — both compose with `ffmpeg`, `sox`, and friends.
- **Config & environment**: persistent defaults in `~/.hark/config.json` plus
  `$HARK_*` overrides.

## Requirements

- macOS 14.4 or later (Core Audio process-tap API). Apple Silicon and Intel.
- For the `whisper` engine: a whisper.cpp binary on `PATH`
  (`brew install whisper-cpp`) and a ggml model.
- For the `apple` engine: the Speech Recognition permission (granted on first
  use). No model download.

## Install

### Homebrew (Apple Silicon)

```sh
brew tap PhantomYdn/hark https://github.com/PhantomYdn/hark
brew install phantomydn/hark/hark
```

This installs the prebuilt arm64 binary and the man page, and pulls in
`whisper-cpp` for the default engine. Homebrew downloads aren't quarantined, so
no Gatekeeper steps are needed.

> The formula is installed by its **tap-qualified name**
> (`phantomydn/hark/hark`) because the bare name `hark` is already taken by an
> unrelated Homebrew cask (the "Hark Player" app). Some Homebrew setups also
> prompt you to trust a third-party tap — run `brew tap` as above (and
> `brew trust phantomydn/hark` if asked).

### Build from source (Intel, or to hack on it)

With the Swift toolchain (Swift 6 / Xcode 16):

```sh
git clone https://github.com/PhantomYdn/hark.git hark && cd hark
make build                      # or: swift build -c release
cp .build/release/hark /usr/local/bin/hark
```

### Direct binary download

The arm64 binary is also attached to each
[GitHub Release](https://github.com/PhantomYdn/hark/releases). This beta build
is **not yet notarized**, so a direct download must be de-quarantined before it
runs:

```sh
xattr -dr com.apple.quarantine ./hark
```

Because the binary is unsigned, macOS attributes its microphone / system-audio /
speech permissions to the **terminal** that runs it — see
[Permissions](#permissions). (Signed, notarized binaries are planned for a
follow-up release; the Homebrew path above already works without these steps.)

Install a transcription engine and model:

```sh
brew install whisper-cpp                 # the default 'whisper' engine
hark models download base.en --default  # fetch a model and make it the default
```

## Quick start

```sh
hark                                  # live mic -> transcript on stdout (Ctrl+C to stop)
hark -i recording.m4a                 # transcribe a file -> stdout
hark -a rec.m4a                       # record only (no transcript)
hark -a rec.m4a -t notes.txt          # record + transcribe to files
hark --system --mix -a mtg.m4a -t mtg.srt   # capture a meeting, keep audio + subtitles
hark -i in.wav -a out.flac            # transcode between formats
hark --engine apple                   # transcribe live with on-device Apple speech
```

## Usage

`hark` takes **one input** and writes the **outputs you name**; naming no
output transcribes to stdout.

**Input — pick one** (default: system default microphone):

| Flag | Source |
|------|--------|
| *(none)* | live capture from the default input device |
| `-d, --device UID` | live capture from a specific input device (`hark devices`) |
| `--system` | all system audio via a process tap |
| `--app ID` | a specific app (bundle ID or PID; repeatable) |
| `--exclude-app ID` | all system audio except the listed app(s) (repeatable) |
| `--mix` | additionally mix the microphone into a system/app capture |
| `--capture-backend auto\|sckit\|coreaudio` | system/app capture backend (default `auto`; or `$HARK_CAPTURE`) |
| `-i, --input PATH\|-` | read an existing file, or `-` for stdin (no live capture) |

**Output — name what to keep; `-` means stdout** (at most one output may be `-`):

| Flag | Output |
|------|--------|
| `-a, --audio PATH\|-` | audio file (`.wav`/`.m4a`/`.flac`/`.mp3`/`.opus`), or `-` for a WAV stream |
| `-t, --transcript PATH\|-` | transcript (`.txt`/`.srt`/`.json`), or `-` for text |
| *(none)* | transcribe to stdout (the default verb) |
| `--raw` | with `-a -`, stream headerless PCM instead of WAV |

**Capture / timing**: `-r/--rate`, `-b/--bits` (16/24/32), `-c/--channels`
(1/2), `--duration SEC`, `--split duration=SEC` / `--split silence=SEC`
(with `--silence-threshold dBFS`).

**Working directory**: `-C, --directory PATH` resolves **relative** artifact
paths (`-i`, `-a`, `-t`, and `--split` outputs) against `PATH` (absolute paths
and `-` are unaffected). Defaults to the current directory; also
`$HARK_DIRECTORY` or config `directory`. The directory must already exist.

**Transcription**: `-e/--engine`, `--model` (engine-specific — see
[Models](#models)), `--language` (`auto`, or a code; support varies by engine),
`--translate` / `--no-translate`, `--transcript-format txt|srt|json`.

**Quiet captures**: live transcription segments speech with an on-device VAD
(Apple Silicon). If phrases are dropped because the input is quiet (low mic/
system gain), lower the gate with `--vad-threshold` (0–1, default `0.5`; lower =
catches quieter speech). Segments are also peak-normalized before the engine to
improve recognition of low-level audio (the recording is unaffected; disable
with `HARK_GAIN=off`).

Run `hark --help` for the full list, and `hark help <subcommand>` for a
subcommand's options.

### Speaker labels

`--speakers` (alias `--diarize`) labels each transcript segment with who spoke,
two ways that combine:

- **Source attribution** — in a meeting capture (`--mix` with `--system`/`--app`),
  your microphone is labeled **`You`** and the call audio **`Others`**.
  Deterministic, no model, works on Intel and headless.
- **Acoustic diarization** — distinct voices within a stream are separated into
  **`Speaker 1`, `Speaker 2`, …** using on-device CoreML models (Apple Silicon).

By default a meeting is labeled **`You` + `Speaker 1..N`** (your mic, plus each
remote participant). Use `--speaker-mode source` for the cheap `You`/`Others`
split with no diarization.

| Flag | Meaning |
|------|---------|
| `--speakers`, `--diarize` | enable speaker labels (off by default) |
| `--speaker-mode auto\|source\|acoustic` | `auto` (default): source + diarization; `source`: You/Others only; `acoustic`: diarize one stream |
| `--diarize-engine auto\|streaming\|offline` | `auto` (default): streaming live / offline batch; `streaming`: real-time; `offline`: accurate, diarized at end of capture |
| `--max-speakers N` | cap the number of distinct speakers |
| `--speaker-threshold 0..1` | clustering sensitivity (default ~0.7; lower splits more, higher merges) |
| `--speaker-labels "You,Others"` | rename the source labels |

```sh
# Live meeting: You + Speaker 1/2/… in real time
hark --system --mix --speakers -t meeting.srt

# Same, but an accurate offline pass (transcript written when you stop)
hark --system --mix --speakers --diarize-engine offline -t meeting.srt

# Cheap deterministic You/Others (no diarization model)
hark --system --mix --speakers --speaker-mode source -t -

# Diarize a recording (everyone becomes Speaker N — "You" is live-only)
hark -i meeting.wav --speakers -t out.json

# Tune sensitivity if speakers merge or over-split
hark -i meeting.wav --speakers --speaker-threshold 0.55 --max-speakers 6 -t out.srt
```

The label appears per format: txt `Speaker 1: …`, srt `[Speaker 1] …`, json a
`"speaker"` field. **Acoustic diarization is Apple-Silicon-only** (on Intel,
diarized modes fall back to `You`/`Others`); the first use downloads a CoreML
model — pre-fetch with `hark models download fluidaudio:diarizer`. Live
segmentation also uses an on-device VAD model (Apple Silicon); disable it with
`HARK_VAD=0`.

### Interactive mode

`--interactive` runs a live capture in a minimal terminal UI: the transcript
streams to the terminal, a startup status line shows the resolved
engine/source/format, and single keys control the session:

- **space** — pause / resume (the paused interval is **not** recorded, so the
  output is shorter than wall-clock)
- **Enter** — finish and finalise the file (Ctrl-C also stops)

```sh
# Interactive meeting capture: watch the transcript, pause during a break
hark --interactive --system --mix -a meeting.m4a

# Same, but also persist the transcript — captions show on screen *and* go to
# the file at the same time
hark --interactive --system --mix -a meeting.m4a -t meeting.txt
```

The live transcript is always shown on screen; naming `-t FILE`/`-a FILE`
concurrently saves the transcript/audio. Interactive mode needs a real terminal
(stdin + stdout are a TTY) and can't be combined with `-i` or stdout output
(`-a -`/`-t -`).

### Remote control

`hark --remote-control [host:]port` runs Hark as a control **agent** instead
of capturing on launch, serving a small HTTP/JSON API so scripts (or a browser
userscript) can start/pause/resume/stop/query a recording. One recording at a
time; the API is control + status only (artifacts are written to files, never
returned over HTTP).

```sh
# Loopback agent (conventional port 8473), recordings under ~/Recordings
hark --remote-control 8473 -C ~/Recordings

curl -s -X POST http://127.0.0.1:8473/start \
  -d '{"system":true,"mix":true,"audio":"call.m4a","transcript":"call.srt"}'
curl -s http://127.0.0.1:8473/status
curl -s -X POST http://127.0.0.1:8473/stop
```

Bound to loopback by default; a non-loopback bind requires `$HARK_REMOTE_TOKEN`.
Launch-time capture flags become per-session defaults. Full API reference and a
Tampermonkey Google-Meet auto-record userscript:
[docs/remote-control.md](docs/remote-control.md).

### Subcommands

```sh
hark devices [--list-inputs|--list-outputs] [--json]   # enumerate audio devices
hark apps [--json]                                     # list capturable applications
hark info <file> [--json]                              # duration/format/metadata
hark models list [--available] [--json]                # local or downloadable models
hark models download <name> [--default] [--force]      # fetch a ggml model
hark config show|set <key> <value>|unset <key>|path    # persisted defaults
```

## Transcription engines

Select with `-e/--engine` (default `whisper`). All engines accept any readable
input; it is normalized to 16 kHz mono internally.

| Engine | Runtime | Languages | Auto-detect | Translate→EN | Notes |
|--------|---------|-----------|-------------|--------------|-------|
| `whisper` (default) | whisper.cpp binary (`whisper-cli`/`whisper-server`) | ~99 | yes (`--language auto`) | yes | needs a non-`.en` model for non-English |
| `apple` | native `Speech.framework` (no deps) | ~50 locales | no (uses the locale) | no | on-device; plain-text only in batch |
| `whisperkit` | WhisperKit CoreML | ~99 | yes | yes | Apple-Silicon-first; models auto-download |
| `parakeet` | FluidAudio CoreML | 25 European (v3) / English (v2) | yes | no | Apple-Silicon-first; `--model v2`/`v3` |
| `cloud` | post-MVP | — | — | — | — |

- `whisper` is found on `PATH` (`whisper-cli`/`whisper-cpp`, and
  `whisper-server` for resident live transcription) or via `$HARK_WHISPER_BIN`
  / `$HARK_WHISPER_SERVER_BIN`. Disable the server with `$HARK_WHISPER_SERVER=0`.
- `apple` needs the Speech Recognition permission and runs entirely on-device
  (no network). Batch transcription writes plain text; for `.srt`/`.json` from a
  file, use another engine. Live `.srt`/`.json` works with any engine.
- `whisperkit` and `parakeet` are CoreML engines (Apple Silicon only). They
  download their models from Hugging Face on first use, then run fully
  on-device. `parakeet` auto-detects its language (`--language` is ignored) and
  cannot translate.

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
hark models download fluidaudio:vad            # live-segmentation VAD
```

The first whisper model you download becomes the default. `--default` makes any
model the default; for whisperkit/parakeet it also sets the engine (e.g.
`hark models download parakeet:v3 --default` ⇒ `engine=parakeet`). CoreML
engines also auto-download on first use, so an explicit download is optional.

## Configuration & environment

Most defaults resolve **flag › environment (`$HARK_*`) › config
(`~/.hark/config.json`) › built-in**:

Every setting has a flag, a `$HARK_*` env var, and a config key. The env var
is `HARK_<KEY>` (uppercased, `-`→`_`) except `model` (`$HARK_WHISPER_MODEL`)
and `capture-backend` (`$HARK_CAPTURE`).

| Config key | Flag | Default |
|------------|------|---------|
| `engine` | `-e/--engine` | `whisper` |
| `model` | `--model` | (required for whisper) |
| `language` | `--language` | `auto` |
| `translate` | `--translate`/`--no-translate` | `false` |
| `device` | `-d/--device` | system default |
| `directory` | `-C/--directory` | current directory |
| `capture-backend` | `--capture-backend` | `auto` |
| `rate` / `bits` / `channels` | `-r` / `-b` / `-c` | live `44100`/`16`; convert = source |
| `silence-threshold` | `--silence-threshold` | `-50` |
| `vad` | `--vad`/`--no-vad` | `true` |
| `vad-threshold` | `--vad-threshold` | `0.5` |
| `gain` | `--gain`/`--no-gain` | `true` |
| `speakers` | `--speakers`/`--no-speakers` | `false` |
| `speaker-mode` | `--speaker-mode` | `auto` |
| `speaker-labels` | `--speaker-labels` | `You,Others` |
| `diarize-engine` | `--diarize-engine` | `auto` |
| `max-speakers` | `--max-speakers` | (unset) |
| `speaker-threshold` | `--speaker-threshold` | (engine default) |

```sh
hark config set engine apple
hark config set silence-threshold -40   # values starting with '-' are taken verbatim
hark config set speaker-mode source
hark config show                        # every setting, its value, and its SOURCE
```

`hark config show` lists **all** settings with their effective value and a
`SOURCE` column — `default` (built-in), `config` (set in the file), or `env`
(an `$HARK_*` override, which outranks config). `--json` emits
`{ "<key>": { "value": …, "source": … } }`.

The config file is plain JSON and hand-editable; `hark config path` prints its
location.

## Permissions

macOS gates microphone, system-audio, and speech recognition behind TCC. For an
unsigned build these prompts are attributed to the **terminal** that launches
`hark`. See [docs/permissions.md](docs/permissions.md) for the exact
System Settings paths, the system-audio "+" flow, and notes for tmux/screen.

System/app capture has two backends, selected by `--capture-backend` (default
`auto`, or `$HARK_CAPTURE`):

- **`coreaudio`** — Core Audio process tap. Needs the narrower **System Audio
  Recording** permission and works headless (cron/launchd/SSH), macOS 14.4+.
- **`sckit`** — ScreenCaptureKit (`SCStream`, macOS 15+). Needs the broader
  **Screen Recording** permission and a graphical login session (not headless).
  It delivers audio continuously, so `--mix` keeps recording the mic while
  system audio is idle.

`auto` prefers `sckit` when it can run (macOS 15+, Screen Recording already
granted, a display present) and otherwise falls back to `coreaudio`.

## Pipelines

```sh
# Stream live WAV into ffmpeg
hark -a - --duration 10 | ffmpeg -i - out.mp3

# Record on one machine, transcribe on another
hark -a - | hark -i -

# Follow a live transcript as it is written
hark -t notes.txt --system & tail -f notes.txt
```

`hark` follows POSIX conventions: audio/transcripts on stdout, diagnostics on
stderr (`-v` for detail), and a non-zero engine exit code propagates through the
pipeline. SIGINT/SIGTERM finalize the current file so it stays playable.

## Recipes

Copy-and-adapt `zsh` wrappers for common workflows live in
[`examples/`](examples/) — `hark-meeting` (interactive system+mic capture →
audio + transcript, then a fabric-ai summary), `hark-note` (quick voice memo),
and `hark-dictate` (speak → clipboard). See [examples/README.md](examples/README.md).

## Exit codes

Following BSD `sysexits(3)` where applicable:

| Code | Meaning |
|------|---------|
| 0 | success |
| 1 | generic failure |
| 64 | usage / invalid arguments |
| 66 | input file or device not found |
| 69 | feature/engine unavailable or not implemented |
| 70 | internal error |
| 74 | I/O error |
| 77 | permission denied (microphone / system audio / speech) |

## Development

```sh
make build      # swift build
make test       # swift test (with a CLT Testing.framework path workaround)
make release    # swift build -c release
```

Modular SwiftPM targets: `DeviceManager`, `TapEngine`, `Encoders`, `CLI`. Many
integration tests are gated on optional tools (whisper.cpp, a model, `say`,
Speech authorization) and skip cleanly when absent.

## Project documents

- [PRD.md](PRD.md) — product requirements
- [PLAN.md](PLAN.md) — phased implementation plan and status
- [docs/permissions.md](docs/permissions.md) — TCC permission setup
