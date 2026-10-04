# AGENTS.md — hyper-voice

## Read first
1. README.md — what it is and how it behaves
2. docs/CONTEXT.md — where the work stands

## Project in one paragraph
Push-to-talk voice control for the Hyper terminal on macOS. One Lua module for
Hammerspoon plus an installer. Offline speech-to-text (whisper.cpp), local phrase
matching, Claude Code or opencode for free-form requests.

## Stack
Hammerspoon (Lua 5.4), sox, whisper.cpp, zsh. No build step, no package manager.

## Commands
| Task | Command |
|---|---|
| Install / update | `./install.sh` |
| Mic test | `./install.sh --test` |
| Reload after editing | `hs -c 'hs.reload()'` |
| Run a phrase without the mic | `hs -c 'require("voice").say("new tab")'` |
| Log | `tail -f ~/.voice-term/history.log` |

## Rules
- `voice.lua` in this repo and `~/.hammerspoon/voice.lua` must stay identical; `install.sh` copies it.
- AI plans never run a command that matches the `risky` list, whatever the AI says. Keep that list conservative.
- Enter is only pressed for aliases, patterns, and AI steps marked RUN that pass the risky check.
- `M.actions` mirrors the user's `~/.hyper.js` keymaps. Change both together.
- No new dependencies without a reason in docs/CONTEXT.md.
