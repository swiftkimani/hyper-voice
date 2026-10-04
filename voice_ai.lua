-- voice_ai.lua — turns a spoken request into plan lines, streamed as they
-- arrive. Providers: Claude Code (`claude -p`), opencode, or any
-- OpenAI-compatible HTTP endpoint (Groq, Ollama, OpenAI…).

local A = {}
local home = os.getenv("HOME")
local cfg = { ai = "claude", claudeArgs = {}, opencodeArgs = {}, aiEndpoint = "", aiModel = "", aiApiKey = nil,
  context = "", actions = "" }
local env = { HOME = home, USER = os.getenv("USER") or home:match("([^/]+)$"),
  PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", LANG = "en_US.UTF-8", TERM = "xterm-256color" }

local function findBin(name)
  for _, dir in ipairs({ "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin" }) do
    if hs.fs.attributes(dir .. "/" .. name) then return dir .. "/" .. name end
  end
  return nil
end
local bin = { claude = findBin("claude"), opencode = findBin("opencode"), curl = "/usr/bin/curl" }

function A.configure(options)
  for k, v in pairs(options or {}) do cfg[k] = v end
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function lastUsefulLine(s)
  local last = ""
  for line in (s or ""):gmatch("[^\n]+") do
    if not line:find("Permission allow rule", 1, true) and trim(line) ~= "" then last = trim(line) end
  end
  return last
end

local template = [[
You are the voice assistant inside the Hyper terminal on macOS. Turn the spoken request into a short plan: one step per line, in order, nothing else.
Step types:
KEYS <action>    press a terminal shortcut. Allowed actions: %s
RUN <command>    type a zsh command and press Enter. Only for safe, read-only or navigation commands (cd, ls, pwd, cat, git status, git log, git diff, open, which, echo, mkdir).
TYPE <command>   type a zsh command WITHOUT pressing Enter. Use for anything that deletes, moves, kills, installs, pushes, overwrites, or is ambiguous.
OPEN <app name>  open a macOS application.
SAY <sentence>   speak a reply. Use it to answer questions, greet, explain briefly, or confirm. Keep each SAY to one short sentence; use several SAY lines for longer answers so they can be spoken as they arrive.
Rules: plan lines only, no explanation, no markdown, no numbering. Every request gets at least one line; questions and chat are answered with SAY. Put SAY lines first when there are actions too.
Context: %s
%s
Spoken request: "%s"]]

local function historyBlock(history)
  if not history or #history == 0 then return "" end
  local lines = { "Recent conversation (oldest first):" }
  for _, h in ipairs(history) do
    table.insert(lines, "You: " .. h.you)
    table.insert(lines, "Assistant: " .. h.bot)
  end
  return table.concat(lines, "\n")
end

function A.prompt(heard, history)
  return string.format(template, cfg.actions, cfg.context, historyBlock(history), heard)
end

-- Feed stream chunks; emits each completed line and the live partial line.
local function lineSplitter(callbacks)
  local text, emitted = "", 0
  return {
    push = function(delta)
      if delta == "" then return end
      text = text .. delta
      local lines = {}
      for line in (text .. "\n"):gmatch("(.-)\n") do table.insert(lines, line) end
      local complete = #lines - 1
      for i = emitted + 1, complete do
        if trim(lines[i]) ~= "" then callbacks.onLine(trim(lines[i])) end
      end
      emitted = complete
      callbacks.onPartial(trim(lines[#lines] or ""))
    end,
    finish = function()
      local tail = trim(text:match("([^\n]*)$") or "")
      if tail ~= "" and (emitted < select(2, (text .. "\n"):gsub("\n", "")) ) then callbacks.onLine(tail) end
      return text
    end,
    text = function() return text end,
  }
end

-- Claude Code streams JSON lines; text arrives in content_block_delta events.
local function askClaude(prompt, callbacks)
  local args = { "-p", prompt, "--output-format", "stream-json", "--verbose", "--include-partial-messages", "--tools", "" }
  for _, a in ipairs(cfg.claudeArgs) do table.insert(args, a) end
  local split = lineSplitter(callbacks)
  local pending, stderrAll = "", ""
  local t = hs.task.new(bin.claude, function(code, _, err)
    local full = split.finish()
    if code ~= 0 and full == "" then
      callbacks.onError(lastUsefulLine(err ~= "" and err or stderrAll))
    else
      callbacks.onDone(full)
    end
  end, function(_, out, err)
    stderrAll = stderrAll .. (err or "")
    pending = pending .. (out or "")
    while true do
      local nl = pending:find("\n", 1, true)
      if not nl then break end
      local line = pending:sub(1, nl - 1)
      pending = pending:sub(nl + 1)
      local ok, msg = pcall(hs.json.decode, line)
      if ok and type(msg) == "table" and msg.type == "stream_event" then
        local ev = msg.event
        if ev and ev.type == "content_block_delta" and ev.delta and ev.delta.text then split.push(ev.delta.text) end
      end
    end
    return true
  end, args)
  t:setEnvironment(env)
  t:setWorkingDirectory(home)
  t:start()
end

-- opencode has no token stream in `run`; deliver its output when it finishes.
local function askOpencode(prompt, callbacks)
  local args = { "run", "--pure" }
  for _, a in ipairs(cfg.opencodeArgs) do table.insert(args, a) end
  table.insert(args, prompt)
  local split = lineSplitter(callbacks)
  local t = hs.task.new(bin.opencode, function(code, out, err)
    if code ~= 0 then callbacks.onError(lastUsefulLine(err)); return end
    split.push(trim((out or ""):gsub("```%w*", "")))
    callbacks.onDone(split.finish())
  end, args)
  t:setEnvironment(env)
  t:start()
end

-- OpenAI-compatible SSE via curl, so Groq/Ollama/OpenAI all stream.
local function askHttp(prompt, callbacks)
  local body = hs.json.encode({ model = cfg.aiModel, temperature = 0, stream = true,
    messages = { { role = "user", content = prompt } } })
  local args = { "-sN", "--max-time", "60", "-H", "Content-Type: application/json" }
  if cfg.aiApiKey then table.insert(args, "-H"); table.insert(args, "Authorization: Bearer " .. cfg.aiApiKey) end
  table.insert(args, "-d"); table.insert(args, body); table.insert(args, cfg.aiEndpoint)
  local split = lineSplitter(callbacks)
  local pending, raw = "", ""
  local t = hs.task.new(bin.curl, function(code, _, err)
    local full = split.finish()
    if full == "" then
      local ok, msg = pcall(hs.json.decode, raw)
      local detail = ok and type(msg) == "table" and msg.error and (msg.error.message or msg.error) or nil
      callbacks.onError(detail and tostring(detail) or (code ~= 0 and ("curl exit " .. code .. " " .. lastUsefulLine(err)) or "empty reply from the LLM endpoint"))
    else
      callbacks.onDone(full)
    end
  end, function(_, out)
    raw = raw .. (out or "")
    pending = pending .. (out or "")
    while true do
      local nl = pending:find("\n", 1, true)
      if not nl then break end
      local line = trim(pending:sub(1, nl - 1))
      pending = pending:sub(nl + 1)
      local data = line:match("^data:%s*(.+)$")
      if data and data ~= "[DONE]" then
        local ok, msg = pcall(hs.json.decode, data)
        local delta = ok and type(msg) == "table" and msg.choices and msg.choices[1] and msg.choices[1].delta
          and msg.choices[1].delta.content
        if delta then split.push(delta) end
      end
    end
    return true
  end, args)
  t:setEnvironment(env)
  t:start()
end

-- callbacks: onLine(line), onPartial(text), onDone(fullText), onError(message)
function A.ask(heard, history, callbacks)
  local prompt = A.prompt(heard, history)
  if cfg.ai == "claude" and bin.claude then return askClaude(prompt, callbacks) end
  if cfg.ai == "opencode" and bin.opencode then return askOpencode(prompt, callbacks) end
  if cfg.ai == "http" and cfg.aiEndpoint ~= "" then return askHttp(prompt, callbacks) end
  callbacks.onError("no AI configured — add the phrase to M.aliases or set ai in voice.lua")
end

return A
