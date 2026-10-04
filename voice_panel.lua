-- voice_panel.lua — the conversation panel glued to the Hyper window.
-- Shows the last few exchanges like a chat, a live status line, streams
-- replies as they arrive, follows the window, can be dragged and pinned.

local P = {}
local cfg = { terminalApp = "Hyper", lines = 6, seconds = 6, pinned = false, width = 640, botLabel = "hyper" }
local OFFSET_KEY, WIDTH_KEY, FONT_KEY = "voice.bannerOffset", "voice.bannerWidth", "voice.bannerFont"
local PAD, GUTTER, GRIP = 10, 56, 18
local fontSize = hs.settings.get(FONT_KEY) or 13
local function lineHeight() return fontSize + 7 end

local state = { canvas = nil, hideTimer = nil, followTimer = nil, lastKey = nil, dragging = false, dragTap = nil,
  rows = {}, status = nil, statusColor = nil, streaming = nil, tickTimer = nil, startedAt = nil,
  wantVisible = false, anywhere = false, parked = false, resizing = false }

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
  local w = math.min(hs.settings.get(WIDTH_KEY) or cfg.width, math.max(320, f.w - 40))
  local off = hs.settings.get(OFFSET_KEY)
  if off and off.dx and off.dy then
    return { x = f.x + math.max(0, math.min(off.dx, f.w - w)), y = f.y + math.max(0, math.min(off.dy, f.h - 44)), w = w }
  end
  return { x = f.x + (f.w - w) / 2, y = f.y + 8, w = w }
end

local function frameKey(f) return string.format("%d,%d,%d", math.floor(f.x), math.floor(f.y), math.floor(f.w)) end

-- The box the panel may occupy: the terminal window, or the screen as a fallback.
local function bounds()
  local win = terminalWindow()
  if win then return win:frame() end
  local front = hs.window.frontmostWindow()
  return front and front:frame() or hs.screen.mainScreen():frame()
end

local function clampTo(box, x, y, w, h)
  return math.max(box.x, math.min(x, box.x + box.w - w)), math.max(box.y, math.min(y, box.y + box.h - h))
end

local function terminalIsFront()
  local app = hs.application.frontmostApplication()
  return app ~= nil and app:name() == cfg.terminalApp
end

local function follow()
  if state.dragging or not state.canvas then return end
  -- Never float over other apps: park the panel while Hyper is not in front.
  local shouldShow = state.wantVisible and (state.anywhere or terminalIsFront())
  if shouldShow and not state.canvas:isShowing() then state.canvas:show(0.12); state.parked = false
  elseif not shouldShow and state.canvas:isShowing() then state.canvas:hide(0.12); state.parked = true end
  if not state.canvas:isShowing() then return end
  local f = anchorFrame()
  local key = frameKey(f)
  if key == state.lastKey then return end
  state.lastKey = key
  local cur = state.canvas:frame()
  local box = bounds()
  local x, y = clampTo(box, f.x, f.y, f.w, cur.h)
  state.canvas:frame({ x = x, y = y, w = f.w, h = cur.h })
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
  state.hideTimer = hs.timer.doAfter(cfg.seconds, function() state.wantVisible = false; state.canvas:hide(0.25) end)
end

local render

