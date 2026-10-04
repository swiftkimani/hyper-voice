-- voice_panel.lua — the conversation panel glued to the Hyper window.
-- Shows the last few exchanges like a chat, a live status line, streams
-- replies as they arrive, follows the window, can be dragged and pinned.

local P = {}
local cfg = { terminalApp = "Hyper", lines = 6, seconds = 6, pinned = false, width = 640, botLabel = "hyper" }
local OFFSET_KEY = "voice.bannerOffset"
local LINE_H, PAD, GUTTER = 20, 10, 56

local state = { canvas = nil, hideTimer = nil, followTimer = nil, lastKey = nil, dragging = false, dragTap = nil,
  rows = {}, status = nil, statusColor = nil, streaming = nil, tickTimer = nil, startedAt = nil }

local colors = {
  listening = { red = 0.95, green = 0.26, blue = 0.21 },
  working   = { red = 0.98, green = 0.75, blue = 0.18 },
  done      = { red = 0.30, green = 0.80, blue = 0.45 },
  error     = { red = 0.95, green = 0.26, blue = 0.21 },
  you       = { white = 1, alpha = 0.55 },
  bot       = { red = 0.55, green = 0.78, blue = 1.0 },
  text      = { white = 1, alpha = 0.92 },
  muted     = { white = 1, alpha = 0.6 },
}
P.colors = colors

function P.configure(options)
  for k, v in pairs(options or {}) do cfg[k] = v end
end

-- ---------------------------------------------------------------------------
-- Geometry: anchored to the terminal window, or to the remembered offset

local function terminalWindow()
  local app = hs.application.find(cfg.terminalApp)
  if not app then return nil end
  local win = app:focusedWindow() or app:mainWindow() or app:allWindows()[1]
  if win and win:isVisible() and not win:isMinimized() then return win end
  return nil
end

local function anchorFrame()
  local target = terminalWindow() or hs.window.frontmostWindow()
  local f = target and target:frame() or hs.screen.mainScreen():frame()
  local w = math.min(cfg.width, math.max(320, f.w - 40))
  local off = hs.settings.get(OFFSET_KEY)
  if off and off.dx and off.dy then
    return { x = f.x + math.max(0, math.min(off.dx, f.w - w)), y = f.y + math.max(0, math.min(off.dy, f.h - 44)), w = w }
  end
  return { x = f.x + (f.w - w) / 2, y = f.y + 8, w = w }
end

local function frameKey(f) return string.format("%d,%d,%d", math.floor(f.x), math.floor(f.y), math.floor(f.w)) end

local function follow()
  if state.dragging or not state.canvas or not state.canvas:isShowing() then return end
  local f = anchorFrame()
  local key = frameKey(f)
  if key == state.lastKey then return end
  state.lastKey = key
  local cur = state.canvas:frame()
  state.canvas:frame({ x = f.x, y = f.y, w = f.w, h = cur.h })
end

local function rememberOffset()
  local win = terminalWindow()
  if not win or not state.canvas then return end
  local wf, cf = win:frame(), state.canvas:frame()
  hs.settings.set(OFFSET_KEY, { dx = cf.x - wf.x, dy = cf.y - wf.y })
end

local function armHide()
  if state.hideTimer then state.hideTimer:stop(); state.hideTimer = nil end
  if cfg.pinned or not state.canvas then return end
  state.hideTimer = hs.timer.doAfter(cfg.seconds, function() state.canvas:hide(0.25) end)
end

local function startDrag()
  if state.dragging or not state.canvas then return end
  state.dragging = true
  if state.hideTimer then state.hideTimer:stop(); state.hideTimer = nil end
  local startMouse, startFrame = hs.mouse.absolutePosition(), state.canvas:frame()
  local types = hs.eventtap.event.types
  state.dragTap = hs.eventtap.new({ types.leftMouseDragged, types.leftMouseUp }, function(e)
    local m = hs.mouse.absolutePosition()
    if e:getType() == types.leftMouseDragged then
      state.canvas:frame({ x = startFrame.x + (m.x - startMouse.x), y = startFrame.y + (m.y - startMouse.y),
        w = startFrame.w, h = startFrame.h })
      return true
    end
    state.dragTap:stop(); state.dragTap = nil
    state.dragging, state.lastKey = false, nil
    rememberOffset()
    armHide()
    return true
  end)
  state.dragTap:start()
end

-- Belt and braces: besides the canvas's own mouse tracking, watch every
-- left-button press and start a drag when it lands inside the visible panel.
local function pointInPanel(pt)
  if not state.canvas or not state.canvas:isShowing() then return false end
  local f = state.canvas:frame()
  return pt.x >= f.x and pt.x <= f.x + f.w and pt.y >= f.y and pt.y <= f.y + f.h
end

local function ensureCanvas()
  if state.canvas then return state.canvas end
  local c = hs.canvas.new({ x = 0, y = 0, w = 10, h = 10 })
  c:level(hs.canvas.windowLevels.floating)
  c:behavior({ "canJoinAllSpaces", "stationary" })
  c:clickActivating(false)
  c:canvasMouseEvents(true, false, false, false)
  c:mouseCallback(function(_, event) if event == "mouseDown" then startDrag() end end)
  state.canvas = c
  state.followTimer = hs.timer.doEvery(0.05, follow)
  state.clickTap = hs.eventtap.new({ hs.eventtap.event.types.leftMouseDown }, function(e)
    if state.dragging then return false end
    if pointInPanel(e:location()) then startDrag(); return true end
    return false
  end)
  state.clickTap:start()
  return c
