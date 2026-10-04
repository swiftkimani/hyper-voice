-- voice.lua — push-to-talk voice control for the Hyper terminal, plus dictation anywhere.
--
-- Hold Right ⌥ (Option)  and speak → command mode: acts on Hyper, answers questions.
-- Tap  Right ⌥             → hands-free: listens until you pause; tap again to stop.
-- Hold or tap Right ⌘      → dictation: types the words into the app in front.
-- Press any other key while listening → cancel.
--
-- Speech-to-text is whisper.cpp running offline. Phrases are matched locally
-- first; anything else goes to an LLM whose reply streams into a conversation
-- panel glued to the Hyper window and is spoken as it arrives.

local M = {}
local home = os.getenv("HOME")
local panel = require("voice_panel")
local speech = require("voice_speech")
local ai = require("voice_ai")

M.config = {
  name = "Fundi",                      -- what the assistant is called; say it before a phrase or not at all
  ai = "claude",                       -- "claude" | "opencode" | "http" | "none"
  -- Flags that skip Claude Code's start-up work (MCP connectors, sessions, skills). Drop "--model","haiku" if haiku isn't on your plan.
  claudeArgs = { "--model", "haiku", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
    "--no-session-persistence", "--no-chrome", "--disable-slash-commands", "--setting-sources", "" },
  opencodeArgs = {},
  -- ai = "http": any OpenAI-compatible endpoint. Fastest free option is Groq (free key at console.groq.com):
  --   ai = "http", aiEndpoint = "https://api.groq.com/openai/v1/chat/completions", aiModel = "llama-3.1-8b-instant", aiApiKey = "gsk_…"
  aiEndpoint = "http://127.0.0.1:11434/v1/chat/completions",
  aiModel = "llama3.2",
  aiApiKey = nil,
  aiContext = "Projects live in ~/Desktop/projects. Home folders: ~/Desktop, ~/Downloads, ~/Documents. The user is in Nairobi, Kenya.",
  historyTurns = 6,                    -- exchanges remembered for follow-up questions
  model = home .. "/.voice-term/models/ggml-small.en.bin",
  terminalApp = "Hyper",
  commandKey = 61,                     -- right ⌥   (left ⌥ = 58)
  dictateKey = 54,                     -- right ⌘   (left ⌘ = 55)
  duckVolume = 10,                     -- speaker volume while listening (0–100)
  minSeconds = 0.4,                    -- shorter holds count as a tap (hands-free)
  tapToTalk = true,
  pauseStop = 1.0,                     -- hands-free: stop after this many seconds of silence
  pauseLevel = "2%",                   -- hands-free: what counts as silence (raise in noisy rooms)
  handsFreeMax = 20,
  aiMayRun = true,                     -- let AI plans press Enter on commands it marks safe
  stepDelay = 0.22,
  focusTimeout = 4,
  panelLines = 6,                      -- exchanges visible in the panel
  panelSeconds = 6,                    -- how long the panel stays after the last activity
  panelPinned = false,                 -- true: never auto-hide
  speak = true,
  tts = "edge",                        -- "edge": Kenyan voices via edge-tts (online, cached) | "system": macOS voice (offline)
  edgeVoice = "en-KE-AsiliaNeural",    -- en-KE-ChilembaNeural (m) · sw-KE-ZuriNeural (f) · sw-KE-RafikiNeural (m)
  speakVoice = "Tessa",                -- macOS fallback voice
}

-- Terminal shortcuts the voice layer can press. Must match ~/.hyper.js keymaps.
M.actions = {
  ["tab:new"] = { { "cmd" }, "t" }, ["tab:close"] = { { "cmd" }, "w" },
  ["tab:next"] = { { "ctrl" }, "tab" }, ["tab:prev"] = { { "ctrl", "shift" }, "tab" },
  ["tab:jump1"] = { { "cmd" }, "1" }, ["tab:jump2"] = { { "cmd" }, "2" }, ["tab:jump3"] = { { "cmd" }, "3" },
  ["tab:jump4"] = { { "cmd" }, "4" }, ["tab:jump5"] = { { "cmd" }, "5" },
  ["window:new"] = { { "cmd" }, "n" },
  ["pane:splitVertical"] = { { "ctrl", "shift" }, "e" }, ["pane:splitHorizontal"] = { { "ctrl", "shift" }, "o" },
  ["pane:next"] = { { "cmd" }, "]" }, ["pane:prev"] = { { "cmd" }, "[" },
  ["editor:clearBuffer"] = { { "ctrl", "shift" }, "k" }, ["editor:interrupt"] = { { "ctrl" }, "c" },
  ["editor:search"] = { { "cmd" }, "f" }, ["window:reload"] = { { "ctrl", "shift" }, "r" },
}

