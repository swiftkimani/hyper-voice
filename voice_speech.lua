-- voice_speech.lua — talking back. Kenyan voices through edge-tts with an
-- on-disk cache and a playback queue, the macOS voice as offline fallback.

local S = {}
local home = os.getenv("HOME")
local cfg = { enabled = true, tts = "edge", edgeVoice = "en-KE-AsiliaNeural", systemVoice = "Tessa" }
local cacheDir = home .. "/.voice-term/tts-cache"
local env = { HOME = home, USER = os.getenv("USER") or home:match("([^/]+)$"),
  PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", LANG = "en_US.UTF-8" }

local state = { speaker = nil, playing = nil, queue = {}, busy = false, edge = nil, timers = {} }

function S.configure(options)
  for k, v in pairs(options or {}) do cfg[k] = v end
end

local function findEdgeTts()
  local candidates = { "/opt/homebrew/bin/edge-tts", "/usr/local/bin/edge-tts" }
  local pyDir = home .. "/Library/Python"
  if hs.fs.attributes(pyDir) then
    for entry in hs.fs.dir(pyDir) do
      if entry ~= "." and entry ~= ".." then table.insert(candidates, pyDir .. "/" .. entry .. "/bin/edge-tts") end
    end
  end
  for _, c in ipairs(candidates) do if hs.fs.attributes(c) then return c end end
  return nil
end
state.edge = findEdgeTts()

function S.available() return state.edge ~= nil end

local function phraseHash(str)
  local h = 5381
  for i = 1, #str do h = (h * 33 + str:byte(i)) % 4294967296 end
  return string.format("%08x", h)
end

local function voiceByName(name)
  if not name or name == "" then return nil end
  local ok, voices = pcall(hs.speech.availableVoices, true)
  if not ok or not voices then return nil end
  for _, id in ipairs(voices) do
    if id:lower():find(name:lower(), 1, true) then
      local ok2, sp = pcall(hs.speech.new, id)
      if ok2 and sp then return sp end
    end
  end
  return nil
end

local playNext

local function speakSystem(text, done)
  if not state.speaker then
    state.speaker = voiceByName(cfg.systemVoice) or hs.speech.new()
    if not state.speaker then done(); return end
    state.speaker:setCallback(function(_, event) if event == "didFinish" then playNext() end end)
  end
  if state.speaker:isSpeaking() then state.speaker:stop() end
  state.speaker:speak(text)
end

local function playFile(path)
  state.playing = hs.sound.getByFile(path)
  if not state.playing then playNext(); return end
  state.playing:setCallback(function() playNext() end)
  state.playing:play()
end

-- Synthesise into the cache (or hit it), then play. Falls back to the system voice.
local function speakEdge(text, onlyCache)
  hs.fs.mkdir(cacheDir)
  local path = string.format("%s/%s-%s.mp3", cacheDir, cfg.edgeVoice, phraseHash(text))
  if hs.fs.attributes(path) then
    if onlyCache then playNext() else playFile(path) end
    return
  end
  local t = hs.task.new(state.edge, function(code)
    if code == 0 and hs.fs.attributes(path) then
      if onlyCache then playNext() else playFile(path) end
    else
      os.remove(path)
      if onlyCache then playNext() else speakSystem(text, playNext) end
    end
  end, { "--voice", cfg.edgeVoice, "--text", text, "--write-media", path })
  t:setEnvironment(env)
  if not t:start() then playNext() end
end

playNext = function()
  local item = table.remove(state.queue, 1)
  if not item then state.busy = false; return end
  state.busy = true
  if cfg.tts == "edge" and state.edge then speakEdge(item.text, item.onlyCache) else speakSystem(item.text, playNext) end
end

-- Queue a sentence. Sentences play in order, so streamed replies sound continuous.
function S.speak(text, onlyCache)
  if not cfg.enabled and not onlyCache then return end
  text = (text or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return end
  table.insert(state.queue, { text = text, onlyCache = onlyCache })
  if not state.busy then playNext() end
end

-- Drop everything queued and stop the current utterance.
function S.stop()
  state.queue = {}
  if state.playing then pcall(function() state.playing:stop() end) end
  if state.speaker and state.speaker:isSpeaking() then state.speaker:stop() end
  state.busy = false
end

-- Pre-synthesise frequent phrases so they are instant the first time.
function S.warm(phrases)
  if cfg.tts ~= "edge" or not state.edge then return end
  for _, p in ipairs(phrases) do S.speak(p, true) end
end

return S
