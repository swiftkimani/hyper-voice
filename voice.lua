-- voice.lua — push-to-talk voice control for the Hyper terminal, plus dictation anywhere.
--
-- Hold Right ⌥ (Option)  and speak → command mode: acts on Hyper (shortcuts, commands).
-- Hold Right ⌘ (Command) and speak → dictation: types the words into the app in front.
-- Press any other key while holding → cancel.
--
-- Speech-to-text is whisper.cpp running offline. Phrases are matched locally first;
-- anything unmatched is turned into a short plan by Claude Code (or opencode).
-- Status, what was heard and what was done are shown in an overlay at the top
-- centre of the Hyper window.

local M = {}
local home = os.getenv("HOME")

M.config = {
  ai = "claude",                       -- "claude" | "opencode" | "http" | "none"
  -- Flags that skip Claude Code's start-up work (MCP connectors, sessions, skills):
  -- they cut a voice command from ~12 s to ~5 s. Remove "--model","haiku" if haiku isn't on your plan.
  claudeArgs = { "--model", "haiku", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
    "--no-session-persistence", "--no-chrome", "--disable-slash-commands", "--setting-sources", "" },
  opencodeArgs = {},                   -- e.g. { "-m", "anthropic/claude-haiku-4-5" }
  -- ai = "http": any OpenAI-compatible chat endpoint. Works with Ollama (free, local),
  -- LM Studio, OpenAI, Groq, OpenRouter, Gemini's compatibility endpoint, etc.
  aiEndpoint = "http://127.0.0.1:11434/v1/chat/completions",
  aiModel = "llama3.2",
  aiApiKey = nil,                      -- or os.getenv("OPENAI_API_KEY") etc.
  model = home .. "/.voice-term/models/ggml-small.en.bin",
  terminalApp = "Hyper",
  commandKey = 61,                     -- right ⌥   (left ⌥ = 58)
  dictateKey = 54,                     -- right ⌘   (left ⌘ = 55)
  duckVolume = 10,                     -- speaker volume while listening (0–100)
  minSeconds = 0.4,                    -- shorter holds are ignored as accidental taps
  aiMayRun = true,                     -- let AI plans press Enter on commands it marks safe
  overlaySeconds = 4,                  -- how long the result stays on screen
  stepDelay = 0.22,                    -- pause between steps of a plan (seconds)
  speak = true,                        -- say a short confirmation out loud (macOS voice, offline)
  speakVoice = nil,                    -- nil = system default; see `say -v ?` for names
  focusTimeout = 4,                    -- seconds to wait for Hyper to come to the front
  tapToTalk = true,                    -- a quick tap (not hold) starts hands-free listening
  pauseStop = 1.5,                     -- hands-free: stop after this many seconds of silence
  pauseLevel = "2%",                   -- hands-free: what counts as silence (raise in noisy rooms)
  handsFreeMax = 20,                   -- hands-free: hard stop after this many seconds
  aiContext = "Projects live in ~/Desktop/projects. Home folders: ~/Desktop, ~/Downloads, ~/Documents.",
}

-- Terminal shortcuts the voice layer can press. Must match ~/.hyper.js keymaps.
M.actions = {
  ["tab:new"]              = { { "cmd" }, "t" },
  ["tab:close"]            = { { "cmd" }, "w" },
  ["tab:next"]             = { { "ctrl" }, "tab" },
  ["tab:prev"]             = { { "ctrl", "shift" }, "tab" },
  ["window:new"]           = { { "cmd" }, "n" },
  ["tab:jump1"]            = { { "cmd" }, "1" },
  ["tab:jump2"]            = { { "cmd" }, "2" },
  ["tab:jump3"]            = { { "cmd" }, "3" },
  ["tab:jump4"]            = { { "cmd" }, "4" },
  ["tab:jump5"]            = { { "cmd" }, "5" },
  ["pane:splitVertical"]   = { { "ctrl", "shift" }, "e" },
  ["pane:splitHorizontal"] = { { "ctrl", "shift" }, "o" },
  ["pane:next"]            = { { "cmd" }, "]" },
  ["pane:prev"]            = { { "cmd" }, "[" },
  ["editor:clearBuffer"]   = { { "ctrl", "shift" }, "k" },
  ["editor:interrupt"]     = { { "ctrl" }, "c" },
  ["editor:search"]        = { { "cmd" }, "f" },
  ["window:reload"]        = { { "ctrl", "shift" }, "r" },
}

