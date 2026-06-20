#!/bin/bash
# Latency-drift validation for dual-source capture (PRD §2: <200 ms drift
# between mic and system tracks over 60 minutes).
#
# Records `--system --mix` while a short 1.5 kHz ping plays every 10 s.
# Each ping reaches the recording twice: digitally (process tap) and
# acoustically (speakers -> microphone). The change in separation between
# the two copies over the run is the clock drift between the sources.
#
# Usage: drift-validation.sh [duration-seconds] [output.wav] [mic-uid]
# Analyze the result with Scripts/drift-analyze.py.
set -euo pipefail

DURATION="${1:-3720}"
OUT="${2:-/tmp/hark-drift.wav}"
MIC="${3:-BuiltInMicrophoneDevice}"
HARK="${HARK:-.build/debug/hark}"
CLICK="/tmp/hark-click.wav"

# 30 ms 1.5 kHz burst with sharp attack; narrowband so analysis can
# filter out unrelated audio.
python3 - "$CLICK" <<'EOF'
import sys, wave, math, struct
rate = 48000
with wave.open(sys.argv[1], 'w') as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate)
    n = int(rate * 0.03)
    w.writeframes(b''.join(
        struct.pack('<h', int(0.9 * 32767 * math.sin(2*math.pi*1500*i/rate)
                              * min(1.0, (n-i)/(n*0.3))))
        for i in range(n)))
EOF

echo "recording $DURATION s to $OUT (mic: $MIC)"
"$HARK" record --system --mix -d "$MIC" -r 48000 -t "$DURATION" -o "$OUT" &
RECORD_PID=$!
trap 'kill $RECORD_PID 2>/dev/null || true' EXIT

sleep 2  # let capture spin up before the first ping
END=$((SECONDS + DURATION))
while [ $SECONDS -lt $END ] && kill -0 $RECORD_PID 2>/dev/null; do
    afplay -v 0.5 "$CLICK" || true
    sleep 10
done

wait $RECORD_PID || true
echo "done: $OUT"
