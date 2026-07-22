# macOS Permissions (TCC)

Hark needs two privacy permissions, both granted per-application by macOS
TCC. **For command-line tools, macOS attributes permissions to the terminal
application that launched them** (Terminal, iTerm2, kitty, an IDE, …), not
to `hark` itself — even though `hark` embeds its own usage descriptions.

## Microphone (live capture, `--mix`)

Service: `kTCCServiceMicrophone`.

The first microphone capture triggers the standard prompt, attributed to
your terminal. If it was denied, re-enable it under:

> System Settings → Privacy & Security → Microphone → *your terminal* → on

## System / app audio capture (`--system`, `--app`, `--exclude-app`)

System/app capture uses one of two backends (`--capture-backend`, default
`auto`), each with its own permission. `auto` prefers ScreenCaptureKit when it
is available (macOS 15+, a GUI session, and Screen Recording granted) and
otherwise falls back to the Core Audio tap, printing a notice.

### Core Audio tap — "System Audio Recording" (headless-capable)

Service: `kTCCServiceAudioCapture` ("System Audio Recording Only"). The narrower
permission; works headless (cron/launchd/SSH) and on macOS 14.4+.

**macOS does not show a prompt for terminal-attributed CLIs** — and a missing
permission does not produce an error: the process tap silently delivers
all-zero samples. Hark detects an entirely-silent system capture and warns:

1. Open **System Settings → Privacy & Security → Screen & System Audio
   Recording**
2. Find the **System Audio Recording Only** section
3. Click **+**, add your terminal application
4. **Restart the terminal** and retry

To verify the grant took effect:

```bash
sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
  "SELECT client, auth_value FROM access WHERE service='kTCCServiceAudioCapture';"
# auth_value 2 = allowed
```

### ScreenCaptureKit — "Screen Recording" (macOS 15+, GUI session only)

Service: `kTCCServiceScreenCapture`. The broader Screen Recording permission;
ScreenCaptureKit needs it for any capture, including audio-only, and only works
inside a graphical login session (not headless/SSH/LaunchDaemon).

> System Settings → Privacy & Security → Screen & System Audio Recording →
> *your terminal* → on, then restart the terminal.

Force the headless-capable Core Audio backend (skipping Screen Recording) with
`--capture-backend coreaudio` or `HARK_CAPTURE=coreaudio`.

## Speech Recognition (`--engine apple`)

Service: `kTCCServiceSpeechRecognition`.

The `apple` engine uses macOS on-device speech recognition, which needs the
Speech Recognition permission — attributed to your terminal, like the mic:

> System Settings → Privacy & Security → Speech Recognition → *your terminal* → on

The first use triggers the prompt; on-device locale assets may download on
first use of a language. The `whisper` and `whisperkit` engines don't need
this permission.

## Speaker labels & VAD (`--speakers`, live segmentation)

Speaker diarization (`--speakers`) and the live-segmentation VAD operate on
audio Hark has **already captured**, so they need **no additional TCC
permission** beyond the mic/system-audio grants above.

They do use on-device CoreML models (FluidAudio, Apple Silicon) that are
**downloaded from Hugging Face on first use**, then run fully offline:

- The VAD model is fetched on the first live transcription (it improves segment
  boundaries). Disable it entirely with `HARK_VAD=0`.
- The diarization model is fetched the first time you use `--speakers` with
  acoustic diarization.

Pre-fetch both to avoid a first-run download (e.g. for offline/air-gapped use):

```sh
hark models download fluidaudio:vad
hark models download fluidaudio:diarizer
```

On Intel Macs, acoustic diarization is unavailable; diarized modes fall back to
deterministic `You`/`Others` source attribution (which needs no model).

## Interactive & remote control (`--interactive`, `--remote-control`)

Neither mode needs a new TCC permission — a recording started interactively or
through the remote-control agent uses the **same** microphone / system-audio
permissions as a normal capture (above). The remote-control agent's HTTP
listener is loopback-only by default (no network exposure); binding it to a
non-loopback interface is opt-in and requires `$HARK_REMOTE_TOKEN`. See
[remote-control.md](remote-control.md).

## Background service (`brew services` / launchd)

When hark runs as a launchd agent (`brew services start hark`, see
[remote-control.md](remote-control.md)), there is no terminal in the chain:
permissions attribute **directly to the signed `hark` binary** (validated on
macOS 26).

- **Microphone** works like an app: the first mic capture pops the standard
  prompt naming *hark* — approve it once.
- **System/app audio** never prompts for a CLI (either backend). Grant it
  manually **to the hark binary**:
  1. Open **System Settings → Privacy & Security → Screen & System Audio
     Recording**
  2. Click **+** (use the **System Audio Recording Only** section for the
     Core Audio backend; the **Screen Recording** section covers
     ScreenCaptureKit), press **⌘⇧G**, and add
     `/opt/homebrew/opt/hark/bin/hark`
  3. Restart the service (`brew services restart hark`) and retry
- A missing grant does **not** error: the capture writes a header-only file
  and hark logs a "captured no audio / only silence" warning pointing here
  (check `$(brew --prefix)/var/log/hark-remote.log`).

**Upgrades:** macOS records CLI grants **by path**, and the resolved path is
the versioned Cellar directory (e.g. `…/Cellar/hark/0.4.1/bin/hark`), so a
`brew upgrade` drops the system-audio grant (verified live on the 0.4.0→0.4.1
upgrade) — re-add hark and restart the service if captures go silent after an
upgrade. The pane keeps the old version's entry as a stale duplicate `hark`
row; remove it (−) to avoid confusion. (The mic grant re-prompts on first use
instead, since mic prompts work for the directly-attributed binary.)

## Multiplexers (tmux, screen)

Permission attribution resolves through tmux/screen to the terminal that
hosts them. Granting the permission to the terminal app is sufficient;
restarting the terminal does not kill detached tmux sessions, so you can
reattach after the restart.

## Notes for packaging (Phase 5)

- `hark` embeds an `Info.plist` (`__TEXT,__info_plist`) with
  `NSMicrophoneUsageDescription`, `NSAudioCaptureUsageDescription`, and
  `NSSpeechRecognitionUsageDescription` plus a bundle identifier, which is
  required for any future direct attribution.
- The release binary is **signed (Developer ID) and notarized**, with a stable
  code identity (`dev.hark.cli`, Team `8UW9J44QNB`), so TCC grants persist across
  upgrades. Whether the prompt attributes to `hark` itself vs the launching
  terminal still depends on macOS's responsible-process handling for shell CLIs.
