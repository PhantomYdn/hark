# Hark recipes

Small, copy-and-adapt `zsh` scripts that wrap the `hark` binary for common
workflows. They are **examples, not an installed part of Hark** — read one,
tweak it to taste, and drop it somewhere on your `PATH`.

| Script | What it does |
| --- | --- |
| [`hark-meeting`](hark-meeting) | Record a meeting (system + mic) interactively, then summarize the transcript with fabric-ai. |
| [`hark-note`](hark-note) | Quick spoken voice memo → timestamped audio + transcript. |
| [`hark-dictate`](hark-dictate) | Speak for a few seconds → text on your clipboard. |

## Install

```sh
# Make them executable and put them on your PATH (adjust the target dir):
chmod +x examples/hark-*
mkdir -p ~/.local/bin
cp examples/hark-meeting examples/hark-note examples/hark-dictate ~/.local/bin/
# ensure ~/.local/bin is on PATH (e.g. in ~/.zshrc):
#   export PATH="$HOME/.local/bin:$PATH"
```

Then:

```sh
hark-meeting "Team Sync"
hark-note "idea about the parser"
hark-dictate 15
```

## Prerequisites

- **`hark`** — built from this repo (`make build`) or installed on your `PATH`.
- **A transcription model** — the default `whisper` engine needs a local
  whisper.cpp model (`hark models download base.en`). Override per the usual
  `--engine`/`$HARK_ENGINE` / `hark config`.
- **`fabric-ai`** — only for `hark-meeting`'s summary step
  (<https://github.com/danielmiessler/fabric>), with a configured model.
- **macOS permissions** — microphone for all of them; the **System Audio
  Recording** permission for `hark-meeting` (it uses `--system`). See
  [`docs/permissions.md`](../docs/permissions.md).
- Acoustic speaker diarization (the `Speaker N` labels in `hark-meeting`) needs
  Apple Silicon; on Intel it falls back to deterministic You/Others attribution.

## Customizing

Each script reads a few environment variables (documented in its header
comment) — output directory, fabric pattern/model, capture length. For example:

```sh
HARK_MEETINGS_DIR=~/Meetings FABRIC_PATTERN=extract_recommendations \
  hark-meeting "1:1 with Sam"
```

Because `hark` itself honors `$HARK_*` and `hark config`, you can set the
engine, model, language, and more globally without touching the scripts.
