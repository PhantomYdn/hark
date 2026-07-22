# Remote control (`hark --remote-control`)

`hark --remote-control [host:]port` runs Hark as a long-lived **control
agent** instead of capturing on launch. It serves a small HTTP/1.1 + JSON API
over TCP so other programs — shell scripts, automations, or a browser userscript
— can start, pause, resume, stop, and query **one** recording at a time.

The API is **control + status only**: it never returns transcript or audio
content. Recordings are written to files under the agent's working directory and
retrieved from the filesystem.

## Starting the agent

```sh
# Loopback (conventional port 8473); writes recordings under ~/Recordings
hark --remote-control 8473 -C ~/Recordings

# Inherit any capture/engine defaults — they apply to every session unless a
# POST /start body overrides them:
hark --remote-control 8473 -C ~/Recordings --system --mix --engine whisper --model base.en
```

The value is **optional**. Omit it to bind **loopback** (`127.0.0.1`) on the
`remote-control-port` config key (default `8473`; also `$HARK_REMOTE_CONTROL_PORT`):

```sh
hark config set remote-control-port 8473   # optional; 8473 is the default
hark --remote-control                        # binds 127.0.0.1:8473
```

Or pass `[host:]port` explicitly: a bare port or empty host binds loopback;
`0.0.0.0:8473` or a specific IPv4 binds elsewhere. An explicit value always wins
over the config key. The agent prints its address on start and runs until Ctrl-C
(SIGINT/SIGTERM), which stops any active recording first.

### Security