-- Plan steps, one per line. Used by aliases, patterns and the AI alike:
--   KEYS <action>     press a terminal shortcut from M.actions
--   RUN  <command>    type a shell command into Hyper and press Enter
--   TYPE <command>    type a shell command into Hyper, do NOT press Enter
--   OPEN <app name>   open a macOS app

-- Exact phrases (lower-case, no punctuation). Value: a step, or a table of steps.
M.aliases = {
  ["go home"]         = "RUN cd ~",
  ["go back"]         = "RUN cd -",
  ["go up"]           = "RUN cd ..",
  ["list files"]      = "RUN ls -la",
  ["git status"]      = "RUN git status",
  ["git log"]         = "RUN git log --oneline -n 20",
  ["git diff"]        = "RUN git diff",
  ["git pull"]        = "RUN git pull",
  ["open here"]       = "RUN open .",
  ["start claude"]    = "RUN claude",
  ["start open code"] = "RUN opencode",
  ["start opencode"]  = "RUN opencode",
}

-- Substring patterns, checked in order, on each part of the phrase ("… and …").
M.patterns = {
  { "new tab",          "KEYS tab:new" },
  { "open a tab",       "KEYS tab:new" },
  { "another tab",      "KEYS tab:new" },
  { "close tab",        "KEYS tab:close" },
  { "close this tab",   "KEYS tab:close" },
  { "close the tab",    "KEYS tab:close" },
  { "next tab",         "KEYS tab:next" },
  { "previous tab",     "KEYS tab:prev" },
  { "last tab",         "KEYS tab:prev" },
  { "new window",       "KEYS window:new" },
  { "first tab",        "KEYS tab:jump1" },
  { "tab one",          "KEYS tab:jump1" },
  { "tab 1",            "KEYS tab:jump1" },
  { "second tab",       "KEYS tab:jump2" },
  { "tab two",          "KEYS tab:jump2" },
  { "tab 2",            "KEYS tab:jump2" },
  { "third tab",        "KEYS tab:jump3" },
  { "tab three",        "KEYS tab:jump3" },
  { "tab 3",            "KEYS tab:jump3" },
  { "fourth tab",       "KEYS tab:jump4" },
  { "tab four",         "KEYS tab:jump4" },
  { "tab 4",            "KEYS tab:jump4" },
  { "fifth tab",        "KEYS tab:jump5" },
  { "tab five",         "KEYS tab:jump5" },
  { "tab 5",            "KEYS tab:jump5" },
  { "split horizontal", "KEYS pane:splitHorizontal" },
  { "split down",       "KEYS pane:splitHorizontal" },
  { "split vertical",   "KEYS pane:splitVertical" },
  { "split side",       "KEYS pane:splitVertical" },
  { "split",            "KEYS pane:splitVertical" },
  { "next pane",        "KEYS pane:next" },
  { "previous pane",    "KEYS pane:prev" },
  { "clear",            "KEYS editor:clearBuffer" },
  { "interrupt",        "KEYS editor:interrupt" },
  { "stop that",        "KEYS editor:interrupt" },
  { "stop it",          "KEYS editor:interrupt" },
  { "reload hyper",     "KEYS window:reload" },
}

-- Words dropped before local matching, so "open a new hyper tab please" matches "new tab".
M.fillers = { "hyper", "terminal", "please", "a", "an", "the", "me", "up", "just", "now", "can", "you" }

-- Folder names understood by "go to <name>" / "cd to <name>" / "change to <name>".
M.places = {
  home = "~", downloads = "~/Downloads", desktop = "~/Desktop", documents = "~/Documents",
  projects = "~/Desktop/projects", root = "/", temp = "/tmp", tmp = "/tmp",
}

-- ---------------------------------------------------------------------------

