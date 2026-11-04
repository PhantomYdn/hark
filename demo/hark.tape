# hark demo — render with:  make demo   (needs: brew install vhs ffmpeg)
#
# Drives only deterministic, no-permission commands so the GIF is
# reproducible: version, device list, a two-voice call transcribed with
# speaker labels (demo/standup.m4a) and as subtitles, and a transcode.
# No microphone/system-audio TCC prompts, nothing from the user's config.
#
# The `make demo` target builds a release binary and puts it on PATH,
# so `hark` below resolves to this checkout.

Output assets/demo.gif

Require hark

Set Shell        "zsh"
Set FontSize     18
Set Width        1240
Set Height       680
Set Padding      24
Set Margin       16
Set BorderRadius 12
Set WindowBar    Colorful
Set Theme        "Catppuccin Mocha"
Set TypingSpeed  55ms
Set PlaybackSpeed 1.0

# Setup (not recorded): enable `#` comments and a clean prompt.
Hide
Type "setopt interactive_comments" Enter
Type "export PROMPT='%F{45}❯%f '" Enter
# warm the model cache so the recorded run is representative
Type "hark -i demo/standup.m4a --speakers -t - >/dev/null 2>&1" Enter
Sleep 15s
Type "clear" Enter
Show
Sleep 600ms

Type "hark --version"
Sleep 400ms
Enter
Sleep 1500ms

Type "hark devices"
Sleep 400ms
Enter
Sleep 3s

Type "# transcribe a two-person call on-device, with speaker labels"
Enter
Type "hark -i demo/standup.m4a --speakers -t -"
Sleep 400ms
Enter
Sleep 5s

Type "# the same call as subtitles"
Enter
Type "hark -i demo/standup.m4a --speakers -t standup.srt && head -3 standup.srt"
Sleep 400ms
Enter
Sleep 4s

Type "# transcode between formats - no model needed"
Enter
Type "hark -i demo/sample.mp3 -a out.flac && hark info out.flac"
Sleep 400ms
Enter
Sleep 4s

# tidy up the scratch file so the demo leaves nothing behind
Hide
Type "rm -f out.flac standup.srt" Enter