-- Plan steps, one per line, shared by aliases, patterns and the AI:
--   KEYS <action> · RUN <command> (Enter) · TYPE <command> (no Enter) · OPEN <app> · SAY <sentence>
M.aliases = {
  ["hello"] = "SAY_HELLO", ["hi"] = "SAY_HELLO", ["who are you"] = "SAY_WHO", ["what is your name"] = "SAY_WHO",
  ["thank you"] = "SAY You're welcome.", ["thanks"] = "SAY Any time.",
  ["what time is it"] = "SAY_TIME", ["what is the time"] = "SAY_TIME",
  ["what is the date"] = "SAY_DATE", ["what day is it"] = "SAY_DATE",
  ["what can you do"] = "SAY I control Hyper by voice: tabs, panes, folders, git, and any command you describe. I can also answer questions.",
  ["go home"] = "RUN cd ~", ["go back"] = "RUN cd -", ["go up"] = "RUN cd ..",
  ["list files"] = "RUN ls -la", ["git status"] = "RUN git status",
  ["git log"] = "RUN git log --oneline -n 20", ["git diff"] = "RUN git diff", ["git pull"] = "RUN git pull",
  ["open here"] = "RUN open .", ["start claude"] = "RUN claude",
  ["start open code"] = "RUN opencode", ["start opencode"] = "RUN opencode",
}

M.patterns = {
  { "new tab", "KEYS tab:new" }, { "open a tab", "KEYS tab:new" }, { "another tab", "KEYS tab:new" },
  { "close tab", "KEYS tab:close" }, { "close this tab", "KEYS tab:close" }, { "close the tab", "KEYS tab:close" },
  { "next tab", "KEYS tab:next" }, { "previous tab", "KEYS tab:prev" }, { "last tab", "KEYS tab:prev" },
  { "new window", "KEYS window:new" },
  { "first tab", "KEYS tab:jump1" }, { "tab one", "KEYS tab:jump1" }, { "tab 1", "KEYS tab:jump1" },
  { "second tab", "KEYS tab:jump2" }, { "tab two", "KEYS tab:jump2" }, { "tab 2", "KEYS tab:jump2" },
  { "third tab", "KEYS tab:jump3" }, { "tab three", "KEYS tab:jump3" }, { "tab 3", "KEYS tab:jump3" },
  { "fourth tab", "KEYS tab:jump4" }, { "tab four", "KEYS tab:jump4" }, { "tab 4", "KEYS tab:jump4" },
  { "fifth tab", "KEYS tab:jump5" }, { "tab five", "KEYS tab:jump5" }, { "tab 5", "KEYS tab:jump5" },
  { "split horizontal", "KEYS pane:splitHorizontal" }, { "split down", "KEYS pane:splitHorizontal" },
  { "split vertical", "KEYS pane:splitVertical" }, { "split side", "KEYS pane:splitVertical" }, { "split", "KEYS pane:splitVertical" },
  { "next pane", "KEYS pane:next" }, { "previous pane", "KEYS pane:prev" },
  { "clear", "KEYS editor:clearBuffer" }, { "interrupt", "KEYS editor:interrupt" },
  { "stop that", "KEYS editor:interrupt" }, { "stop it", "KEYS editor:interrupt" }, { "reload hyper", "KEYS window:reload" },
}

M.fillers = { "hyper", "terminal", "please", "a", "an", "the", "me", "up", "just", "now", "can", "you" }

M.places = { home = "~", downloads = "~/Downloads", desktop = "~/Desktop", documents = "~/Documents",
  projects = "~/Desktop/projects", root = "/", temp = "/tmp", tmp = "/tmp" }

local spokenAction = {
  ["tab:new"] = "new tab", ["tab:close"] = "close tab", ["tab:next"] = "next tab", ["tab:prev"] = "previous tab",
  ["window:new"] = "new window", ["tab:jump1"] = "tab one", ["tab:jump2"] = "tab two", ["tab:jump3"] = "tab three",
  ["tab:jump4"] = "tab four", ["tab:jump5"] = "tab five", ["pane:splitVertical"] = "split",
  ["pane:splitHorizontal"] = "split down", ["pane:next"] = "next pane", ["pane:prev"] = "previous pane",
  ["editor:clearBuffer"] = "clear", ["editor:interrupt"] = "interrupt", ["editor:search"] = "search", ["window:reload"] = "reload",
}