local logDir  = home .. "/.voice-term"
local wavPath = logDir .. "/last.wav"
local logPath = logDir .. "/history.log"

local function findBin(names)
  for _, n in ipairs(names) do
    for _, dir in ipairs({ "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin" }) do
      local p = dir .. "/" .. n
      if hs.fs.attributes(p) then return p end
    end
  end
  return nil
end

local bin = {
  sox      = findBin({ "sox" }),
  whisper  = findBin({ "whisper-cli", "whisper-cpp" }),
  claude   = findBin({ "claude" }),
  opencode = findBin({ "opencode" }),
}

-- Child processes get a minimal but complete environment. USER is required:
-- Claude Code reads its login from the Keychain and reports "Not logged in" without it.
local env = {
  HOME = home,
  USER = os.getenv("USER") or home:match("([^/]+)$"),
  PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
  LANG = "en_US.UTF-8",
  TERM = "xterm-256color",
  SHELL = os.getenv("SHELL") or "/bin/zsh",
}

local function log(mode, heard, action)
  local f = io.open(logPath, "a")
  if f then
    f:write(os.date("%Y-%m-%d %H:%M:%S"), "\t", mode, "\t", (heard or ""):gsub("\n", " "), "\t",
      (action or ""):gsub("\n", " | "), "\n")
    f:close()
  end
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local function normalize(s) return trim(s:lower():gsub("[%p]", " "):gsub("%s+", " ")) end

local function lastUsefulLine(s)
  local last = ""
  for line in (s or ""):gmatch("[^\n]+") do
    if not line:find("Permission allow rule", 1, true) and trim(line) ~= "" then last = trim(line) end
  end
  return last
end

-- ---------------------------------------------------------------------------
-- Overlay: a small banner at the top centre of the Hyper window (or the screen)

local overlay = { canvas = nil, hideTimer = nil, followTimer = nil, lastKey = nil }

local function terminalWindow()
  local app = hs.application.find(M.config.terminalApp)
  if not app then return nil end
  local win = app:focusedWindow() or app:mainWindow() or app:allWindows()[1]
  if win and win:isVisible() and not win:isMinimized() then return win end
  return nil
end

local function overlayFrame()
  local target = terminalWindow() or hs.window.frontmostWindow()
  local f = target and target:frame() or hs.screen.mainScreen():frame()
  local w = math.min(640, math.max(320, f.w - 40))
  return { x = f.x + (f.w - w) / 2, y = f.y + 8, w = w }
end

-- Keep the banner glued to the terminal window: re-anchor whenever the window
-- moves, resizes, or changes screen. Cheap enough to run 20× a second.
local function overlayFollow()
  if not overlay.canvas or not overlay.canvas:isShowing() then return end
  local f = overlayFrame()
  local key = string.format("%d,%d,%d", f.x, f.y, f.w)
  if key == overlay.lastKey then return end
  overlay.lastKey = key
  local cur = overlay.canvas:frame()
  overlay.canvas:frame({ x = f.x, y = f.y, w = f.w, h = cur.h })
end

local function overlayShow(lines, color, seconds)
  local f = overlayFrame()
  local lineH, pad = 20, 10
  local h = pad * 2 + lineH * #lines
  if not overlay.canvas then
    overlay.canvas = hs.canvas.new({ x = 0, y = 0, w = 10, h = 10 })
    overlay.canvas:level(hs.canvas.windowLevels.floating)
    overlay.canvas:behavior({ "canJoinAllSpaces", "moveToActiveSpace" })
    overlay.followTimer = hs.timer.doEvery(0.05, overlayFollow)
  end
  local c = overlay.canvas
  overlay.lastKey = string.format("%d,%d,%d", f.x, f.y, f.w)
  c:frame({ x = f.x, y = f.y, w = f.w, h = h })
  c:replaceElements({
    { type = "rectangle", action = "fill", roundedRectRadii = { xRadius = 8, yRadius = 8 },
      fillColor = { red = 0.08, green = 0.09, blue = 0.11, alpha = 0.92 },
      strokeColor = { white = 1, alpha = 0.12 }, strokeWidth = 1, action = "strokeAndFill" },
    { type = "circle", action = "fill", center = { x = pad + 6, y = pad + lineH / 2 }, radius = 5,
      fillColor = color },
  })
  for i, line in ipairs(lines) do
    c:appendElements({
      type = "text", text = line,
      frame = { x = pad + 20, y = pad + lineH * (i - 1), w = f.w - pad * 2 - 20, h = lineH },
      textSize = 13, textColor = { white = 1, alpha = i == 1 and 1 or 0.75 },
      textFont = "Menlo", textLineBreak = "truncateTail",
    })
  end
  if not c:isShowing() then c:show(0.12) end
  if overlay.hideTimer then overlay.hideTimer:stop(); overlay.hideTimer = nil end
  if seconds then
    overlay.hideTimer = hs.timer.doAfter(seconds, function() c:hide(0.25) end)
  end
