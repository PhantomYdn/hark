# Reference

The complete flag, environment, and configuration reference. For the guided
tour, start with the [README](../README.md); this page is the exhaustive
lookup. Run `hark --help` for the canonical list and `hark help <subcommand>`
for a subcommand's options.

## The model

`hark` takes **one input** and writes the **outputs you name**. Naming no
output transcribes to stdout (the default verb).

## Input — pick one

Default: the system default microphone.

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

## Output — name what to keep

`-` means stdout; at most one output may be `-`.

| Flag | Output |
|------|--------|
| `-a, --audio PATH\|-` | audio file (`.wav`/`.m4a`/`.flac`/`.mp3`/`.opus`), or `-` for a WAV stream |
| `-t, --transcript PATH\|-` | transcript (`.txt`/`.srt`/`.json`), or `-` for text |
| *(none)* | transcribe to stdout (the default verb) |
| `--raw` | with `-a -`, stream headerless PCM instead of WAV |
| `--tracks mixed\|stereo` | how the two capture sources land in the audio output (default `mixed`) |
| `--if-exists ask\|error\|overwrite\|unique` | what to do when an output file already exists (default `ask`) |

### Existing output files

Nothing is ever clobbered silently. Before capture starts — so no permission
prompt, model load, or long recording is wasted — hark checks every file the run
would write and applies `--if-exists` (also `$HARK_IF_EXISTS` / config
`if-exists`):

| Mode | Behavior |
|------|----------|
| `ask` *(default)* | on a terminal, ask: `[o]verwrite  [u]nique  [c]ancel`; without a terminal (cron, pipes) it behaves like `error` |
| `error` | refuse and exit 73, listing the files |
| `overwrite` | replace them (for `--split`, stale `NAME_###` chunks of a previous run are removed first) |
| `unique` | write to the next free numbered name: `rec.m4a` → `rec-1.m4a` |

The whole run is treated as one artifact set: a single decision covers every
output, and `unique` picks one suffix that is free for all of them, so an
audio/transcript pair stays aligned (`rec-1.m4a` + `rec-1.txt`). `-` (stdout)
and `--no-output` are never affected, and appending is the shell's job:
`hark -t - >> notes.txt`.

An output that is also the input (`-i rec.wav -a rec.wav`), or `-a` and `-t`
pointing at the same file, is always a usage error.

### Separate tracks (`--tracks`)

A meeting capture has two genuinely separate signals — your microphone and the
call — and by default `-a` saves their **sum**: left and right are identical and
the separation is gone the moment the file is written.

`--tracks stereo` keeps them apart in the same single file: the **microphone on
the left channel, the system/app audio on the right**. Nothing else changes —
one file, one `--if-exists` decision, one `--split` series — so a later
`ffmpeg -filter_complex channelsplit` (or any editor) gets your voice and
theirs as separate signals:

```sh
hark --system --mix --tracks stereo -a call.wav
ffmpeg -i call.wav -filter_complex "channelsplit=channel_layout=stereo[l][r]" \
       -map "[l]" me.wav -map "[r]" them.wav
hark -i them.wav -t them.txt        # transcribe just the other side
```

Splitting is for when you want two audio files. To find out who said what you do
not need it: `hark -i call.wav --speakers` attributes the recording as it stands,
and a file written with `--tracks stereo` is exactly the two-channel input that
per-channel attribution reads.

`mixed` is the default and is exactly today's output. Worth knowing before you
switch:

- **It needs two sources** — `--mix` together with `--system`/`--app`/
  `--exclude-app`. One source has nothing to separate, so `stereo` is refused
  rather than silently writing the same thing twice.
- **It needs both channels**, so it cannot be combined with `-c/--channels 1`.
  Typing `--tracks stereo` overrides a `channels 1` stored in the config or the
  environment for that run.
- **Each side is folded to mono.** A mono microphone comes back exactly as it
  was, but **genuinely stereo system audio is downmixed** — if the stereo image
  of the call matters more than telling the two sides apart, stay on `mixed`.
- It applies to `-a` only. With no audio output there is nothing to lay out and
  the setting is ignored, so a configured `tracks stereo` never breaks a
  transcript-only run.
- `--duration` trims both channels at the same instant, a paused interval gaps
  both together, and `--split` chunks the interleaved stream.
- **A source that goes quiet leaves silence, not a gap.** If one side delivers
  no audio for more than 2 s (say the mic stops), its channel is filled with
  silence so the other side is kept and stays on the same timeline. hark says
  so on stderr, and reports at the end how much of the channel is silence.

Also `$HARK_TRACKS` / config `tracks`, and the `tracks` field of the
remote-control [`POST /start`](remote-control.md).

## Capture / timing

