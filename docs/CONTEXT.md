# CONTEXT — hyper-voice
_Last updated: 2026-10-04 13:05_

## Current goal
Reliable hands-free control of Hyper: shortcuts, navigation, and free-form commands, with feedback inside the terminal window.

## Status at a glance
| Area | State | Notes |
|---|---|---|
| Push-to-talk recording (Right ⌥ / Right ⌘) | ✅ done | sox, volume ducking, any-key cancel |
| Offline transcription (whisper small.en) | ✅ done | ~1–2 s per phrase on M-series |
| Local phrases, patterns, places, "and" chaining | ✅ done | |
| Hyper shortcut actions (tabs, panes, clear, interrupt) | ✅ done | mirrors ~/.hyper.js keymaps |
| AI fallback (claude -p haiku / opencode) → plan | ✅ done | RUN/TYPE/KEYS/OPEN; risky commands never auto-run |
| Overlay banner at top centre of Hyper window | ✅ done | hs.canvas, follows the window frame |
| Spoken feedback (macOS voice) | ✅ done | `speak` / `speakVoice` |
| Tap-to-talk hands-free (sox silence auto-stop) | ✅ done | `pauseStop`, `pauseLevel`, `handsFreeMax` |
| Any-LLM planner via OpenAI-compatible HTTP | ✅ done | `ai = "http"`, defaults to Ollama |
| Keystroke guard: Hyper must be frontmost | ✅ done | aborts after `focusTimeout` |
| Installer | ✅ done | idempotent, resumable model download |
| Cross-platform / MCP server | ⬜ not started | see Next |

## Done (most recent first)
- 2026-10-04 panel clamped to the Hyper window while dragging, parked when Hyper is not in front, 50 Hz follow; resize grip (width) and text-size commands; file-based dev hook (~/.voice-term/cmd.lua → cmd.out)
- 2026-10-04 assistant name (Fundi); project-folder matching and names in the AI context; volume-ducking fix (original level captured once); duplicate streamed lines fixed; global click watcher for dragging
- 2026-10-04 split into voice / voice_panel / voice_speech / voice_ai; conversation panel with streamed replies; sentence-by-sentence speech queue; six-turn memory
- 2026-10-04 SAY step: answers questions and greetings by voice; Groq documented as the fast free LLM; timers kept referenced (GC bug); hands-free pause 1.0 s
- 2026-10-04 Kenyan voices via edge-tts with on-disk cache and warm-up; banner drag fixed (elements need trackMouseDown); pin option
- 2026-10-04 draggable banner with remembered offset per window; Tessa (en_ZA) default voice with fallback; `banner()` test hook
- 2026-10-04 banner follows the Hyper window (20 Hz re-anchor, fades); claude -p start-up flags (12 s → ~5 s); tab one–five; speech crash fix
- 2026-10-04 tap-to-talk hands-free, spoken feedback, `http` LLM provider, frontmost guard, filler words, `plan()` dry run
- 2026-10-04 overlay banner, Hyper actions, plan steps, local chaining, `say()` test hook
- 2026-10-04 fix: child processes need USER so Claude Code can read its Keychain login
- 2026-10-04 first version: hold-to-talk, whisper, aliases, AI command conversion

## Next
0. Optional wake word ("Hey Fundi") via Picovoice Porcupine if the user wants it; not started.
1. User to add a Groq key (`ai = "http"`) for ~0.5 s free-form commands; collect misheard phrases from history.log into patterns.
2. Optional: a Hyper plugin that renders the banner inside the terminal DOM instead of a floating canvas.
3. **Cross-platform MCP server (proposed, not started).** Split the tool in two:
   - A small daemon (Python or Node) that owns the mic, hotkeys, whisper.cpp, text-to-speech and
     keystroke injection per OS (macOS: this Hammerspoon module can stay; Windows/Linux: pynput +
     sounddevice + platform key injection). It exposes MCP tools: `listen() → text`,
     `speak(text)`, `terminal(plan)`, `dictate(text)`.
   - Any MCP client (Claude Code, opencode, Cursor, Gemini CLI, a local Ollama agent) can then ask the
     user something by voice and act on the answer; the planner becomes the client's own model.
   - Estimate: 1–2 days for the daemon + MCP surface on macOS, plus per-OS work for Windows/Linux.
   Decide before starting: keep the push-to-talk hotkeys in the daemon (recommended) or let the
   client trigger listening.

## Decisions
- Hammerspoon beside Hyper rather than a Hyper plugin: a plugin cannot hold the mic or listen while Hyper is unfocused.
- Streaming: Claude Code via `--output-format stream-json --include-partial-messages`, HTTP providers via curl SSE; lines are acted on as they complete, so the first sentence is spoken before the reply ends.
- Hold-to-talk, no wake word: cannot be triggered by meetings or music; nothing is said aloud.
- Siri rejected: wake word, mishears in noise, no free-form shell commands.
- whisper small.en over base.en: noticeably better in noise; still fast enough.
- AI may press Enter only on steps it marks safe AND that pass a local blocklist.

## Assumptions
- Hyper keymaps are the ones in the user's ~/.hyper.js (⌘T, ⌘W, ⌃Tab, ⌃⇧E, ⌃⇧O, ⌃⇧K, ⌃⇧R).
- `claude` is logged in via the Keychain; `opencode` is optional.

## Known issues
- Dragging the panel: verified with synthetic events (moved and saved); the user should confirm with a real mouse.
- The `hs` CLI's IPC port jams after rapid or overlapping calls; use the cmd.lua hook for tests instead.
- Kenyan voices come from edge-tts (unofficial Microsoft endpoint, no key). First utterance of a phrase needs internet; cached afterwards. Offline fallback is Tessa.
- Hands-free auto-stop depends on `pauseLevel`; in a loud room it may run to `handsFreeMax` (20 s) before stopping.
- Free-form requests take as long as a `claude -p` round trip: ~4–6 s with the start-up flags, more on a slow network. `--bare` would be faster still but cannot see the Keychain login.
- Bluetooth headsets without volume control skip the ducking step.
- The Claude CLI prints permission-rule warnings on stderr; they are filtered out of the log.

## How to run
- `./install.sh`, grant Accessibility and Microphone, hold Right ⌥ and speak.
- `hs -c 'require("voice").say("…")'` runs a phrase without the mic.
