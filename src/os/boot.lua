-- Boot menu. Returns "wardenos" or "craftos".
local screen = dofile("/os/lib/screen.lua")
local font   = dofile("/os/lib/bigfont.lua")

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
  { id = "wardenos", label = "WardenOS" },
  { id = "craftos", label = "CraftOS" },
}
local sel = 1
for i, e in ipairs(entries) do if e.id == cfg.default then sel = i end end

local S = screen.open(29, 12, "right")
local W, H = S.W, S.H
local zones = {}

local function at(x, y, s, fg, bg)
  term.setCursorPos(x, y)
  term.setTextColor(fg or colors.white)
  term.setBackgroundColor(bg or colors.black)
  term.write(s)
end
local function center(y, s, fg, bg)
  at(math.floor((W - #s) / 2) + 1, y, s, fg, bg)
end

local left = (cfg.timeout and cfg.timeout > 0) and cfg.timeout or nil

local function draw()
  term.setBackgroundColor(colors.black)
  term.clear()
  local top
  if H >= 17 then
    font.draw(term, "WARDEN", math.floor((W - font.width("WARDEN")) / 2) + 1, 2, colors.cyan)
    top = 9
  else
    center(2, "W A R D E N", colors.cyan)
    top = 4
  end
  center(top, "boot menu", colors.lightGray)
  local bw = math.min(W - 2, 27)
  local bx = math.floor((W - bw) / 2) + 1
  for i, e in ipairs(entries) do
    local y = top + 2 + (i - 1) * 2
    local line = (" %d  %s%s"):format(i, e.label, e.id == cfg.default and "  (default)" or "")
    line = (line .. string.rep(" ", bw)):sub(1, bw)
    if i == sel then at(bx, y, line, colors.black, colors.cyan)
    else at(bx, y, line, colors.white, colors.gray) end
    zones[i] = { bx, bx + bw - 1, y }
  end
  center(H - 1, "UP/DOWN ENTER D=default", colors.lightGray)
  if left then center(H, ("auto boot in %ds"):format(left), colors.lightGray)
  else center(H, "choose a system", colors.lightGray) end
end

local function saveDefault()
  cfg.default = entries[sel].id
  local fh = fs.open(CFG, "w")
  fh.write(textutils.serialize({ default = cfg.default, timeout = cfg.timeout }))
  fh.close()
end

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
