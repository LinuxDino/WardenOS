-- WardenOS kernel: dock + top bar desktop, window manager, mirrored display
local cfg  = dofile("/os/config.lua")
local font = dofile("/os/lib/bigfont.lua")
local login = dofile("/os/lib/login.lua")

---------------------------------------------------------------- settings / theme
local SETTINGS = "/os/settings.lua"
local settings = { theme = cfg.default }
if fs.exists(SETTINGS) then
  local f = fs.open(SETTINGS, "r")
  local d = textutils.unserialize(f.readAll())
  f.close()
  if type(d) == "table" then for k, v in pairs(d) do settings[k] = v end end
end
if not cfg.themes[settings.theme] then settings.theme = cfg.default end
local function saveSettings()
  local f = fs.open(SETTINGS, "w")
  f.write(textutils.serialize(settings))
  f.close()
end

local T = {}                                   -- live theme, shared with apps
rawset(_G, "WardenOS", { name = cfg.name, version = cfg.version, theme = T })

---------------------------------------------------------------- display (monitor + mirror)
local scr = term.current()                      -- the computer's own screen
local tw, th = scr.getSize()

-- preferred side first, then any other monitor (also over wired modems)
local monSide
if peripheral.getType(cfg.side) == "monitor" then
  monSide = cfg.side
else
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n) == "monitor" then monSide = n break end
  end
end
local MINW, MINH = 30, 12                       -- smallest usable desktop
local mon = monSide and peripheral.wrap(monSide)
local common = false                            -- desktop = area both screens share
if mon then
  local a, b
  local fitted = false
  if cfg.mirror == "fit" then
    -- smallest text scale at which the whole monitor fits on the computer screen
    for _, s in ipairs({ 0.5, 1, 1.5, 2, 2.5, 3, 3.5, 4, 4.5, 5 }) do
      if s >= cfg.scale then
        mon.setTextScale(s)
        a, b = mon.getSize()
        if a <= tw and b <= th and a >= MINW and b >= MINH then fitted = true break end
      end
    end
  end
  if not fitted then
    mon.setTextScale(cfg.scale)
    a, b = mon.getSize()
    if cfg.mirror == "fit" then
      common = true                               -- monitor bigger than the screen: use the shared area
      a, b = math.min(a, tw), math.min(b, th)
    end
    if a < MINW or b < MINH then mon = nil end    -- too small for a desktop: use the computer screen
  end
end
if not mon then monSide = nil end
WardenOS.monitor = monSide

local both = {
  write = 1, blit = 1, clear = 1, clearLine = 1, scroll = 1,
  setCursorPos = 1, setCursorBlink = 1,
  setTextColor = 1, setTextColour = 1, setBackgroundColor = 1, setBackgroundColour = 1,
  setPaletteColor = 1, setPaletteColour = 1,
}
local out = mon or scr
local screenInput = (not mon) or cfg.mirror     -- clicks on the computer screen count as touch
if mon and cfg.mirror then
  out = setmetatable({}, { __index = function(_, k)
    local f = mon[k]
    if type(f) ~= "function" then return f end
    local g = scr[k]
    if both[k] and g then
      return function(...) g(...) return f(...) end
    end
    return f
  end })
  if common then
    out.getSize = function()
      local a, b = mon.getSize()
      return math.min(a, tw), math.min(b, th)
    end
  end
end
local W, H = out.getSize()
local DW = 6                                    -- dock width

