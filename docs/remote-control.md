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

The value is `[host:]port`. A bare port or empty host binds **loopback**
(`127.0.0.1`); `0.0.0.0:8473` or a specific IPv4 binds elsewhere. The agent
prints its address on start and runs until Ctrl-C (SIGINT/SIGTERM), which stops
any active recording first.

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

## Endpoints

| Method & path | Purpose |
|---------------|---------|
| `GET /status` | Agent + current/last session state |
| `POST /start` | Begin a recording (JSON body, all fields optional) |
| `POST /pause` | Pause the active recording (the paused interval is not recorded) |
| `POST /resume` | Resume a paused recording |
| `POST /stop` | Stop and finalise the active recording |

A second `POST /start` while a recording is active is rejected with `409`. Only
one session runs at a time.

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
    "elapsed": 12.4,
    "audio": "meeting.m4a",
    "transcript": "meeting.srt",
    "error": null
  }
}
```

`session` is omitted before the first recording. `state` is one of `recording`,
`paused`, `stopped`, `failed`.

### `POST /start`

The JSON body mirrors the CLI flags; any field overrides the agent's launch-time
default. At least one of `audio`/`transcript` must be a file path (stdout `-` is
not supported).

```sh
curl -s -X POST http://127.0.0.1:8473/start \
  -d '{"system": true, "mix": true, "audio": "meeting.m4a", "transcript": "meeting.srt", "speakers": true}'
```

```json
{ "id": "28D1DBD7-…", "state": "recording", "audio": "meeting.m4a", "transcript": "meeting.srt" }
```

Relative paths resolve under the agent's working directory (`-C` at launch).

| Field | Type | Maps to |
|-------|------|---------|
| `audio` | string | `-a/--audio` (file; `.wav/.m4a/.flac/.mp3/.opus`) |
| `transcript` | string | `-t/--transcript` (file; `.txt/.srt/.json`) |
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

### `POST /pause`, `/resume`, `/stop`

```sh
curl -s -X POST http://127.0.0.1:8473/pause
curl -s -X POST http://127.0.0.1:8473/resume
curl -s -X POST http://127.0.0.1:8473/stop
```

```json
{ "id": "28D1DBD7-…", "state": "paused" }
```

Pausing **excludes** the paused interval from both the audio file and the
transcript (a true gap), so the output is shorter than wall-clock.

## Status codes

| Code | When |
|------|------|
| `200` | status / pause / resume / stop |
| `201` | start accepted |
| `400` | invalid JSON or invalid parameters (bad combo, stdout output) |
| `401` | missing/incorrect bearer token |
| `403` | permission denied (microphone / system audio) |
| `404` | control verb with no active recording; input not found |
| `409` | a recording is already active |
| `422` | unusable engine/model |

Errors carry a JSON body `{ "error": "…" }`.

## Reference: Google Meet userscript (Tampermonkey)

Records every Google Meet call automatically: it starts a capture when you join
and stops it when you leave, naming the file from the meeting title and date.

Install [Tampermonkey](https://www.tampermonkey.net/), create a new script, and
paste the following. Start the agent first, e.g.
`hark --remote-control 8473 -C ~/Recordings` (with a working engine/model if you
want transcripts — see the Configuration section of the README).

```javascript
// ==UserScript==
// @name         Hark — auto-record Google Meet
// @namespace    hark
// @match        https://meet.google.com/*
// @grant        GM_xmlhttpRequest
// @connect      127.0.0.1
// @run-at       document-idle
// ==/UserScript==

(function () {
  "use strict";

  const AGENT = "http://127.0.0.1:8473";
  const TOKEN = ""; // set if the agent uses $HARK_REMOTE_TOKEN

  let recording = false;

  function post(path, body) {
    const headers = { "Content-Type": "application/json" };
    if (TOKEN) headers["Authorization"] = "Bearer " + TOKEN;
    GM_xmlhttpRequest({
      method: "POST",
      url: AGENT + path,
      headers,
      data: body ? JSON.stringify(body) : "",
      onload: (r) => console.log("[hark]", path, r.status, r.responseText),
      onerror: (e) => console.warn("[hark] agent unreachable", e),
    });
  }

  function fileBase() {
    const stamp = new Date()
      .toISOString()
      .slice(0, 16)
      .replace("T", "-")
      .replace(":", "");
    const title = (document.title || "Meet")
      .replace(/^Meet\s*[-–—]\s*/, "")
      .replace(/[^\w.-]+/g, "_")
      .replace(/^_+|_+$/g, "")
      .slice(0, 60) || "meeting";
    return `Meet-${title}-${stamp}`;
  }

  // Heuristic: the in-call UI shows a "Leave call" control.
  function inCall() {
    return !!document.querySelector(
      '[aria-label*="Leave call" i], [aria-label*="Leave meeting" i]'
    );
  }

  function tick() {
    const active = inCall();
    if (active && !recording) {
      recording = true;
      const base = fileBase();
      post("/start", {
        system: true,
        mix: true,
        audio: base + ".m4a",
        transcript: base + ".srt",
        speakers: true,
      });
    } else if (!active && recording) {
      recording = false;
      post("/stop");
    }
  }

  setInterval(tick, 2000);
  window.addEventListener("beforeunload", () => {
    if (recording) post("/stop");
  });
})();
```

Notes:

- The `@connect 127.0.0.1` grant lets Tampermonkey reach the loopback agent.
- Adjust the JSON body to taste — e.g. drop `transcript`/`speakers` to record
  audio only, or set `engine`/`model` if you don't configure them at launch.
- The "Leave call" selector is a heuristic; Google changes Meet's DOM over time,
  so you may need to update it.