-- Drag to move; drag from the bottom-right corner to resize the width.
local function startDrag()
  if state.dragging or not state.canvas then return end
  state.dragging = true
  if state.hideTimer then state.hideTimer:stop(); state.hideTimer = nil end
  local startMouse, startFrame = hs.mouse.absolutePosition(), state.canvas:frame()
  state.resizing = (startMouse.x >= startFrame.x + startFrame.w - GRIP) and (startMouse.y >= startFrame.y + startFrame.h - GRIP)
  local types = hs.eventtap.event.types
  state.dragTap = hs.eventtap.new({ types.leftMouseDragged, types.leftMouseUp }, function(e)
    local m = hs.mouse.absolutePosition()
    if e:getType() == types.leftMouseDragged then
      local box = bounds()
      if state.resizing then
        local w = math.max(320, math.min(startFrame.w + (m.x - startMouse.x), box.x + box.w - startFrame.x))
        hs.settings.set(WIDTH_KEY, w)
        render()
      else
        local x, y = clampTo(box, startFrame.x + (m.x - startMouse.x), startFrame.y + (m.y - startMouse.y),
          startFrame.w, startFrame.h)
        state.canvas:frame({ x = x, y = y, w = startFrame.w, h = startFrame.h })
      end
      return true
    end
    state.dragTap:stop(); state.dragTap = nil
    state.dragging, state.resizing, state.lastKey = false, false, nil
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
  state.followTimer = hs.timer.doEvery(0.02, follow)   -- 50× a second: stays glued while the window moves
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

render = function()
  local c = ensureCanvas()
  local rows = visibleRows()
  local n = #rows + (state.status and 1 or 0)
  if n == 0 then return end
  local LINE_H = lineHeight()
  local h = PAD * 2 + LINE_H * n
  local f = anchorFrame()
  if state.dragging then
    local cur = c:frame()
    f = { x = cur.x, y = cur.y, w = state.resizing and f.w or cur.w }
  else
    state.lastKey = frameKey(f)
  end
  local x, y = clampTo(bounds(), f.x, f.y, f.w, h)
  c:frame({ x = x, y = y, w = f.w, h = h })
  local elems = {
    { type = "rectangle", roundedRectRadii = { xRadius = 10, yRadius = 10 },
      fillColor = { red = 0.08, green = 0.09, blue = 0.11, alpha = 0.94 },
      strokeColor = { white = 1, alpha = 0.12 }, strokeWidth = 1, action = "strokeAndFill", trackMouseDown = true },
  }
  local y = PAD
  for _, row in ipairs(rows) do
    local label = row.who == "you" and "you" or cfg.botLabel
    table.insert(elems, { type = "text", text = label, frame = { x = PAD, y = y, w = GUTTER - 6, h = LINE_H },
      textSize = fontSize - 1, textColor = row.who == "you" and colors.you or colors.bot, textFont = "Menlo-Bold", trackMouseDown = true })
    table.insert(elems, { type = "text", text = row.text, frame = { x = PAD + GUTTER, y = y, w = f.w - PAD * 2 - GUTTER, h = LINE_H },
      textSize = fontSize, textColor = row.dim and colors.muted or colors.text, textFont = "Menlo",
      textLineBreak = "truncateTail", trackMouseDown = true })
    y = y + LINE_H
  end
  if state.status then
    table.insert(elems, { type = "circle", action = "fill", center = { x = PAD + 6, y = y + LINE_H / 2 }, radius = 5,
      fillColor = state.statusColor or colors.working, trackMouseDown = true })
    table.insert(elems, { type = "text", text = state.status, frame = { x = PAD + 20, y = y, w = f.w - PAD * 2 - 20, h = LINE_H },
      textSize = fontSize - 1, textColor = colors.muted, textFont = "Menlo", textLineBreak = "truncateTail", trackMouseDown = true })
  end
  -- resize grip: two short diagonal lines in the bottom-right corner
  for i = 1, 2 do
    local d = i * 5
    table.insert(elems, { type = "segments", action = "stroke", strokeColor = { white = 1, alpha = 0.35 }, strokeWidth = 1,
      coordinates = { { x = f.w - 4 - d, y = h - 4 }, { x = f.w - 4, y = h - 4 - d } }, trackMouseDown = true })
  end
  c:replaceElements(elems)
  state.wantVisible = true
  if not c:isShowing() and (state.anywhere or terminalIsFront()) then c:show(0.12) end
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
  state.wantVisible = false
  if state.canvas then state.canvas:hide(0.25) end
end

-- Dictation into another app: let the panel sit on whatever window is in front.
function P.anywhere(on) state.anywhere = on == true end

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
function P.visible() return state.canvas ~= nil and state.canvas:isShowing() end

-- Text size (persisted). Lines grow with it.
function P.font(delta)
  fontSize = math.max(10, math.min(24, fontSize + (delta or 0)))
  hs.settings.set(FONT_KEY, fontSize)
  render()
  return fontSize
end

function P.width(w)
  hs.settings.set(WIDTH_KEY, math.max(320, w))
  render()
end

function P.clear()
  state.rows = {}
  state.status = nil
  P.hide()
end

return P
