# hark speaker-label demo — render with:  make demo   (needs: brew install vhs ffmpeg)
#
# Transcribes demo/standup.m4a (a 29 s two-voice call synthesized with the
# macOS `say` voices Samantha and Daniel) with --speakers, then again as
# subtitles. File input only: no microphone/system-audio TCC prompts, so the
# GIF is reproducible. Rendered to assets/demo-speakers.gif.

Output assets/demo-speakers.gif

Require hark

Set Shell        "zsh"
Set FontSize     18
Set Width        1240
Set Height       560
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

Type "# a two-person call, transcribed on-device with speaker labels"
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
Sleep 5s

# tidy up the scratch file so the demo leaves nothing behind (stays hidden,
# so the recording ends on the subtitle output)
Hide
Type "rm -f standup.srt" Enter
