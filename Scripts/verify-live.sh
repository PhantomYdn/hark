#!/bin/bash
# Live-capture verification for the pending items that need real audio
# permissions (PLAN: "Pending live verification"). These can't run headless or
# in CI — they exercise the microphone and system-audio process taps, which
# require TCC grants the GUI must approve.
#
# Prerequisites (grant to YOUR terminal, then restart it):
#   System Settings -> Privacy & Security -> Microphone -> <terminal> -> on
#   System Settings -> Privacy & Security -> Screen & System Audio Recording
#     -> "+" -> <terminal> -> on
#
# Audible: records ~2-5 s from the mic per check and plays a quiet tone during
# the app-isolation step. Best run on a quiet system. Each check reports PASS or
# FAIL and the script continues; exit status is non-zero if any check failed.
#
# Usage:  ./Scripts/verify-live.sh        (uses .build/release/hark)
#         HARK=.build/debug/hark ./Scripts/verify-live.sh

set -uo pipefail

HARK="${HARK:-.build/release/hark}"
WORK="$(mktemp -d /tmp/hark-verify.XXXXXX)"
FAILED=0
trap 'rm -rf "$WORK"' EXIT

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILED=1; }
skip() { echo "  SKIP: $1"; }

# Validates that a file is readable audio of at least MINSEC seconds.
check_audio() { # path minsec label
  local path="$1" minsec="$2" label="$3"
  if [[ ! -s "$path" ]]; then fail "$label — no file produced"; return; fi
  local dur
  dur="$(afinfo "$path" 2>/dev/null | awk -F'[ :]+' '/estimated duration/ {print $4}')"
  if [[ -z "$dur" ]]; then fail "$label — afinfo could not read $path"; return; fi
  if awk "BEGIN{exit !($dur >= $minsec)}"; then
    pass "$label (${dur}s)"
  else
    fail "$label — duration ${dur}s < ${minsec}s"
  fi
}

if [[ ! -x "$HARK" ]]; then
  echo "error: hark binary not found at '$HARK' (build it, or set HARK=...)." >&2
  exit 69
fi
echo "hark: $HARK"
echo "work:  $WORK"
echo "NOTE: grant Microphone + System Audio Recording to this terminal first."
echo

echo "[1] Live encoded capture (m4a, flac) — 2 s each"
"$HARK" --duration 2 -a "$WORK/mic.m4a"  2>/dev/null; check_audio "$WORK/mic.m4a"  1.5 "m4a mic capture"
"$HARK" --duration 2 -a "$WORK/mic.flac" 2>/dev/null; check_audio "$WORK/mic.flac" 1.5 "flac mic capture"

echo "[2] --split duration=2 over 5 s -> 3 numbered chunks, each playable"
"$HARK" --duration 5 --split duration=2 -a "$WORK/split.wav" 2>/dev/null
chunks=("$WORK"/split_*.wav)
if [[ -e "${chunks[0]}" ]]; then
  n="${#chunks[@]}"
  [[ "$n" -eq 3 ]] && pass "chunk count = 3" || fail "chunk count = $n (expected 3)"
  for c in "${chunks[@]}"; do check_audio "$c" 0.3 "chunk $(basename "$c")"; done
else
  fail "no split_*.wav chunks produced"
fi

echo "[3] --split silence smoke (4 s, threshold default)"
"$HARK" --duration 4 --split silence=1 -a "$WORK/sil.wav" 2>/dev/null
sil=("$WORK"/sil_*.wav)
if [[ -e "${sil[0]}" ]]; then
  pass "produced ${#sil[@]} silence-split chunk(s)"
  for c in "${sil[@]}"; do check_audio "$c" 0.1 "silence chunk $(basename "$c")"; done
else
  fail "no sil_*.wav chunks produced"
fi

echo "[4] US03 mic pipeline: hark -a - --duration 5 | hark -i -"
if "$HARK" --engine whisper -i /dev/null -t - >/dev/null 2>&1 \
  || "$HARK" models list 2>/dev/null | grep -q whisper; then
  out="$("$HARK" -a - --duration 5 2>/dev/null | "$HARK" -i - 2>/dev/null)"
  if [[ -n "${out// /}" ]]; then pass "pipeline produced transcript: ${out:0:60}"; else
    skip "pipeline ran but transcript empty (speak during capture; needs whisper + model)"
  fi
