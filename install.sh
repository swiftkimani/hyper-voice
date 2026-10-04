#!/usr/bin/env bash
# One-time setup for push-to-talk voice control in Hyper. Everything here is free.
# Safe to re-run. Pass --test to record 4 seconds from the mic and print what was heard.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

command -v brew >/dev/null || { echo "Install Homebrew first: https://brew.sh"; exit 1; }

echo "→ Installing Hammerspoon (hotkeys), whisper.cpp (offline speech-to-text), sox (mic recording)"
[ -d /Applications/Hammerspoon.app ] || brew install --cask hammerspoon
command -v sox >/dev/null || brew install sox
command -v whisper-cli >/dev/null || command -v whisper-cpp >/dev/null || brew install whisper-cpp

mkdir -p ~/.voice-term/models ~/.hammerspoon
MODEL=~/.voice-term/models/ggml-small.en.bin
MODEL_URL=https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin
MODEL_SIZE=487601967
if [ ! -f "$MODEL" ] || [ "$(stat -f%z "$MODEL")" -ne "$MODEL_SIZE" ]; then
  echo "→ Downloading the English speech model (~465 MB, one time only; resumes if interrupted)"
  curl -L --fail -C - --retry 10 --retry-delay 5 -o "$MODEL" "$MODEL_URL"
fi

cp "$here/voice.lua" ~/.hammerspoon/voice.lua
touch ~/.hammerspoon/init.lua
grep -q 'require("voice")' ~/.hammerspoon/init.lua || echo 'require("voice")' >> ~/.hammerspoon/init.lua

if [ "${1:-}" = "--test" ]; then
  WHISPER="$(command -v whisper-cli || command -v whisper-cpp)"
  echo
  echo "→ Mic test: say a sentence now (recording 4 seconds)…"
  sox -q -d -c 1 -r 16000 -b 16 /tmp/voice-term-test.wav trim 0 4 highpass 100
  echo "→ You said:"
  "$WHISPER" -m "$MODEL" -f /tmp/voice-term-test.wav -l en -nt -np || true
fi

open -a Hammerspoon
echo
echo "Done. Now:"
echo "  1. Allow Hammerspoon in System Settings → Privacy & Security → Accessibility"
echo "  2. Hold Right ⌥ and speak once — allow Microphone when macOS asks"
echo "  3. Hammerspoon menu-bar icon → Reload Config"