- **Loopback by default** — the listener accepts only local connections and
  makes no outbound calls (consistent with Hark's "no network by default").
- **Non-loopback requires a token.** Binding to `0.0.0.0` or a LAN IP is refused
  unless `$HARK_REMOTE_TOKEN` is set; when a token is configured, every request
  must send `Authorization: Bearer <token>` (otherwise `401`).
- No new TCC permission is required — the agent uses the same microphone /
  system-audio permissions as a normal capture (see
  [permissions.md](permissions.md)).

```sh
HARK_REMOTE_TOKEN=$(openssl rand -hex 16) hark --remote-control 0.0.0.0:8473
```

## Running as a service (`brew services`)

If you installed hark via Homebrew, you can keep the agent always-on so the
userscript can reach it without an open terminal:

```sh
brew services start hark      # start now + at every login
brew services stop hark       # stop (sends SIGTERM; finalises any recording)
brew services restart hark    # after changing config
```

This runs the agent as a **per-user LaunchAgent** in your login session. It binds
loopback on the `remote-control-port` config key and writes recordings under the
`directory` config key — configure both first (**the directory must be an
absolute path**: a launchd agent's working directory is not your shell's, so
relative outputs would land somewhere surprising):

```sh
hark config set remote-control-port 8473
hark config set directory ~/Recordings
hark config set engine whisper      # + model, etc. for transcripts
```

Logs go to `$(brew --prefix)/var/log/hark-remote.log`.

**Permissions.** Under launchd there is no terminal in the chain, so TCC
attributes **directly to the hark binary**: the mic prompts on first use
(approve it once), but **system/app audio needs a one-time manual grant** to
`/opt/homebrew/opt/hark/bin/hark` in System Settings — see
[permissions.md](permissions.md#background-service-brew-services--launchd),
including the re-grant-after-upgrade caveat. A capture missing the grant writes
a header-only file and logs a "captured no audio" warning.

Notes:

- **macOS 26: the first start needs a nudge.** launchd registers a
  newly-bootstrapped agent but does not spawn it mid-session (`RunAtLoad` and
  `KeepAlive` only take effect from the next login). After the first
  `brew services start hark`, run once:
  `launchctl kickstart gui/$(id -u)/homebrew.mxcl.hark` — or just log out and
  back in. Subsequent logins start it automatically.
- **It does not survive logout** (a per-user agent). Headless / survives-logout /
  scheduled operation is a future system-LaunchDaemon feature.
- **Auto-restart on crash.** The service sets launchd `KeepAlive`: a crashed
  agent is relaunched (throttled by launchd to ~10s); a clean
  `brew services stop` stays stopped. Failures remain visible in the log.
- **No keep-awake.** The service runs with `--no-keep-awake`, so it never holds a
  power assertion (an idle agent doesn't keep the Mac awake regardless). The Mac
  can therefore idle-sleep during an active service recording and cut it short;
  if you want a service recording to prevent that, change `--no-keep-awake` to
  `--keep-awake` in the plist's program arguments.

## Endpoints

| Method & path | Purpose |
|---------------|---------|
| `GET /status` | Agent + current/last session state |
| `POST /start` | Begin a recording (JSON body, all fields optional) |
| `POST /pause` | Pause the active recording (the paused interval is not recorded) |
| `POST /resume` | Resume a paused recording |
| `POST /mute` | Mute the microphone (only the mic is silenced; the timeline is preserved) |
| `POST /unmute` | Unmute the microphone |
| `POST /stop` | Stop and finalise the active recording |

A second `POST /start` while a recording is active is rejected with `409`. Only
one session runs at a time.

`/mute` and `/unmute` are **orthogonal to `state`** (they don't pause capture):
they silence only the microphone, so any system/call audio keeps recording and
the timeline is preserved — distinct from `/pause`, which omits the interval.
They require a microphone in the capture (mic-only or `--mix`); on a system/app
capture with no mic they return `422`. They are idempotent. The transcript yank
(`y`) stays interactive-only — the API never serves transcript content.

### `GET /status`

```sh
curl -s http://127.0.0.1:8473/status
```

```json
{
  "agent": { "version": "0.1.0", "address": "127.0.0.1:8473" },
  "session": {
    "id": "28D1DBD7-…",
    "state": "recording",
    "muted": false,
    "elapsed": 12.4,
    "audio": "meeting.m4a",
    "transcript": "meeting.srt",
    "error": null
  }
}
```

`session` is omitted before the first recording. `state` is one of `recording`,
`paused`, `stopped`, `failed`. `muted` reflects the microphone mute toggle (see
`/mute`).

### `POST /start`

The JSON body mirrors the CLI flags; any field overrides the agent's launch-time
default. At least one of `audio`/`transcript` must be a file path (stdout `-` is
not supported).

```sh
curl -s -X POST http://127.0.0.1:8473/start \
  -d '{"system": true, "mix": true, "audio": "meeting.m4a", "transcript": "meeting.srt", "speakers": true}'
```

```json
{ "id": "28D1DBD7-…", "state": "recording", "muted": false, "audio": "meeting.m4a", "transcript": "meeting.srt" }
```

Relative paths resolve under the agent's working directory (`-C` at launch).

| Field | Type | Maps to |
|-------|------|---------|
| `audio` | string | `-a/--audio` (file; `.wav/.m4a/.flac/.mp3/.opus`) |
| `transcript` | string | `-t/--transcript` (file; `.txt/.srt/.json`) |
| `muted` | bool | start with the mic muted (requires a mic in the capture, else `422`) |
| `system` | bool | `--system` |
| `apps` | [string] | `--app` (repeatable) |
| `excludeApps` | [string] | `--exclude-app` (repeatable) |
| `device` | string | `-d/--device` |
| `mix` | bool | `--mix` |
| `captureBackend` | string | `--capture-backend` |
| `engine` | string | `-e/--engine` |
| `model` | string | `--model` |
| `language` | string | `--language` |
| `translate` | bool | `--translate` |
| `duration` | number | `--duration` (seconds; auto-stop) |
| `format` | string | `--format` |
| `transcriptFormat` | string | `--transcript-format` |
| `rate` / `bits` / `channels` | number | `-r` / `-b` / `-c` |
| `split` | string | `--split` (`duration=SEC` / `silence=SEC`) |
| `silenceThreshold` | number | `--silence-threshold` |
| `speakers` | bool | `--speakers` |
| `speakerMode` | string | `--speaker-mode` |
| `speakerLabels` | string | `--speaker-labels` |
| `diarizeEngine` | string | `--diarize-engine` |
| `maxSpeakers` | number | `--max-speakers` |
| `speakerThreshold` | number | `--speaker-threshold` |
| `vad` / `vadThreshold` / `gain` | bool/number/bool | `--vad` / `--vad-threshold` / `--gain` |

### `POST /pause`, `/resume`, `/mute`, `/unmute`, `/stop`

```sh
curl -s -X POST http://127.0.0.1:8473/pause
curl -s -X POST http://127.0.0.1:8473/resume
curl -s -X POST http://127.0.0.1:8473/mute     # silence only the mic; timeline preserved
curl -s -X POST http://127.0.0.1:8473/unmute
curl -s -X POST http://127.0.0.1:8473/stop
```

```json
{ "id": "28D1DBD7-…", "state": "paused", "muted": false }
```

Pausing **excludes** the paused interval from both the audio file and the
transcript (a true gap), so the output is shorter than wall-clock. Muting instead
silences **only the microphone** and keeps the timeline intact (any system/call
audio keeps recording); it is independent of pause and idempotent.

## Status codes

| Code | When |
|------|------|
| `200` | status / pause / resume / mute / unmute / stop |
| `201` | start accepted |
| `400` | invalid JSON or invalid parameters (bad combo, stdout output) |
| `401` | missing/incorrect bearer token |
| `403` | permission denied (microphone / system audio) |
| `404` | control verb with no active recording; input not found |
| `409` | a recording is already active |
| `422` | unusable engine/model; or `mute`/`unmute` on a capture with no microphone |

Errors carry a JSON body `{ "error": "…" }`.

## Reference: Google Meet userscript (Tampermonkey)

A ready-to-install userscript ships at
[`examples/hark-meet.user.js`](../examples/hark-meet.user.js). It records every
Google Meet call automatically — starting a capture when you join and stopping
it when you leave, naming the file from the meeting title and date — and while
recording it **mirrors your Meet mic mute to the recording**: muting yourself in
Meet silences only the mic in the capture (the call audio keeps recording and
the timeline is preserved), and unmuting restores it.

Install [Tampermonkey](https://www.tampermonkey.net/), then open the raw file
([`examples/hark-meet.user.js`](../examples/hark-meet.user.js)) — Tampermonkey
offers a one-click install and self-updates from the same URL. Start the agent
first, e.g. `hark --remote-control 8473 -C ~/Recordings` (or
`brew services start hark`), with a working engine/model if you want transcripts
— see the Configuration section of the README.

Notes:

- The `@connect 127.0.0.1` grant lets Tampermonkey reach the loopback agent; set
  `TOKEN` at the top of the script if the agent uses `$HARK_REMOTE_TOKEN`.
- Adjust the JSON `/start` body to taste — e.g. drop `transcript`/`speakers` to
  record audio only, or set `engine`/`model` if you don't configure them at
  launch.
- Mic-mute mirroring is **one-way** (Meet → hark) and needs a microphone in the
  capture (`mix`, as in the sample, or a mic-only session); on a system/app
  capture with no mic the agent's `/mute` returns `422`, so the script leaves it
  alone. hark never drives Meet's mic.
- The "Leave call" and mic-state (`data-is-muted` / aria-label) selectors are
  heuristics; Google changes Meet's DOM over time, so you may need to update
  them.