end

local function overlayHide()
  if overlay.hideTimer then overlay.hideTimer:stop(); overlay.hideTimer = nil end
  if overlay.canvas then overlay.canvas:hide(0.25) end
end

local colors = {
  listening = { red = 0.95, green = 0.26, blue = 0.21 },
  working   = { red = 0.98, green = 0.75, blue = 0.18 },
  done      = { red = 0.30, green = 0.80, blue = 0.45 },
  error     = { red = 0.95, green = 0.26, blue = 0.21 },
}

-- ---------------------------------------------------------------------------
-- Spoken feedback (macOS built-in voice, works offline)

local speaker = nil

local function speak(text)
  if not M.config.speak or not text or text == "" then return end
  if not speaker then
    -- hs.speech.new(nil) throws; only pass a voice when one is configured.
    speaker = M.config.speakVoice and hs.speech.new(M.config.speakVoice) or hs.speech.new()
    if not speaker then return end
  end
  if speaker:isSpeaking() then speaker:stop() end
  speaker:speak(text)
end

-- Short, human wording of a plan for the voice: "new tab, then cd Desktop".
local spokenAction = {
  ["tab:new"] = "new tab", ["tab:close"] = "close tab", ["tab:next"] = "next tab", ["tab:prev"] = "previous tab",
  ["window:new"] = "new window", ["tab:jump1"] = "tab one", ["tab:jump2"] = "tab two", ["tab:jump3"] = "tab three",
  ["tab:jump4"] = "tab four", ["tab:jump5"] = "tab five", ["pane:splitVertical"] = "split", ["pane:splitHorizontal"] = "split down",
  ["pane:next"] = "next pane", ["pane:prev"] = "previous pane", ["editor:clearBuffer"] = "clear",
  ["editor:interrupt"] = "interrupt", ["editor:search"] = "search", ["window:reload"] = "reload",
}

local function spokenSummary(steps)
  local parts = {}
  for _, s in ipairs(steps) do
    if s.kind == "KEYS" then table.insert(parts, spokenAction[s.arg] or s.arg)
    elseif s.kind == "RUN" then table.insert(parts, (s.arg:gsub("~/", ""):gsub("[%p]", " ")))
    elseif s.kind == "TYPE" then table.insert(parts, "typed, press return to run")
    elseif s.kind == "OPEN" then table.insert(parts, "opening " .. s.arg)
    end
  end
  return table.concat(parts, ", then ")
end

-- ---------------------------------------------------------------------------
-- Volume ducking

local savedVolume = nil

local function duck()
  local dev = hs.audiodevice.defaultOutputDevice()
  if not dev then return end
  savedVolume = dev:volume()
  if savedVolume and savedVolume > M.config.duckVolume then dev:setVolume(M.config.duckVolume) end
end

local function unduck()
  local dev = hs.audiodevice.defaultOutputDevice()
  if dev and savedVolume then dev:setVolume(savedVolume) end
  savedVolume = nil
end

-- ---------------------------------------------------------------------------
-- Plans: parsing and execution

