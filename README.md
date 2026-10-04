# hyper-voice

Push-to-talk voice control for the [Hyper](https://hyper.is) terminal on macOS, plus dictation into any app.

Hold a key, say what you want, let go. "Open a new tab and go to desktop" opens a tab and runs `cd ~/Desktop`. "Show me the ten largest files in downloads" becomes a shell command and runs. What was heard and what was done appears in a small banner glued to the top of the Hyper window; it follows the window when you move or resize it and fades out after a few seconds.

Everything runs locally and costs nothing: [Hammerspoon](https://www.hammerspoon.org) listens for the key, [sox](https://sox.sourceforge.net) records the mic, [whisper.cpp](https://github.com/ggerganov/whisper.cpp) turns speech into text offline, and the built-in macOS voice talks back. Phrases are matched locally first. Anything unmatched is turned into a short plan by an LLM: [Claude Code](https://claude.com/claude-code) (`claude -p`), [opencode](https://opencode.ai), or any OpenAI-compatible endpoint such as [Ollama](https://ollama.com) running a local model.

## Gestures

| Gesture | What happens |
|---|---|
| **Hold Right ⌥ Option**, speak, release | Command mode. Acts on Hyper: presses shortcuts, types commands, runs the safe ones. |
| **Tap Right ⌥ Option** (quick press) | Hands-free command mode. It listens, stops by itself after you pause for 1.5 s (or after 20 s). Tap again to stop early. For when holding a key is a pain. |
| **Hold or tap Right ⌘ Command** | Dictation, same two ways. The words are typed into whichever app is in front. |
| Any other key while listening | Cancels. |

While it listens, speaker volume drops to 10% and comes back after, so music is not a problem. There is no wake word on purpose: meeting chatter or a podcast cannot trigger it, and nothing is said aloud to start it. In a call, mute yourself in Zoom or Teams first, or the meeting hears you.

It talks back with the macOS voice: "new tab, then cd Desktop", "typed, press return to run", "didn't catch that". Set `speak = false` to silence it, or `speakVoice = "Daniel"` to pick a voice (`say -v ?` lists them).

## What you can say

Local phrases run instantly, no AI involved. Join several with "and".

| Say | Does |
|---|---|
| new tab · close tab · next tab · previous tab | ⌘T · ⌘W · ⌃Tab · ⌃⇧Tab |
| new window | ⌘N |
| tab one … tab five · first tab · second tab | ⌘1 … ⌘5 (switch terminal by voice) |
| split · split vertical · split horizontal | ⌃⇧E · ⌃⇧E · ⌃⇧O |
| next pane · previous pane | ⌘] · ⌘[ |
| clear | ⌃⇧K |
| stop that · interrupt | ⌃C |
| go to downloads / desktop / documents / projects / home | `cd …` and Enter |
| go back · go up | `cd -` · `cd ..` |
| list files · git status · git log · git diff · git pull | the command, and Enter |
| open Safari · launch Figma | opens the app |
| start claude · start opencode | starts the tool in Hyper |

Filler words ("please", "hyper", "the", …) are ignored, so "open a new hyper tab please" still matches.

Keystrokes go to whichever Hyper window and pane has focus, so with several terminals open say "tab two and git status" to pick one. Jobs running in the background do not get in the way; a program running in the foreground of that pane receives the keystrokes as its input, which is how you answer its prompts by voice.

Anything else goes to the LLM, which replies with a plan of the same steps. Commands it marks as safe (navigation, read-only) run with Enter. Anything that deletes, moves, kills, installs or pushes is typed but **not** run, so you read it and press Return yourself. A local blocklist enforces this even if the model gets it wrong. Keystrokes are only ever sent once Hyper is confirmed to be the frontmost app; otherwise nothing is sent and the banner says so.

## Choosing the LLM

| `ai =` | Uses | Cost |
|---|---|---|
| `"claude"` (default) | `claude -p --model haiku`, your Claude Code login | your existing plan |
| `"opencode"` | `opencode run`, whatever model opencode is set to | your existing plan |
| `"http"` | any OpenAI-compatible chat endpoint: `aiEndpoint`, `aiModel`, `aiApiKey` | free with Ollama |
| `"none"` | local phrases only | free |

For a fully offline setup: `brew install ollama && ollama pull llama3.2`, then set `ai = "http"`. The defaults already point at Ollama on `127.0.0.1:11434`. For OpenAI, Groq, OpenRouter or Gemini, set `aiEndpoint`, `aiModel` and `aiApiKey` to theirs.

## Install

```sh
git clone https://github.com/swiftkimani/hyper-voice.git
cd hyper-voice
./install.sh          # Homebrew installs, model download (~465 MB once), copies voice.lua
./install.sh --test   # same, then records 4 s from the mic and prints what it heard
```

Then:

1. System Settings → Privacy & Security → Accessibility → enable Hammerspoon. The script notices and starts by itself.
2. Open Hyper, hold Right ⌥ and say "new tab". Allow Microphone when macOS asks.

Requirements: Apple Silicon or Intel Mac, Homebrew, Hyper, and `claude` or `opencode` on your PATH for free-form requests. Without an AI tool the local phrases still work.

## Configure

Edit `~/.hammerspoon/voice.lua`, then Reload Config from the Hammerspoon menu-bar icon (or `hs -c 'hs.reload()'`).

| Setting | Default | Meaning |
|---|---|---|
| `M.aliases` | see file | Exact phrases → steps. `["go to garda"] = "RUN cd ~/Desktop/projects/garda-fleet"` |
| `M.patterns` | see file | Substrings → steps, checked in order. |
| `M.places` | see file | Folder names for "go to …". |
| `M.actions` | from `~/.hyper.js` | Shortcut names → key combos. Change these if you change your Hyper keymaps. |
| `ai` | `"claude"` | `"claude"`, `"opencode"` or `"none"`. |
| `claudeArgs` | haiku + start-up-skipping flags | Drop `"--model", "haiku"` if haiku is not on your plan. The other flags stop Claude Code loading MCP connectors, sessions and skills for each voice command (12 s → ~5 s). |
| `aiMayRun` | `true` | Let AI plans press Enter on commands marked safe. `false` types everything. |
| `tapToTalk` | `true` | A quick tap starts hands-free listening. |
| `pauseStop` / `pauseLevel` | 1.5 / `"2%"` | Hands-free: stop after this pause; raise the level in noisy rooms. |
| `speak` / `speakVoice` | `true` / system | Spoken confirmations. |
| `commandKey` / `dictateKey` | 61 / 54 | Right ⌥ / Right ⌘. Left ⌥ = 58, Left ⌘ = 55. |
| `duckVolume` | 10 | Speaker volume while listening. |
| `aiContext` | one sentence | Context given to the AI with every request. |

Plan steps, used by aliases, patterns and the AI alike:

```
KEYS tab:new          press a Hyper shortcut from M.actions
RUN  cd ~/Desktop     type a command and press Enter
TYPE rm -rf build     type a command, do not press Enter
OPEN Safari           open a macOS app
```

## Test without the mic

```sh
hs -c 'return require("voice").plan("open a new tab and go to desktop")'   # dry run, shows the plan
hs -c 'require("voice").say("open a new tab and go to desktop")'           # actually does it
```

## Troubleshooting

- Everything heard and done is appended to `~/.voice-term/history.log`.
- The last recording is kept at `~/.voice-term/last.wav`. Play it to check the mic.
- "no audio": Hammerspoon lacks Microphone permission, or the default input device changed.
- Nothing happens on key hold: Hammerspoon lacks Accessibility permission, or the config has an error. Open the Hammerspoon Console from its menu-bar icon.
- "Not logged in" from the AI step: run `claude` once in a terminal and log in.
- Slow or wrong AI plans: add the phrase to `M.aliases` or `M.patterns`.

## How it works

```
Right ⌥ down ─► sox records mic ─► Right ⌥ up ─► whisper-cli (offline) ─► text
   text ─► aliases / patterns / places ─► plan        (instant)
        └─► claude -p / opencode ─► plan              (free-form)
   plan ─► Hammerspoon presses keys / types into Hyper ─► banner at top of window
```

## Files

- `voice.lua` — the Hammerspoon module. Installed to `~/.hammerspoon/voice.lua`.
- `install.sh` — idempotent installer.
- `docs/CONTEXT.md` — where the work stands and what is planned (including the cross-platform MCP idea).

## Licence

MIT. See `LICENSE`.