---------------------------------------------------------------- apps
local apps, order = {}, {}
for _, f in ipairs(fs.list("/os/apps")) do
  if f:sub(-4) == ".lua" then
    local ok, app = pcall(dofile, "/os/apps/" .. f)
    if ok and type(app) == "table" then
      apps[f:sub(1, -5)] = app
      order[#order + 1] = f:sub(1, -5)
    end
  end
end
table.sort(order, function(a, b) return (apps[a].order or 50) < (apps[b].order or 50) end)

---------------------------------------------------------------- state + theme apply
local wins = {}
local menuOpen, moving, running = false, nil, true
local exitAction
local clockTimer
local user = { name = "guest" }

local function applyPalette(t)
  for c, hex in pairs(cfg.themes[settings.theme].palette) do t.setPaletteColour(c, hex) end
end

local function setTheme(name, save)
  settings.theme = name
  if save then saveSettings() end
  for k in pairs(T) do T[k] = nil end
  for k, v in pairs(cfg.themes[name]) do if k ~= "palette" then T[k] = v end end
  applyPalette(out)
  for _, w in ipairs(wins) do applyPalette(w.win) end
end
setTheme(settings.theme, false)

---------------------------------------------------------------- accounts / login
local USERS = "/os/users.dat"
local users
if fs.exists(USERS) then
  local fh = fs.open(USERS, "r")
  users = textutils.unserialize(fh.readAll())
  fh.close()
end
if type(users) ~= "table" or type(users.users) ~= "table" or #users.users == 0 then users = nil end

local function doLogin()
  if not users then return { name = "guest" } end
  local old = term.redirect(out)
  local u = login(users, { theme = T, side = monSide, mirror = screenInput })
  term.redirect(old)
  users.last = u.name
  local fh = fs.open(USERS, "w")
  fh.write(textutils.serialize(users))
  fh.close()
  WardenOS.user = u.name
  return u
end

---------------------------------------------------------------- draw helpers
local function fill(x, y, w, h, bg)
  if w <= 0 or h <= 0 then return end
  out.setBackgroundColor(bg)
  local s = string.rep(" ", w)
  for i = 0, h - 1 do out.setCursorPos(x, y + i) out.write(s) end
end

local function text(x, y, s, fg, bg)
  out.setCursorPos(x, y)
  out.setTextColor(fg)
  out.setBackgroundColor(bg)
  out.write(s)
end

local function clockStr()
  local t = os.time()
  local h = math.floor(t)
  return string.format("%02d:%02d", h % 24, math.floor((t - h) * 60))
end

local function topWin()
  for i = #wins, 1, -1 do if not wins[i].min then return wins[i] end end
end

local function focus(w)
  for i, v in ipairs(wins) do if v == w then table.remove(wins, i) break end end
  w.min = false
  wins[#wins + 1] = w
end

local MW = 18
local function menuItems()
  local items = { { label = settings.theme == "dark" and "Light mode" or "Dark mode", act = "theme" } }
  if users then items[#items + 1] = { label = "Log out", act = "logout" } end
  items[#items + 1] = { label = "Update WardenOS", act = "update" }
  items[#items + 1] = { label = "Exit to CraftOS", act = "exit" }
  items[#items + 1] = { label = "Reboot", act = "reboot" }
  items[#items + 1] = { label = "Shut down", act = "shutdown", bad = true }
  return items
end

local function drawDesktop()
  fill(1, 2, W, H - 1, T.bg)
  local ww = W - DW
  if ww >= 21 and H >= 12 then
    local cx = DW + math.floor((ww - 17) / 2) + 1
    local cy = math.floor(H / 2) - 2
    font.draw(out, clockStr(), cx, cy, T.panel)
    local nm = cfg.name:lower()
    text(DW + math.floor((ww - #nm) / 2) + 1, cy + 7, nm, T.dim, T.bg)
  end
end

local function drawTitle(w, active)
  fill(w.x, w.y, w.w, 1, T.panel)
  if active then fill(w.x, w.y, 1, 1, T.accent) end
  local label = (moving == w and "place: tap a spot  " or "") .. w.title
  local col = (moving == w) and T.warn or (active and T.text or T.dim)
  text(w.x + 2, w.y, label:sub(1, math.max(1, w.w - 12)), col, T.panel)
  local e = w.x + w.w - 1
  text(e - 8, w.y, " - ", T.dim, T.panel)
  text(e - 5, w.y, " + ", T.dim, T.panel)
  text(e - 2, w.y, " x ", T.bad, T.panel)
end

-- rows per dock entry: 3 (with a gap) when everything fits, else 2
local function dockStep()
  return (#order * 3 <= H - 2) and 3 or 2
end

local function drawDock()
  fill(1, 2, DW, H - 1, T.panel)
  local top = topWin()
  local step = dockStep()
  for i, id in ipairs(order) do
    local y0 = 2 + (i - 1) * step
    if y0 + 1 >= H then break end
    local a = apps[id]
    local running_ = false
    for _, w in ipairs(wins) do if w.app == id then running_ = true end end
    local focused = top and top.app == id
    fill(1, y0, 1, 2, focused and T.accent or (running_ and T.dim or T.panel))
    local g = (a.icon or "?"):sub(1, 3)
    text(2 + math.floor((5 - #g) / 2), y0, g, a.color or T.text, T.panel)
    local s = (a.short or a.name):sub(1, 5)
    text(2 + math.floor((5 - #s) / 2), y0 + 1, s, T.dim, T.panel)
  end
  local label = settings.theme == "dark" and "dark" or "light"
  text(2 + math.floor((5 - #label) / 2), H, label, T.dim, T.panel)
end

local function drawTop()
  fill(1, 1, W, 1, T.panel)
  text(2, 1, cfg.name:upper(), menuOpen and T.warn or T.accent, T.panel)
  local t = topWin()
  if t then
    local s = t.title
    text(math.floor((W - #s) / 2) + 1, 1, s, T.text, T.panel)
  end
  local c = user.name .. "  " .. clockStr() .. " "
  text(W - #c + 1, 1, c, T.dim, T.panel)
end

local function drawMenu()
  for i, it in ipairs(menuItems()) do
    local s = (" " .. it.label .. string.rep(" ", MW)):sub(1, MW)
    text(1, 1 + i, s, it.bad and T.bad or T.text, T.panel)
  end
end

local function drawAll()
  out.setCursorBlink(false)
  drawDesktop()
  local top = topWin()
  for _, w in ipairs(wins) do
    if w.min then
      w.win.setVisible(false)
    else
      drawTitle(w, w == top)
      w.win.setVisible(false)
      w.win.setVisible(true)
      if w ~= top then w.win.setVisible(false) end
    end
  end
  drawDock()
  drawTop()
  if menuOpen then drawMenu() end
  if top and not menuOpen then top.win.restoreCursor() end
end

---------------------------------------------------------------- processes
local function send(p, ev)
  if p.dead then return end
  if p.filter and ev[1] ~= p.filter and ev[1] ~= "terminate" then return end
  local old = term.redirect(p.win)
  local ok, res = coroutine.resume(p.co, table.unpack(ev, 1, ev.n or #ev))
  if not ok then
    p.dead = true
    if tostring(res):find("Terminated") then
      p.done = true
    else
      term.setTextColor(colors.red)
      term.setBackgroundColor(colors.black)
      print()
      print(tostring(res))
      term.setTextColor(colors.white)
      print("[crashed - close with x]")
    end
  elseif coroutine.status(p.co) == "dead" then
    p.dead, p.done = true, true
  else
    p.filter = res
  end
  term.redirect(old)
end

local function sweep()
  local removed = false
  for i = #wins, 1, -1 do
    if wins[i].done then table.remove(wins, i) removed = true end
  end
  return removed
end

local function kill(w)
  for i, v in ipairs(wins) do if v == w then table.remove(wins, i) break end end
  if moving == w then moving = nil end
end

local function spawn(id, arg)
  local app = apps[id]
  if not app then return end
  menuOpen = false
  local n = #wins
  local w = math.min(app.w or 40, W - DW)
  local h = math.min(app.h or 14, H - 1)
  local x = math.max(DW + 1, math.min(DW + 2 + (n % 5) * 3, W - w + 1))
  local y = math.max(2, math.min(3 + (n % 5) * 2, H - h + 1))
  local p = { app = id, title = app.name, x = x, y = y, w = w, h = h,
              win = window.create(out, x, y + 1, w, h - 1, false) }
  applyPalette(p.win)
  p.co = coroutine.create(function() app.main(arg) end)
  wins[#wins + 1] = p
  send(p, { n = 0 })
end

local function toggleMax(w)
  if w.max then
    w.x, w.y, w.w, w.h = table.unpack(w.rest)
    w.max = false
  else
    w.rest = { w.x, w.y, w.w, w.h }
    w.x, w.y, w.w, w.h = DW + 1, 2, W - DW, H - 1
    w.max = true
  end
  w.win.reposition(w.x, w.y + 1, w.w, w.h - 1)
  send(w, { "term_resize", n = 1 })
end

local function toggleTheme()
  setTheme(settings.theme == "dark" and "light" or "dark", true)
  for _, w in ipairs({ table.unpack(wins) }) do send(w, { "theme_changed", n = 1 }) end
end

local function dockTap(id)
  local mine
  for i = #wins, 1, -1 do if wins[i].app == id then mine = wins[i] break end end
  if not mine then spawn(id)
  elseif mine == topWin() then
    if apps[id].multi then spawn(id) else mine.min = true end
  else focus(mine) end
end

---------------------------------------------------------------- input
local function onTouch(x, y)
  if menuOpen then
    menuOpen = false
    local items = menuItems()
    if x <= MW and y >= 2 and y < 2 + #items then
      local it = items[y - 1]
      if it.act == "theme" then toggleTheme()
      elseif it.act == "logout" then
        wins, moving = {}, nil
        user = doLogin()
        clockTimer = os.startTimer(1)
      elseif it.act == "update" then running, exitAction = false, "update"
      elseif it.act == "exit" then running = false
      elseif it.act == "reboot" then os.reboot()
      elseif it.act == "shutdown" then os.shutdown() end
    end
    return
  end

  if y == 1 then
    if x <= #cfg.name + 2 then menuOpen = true end
    return
  end

  if x <= DW then
    if y == H then toggleTheme() return end
    local step = dockStep()
    local i = math.floor((y - 2) / step) + 1
    if (y - 2) % step < 2 and order[i] and 2 + (i - 1) * step + 1 < H then dockTap(order[i]) end
    return
  end

  if moving then
    local w = moving
    moving = nil
    w.x = math.max(DW + 1, math.min(x, W - w.w + 1))
    w.y = math.max(2, math.min(y, H - w.h + 1))
    w.win.reposition(w.x, w.y + 1)
    return
  end

  for i = #wins, 1, -1 do
    local w = wins[i]
    if not w.min and x >= w.x and x < w.x + w.w and y >= w.y and y < w.y + w.h then
      local wasTop = (w == topWin())
      focus(w)
      if y == w.y then
        local e = w.x + w.w - 1
        if x >= e - 2 then kill(w)
        elseif x >= e - 5 then toggleMax(w)
        elseif x >= e - 8 then w.min = true
        elseif wasTop then moving = w end
      else
        local rx, ry = x - w.x + 1, y - w.y
        send(w, { "mouse_click", 1, rx, ry, n = 4 })
        send(w, { "mouse_up", 1, rx, ry, n = 4 })
      end
      return
    end
  end
end

---------------------------------------------------------------- main loop
out.setBackgroundColor(colors.black)
out.clear()
user = doLogin()
clockTimer = os.startTimer(1)
local lastClock = clockStr()
drawAll()

while running do
  local ev = table.pack(os.pullEventRaw())
  local name = ev[1]
  local redraw = false

  if name == "monitor_touch" then
    if ev[2] == monSide then onTouch(ev[3], ev[4]) redraw = true end

  elseif name == "mouse_click" and screenInput then     -- click on the computer screen
    if ev[2] == 1 then onTouch(ev[3], ev[4]) redraw = true end

  elseif name == "mouse_scroll" and screenInput then    -- wheel goes to the window under the pointer
    local t = topWin()
    local x, y = ev[3], ev[4]
    if t and not menuOpen and x >= t.x and x < t.x + t.w and y > t.y and y < t.y + t.h then
      send(t, { "mouse_scroll", ev[2], x - t.x + 1, y - t.y, n = 4 })
    end

  elseif name == "timer" and ev[2] == clockTimer then
    clockTimer = os.startTimer(1)
    local visible = 0
    for _, w in ipairs(wins) do if not w.min then visible = visible + 1 end end
    local c = clockStr()
    if c ~= lastClock or visible > 1 then
      lastClock = c
      redraw = true
    else
      drawTop()
      local t = topWin()
      if t and not menuOpen then t.win.restoreCursor() end
    end

  elseif name == "os_launch" then
    spawn(ev[2], ev[3])
    redraw = true

  elseif name == "monitor_resize" or name == "term_resize" then
    W, H = out.getSize()
    redraw = true

  elseif name == "key" and ev[2] == keys.f12 then
    running = false

  elseif name == "key" or name == "key_up" or name == "char"
      or name == "paste" or name == "terminate" then
    local t = topWin()
    if t then send(t, ev) end

  elseif name:sub(1, 5) == "mouse" then
    -- other mouse events ignored

  else
    for _, w in ipairs({ table.unpack(wins) }) do send(w, ev) end
  end

  if sweep() then redraw = true end
  if redraw and running then drawAll() end
end

for i = 0, 15 do
  local c = 2 ^ i
  out.setPaletteColour(c, term.nativePaletteColour(c))
end
out.setBackgroundColor(colors.black)
out.setTextColor(colors.white)
out.clear()
out.setCursorBlink(false)
term.redirect(scr)
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)

if exitAction == "update" then
  print("Updating " .. cfg.name .. "...")
  local url = ("https://raw.githubusercontent.com/%s/%s/install.lua"):format(cfg.repo, cfg.branch)
  local h, err = http and http.get(url)
  if not h then
    printError("Download failed: " .. tostring(err or "http API disabled"))
    return
  end
  local src = h.readAll()
  h.close()
  local fn, lerr = load(src, "=install.lua", "t", setmetatable({ shell = shell }, { __index = _G }))
  if not fn then printError(lerr) return end
  fn("update", cfg.branch)
  return
end
print(cfg.name .. " stopped. Reboot to start it again.")