local function parsePlan(text)
  local steps = {}
  if type(text) == "table" then
    for _, s in ipairs(text) do
      for _, sub in ipairs(parsePlan(s)) do table.insert(steps, sub) end
    end
    return steps
  end
  for line in (text or ""):gmatch("[^\n]+") do
    line = trim(line):gsub("^[%-%*%d%.]+%s+", "")
    local kind, arg = line:match("^(%u+)%s+(.+)$")
    if kind == "KEYS" and M.actions[trim(arg)] then
      table.insert(steps, { kind = "KEYS", arg = trim(arg) })
    elseif kind == "RUN" or kind == "TYPE" or kind == "OPEN" then
      table.insert(steps, { kind = kind, arg = trim(arg) })
    end
  end
  return steps
end

-- Commands an AI plan may never run unattended, whatever it claims.
local risky = { "^rm ", " rm ", "sudo", "kill", "pkill", "killall", "git push", "git reset", "git checkout",
  "git clean", "git rebase", "^mv ", " mv ", ">", "dd ", "chmod", "chown", "mkfs", "shutdown", "reboot",
  "curl", "wget", "brew ", "npm i", "pnpm ", "yarn ", "pip ", "cargo install", "eval", "diskutil", "truncate" }

local function isRisky(cmd)
  local c = " " .. cmd:lower() .. " "
  for _, r in ipairs(risky) do
    if r:sub(1, 1) == "^" then
      if cmd:lower():find(r:sub(2), 1, true) == 1 then return true end
    elseif c:find(r, 1, true) then return true end
  end
  return false
end

local function describe(steps)
  local parts = {}
  for _, s in ipairs(steps) do
    if s.kind == "KEYS" then
      local mods, key = table.unpack(M.actions[s.arg])
      local sym = { cmd = "⌘", ctrl = "⌃", shift = "⇧", alt = "⌥" }
      local label = ""
      for _, m in ipairs(mods) do label = label .. (sym[m] or m) end
      table.insert(parts, label .. key:upper())
    elseif s.kind == "RUN" then table.insert(parts, s.arg .. " ↵")
    elseif s.kind == "TYPE" then table.insert(parts, s.arg)
    elseif s.kind == "OPEN" then table.insert(parts, "open " .. s.arg)
    end
  end
  return table.concat(parts, "  ·  ")
end

local function focusTerminal()
  local app = hs.application.find(M.config.terminalApp)
  if app then app:activate(true) else hs.application.launchOrFocus(M.config.terminalApp) end
end

local function runStep(step)
  if step.kind == "KEYS" then
    local mods, key = table.unpack(M.actions[step.arg])
    focusTerminal()
    hs.eventtap.keyStroke(mods, key, 0)
  elseif step.kind == "RUN" or step.kind == "TYPE" then
    focusTerminal()
    hs.eventtap.keyStrokes(step.arg)
    if step.kind == "RUN" then hs.eventtap.keyStroke({}, "return", 0) end
  elseif step.kind == "OPEN" then
    hs.application.launchOrFocus(step.arg)
  end
end

local function needsTerminal(steps)
  for _, s in ipairs(steps) do if s.kind ~= "OPEN" then return true end end
  return false
end

local function terminalInFront()
  local app = hs.application.frontmostApplication()
  return app and app:name() == M.config.terminalApp
end

local function executePlan(steps, heard, mode)
  local summary = describe(steps)
  local i = 0
  local function nextStep()
    i = i + 1
    local step = steps[i]
    if not step then return end
    runStep(step)
    hs.timer.doAfter(M.config.stepDelay, nextStep)
  end
  local function go()
    log(mode, heard, summary)
    overlayShow({ "“" .. heard .. "”", summary }, colors.done, M.config.overlaySeconds)
    speak(spokenSummary(steps))
    nextStep()
  end
  if not needsTerminal(steps) then go(); return end
  -- Never send keystrokes until Hyper is actually the frontmost app, or they
  -- would land in whatever window the user is working in.
  focusTerminal()
  local waited = 0
  local poll
  poll = hs.timer.doEvery(0.1, function()
    waited = waited + 0.1
    if terminalInFront() then
      poll:stop()
      hs.timer.doAfter(0.15, go)
    elseif waited >= M.config.focusTimeout then
      poll:stop()
      log(mode, heard, "ABORTED: " .. M.config.terminalApp .. " did not come to the front")
      overlayShow({ "“" .. heard .. "”", "✗ " .. M.config.terminalApp .. " is not in front — nothing sent" }, colors.error, M.config.overlaySeconds)
      speak(M.config.terminalApp .. " is not in front")
    end
  end)
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
  local app = part:match("^open (.+)$") or part:match("^launch (.+)$")
  if app and not app:find("tab") and not app:find("window") then
    return parsePlan("OPEN " .. app:gsub("^the ", ""))
  end
  return nil