`-r/--rate`, `-b/--bits` (16/24/32), `-c/--channels` (1/2),
`--tracks mixed|stereo` (see [Separate tracks](#separate-tracks---tracks)),
`--duration SEC`,
`--split duration=SEC` / `--split silence=SEC` (with `--silence-threshold dBFS`),
`--keep-awake` to stop the system sleeping mid-recording (also the display in
`--interactive`; off by default, or `$HARK_KEEP_AWAKE` / config `keep-awake`).

## Interruptions

Capture auto-recovers from a screen lock, display/system sleep, or device
change — the stream is restarted and recording resumes (tunable via
`$HARK_STALL_SECONDS`, `$HARK_RECOVER_TIMEOUT`; disable with `$HARK_NO_RECOVER`).
Pair with `--keep-awake` to avoid idle sleep entirely.

Stopping is also bounded: if the audio stream can't be torn down (most often a
missing or stale **System Audio Recording** grant, which has been seen to block
the Core Audio teardown indefinitely), hark reports it and finalizes the
recording anyway so the audio captured so far stays playable — after
`$HARK_TEARDOWN_TIMEOUT` seconds (default 5; `0` waits indefinitely).

## Working directory

`-C, --directory PATH` resolves **relative** artifact paths (`-i`, `-a`, `-t`,
and `--split` outputs) against `PATH` (absolute paths and `-` are unaffected).
Defaults to the current directory; also `$HARK_DIRECTORY` or config `directory`.
The directory must already exist.

## Transcription

`-e/--engine`, `--model` (engine-specific — see
[Models](../README.md#models)), `--language` (`auto`, or a code; support varies
by engine), `--translate` / `--no-translate`,
`--transcript-format txt|srt|json`.

### Quiet captures

Live transcription covers the whole timeline — an on-device VAD (Apple Silicon)
only picks clean cut points, and speech the VAD doesn't flag (quiet or
overlapping, e.g. remote participants over a room mic) is still transcribed
rather than dropped; only true silence is skipped. `--vad-threshold` (0–1,
default `0.5`) tunes where turns are cut. Segments are also peak-normalized
before the engine to improve recognition of low-level audio (the recording is
unaffected; disable with `HARK_GAIN=off`).

### Segment timing

A live transcript line appears when the speaker pauses for `--segment-pause`
seconds (over 0, up to 2; default `0.7`), or when unbroken speech reaches
`--segment-window` seconds (2–60, default `12`). Lower the window to see text
sooner when someone talks without pausing; raise the pause to keep a slow
speaker's sentences together. Shorter segments give the engine less context.
The two ranges meet at 2 s, so the window is never shorter than the pause. Both
apply to the VAD path and to the amplitude fallback (`--no-vad`).

## Speaker labels

| Flag | Meaning |
|------|---------|
| `--speakers`, `--diarize` | enable speaker labels (off by default) |
| `--speaker-mode auto\|source\|acoustic` | `auto` (default): source + diarization; `source`: You/Others only; `acoustic`: diarize one stream |
| `--diarize-engine auto\|streaming\|offline` | `auto` (default): streaming live / offline batch; `streaming`: real-time; `offline`: accurate, diarized at end of capture |
| `--max-speakers N` | cap the number of distinct speakers |
| `--speaker-threshold 0..1` | clustering sensitivity (default ~0.7; lower splits more, higher merges) |
| `--speaker-labels "You,Others"` | rename the source labels |

`source` labels by where the audio came from, so it needs the two sides to be
separate: two live streams (`--mix` with `--system`/`--app`), or a two-channel
file. On `-i FILE` it reads channel 1 (left) as `You` and channel 2 (right) as
`Others`, transcribes each channel on its own, and merges them into one
time-ordered transcript — so people talking over each other both survive:

```sh
hark -i call.wav --speakers --speaker-mode source -t call.srt
```

Such a file comes from any recorder that keeps the two sides apart: a
conferencing tool that exports the local and the remote side on their own
channel, or a capture that wrote your microphone and the system audio to one
channel each instead of summing them.

A mono file carries no such split; `--speaker-mode source` on one is a usage
error (exit 64) rather than unlabeled output. Use the default
`--speaker-mode auto` to diarize a mixed recording into `Speaker 1/2…`; `auto`
treats a stereo file as one recording too, since most stereo is not one speaker
per channel.

The labels are deterministic and work on any Mac. On Apple Silicon the offline
diarizer finds each channel's speech, and only those spans are transcribed;
elsewhere, or when the diarizer model can't load, each channel is transcribed
whole by the selected `--engine` and hark prints a one-line notice saying so.

## Configuration & environment

Most defaults resolve **flag › environment (`$HARK_*`) › config
(`~/.hark/config.json`) › built-in**.

Every setting has a flag, a `$HARK_*` env var, and a config key. The env var is
`HARK_<KEY>` (uppercased, `-`→`_`) except `model` (`$HARK_WHISPER_MODEL`) and
`capture-backend` (`$HARK_CAPTURE`).

| Config key | Flag | Default |
|------------|------|---------|
| `engine` | `-e/--engine` | `whisper` |
| `model` | `--model` | (required for whisper) |
| `language` | `--language` | `auto` |
| `translate` | `--translate`/`--no-translate` | `false` |
| `device` | `-d/--device` | system default |
| `directory` | `-C/--directory` | current directory |
| `if-exists` | `--if-exists` | `ask` |
| `capture-backend` | `--capture-backend` | `auto` |
| `rate` / `bits` / `channels` | `-r` / `-b` / `-c` | live `44100`/`16`; convert = source |
| `tracks` | `--tracks` | `mixed` |
| `keep-awake` | `--keep-awake`/`--no-keep-awake` | `false` |
| `silence-threshold` | `--silence-threshold` | `-50` |
| `vad` | `--vad`/`--no-vad` | `true` |
| `vad-threshold` | `--vad-threshold` | `0.5` |
| `segment-pause` | `--segment-pause` | `0.7` |
| `segment-window` | `--segment-window` | `12` |
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

## Subcommands

```sh
hark devices [--list-inputs|--list-outputs] [--json]   # enumerate audio devices
hark apps [--json]                                     # list capturable applications
hark info <file> [--json]                              # duration/format/metadata
hark models list [--available] [--json]                # local or downloadable models
hark models download <name> [--default] [--force]      # fetch a ggml model
hark config show|set <key> <value>|unset <key>|path    # persisted defaults
```

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
| 73 | refused to write an output file that already exists (see `--if-exists`) |
| 74 | I/O error |
| 77 | permission denied (microphone / system audio / speech) |