-- ---------------------------------------------------------------------------

local logDir, wavPath, logPath = home .. "/.voice-term", home .. "/.voice-term/last.wav", home .. "/.voice-term/history.log"
local timers = {}
local function after(seconds, fn)
  local id = #timers + 1
  timers[id] = hs.timer.doAfter(seconds, function() timers[id] = nil; fn() end)
  return timers[id]
end

local function findBin(names)
  for _, n in ipairs(names) do
    for _, dir in ipairs({ "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin" }) do
      if hs.fs.attributes(dir .. "/" .. n) then return dir .. "/" .. n end
    end
  end
  return nil
end
local bin = { sox = findBin({ "sox" }), whisper = findBin({ "whisper-cli", "whisper-cpp" }) }
local env = { HOME = home, USER = os.getenv("USER") or home:match("([^/]+)$"),
  PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", LANG = "en_US.UTF-8" }

local function log(mode, heard, action)
  local f = io.open(logPath, "a")
  if f then
    f:write(os.date("%Y-%m-%d %H:%M:%S"), "\t", mode, "\t", (heard or ""):gsub("\n", " "), "\t", (action or ""):gsub("\n", " | "), "\n")
    f:close()
  end
end
local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local function normalize(s) return trim(s:lower():gsub("[%p]", " "):gsub("%s+", " ")) end

-- Names of the user's project folders, so "open design poc" can be matched
-- locally and the AI knows what exists.
local projectsDir = home .. "/Desktop/projects"
local function projectNames()
  local names = {}
  if not hs.fs.attributes(projectsDir) then return names end
  for entry in hs.fs.dir(projectsDir) do
    if entry:sub(1, 1) ~= "." and hs.fs.attributes(projectsDir .. "/" .. entry, "mode") == "directory" then
      table.insert(names, entry)
    end
  end
  table.sort(names)
  return names
end
local function slug(s) return (s:lower():gsub("[^%w]", "")) end
local function projectMatch(spoken)
  local want = slug(spoken)
  if want == "" then return nil end
  local best, bestLen
  for _, name in ipairs(projectNames()) do
    local have = slug(name)
    if have == want then return name end
    if (have:find(want, 1, true) or want:find(have, 1, true)) and (not bestLen or #have < bestLen) then best, bestLen = name, #have end
  end
  return best
end

local history = {}
local function remember(you, bot)
  table.insert(history, { you = you, bot = bot })
  while #history > M.config.historyTurns do table.remove(history, 1) end
end

-- ---------------------------------------------------------------------------
-- Plans

local function parseLine(line)
  line = trim(line):gsub("^[%-%*%d%.]+%s+", "")
  if line == "SAY_HELLO" then line = "SAY Hello, I'm " .. M.config.name .. ". I'm listening." end
  if line == "SAY_WHO" then line = "SAY I'm " .. M.config.name .. ", your terminal assistant." end
  if line == "SAY_TIME" then line = "SAY It is " .. os.date("%I:%M %p"):gsub("^0", "") end
  if line == "SAY_DATE" then line = "SAY Today is " .. os.date("%A, %d %B %Y") end
  local kind, arg = line:match("^(%u+)%s+(.+)$")
  if not kind then return nil end
  arg = trim(arg)
  if kind == "KEYS" then return M.actions[arg] and { kind = kind, arg = arg } or nil end
  if kind == "RUN" or kind == "TYPE" or kind == "OPEN" or kind == "SAY" then return { kind = kind, arg = arg } end
  return nil
end

local function parsePlan(text)
  local steps = {}
  if type(text) == "table" then
    for _, s in ipairs(text) do for _, sub in ipairs(parsePlan(s)) do table.insert(steps, sub) end end
    return steps
  end
  for line in (text or ""):gmatch("[^\n]+") do
    local step = parseLine(line)
    if step then table.insert(steps, step) end
  end
  return steps
end

local risky = { "^rm ", " rm ", "sudo", "kill", "pkill", "killall", "git push", "git reset", "git checkout", "git clean",
  "git rebase", "^mv ", " mv ", ">", "dd ", "chmod", "chown", "mkfs", "shutdown", "reboot", "curl", "wget", "brew ",
  "npm i", "pnpm ", "yarn ", "pip ", "cargo install", "eval", "diskutil", "truncate" }
local function isRisky(cmd)
  local c = " " .. cmd:lower() .. " "
  for _, r in ipairs(risky) do
    if r:sub(1, 1) == "^" then
      if cmd:lower():find(r:sub(2), 1, true) == 1 then return true end
    elseif c:find(r, 1, true) then return true end
  end
  return false
end

local function keyLabel(action)
  local mods, key = table.unpack(M.actions[action])
  local sym = { cmd = "⌘", ctrl = "⌃", shift = "⇧", alt = "⌥" }
  local label = ""
  for _, m in ipairs(mods) do label = label .. (sym[m] or m) end
  return label .. key:upper()
end

local function describeStep(s)
  if s.kind == "KEYS" then return keyLabel(s.arg) end
  if s.kind == "RUN" then return s.arg .. " ↵" end
  if s.kind == "TYPE" then return s.arg .. "  (press ↵ to run)" end
  if s.kind == "OPEN" then return "open " .. s.arg end
  return s.arg
end

local function describe(steps)
  local parts = {}
  for _, s in ipairs(steps) do table.insert(parts, describeStep(s)) end
  return table.concat(parts, "  ·  ")
end

local function spokenStep(s)
  if s.kind == "KEYS" then return spokenAction[s.arg] or s.arg end
  if s.kind == "RUN" then return (s.arg:gsub("~/", ""):gsub("[%p]", " ")) end
  if s.kind == "TYPE" then return "typed, press return to run" end
  if s.kind == "OPEN" then return "opening " .. s.arg end
  return s.arg
end

-- ---------------------------------------------------------------------------
-- Executing steps, one at a time, in order, with the Hyper-in-front guard

local function focusTerminal()
  local app = hs.application.find(M.config.terminalApp)
  if app then app:activate(true) else hs.application.launchOrFocus(M.config.terminalApp) end
end

local function terminalInFront()
  local app = hs.application.frontmostApplication()
  return app and app:name() == M.config.terminalApp
end

local function doStep(step)
  if step.kind == "KEYS" then
    local mods, key = table.unpack(M.actions[step.arg])
    hs.eventtap.keyStroke(mods, key, 0)
  elseif step.kind == "RUN" or step.kind == "TYPE" then
    hs.eventtap.keyStrokes(step.arg)
    if step.kind == "RUN" then hs.eventtap.keyStroke({}, "return", 0) end
  elseif step.kind == "OPEN" then
    hs.application.launchOrFocus(step.arg)
  elseif step.kind == "SAY" then
    speech.speak(step.arg)
  end
end

-- A queue so streamed lines run in order; terminal steps wait for Hyper to be in front.
local queue = { items = {}, running = false, focused = false }

local function runQueue()
  if queue.running then return end
  local step = table.remove(queue.items, 1)
  if not step then return end
  queue.running = true
  local needsTerminal = step.kind == "KEYS" or step.kind == "RUN" or step.kind == "TYPE"
  local function go()
    doStep(step)
    after(step.kind == "SAY" and 0.05 or M.config.stepDelay, function() queue.running = false; runQueue() end)
  end
  if not needsTerminal or queue.focused and terminalInFront() then go(); return end
  focusTerminal()
  local waited = 0
  timers.focusPoll = hs.timer.doEvery(0.1, function()
    waited = waited + 0.1
    if terminalInFront() then
      timers.focusPoll:stop(); timers.focusPoll = nil
      queue.focused = true
      after(0.15, go)
    elseif waited >= M.config.focusTimeout then
      timers.focusPoll:stop(); timers.focusPoll = nil
      queue.items, queue.running = {}, false
      panel.add("hyper", "✗ " .. M.config.terminalApp .. " is not in front — nothing sent")
      speech.speak(M.config.terminalApp .. " is not in front")
    end
  end)
end

local function enqueue(step)
  table.insert(queue.items, step)
  runQueue()
end

-- Run a whole local plan: show it, speak it, do it.
local function executePlan(steps, heard)
  queue.focused = false
  local summary = describe(steps)
  log("command", heard, summary)
  panel.add("hyper", summary)
  local hasSay = false
  for _, s in ipairs(steps) do if s.kind == "SAY" then hasSay = true end end
  if not hasSay then
    local parts = {}
    for _, s in ipairs(steps) do table.insert(parts, spokenStep(s)) end
    speech.speak(table.concat(parts, ", then "))
  end
  for _, s in ipairs(steps) do enqueue(s) end
  remember(heard, summary)
  panel.clearStatus()
end

-- ---------------------------------------------------------------------------
-- Local matching (no AI)

local function stripFillers(part)
  local words = {}
  for w in part:gmatch("%S+") do
    local keep = true
    for _, f in ipairs(M.fillers) do if w == f then keep = false; break end end
    if keep then table.insert(words, w) end
  end
  return table.concat(words, " ")
end

local function matchPart(part)
  local alias = M.aliases[part] or M.aliases[stripFillers(part)]
  if alias then return parsePlan(alias) end
  local lean = stripFillers(part)
  for _, p in ipairs(M.patterns) do
    if lean:find(p[1], 1, true) or part:find(p[1], 1, true) then return parsePlan(p[2]) end
  end
  part = lean
  local place = part:match("^go to (.+)$") or part:match("^cd to (.+)$") or part:match("^cd (.+)$")
    or part:match("^change to (.+)$") or part:match("^change directory to (.+)$")
  if place then
    place = place:gsub("^the ", ""):gsub(" folder$", ""):gsub(" directory$", "")
    if M.places[place] then return parsePlan("RUN cd " .. M.places[place]) end
    return nil
  end
  local proj = part:match("^open project (.+)$") or part:match("^open (.+) project$") or part:match("^go to project (.+)$")
    or part:match("^project (.+)$")
  if proj then
    local name = projectMatch(proj)
    if name then return parsePlan("RUN cd " .. projectsDir .. "/" .. name) end
  end
  if part == "run claude" or part == "start claude" or part == "open claude" then return parsePlan("RUN claude") end
  local app = part:match("^open (.+)$") or part:match("^launch (.+)$")
  if app and not app:find("tab") and not app:find("window") then
    local name = projectMatch(app)
    if name then return parsePlan("RUN cd " .. projectsDir .. "/" .. name) end
    return parsePlan("OPEN " .. app:gsub("^the ", ""))
  end
  return nil
end

local function matchLocally(phrase)
  local plan = {}
  for part in (phrase .. " and "):gmatch("(.-) and ") do
    part = trim(part:gsub("^then ", ""))
    if part ~= "" then
      local steps = matchPart(part)
      if not steps then return nil end
      for _, s in ipairs(steps) do table.insert(plan, s) end
    end
  end
  return #plan > 0 and plan or nil
end

-- ---------------------------------------------------------------------------
-- AI path: lines stream in; SAY lines are spoken and shown as they complete,
-- action lines run in order.

local function actionList()
  local names = {}
  for k in pairs(M.actions) do table.insert(names, k) end
  table.sort(names)
  return table.concat(names, ", ")
end

local function pretty(line)
  local step = parseLine(line)
  if step then return describeStep(step) end
  return line
end

local function askAi(heard)
  queue.focused = false
  panel.status("thinking", "working", true)
  speech.speak("thinking")
  local done = {}
  ai.ask(heard, history, {
    onPartial = function(partial)
      if partial == "" then return end
      local shown = partial:gsub("^%u+%s+", "")
      panel.streamSet(shown)
    end,
    onLine = function(line)
      local step = parseLine(line)
      panel.endStream()
      if #done == 0 then panel.status("answering", "working", true) end
      if not step then return end
      if step.kind == "RUN" and (not M.config.aiMayRun or isRisky(step.arg)) then step.kind = "TYPE" end
      panel.add("hyper", describeStep(step))
      table.insert(done, describeStep(step))
      enqueue(step)
    end,
    onDone = function(full)
      panel.endStream()
      panel.clearStatus()
      if #done == 0 then
        panel.add("hyper", "✗ I couldn't turn that into anything")
        speech.speak("sorry, I couldn't turn that into anything")
        log("command", heard, "ERROR unusable reply: " .. full:sub(1, 80))
        return
      end
      local summary = table.concat(done, "  ·  ")
      log("command", heard, summary)
      remember(heard, summary)
    end,
    onError = function(msg)
      panel.endStream()
      panel.clearStatus()
      panel.add("hyper", "✗ " .. (msg or "failed"))
      speech.speak("sorry, that failed")
      log("command", heard, "ERROR " .. (msg or ""))
    end,
  })
end

local function stripName(heard)
  local n = M.config.name:lower()
  local h = heard:gsub("^%s*[Hh]ey[,%s]+", "")
  local lower = h:lower()
  if lower:sub(1, #n) == n then h = h:sub(#n + 1):gsub("^[,%s]+", "") end
  return h ~= "" and h or heard
end

local function handleCommand(heard)
  speech.stop()
  heard = stripName(heard)
  panel.add("you", heard)
  local plan = matchLocally(normalize(heard))
  if plan then executePlan(plan, heard) else askAi(heard) end
end

local function handleDictation(heard)
  log("dictate", heard, "typed")
  panel.add("you", heard)
  panel.add("hyper", "typed", true)
  panel.clearStatus()
  hs.eventtap.keyStrokes(heard)
end

-- ---------------------------------------------------------------------------
-- Recording and transcribing

local state = { mode = nil, task = nil, startedAt = nil, cancelled = false, handsFree = false, switchToHandsFree = nil }
local savedVolume = nil

-- Lower the speakers while listening. The original level is captured once and
-- kept until it is restored, so a quick tap-then-hands-free restart cannot
-- mistake the ducked level for the original.
local function duck()
  local dev = hs.audiodevice.defaultOutputDevice()
  if not dev then return end
  if savedVolume == nil then
    local v = dev:volume()
    if not v or v <= M.config.duckVolume then return end
    savedVolume = v
  end
  dev:setVolume(M.config.duckVolume)
end

local function unduck()
  local dev = hs.audiodevice.defaultOutputDevice()
  if dev and savedVolume then dev:setVolume(savedVolume) end
  savedVolume = nil
end

local function transcribe(mode)
  if not bin.whisper then panel.status("whisper-cli not found — run install.sh", "error"); return end
  if not hs.fs.attributes(M.config.model) then panel.status("speech model missing — run install.sh", "error"); return end
  panel.status("transcribing", "working", true)
  local t = hs.task.new(bin.whisper, function(code, out, err)
    if code ~= 0 then
      log(mode, "", "whisper failed: " .. trim(err or ""))
      panel.status("✗ transcription failed — see history.log", "error")
      after(3, panel.clearStatus)
      return
    end
    local heard = trim((out or ""):gsub("%[.-%]", ""):gsub("%s+", " "))
    if heard == "" then
      panel.status("heard nothing", "error"); log(mode, "", "silence"); speech.speak("didn't catch that")
      after(2, panel.clearStatus); return
    end
    if mode == "command" then handleCommand(heard) else handleDictation(heard) end
  end, { "-m", M.config.model, "-f", wavPath, "-l", "en", "-nt", "-np", "-t", "4" })
  t:setEnvironment(env)
  t:start()
end

local function stopRecording()
  if not state.task then return end
  unduck()
  state.task:terminate()
end

local function startRecording(mode, handsFree)
  if state.mode then return end
  if not bin.sox then panel.status("sox not found — run install.sh", "error"); return end
  os.remove(wavPath)
  state.mode, state.cancelled, state.startedAt = mode, false, hs.timer.secondsSinceEpoch()
  state.handsFree, state.switchToHandsFree = handsFree or false, nil
  speech.stop()
  duck()
  local title = mode == "command" and "listening" or "listening — dictation"
  panel.status(handsFree and (title .. " · hands-free, stops when you pause · tap to stop") or (title .. " · release to send · tap for hands-free"), "listening")
  local args = { "-q", "-d", "-c", "1", "-r", "16000", "-b", "16", wavPath, "highpass", "100" }
  if handsFree then
    for _, a in ipairs({ "silence", "1", "0.1", M.config.pauseLevel, "1", tostring(M.config.pauseStop), M.config.pauseLevel }) do table.insert(args, a) end
    timers.maxTimer = hs.timer.doAfter(M.config.handsFreeMax, function() if state.task and state.handsFree then stopRecording() end end)
  end
  state.task = hs.task.new(bin.sox, function(_, _, err)
    local finished = state.mode
    local held = hs.timer.secondsSinceEpoch() - (state.startedAt or 0)
    local cancelled, switchTo = state.cancelled, state.switchToHandsFree
    if timers.maxTimer then timers.maxTimer:stop(); timers.maxTimer = nil end
    state.mode, state.task, state.startedAt, state.handsFree = nil, nil, nil, false
    if switchTo then startRecording(switchTo, true); return end
    if cancelled then panel.status("cancelled", "error"); after(1.5, panel.clearStatus); return end
    if held < M.config.minSeconds then panel.clearStatus(); return end
    if not hs.fs.attributes(wavPath) then
      log(finished, "", "no audio captured (mic permission?) " .. trim(err or ""))
      panel.status("✗ no audio — allow Microphone for Hammerspoon", "error")
      after(4, panel.clearStatus)
      return
    end
    transcribe(finished)
  end, args)
  state.task:setEnvironment(env)
  state.task:start()
end

local function cancelRecording()
  if not state.task then return end
  state.cancelled = true
  stopRecording()
end

-- ---------------------------------------------------------------------------
-- Keys

local keyToMode = {
  [M.config.commandKey] = { mode = "command", flag = "alt" },
  [M.config.dictateKey] = { mode = "dictate", flag = "cmd" },
}

M.flagsTap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(e)
  local spec = keyToMode[e:getKeyCode()]
  if not spec then return false end
  local down = e:getFlags()[spec.flag] == true
  if down then
    if state.mode == spec.mode and state.handsFree then stopRecording()
    elseif not state.mode then startRecording(spec.mode) end
  elseif not down and state.mode == spec.mode and not state.handsFree then
    local held = hs.timer.secondsSinceEpoch() - (state.startedAt or 0)
    if M.config.tapToTalk and held < M.config.minSeconds then
      state.switchToHandsFree = spec.mode   -- stay ducked across the restart
      state.task:terminate()
    else
      stopRecording()
    end
  end
  return false
end)

M.keyTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function()
  if state.mode then cancelRecording() end
  return false
end)

-- ---------------------------------------------------------------------------
-- Hooks for testing from the hs command line

function M.say(phrase) handleCommand(phrase) end                      -- run a phrase as if spoken
function M.plan(phrase)                                               -- dry run, local matches only
  local steps = matchLocally(normalize(stripName(phrase)))
  if not steps then return "no local match → would ask the AI" end
  return describe(steps)
end
function M.say_text(text) speech.speak(text) end                      -- try the voice
function M.banner(text) panel.add("hyper", text or "banner test") end -- show the panel
function M.pin(on) M.config.panelPinned = on ~= false; panel.pin(on) end
function M.resetBanner() panel.resetPosition() end
function M.panelFrame() local f = panel.frame(); return f and string.format("%d,%d,%d,%d", f.x, f.y, f.w, f.h) or "hidden" end
function M.forget() history = {} end                                  -- clear conversation memory

local function startTaps()
  M.flagsTap:start()
  M.keyTap:start()
  local missing = {}
  for _, n in ipairs({ "sox", "whisper" }) do if not bin[n] then table.insert(missing, n) end end
  if #missing > 0 then
    panel.status("voice: missing " .. table.concat(missing, ", ") .. " — run install.sh", "error")
  else
    panel.status(M.config.name .. " ready — hold or tap Right ⌥ to talk", "done")
    after(3, panel.clearStatus)
  end
end

function M.start()
  hs.fs.mkdir(logDir)
  panel.configure({ terminalApp = M.config.terminalApp, lines = M.config.panelLines, seconds = M.config.panelSeconds, pinned = M.config.panelPinned, botLabel = M.config.name:lower() })
  speech.configure({ enabled = M.config.speak, tts = M.config.tts, edgeVoice = M.config.edgeVoice, systemVoice = M.config.speakVoice })
  ai.configure({ ai = M.config.ai, claudeArgs = M.config.claudeArgs, opencodeArgs = M.config.opencodeArgs,
    aiEndpoint = M.config.aiEndpoint, aiModel = M.config.aiModel, aiApiKey = M.config.aiApiKey,
    context = "Your name is " .. M.config.name .. ". " .. M.config.aiContext .. " Project folders under ~/Desktop/projects: " .. table.concat(projectNames(), ", ") ..
      ". 'run claude' means RUN claude; 'run opencode' means RUN opencode.", actions = actionList() })
  speech.warm({ "thinking", "didn't catch that", "cancelled", "new tab", "close tab", "clear",
    "typed, press return to run", "Hyper is not in front", "next tab", "split", "sorry, that failed" })
  if hs.accessibilityState(true) then startTaps(); return end
  panel.status("allow Hammerspoon under Accessibility — it starts by itself after", "working")
  timers.wait = hs.timer.doEvery(2, function()
    if hs.accessibilityState() then timers.wait:stop(); startTaps() end
  end)
end

M.start()
return M