end

local function matchLocally(phrase)
  local plan = {}
  local parts = {}
  for part in (phrase .. " and "):gmatch("(.-) and ") do
    part = trim(part:gsub("^then ", ""))
    if part ~= "" then table.insert(parts, part) end
  end
  for _, part in ipairs(parts) do
    local steps = matchPart(part)
    if not steps then return nil end
    for _, s in ipairs(steps) do table.insert(plan, s) end
  end
  return #plan > 0 and plan or nil
end

-- ---------------------------------------------------------------------------
-- AI fallback

local function actionList()
  local names = {}
  for k in pairs(M.actions) do table.insert(names, k) end
  table.sort(names)
  return table.concat(names, ", ")
end

local aiPrompt = [[
You control the Hyper terminal on macOS by voice. Turn the spoken request into a short plan: one step per line, in order, nothing else.
Step types:
KEYS <action>    press a terminal shortcut. Allowed actions: %s
RUN <command>    type a zsh command and press Enter. Only for safe, read-only or navigation commands (cd, ls, pwd, cat, git status, git log, git diff, open, which, echo, mkdir).
TYPE <command>   type a zsh command WITHOUT pressing Enter. Use for anything that deletes, moves, kills, installs, pushes, overwrites, or is ambiguous.
OPEN <app name>  open a macOS application.
Rules: reply with plan lines only, no explanation, no markdown, no numbering. If nothing applies, reply with exactly: NONE
Context: %s
Spoken request: "%s"]]

local function finishAi(text, callback)
  text = trim((text or ""):gsub("```%w*", ""))
  if text == "" or text:upper() == "NONE" then callback(nil, "no action for that"); return end
  local steps = parsePlan(text)
  if #steps == 0 then callback(nil, "AI reply not understood: " .. text:sub(1, 60)); return end
  for _, s in ipairs(steps) do
    if s.kind == "RUN" and (not M.config.aiMayRun or isRisky(s.arg)) then s.kind = "TYPE" end
  end
  callback(steps)
end

local function askHttp(prompt, callback)
  local body = hs.json.encode({
    model = M.config.aiModel,
    temperature = 0,
    messages = { { role = "user", content = prompt } },
  })
  local headers = { ["Content-Type"] = "application/json" }
  if M.config.aiApiKey then headers["Authorization"] = "Bearer " .. M.config.aiApiKey end
  hs.http.asyncPost(M.config.aiEndpoint, body, headers, function(status, reply)
    if status ~= 200 then
      callback(nil, "LLM endpoint returned " .. tostring(status) .. (status <= 0 and " — is it running?" or ""))
      return
    end
    local ok, data = pcall(hs.json.decode, reply)
    local content = ok and data and data.choices and data.choices[1] and data.choices[1].message
      and data.choices[1].message.content
    if not content then callback(nil, "LLM reply had no content"); return end
    finishAi(content, callback)
  end)
end

