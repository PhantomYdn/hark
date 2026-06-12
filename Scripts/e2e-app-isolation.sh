#!/bin/bash
# End-to-end validation of per-app capture isolation (US02 / US07).
#
# Plays a 440 Hz tone via afplay (the "target app") and verifies:
#   1. `aural record --app <afplay-pid>` captures the tone (RMS high)
#   2. `aural record --exclude-app <afplay-pid>` does not (RMS low)
#
# Requirements: System Audio Recording permission granted to the terminal;
# best run on a quiet system (other apps' audio raises the exclusion RMS).
# Audible: plays a quiet tone through the speakers twice.
set -euo pipefail

AURAL="${AURAL:-.build/debug/aural}"
WORK="$(mktemp -d /tmp/aural-e2e.XXXXXX)"
trap 'rm -rf "$WORK"; kill $(jobs -p) 2>/dev/null || true' EXIT

echo "== generating tone"
python3 - "$WORK/tone.wav" <<'EOF'
import sys, wave, math, struct
with wave.open(sys.argv[1], 'w') as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(44100)
    w.writeframes(b''.join(
        struct.pack('<h', int(0.4 * 32767 * math.sin(2*math.pi*440*t/44100)))
        for t in range(44100 * 8)))
EOF

# Amplitude of the 440 Hz component (Goertzel) - robust against unrelated
# background audio, unlike broadband RMS.
tone_amp() {
    python3 - "$1" <<'EOF'
import sys, wave, struct, math
with wave.open(sys.argv[1]) as w:
    n, ch, rate = w.getnframes(), w.getnchannels(), w.getframerate()
    s = struct.unpack(f'<{n*ch}h', w.readframes(n))
    x = [s[i*ch] / 32768 for i in range(n)]
k = 2 * math.pi * 440 / rate
s1 = s2 = 0.0
for v in x:
    s0 = v + 2 * math.cos(k) * s1 - s2
    s2, s1 = s1, s0
print(f"{math.sqrt(abs(s1*s1 + s2*s2 - 2*math.cos(k)*s1*s2)) / len(x) * 2:.6f}")
EOF
}

echo "== case 1: --app captures the target app"
afplay -v 0.3 "$WORK/tone.wav" &
AFPLAY_PID=$!
sleep 0.8
"$AURAL" record --app "$AFPLAY_PID" -t 2 -o "$WORK/included.wav"
kill $AFPLAY_PID 2>/dev/null || true
wait $AFPLAY_PID 2>/dev/null || true
INCLUDED_AMP=$(tone_amp "$WORK/included.wav")
echo "   included 440Hz amplitude: $INCLUDED_AMP"

echo "== case 2: --exclude-app suppresses the target app"
afplay -v 0.3 "$WORK/tone.wav" &
AFPLAY_PID=$!
sleep 0.8
"$AURAL" record --exclude-app "$AFPLAY_PID" -t 2 -o "$WORK/excluded.wav"
kill $AFPLAY_PID 2>/dev/null || true
wait $AFPLAY_PID 2>/dev/null || true
EXCLUDED_AMP=$(tone_amp "$WORK/excluded.wav")
echo "   excluded 440Hz amplitude: $EXCLUDED_AMP"

echo "== verdict"
python3 - "$INCLUDED_AMP" "$EXCLUDED_AMP" <<'EOF'
import sys
included, excluded = float(sys.argv[1]), float(sys.argv[2])
ok_included = included > 0.02
ok_excluded = excluded < included / 10
print(f"   tone captured via --app:      {'PASS' if ok_included else 'FAIL'} ({included:.4f})")
print(f"   tone suppressed via --exclude: {'PASS' if ok_excluded else 'FAIL'} ({excluded:.4f})")
sys.exit(0 if ok_included and ok_excluded else 1)
EOF
echo "OK"