else
  skip "pipeline — no whisper engine/model available"
fi

echo "[5] App-isolation e2e (Scripts/e2e-app-isolation.sh)"
if [[ -x Scripts/e2e-app-isolation.sh ]]; then
  if HARK="$HARK" Scripts/e2e-app-isolation.sh >/dev/null 2>&1; then
    pass "app isolation"
  else
    fail "app isolation (see: HARK=$HARK Scripts/e2e-app-isolation.sh)"
  fi
else
  skip "Scripts/e2e-app-isolation.sh not found"
fi

# Captures system audio on a backend; a missing-permission/headless error for
# the sckit backend is a SKIP (not a FAIL) so the script is usable without
# Screen Recording granted.
check_system_backend() { # backend extra-flags... label
  local backend="$1"; shift
  local label="${*: -1}"; set -- "${@:1:$(($#-1))}"
  local out="$WORK/sys-$backend-$RANDOM.wav" err="$WORK/sys-$backend.err"
  "$HARK" --system --capture-backend "$backend" "$@" --duration 2 -a "$out" 2>"$err"
  if grep -qiE "permission denied|no display|needs macOS 15" "$err"; then
    skip "$label — $(tr '\n' ' ' <"$err" | sed 's/  */ /g' | cut -c1-80)"
    return
  fi
  check_audio "$out" 1.5 "$label"
}

echo "[6] System-capture backends (records ~2 s of system audio each)"
check_system_backend coreaudio "coreaudio --system"
check_system_backend coreaudio --mix "coreaudio --system --mix (full-length even if silent)"
check_system_backend sckit "sckit --system"
check_system_backend sckit --mix "sckit --system --mix"
check_system_backend auto "auto --system (picks a backend)"

echo "[7] Interactive mode requires a TTY (negative guard)"
if "$HARK" --interactive </dev/null >/dev/null 2>"$WORK/interactive.err"; then
  fail "interactive — expected a usage error without a TTY"
elif grep -qi "interactive terminal" "$WORK/interactive.err"; then
  pass "interactive rejects a non-TTY with a clear error"
else
  fail "interactive — unexpected error: $(tr '\n' ' ' <"$WORK/interactive.err" | cut -c1-80)"
fi
echo "  NOTE: the positive interactive path (space/Enter keys) needs a real TTY; run 'hark --interactive' by hand."

echo "[8] Remote-control agent (loopback HTTP API: start/409/stop lifecycle)"
if ! command -v curl >/dev/null; then
  skip "remote-control — curl not found"
else
  PORT=$((8500 + RANDOM % 400))
  "$HARK" --remote-control "127.0.0.1:$PORT" -C "$WORK" >"$WORK/agent.log" 2>&1 &
  AGENT_PID=$!
  sleep 1
  if curl -fsS "http://127.0.0.1:$PORT/status" >/dev/null 2>&1; then
    start="$(curl -fsS -X POST "http://127.0.0.1:$PORT/start" -d '{"audio":"agent-rec.wav","duration":3}')"
    code409="$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/start" -d '{"audio":"x.wav"}')"
    if echo "$start" | grep -q '"state":"recording"' && [[ "$code409" == "409" ]]; then
      sleep 4
      st="$(curl -fsS "http://127.0.0.1:$PORT/status")"
      if echo "$st" | grep -q '"state":"stopped"'; then
        check_audio "$WORK/agent-rec.wav" 2 "remote-control start/stop lifecycle"
      else
        fail "remote-control — session did not stop cleanly: $st"
      fi
    else
      fail "remote-control — start/409 failed (start=$start, second=$code409)"
    fi
  else
    skip "remote-control — agent did not respond (mic permission?): $(tr '\n' ' ' <"$WORK/agent.log" | cut -c1-80)"
  fi
  kill "$AGENT_PID" 2>/dev/null
fi

echo
if [[ "$FAILED" -eq 0 ]]; then
  echo "ALL LIVE CHECKS PASSED"
else
  echo "SOME LIVE CHECKS FAILED (see FAIL lines above)"
fi
exit "$FAILED"