local function askAi(heard, callback)
  local prompt = string.format(aiPrompt, actionList(), M.config.aiContext, heard)
  local path, args
  if M.config.ai == "http" then
    overlayShow({ "“" .. heard .. "”", "thinking…" }, colors.working)
    speak("thinking")
    askHttp(prompt, callback)
    return
  elseif M.config.ai == "claude" and bin.claude then
    path = bin.claude
    args = { "-p", prompt, "--output-format", "text", "--tools", "" }
    for _, a in ipairs(M.config.claudeArgs) do table.insert(args, a) end
  elseif M.config.ai == "opencode" and bin.opencode then
    path = bin.opencode
    args = { "run", "--pure" }
    for _, a in ipairs(M.config.opencodeArgs) do table.insert(args, a) end
    table.insert(args, prompt)
  else
    callback(nil, "no AI configured — add the phrase to M.aliases")
    return
  end
  overlayShow({ "“" .. heard .. "”", "thinking…" }, colors.working)
  speak("thinking")
  local t = hs.task.new(path, function(code, out, err)
    if code ~= 0 then callback(nil, lastUsefulLine(err) ~= "" and lastUsefulLine(err) or lastUsefulLine(out)); return end
    finishAi(out, callback)
  end, args)
  t:setEnvironment(env)
  t:setWorkingDirectory(home)
  t:start()
end

local function handleCommand(heard)
  local phrase = normalize(heard)
  local plan = matchLocally(phrase)
  if plan then executePlan(plan, heard, "command"); return end
  askAi(heard, function(steps, errMsg)
    if not steps then
      log("command", heard, "ERROR " .. (errMsg or ""))
      overlayShow({ "“" .. heard .. "”", "✗ " .. (errMsg or "failed") }, colors.error, M.config.overlaySeconds)
      speak("sorry, " .. (errMsg or "that failed"))
      return
    end
    executePlan(steps, heard, "command")
  end)
end

local function handleDictation(heard)
  log("dictate", heard, "typed")
  overlayShow({ "“" .. heard .. "”", "typed" }, colors.done, M.config.overlaySeconds)
  hs.eventtap.keyStrokes(heard)
end

-- ---------------------------------------------------------------------------
-- Recording and transcribing

local state = { mode = nil, task = nil, startedAt = nil, cancelled = false, handsFree = false,
  switchToHandsFree = nil, maxTimer = nil }

local function transcribe(mode)
  if not bin.whisper then overlayShow({ "whisper-cli not found — run install.sh" }, colors.error, 4); return end
  if not hs.fs.attributes(M.config.model) then
    overlayShow({ "speech model missing — run install.sh" }, colors.error, 4); return
  end
  overlayShow({ "transcribing…" }, colors.working)
  local t = hs.task.new(bin.whisper, function(code, out, err)
    if code ~= 0 then
      log(mode, "", "whisper failed: " .. lastUsefulLine(err))
      overlayShow({ "✗ transcription failed — see ~/.voice-term/history.log" }, colors.error, 4)
      return
    end
    local heard = trim((out or ""):gsub("%[.-%]", ""):gsub("%s+", " "))
    if heard == "" then
      overlayShow({ "heard nothing" }, colors.error, 2); log(mode, "", "silence"); speak("didn't catch that"); return
    end
    if mode == "command" then handleCommand(heard) else handleDictation(heard) end
  end, { "-m", M.config.model, "-f", wavPath, "-l", "en", "-nt", "-np", "-t", "4" })
  t:setEnvironment(env)
  t:start()
end

local function startRecording(mode, handsFree)
  if state.mode then return end
  if not bin.sox then overlayShow({ "sox not found — run install.sh" }, colors.error, 4); return end
  os.remove(wavPath)
  state.mode, state.cancelled, state.startedAt = mode, false, hs.timer.secondsSinceEpoch()
  state.handsFree, state.switchToHandsFree = handsFree or false, nil
  duck()
  local title = mode == "command" and "listening — command" or "listening — dictation"
  if handsFree then
    overlayShow({ title .. " · hands-free", "stops when you pause · tap again to stop · any key cancels" }, colors.listening)
  else
    overlayShow({ title, "release to send · tap instead of hold for hands-free · any key cancels" }, colors.listening)
  end
  local args = { "-q", "-d", "-c", "1", "-r", "16000", "-b", "16", wavPath, "highpass", "100" }
  if handsFree then
    -- sox waits for speech, then stops on the first pause of `pauseStop` seconds.
    for _, a in ipairs({ "silence", "1", "0.1", M.config.pauseLevel, "1", tostring(M.config.pauseStop), M.config.pauseLevel }) do
      table.insert(args, a)
    end
    state.maxTimer = hs.timer.doAfter(M.config.handsFreeMax, function()
      if state.task and state.handsFree then stopRecording() end
    end)
  end
  state.task = hs.task.new(bin.sox, function(code, out, err)
    local finished = state.mode
    local held = hs.timer.secondsSinceEpoch() - (state.startedAt or 0)
    local cancelled, switchTo = state.cancelled, state.switchToHandsFree
    if state.maxTimer then state.maxTimer:stop(); state.maxTimer = nil end
    state.mode, state.task, state.startedAt, state.handsFree = nil, nil, nil, false
    if switchTo then startRecording(switchTo, true); return end
    if cancelled then overlayShow({ "cancelled" }, colors.error, 1.5); return end
    if held < M.config.minSeconds then overlayHide(); return end
    if not hs.fs.attributes(wavPath) then
      log(finished, "", "no audio captured (mic permission?) " .. lastUsefulLine(err))
      overlayShow({ "✗ no audio — allow Microphone for Hammerspoon" }, colors.error, 4)
      return
    end
    transcribe(finished)
  end, args)
  state.task:setEnvironment(env)
  state.task:start()
