-- Boot screen + boot menu. Returns "wardenos" or "craftos".
-- The boot screen (Warden, name, version, loading bar) takes under a second; any key or tap skips it
-- (a key is passed on to the menu, so Enter at once still boots the default).
local screen = dofile("/os/lib/screen.lua")
local font   = dofile("/os/lib/bigfont.lua")
local art
do
  local ok, m = pcall(dofile, "/os/lib/art.lua")
  if ok and type(m) == "table" then art = m end
end
local OS = {}
do
  local ok, c = pcall(dofile, "/os/config.lua")
  if ok and type(c) == "table" then OS = c end
end

local CFG = "/os/boot.cfg"
local cfg = { default = "wardenos", timeout = 2 }
if fs.exists(CFG) then
  local fh = fs.open(CFG, "r")
  local d = textutils.unserialize(fh.readAll())
  fh.close()
  if type(d) == "table" then
    cfg.default = d.default or cfg.default
    cfg.timeout = tonumber(d.timeout) or cfg.timeout
  end
end

local entries = {
  { id = "wardenos", label = "WardenOS", hint = "desktop" },
  { id = "craftos", label = "CraftOS", hint = "shell" },
  { id = "recovery", label = "Recovery", hint = "repair" },
}
local sel = 1
for i, e in ipairs(entries) do if e.id == cfg.default then sel = i end end

local S = screen.open(29, 12, "right")
local W, H = S.W, S.H
local zones = {}

-- colors of the desktop theme (the boot screen is always dark: the sculk theme if chosen, else dark)
do
  local theme = "dark"
  if fs.exists("/os/settings.lua") then
    local fh = fs.open("/os/settings.lua", "r")
    local d = fh and textutils.unserialize(fh.readAll())
    if fh then fh.close() end
    if type(d) == "table" and d.theme == "sculk" then theme = "sculk" end
  end
  local th = type(OS.themes) == "table" and OS.themes[theme]
  if th and type(th.palette) == "table" then S.palette(th.palette) end
end

local function at(x, y, s, fg, bg)
  if y < 1 or y > H or x > W then return end
  if x < 1 then s, x = s:sub(2 - x), 1 end
  term.setCursorPos(x, y)
  term.setTextColor(fg or colors.white)
  term.setBackgroundColor(bg or colors.black)
  term.write(s:sub(1, W - x + 1))
end
local function center(y, s, fg, bg)
  at(math.floor((W - #s) / 2) + 1, y, s, fg, bg)
end
local version = OS.version and ("WardenOS " .. OS.version) or "WardenOS"

---------------------------------------------------------------- boot screen
local function drawSplash(frac)
  term.setBackgroundColor(colors.black)
  term.clear()
  local size = art and art.fit("warden", W - 2, H - 6)
  local a = size and art.get("warden", size)
  local y = math.max(1, math.floor((H - (a and a.h + 1 or 0) - 4) / 2) + 1)
  if a then
    art.draw(term, "warden", size, math.floor((W - a.w) / 2) + 1, y)
    y = y + a.h + 1
  end
  center(y, version, colors.cyan)
  local bw = math.min(W - 4, 24)
  local bx = math.floor((W - bw) / 2) + 1
  local n = math.floor(bw * frac + 0.5)
  at(bx, y + 2, string.rep(" ", bw), colors.white, colors.gray)
  if n > 0 then at(bx, y + 2, string.rep(" ", n), colors.white, colors.cyan) end
end

local function splash()
  local FRAMES, STEP = 8, 0.1                     -- ~0.8 s in total
  local frame = 0
  drawSplash(0)
  local timer = os.startTimer(STEP)
  while frame < FRAMES do
    local ev = table.pack(os.pullEventRaw())
    local e = ev[1]
    if e == "timer" and ev[2] == timer then
      frame = frame + 1
      drawSplash(frame / FRAMES)
      if frame < FRAMES then timer = os.startTimer(STEP) end
    elseif e == "key" or e == "char" or e == "terminate" then
      os.queueEvent(table.unpack(ev, 1, ev.n))    -- skipped: the menu gets the key
      return
    elseif e == "monitor_touch" or e == "mouse_click" then
      return
    end
  end
end

---------------------------------------------------------------- boot menu
local left = (cfg.timeout and cfg.timeout > 0) and cfg.timeout or nil

local function draw()
  term.setBackgroundColor(colors.black)
  term.clear()
  local top
  local size = art and ((H >= 19 and W >= 24 and "medium") or (H >= 14 and "small"))
  if size then
    local a = art.get("warden", size)
    art.draw(term, "warden", size, math.floor((W - a.w) / 2) + 1, 2)
    top = 2 + a.h + 1
    center(top, version, colors.cyan)
  elseif H >= 17 then
    font.draw(term, "WARDEN", math.floor((W - font.width("WARDEN")) / 2) + 1, 2, colors.cyan)
    top = 8
    center(top, "boot menu", colors.lightGray)
  else
    center(2, "W A R D E N", colors.cyan)
    top = 3
  end
  local bw = math.min(W - 2, 27)
  local bx = math.floor((W - bw) / 2) + 1
  local gap = (top + 2 + 2 * #entries <= H - 2) and 2 or 1
  for i, e in ipairs(entries) do
    local y = top + 2 + (i - 1) * gap
    local on = i == sel
    local tag = e.id == cfg.default and "default" or e.hint
    local line = (" " .. (on and ">" or " ") .. " " .. e.label .. string.rep(" ", bw)):sub(1, bw)
    if #tag + #e.label + 6 <= bw then line = line:sub(1, bw - #tag - 1) .. tag .. " " end
    at(bx, y, line, on and colors.black or colors.white, on and colors.cyan or colors.gray)
    if not on and #tag + #e.label + 6 <= bw then at(bx + bw - #tag - 1, y, tag, colors.lightGray, colors.gray) end
    zones[i] = { bx, bx + bw - 1, y }
  end
  center(H - 1, "UP/DOWN ENTER D=default", colors.lightGray)
  if left then center(H, ("auto boot in %ds"):format(left), colors.lightGray)
  else center(H, "choose a system", colors.lightGray) end
end

local function saveDefault()
  if entries[sel].id == "recovery" then return end   -- never start in Recovery by default
  cfg.default = entries[sel].id
  local fh = fs.open(CFG, "w")
  fh.write(textutils.serialize({ default = cfg.default, timeout = cfg.timeout }))
  fh.close()
end

splash()
local timer = left and os.startTimer(1)
local choice
while not choice do
  draw()
  local e, a, b, c = os.pullEventRaw()
  if e == "timer" and a == timer and left then
    left = left - 1
    if left <= 0 then choice = entries[sel].id else timer = os.startTimer(1) end
  elseif e == "terminate" then
    choice = "craftos"
  elseif e == "key" then
    left = nil
    if a == keys.up then sel = (sel - 2) % #entries + 1
    elseif a == keys.down then sel = sel % #entries + 1
    elseif a == keys.enter then choice = entries[sel].id
    elseif a == keys.d then saveDefault() end
  elseif e == "char" then
    left = nil
    local n = tonumber(a)
    if n and entries[n] then choice = entries[n].id end
  elseif e == "monitor_touch" or (e == "mouse_click" and a == 1) then
    left = nil
    for i, z in ipairs(zones) do
      if c == z[3] and b >= z[1] and b <= z[2] then choice = entries[i].id end
    end
  end
end

S.close()
return choice
