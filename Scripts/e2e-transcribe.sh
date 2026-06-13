#!/bin/bash
# End-to-end transcription validation (US03, PRD §6.4/§6.6).
#
# Uses say(1) to synthesize speech — no microphone or TCC permissions
# needed. Verifies: file transcription across output formats, whisper.cpp
# acceptance of every aural output format (wav/m4a/flac), stdin pipes
# (WAV stream + raw PCM), and engine exit-code propagation.
#
# Requirements: whisper-cli on PATH (brew install whisper-cpp) and a ggml
# model at $AURAL_WHISPER_MODEL (default: ~/.aural/models/ggml-base.en.bin).
set -euo pipefail

AURAL="${AURAL:-.build/debug/aural}"
export AURAL_WHISPER_MODEL="${AURAL_WHISPER_MODEL:-$HOME/.aural/models/ggml-base.en.bin}"
WORK="$(mktemp -d /tmp/aural-e2e-tr.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
PHRASE="the quick brown fox jumps over the lazy dog"
FAILURES=0

check() { # name, transcript-file
    if grep -qi "quick brown fox" "$2"; then
        echo "   $1: PASS"
    else
        echo "   $1: FAIL ($(head -c 120 "$2"))"
        FAILURES=$((FAILURES + 1))
    fi
}

echo "== synthesizing speech"
say -o "$WORK/speech.aiff" "$PHRASE"

echo "== file transcription + output formats"
"$AURAL" transcribe -i "$WORK/speech.aiff" 2>/dev/null > "$WORK/out.txt"
check "aiff -> txt" "$WORK/out.txt"
"$AURAL" transcribe -i "$WORK/speech.aiff" --output-format srt 2>/dev/null > "$WORK/out.srt"
grep -q -- "-->" "$WORK/out.srt" && check "aiff -> srt" "$WORK/out.srt"
"$AURAL" transcribe -i "$WORK/speech.aiff" --output-format json 2>/dev/null > "$WORK/out.json"
python3 -c "import json;json.load(open('$WORK/out.json'))" && check "aiff -> json" "$WORK/out.json"

echo "== whisper accepts every aural output format (PRD §6.4)"
for fmt in wav m4a flac; do
    "$AURAL" convert -i "$WORK/speech.aiff" -o "$WORK/speech.$fmt"
    "$AURAL" transcribe -i "$WORK/speech.$fmt" 2>/dev/null > "$WORK/out-$fmt.txt"
    check "$fmt" "$WORK/out-$fmt.txt"
done

echo "== stdin: WAV stream pipe"
cat "$WORK/speech.wav" | "$AURAL" transcribe -i - 2>/dev/null > "$WORK/out-pipe.txt"
check "wav pipe" "$WORK/out-pipe.txt"

echo "== stdin: raw PCM pipe"
"$AURAL" convert -i "$WORK/speech.aiff" -o "$WORK/speech16.wav" -r 16000 -c 1
python3 - "$WORK/speech16.wav" "$WORK/speech16.pcm" <<'EOF'
import struct, sys
d = open(sys.argv[1], 'rb').read()
size = struct.unpack('<I', d[40:44])[0]
open(sys.argv[2], 'wb').write(d[44:44 + size])
EOF
cat "$WORK/speech16.pcm" \
    | "$AURAL" transcribe -i - --input-rate 16000 --input-channels 1 2>/dev/null \
    > "$WORK/out-raw.txt"
check "raw pcm pipe" "$WORK/out-raw.txt"

echo "== engine failure propagates non-zero exit (US03)"
echo "not a model" > "$WORK/fake-model.bin"
if "$AURAL" transcribe -i "$WORK/speech.wav" --model "$WORK/fake-model.bin" 2>/dev/null; then
    echo "   propagation: FAIL (exit 0 with corrupt model)"
    FAILURES=$((FAILURES + 1))
else
    echo "   propagation: PASS (exit $?)"
fi

echo "== verdict"
if [ "$FAILURES" -eq 0 ]; then echo "ALL PASS"; else echo "$FAILURES FAILURE(S)"; exit 1; fi