end

-- ---------------------------------------------------------------------------
-- Rendering

local function visibleRows()
  local rows = {}
  local first = math.max(1, #state.rows - cfg.lines + 1)
  for i = first, #state.rows do table.insert(rows, state.rows[i]) end
  return rows
end

local function render()
  local c = ensureCanvas()
  local rows = visibleRows()
  local n = #rows + (state.status and 1 or 0)
  if n == 0 then return end
  local h = PAD * 2 + LINE_H * n
  local f = state.dragging and c:frame() or anchorFrame()
  if not state.dragging then state.lastKey = frameKey(f) end
  c:frame({ x = f.x, y = f.y, w = f.w, h = h })
  local elems = {
    { type = "rectangle", roundedRectRadii = { xRadius = 10, yRadius = 10 },
      fillColor = { red = 0.08, green = 0.09, blue = 0.11, alpha = 0.94 },
      strokeColor = { white = 1, alpha = 0.12 }, strokeWidth = 1, action = "strokeAndFill", trackMouseDown = true },
  }
  local y = PAD
  for _, row in ipairs(rows) do
    local label = row.who == "you" and "you" or cfg.botLabel
    table.insert(elems, { type = "text", text = label, frame = { x = PAD, y = y, w = GUTTER - 6, h = LINE_H },
      textSize = 12, textColor = row.who == "you" and colors.you or colors.bot, textFont = "Menlo-Bold", trackMouseDown = true })
    table.insert(elems, { type = "text", text = row.text, frame = { x = PAD + GUTTER, y = y, w = f.w - PAD * 2 - GUTTER, h = LINE_H },
      textSize = 13, textColor = row.dim and colors.muted or colors.text, textFont = "Menlo",
      textLineBreak = "truncateTail", trackMouseDown = true })
    y = y + LINE_H
  end
  if state.status then
    table.insert(elems, { type = "circle", action = "fill", center = { x = PAD + 6, y = y + LINE_H / 2 }, radius = 5,
      fillColor = state.statusColor or colors.working, trackMouseDown = true })
    table.insert(elems, { type = "text", text = state.status, frame = { x = PAD + 20, y = y, w = f.w - PAD * 2 - 20, h = LINE_H },
      textSize = 12, textColor = colors.muted, textFont = "Menlo", textLineBreak = "truncateTail", trackMouseDown = true })
  end
  c:replaceElements(elems)
  if not c:isShowing() then c:show(0.12) end
end

local function stopTick()
  if state.tickTimer then state.tickTimer:stop(); state.tickTimer = nil end
end

-- ---------------------------------------------------------------------------
-- Public API

-- Add a line from the user ("you") or the assistant ("hyper").
function P.add(who, text, dim)
  table.insert(state.rows, { who = who, text = text or "", dim = dim })
  if #state.rows > 40 then table.remove(state.rows, 1) end
  render()
  armHide()
end

-- Start a streamed assistant line; append with P.stream(delta); finish with P.endStream().
function P.beginStream()
  state.streaming = { who = "hyper", text = "" }
  table.insert(state.rows, state.streaming)
  render()
end

function P.stream(delta)
  if not state.streaming then P.beginStream() end
  state.streaming.text = state.streaming.text .. delta
  render()
end

-- Replace the streamed line's text (for a cleaned-up partial line).
function P.streamSet(text)
  if not state.streaming then P.beginStream() end
  state.streaming.text = text
  render()
end

-- Remove the live partial line; the caller adds the final line itself.
function P.endStream()
  if state.streaming then
    for i = #state.rows, 1, -1 do
      if state.rows[i] == state.streaming then table.remove(state.rows, i); break end
    end
  end
  state.streaming = nil
  render()
end

-- Status line under the transcript. `ticking` appends elapsed seconds.
function P.status(text, kind, ticking)
  stopTick()
  state.status, state.statusColor = text, colors[kind or "working"]
  if ticking then
    state.startedAt = hs.timer.secondsSinceEpoch()
    state.tickTimer = hs.timer.doEvery(0.25, function()
      local t = hs.timer.secondsSinceEpoch() - state.startedAt
      state.status = string.format("%s %.1fs", text, t)
      render()
    end)
  end
  if state.hideTimer then state.hideTimer:stop(); state.hideTimer = nil end
  render()
end

function P.clearStatus()
  stopTick()
  state.status = nil
  render()
  armHide()
end

function P.hide()
  stopTick()
  if state.hideTimer then state.hideTimer:stop(); state.hideTimer = nil end
  if state.canvas then state.canvas:hide(0.25) end
end

function P.pin(on)
  cfg.pinned = on ~= false
  if cfg.pinned then render() else armHide() end
end

function P.resetPosition()
  hs.settings.clear(OFFSET_KEY)
  state.lastKey = nil
  render()
end

function P.frame() return state.canvas and state.canvas:frame() end

function P.clear()
  state.rows = {}
  state.status = nil
  P.hide()
end

return P