end

local function stopRecording()
  if not state.task then return end
  unduck()
  state.task:terminate()   -- SIGTERM: sox finalises the wav, then the callback above runs
end

local function cancelRecording()
  if not state.task then return end
  state.cancelled = true
  stopRecording()
end

-- ---------------------------------------------------------------------------
-- Key handling

local keyToMode = {
  [M.config.commandKey] = { mode = "command", flag = "alt" },
  [M.config.dictateKey] = { mode = "dictate", flag = "cmd" },
}

M.flagsTap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(e)
  local spec = keyToMode[e:getKeyCode()]
  if not spec then return false end
  local down = e:getFlags()[spec.flag] == true
  if down then
    if state.mode == spec.mode and state.handsFree then
      stopRecording()                      -- second tap ends a hands-free session
    elseif not state.mode then
      startRecording(spec.mode)
    end
  elseif not down and state.mode == spec.mode and not state.handsFree then
    local held = hs.timer.secondsSinceEpoch() - (state.startedAt or 0)
    if M.config.tapToTalk and held < M.config.minSeconds then
      state.switchToHandsFree = spec.mode  -- a quick tap: restart in hands-free mode
      unduck()
      state.task:terminate()
    else
      stopRecording()
    end
  end
  return false
end)

M.keyTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
  if state.mode then cancelRecording() end
  return false
end)

-- Run a phrase as if it had been spoken (for testing from the hs CLI):
--   hs -c 'require("voice").say("open a new tab and go to desktop")'
function M.say(phrase) handleCommand(phrase) end

-- Dry run: what a phrase would do, without doing it. Local matches only (no AI).
--   hs -c 'return require("voice").plan("open a new hyper tab and cd to desktop")'
function M.plan(phrase)
  local steps = matchLocally(normalize(phrase))
  if not steps then return "no local match → would ask the AI" end
  return describe(steps) .. "   (speaks: " .. spokenSummary(steps) .. ")"
end

local function startTaps()
  M.flagsTap:start()
  M.keyTap:start()
  local missing = {}
  for _, n in ipairs({ "sox", "whisper" }) do if not bin[n] then table.insert(missing, n) end end
  if #missing > 0 then
    overlayShow({ "voice: missing " .. table.concat(missing, ", ") .. " — run install.sh" }, colors.error, 6)
  else
    overlayShow({ "voice ready", "hold Right ⌥ to command · Right ⌘ to dictate" }, colors.done, 3)
  end
end

function M.start()
  hs.fs.mkdir(logDir)
  if hs.accessibilityState(true) then startTaps(); return end
  -- Accessibility not granted yet: macOS has just shown its prompt. Poll until
  -- the user allows Hammerspoon, then start without needing a manual reload.
  overlayShow({ "allow Hammerspoon under Accessibility — it starts by itself after" }, colors.working, 8)
  M.waitTimer = hs.timer.doEvery(2, function()
    if hs.accessibilityState() then M.waitTimer:stop(); startTaps() end
  end)
end

M.start()
return M
