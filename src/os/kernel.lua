-- WardenOS kernel: dock + top bar desktop, app view, window manager, display modes
local cfg      = dofile("/os/config.lua")
local font     = dofile("/os/lib/bigfont.lua")
local login    = dofile("/os/lib/login.lua")
local Settings = dofile("/os/lib/settings.lua")
local art                                       -- /os/lib/art.lua (pixel art); the desktop also works without it
do
  local ok, m = pcall(dofile, "/os/lib/art.lua")
  if ok and type(m) == "table" then art = m end
end

local settings = Settings.load()
if not cfg.themes[settings.theme] then settings.theme = cfg.default end

local T = {}                                   -- live theme, shared with apps
rawset(_G, "WardenOS", { name = cfg.name, version = cfg.version, theme = T, repo = cfg.repo, branch = cfg.branch })
-- what Claude is doing (kept by /os/lib/claudetools.lua): shown in the top bar
WardenOS.claude = { busy = false, status = "", drones = {}, talks = {} }

---------------------------------------------------------------- display
-- auto     desktop on the whole monitor (computer screen shows a status panel), else the computer
-- monitor  same as auto
-- mirror   same picture on monitor and computer (area both share, centered on the monitor)
-- computer ignore monitors
local scr = term.current()                      -- the computer's own screen
local tw, th = scr.getSize()
local MINW, MINH = 30, 12                       -- smallest usable desktop

local monSide
if settings.display ~= "computer" then
  if peripheral.getType(cfg.side) == "monitor" then
    monSide = cfg.side
  else
    for _, n in ipairs(peripheral.getNames()) do
      if peripheral.getType(n) == "monitor" then monSide = n break end
    end
  end
end
local mon = monSide and peripheral.wrap(monSide)
local mode = "computer"
local W, H
if mon then
  local mirror = settings.display == "mirror"
  for _, s in ipairs({ settings.scale, 0.5 }) do   -- chosen scale, else the smallest one
    mon.setTextScale(s)
    local a, b = mon.getSize()
    if mirror then a, b = math.min(a, tw), math.min(b, th) end
    if a >= MINW and b >= MINH then
      W, H, mode = a, b, mirror and "mirror" or "monitor"
      break
    end
  end
  if mode == "computer" then mon.setTextScale(0.5) mon = nil end
end
if not mon then monSide = nil W, H = tw, th end
WardenOS.monitor, WardenOS.display = monSide, mode

local out
if mode == "monitor" then
  out = mon
elseif mode == "mirror" then
  local mw, mh = mon.getSize()
  mon.setBackgroundColor(colors.black)
  mon.clear()
  local mwin = window.create(mon, math.floor((mw - W) / 2) + 1, math.floor((mh - H) / 2) + 1, W, H, true)
  local both = {
    write = 1, blit = 1, clear = 1, clearLine = 1, scroll = 1,
    setCursorPos = 1, setCursorBlink = 1,
    setTextColor = 1, setTextColour = 1, setBackgroundColor = 1, setBackgroundColour = 1,
    setPaletteColor = 1, setPaletteColour = 1,
  }
  out = setmetatable({}, { __index = function(_, k)
    local f = mwin[k]
    if type(f) ~= "function" then return f end
    local g = scr[k]
    if both[k] and g then return function(...) g(...) return f(...) end end
    return f
  end })
else
  out = scr
end
local screenInput = mode ~= "monitor"           -- clicks on the computer screen count as touch
local DW = 6                                    -- dock width

---------------------------------------------------------------- apps
-- apps[id] = header table of /os/apps/<id>.lua, order = ids for the app view. ghosts[id] keeps the header of an
-- app that was removed (App Store) while its window still runs, until that window is closed.
local apps, order, ghosts = {}, {}, {}
local wins = {}
local function loadApps()
  local old = apps
  apps, order = {}, {}
  for _, f in ipairs(fs.isDir("/os/apps") and fs.list("/os/apps") or {}) do
    if f:sub(-4) == ".lua" then
      local ok, app = pcall(dofile, "/os/apps/" .. f)
      if ok and type(app) == "table" and type(app.main) == "function" then
        if type(app.name) ~= "string" then app.name = f:sub(1, -5) end
        apps[f:sub(1, -5)] = app
        order[#order + 1] = f:sub(1, -5)
      end
    end
  end
  table.sort(order, function(a, b)
    local x, y = tonumber(apps[a].order) or 50, tonumber(apps[b].order) or 50
    if x ~= y then return x < y end
    return a < b
  end)
  for _, w in ipairs(wins) do
    if not apps[w.app] then ghosts[w.app] = ghosts[w.app] or old[w.app] end
  end
  for id in pairs(ghosts) do if apps[id] then ghosts[id] = nil end end
  WardenOS.apps, WardenOS.appNames = order, {}
  for id, a in pairs(apps) do WardenOS.appNames[id] = a.name end
end
loadApps()
local function appInfo(id) return apps[id] or ghosts[id] end

---------------------------------------------------------------- state + theme
local menuOpen, appView, moving, running = false, false, nil, true
local exitAction
local clockTimer
local user = { name = "guest" }

local function applyPalette(t)
  for c, hex in pairs(cfg.themes[settings.theme].palette) do t.setPaletteColour(c, hex) end
end

local function setTheme(name)
  settings.theme = name
  for k in pairs(T) do T[k] = nil end
  for k, v in pairs(cfg.themes[name]) do if k ~= "palette" then T[k] = v end end
  applyPalette(out)
  if mode == "monitor" then applyPalette(scr) end
  for _, w in ipairs(wins) do applyPalette(w.win) end
end
setTheme(settings.theme)

---------------------------------------------------------------- accounts / login
local USERS = "/os/users.dat"
local users
if fs.exists(USERS) then
  local fh = fs.open(USERS, "r")
  users = textutils.unserialize(fh.readAll())
  fh.close()
end
if type(users) ~= "table" or type(users.users) ~= "table" or #users.users == 0 then users = nil end

---------------------------------------------------------------- draw helpers
local function fill(t, x, y, w, h, bg)
  if w <= 0 or h <= 0 then return end
  t.setBackgroundColor(bg)
  local s = string.rep(" ", w)
  for i = 0, h - 1 do t.setCursorPos(x, y + i) t.write(s) end
end

local function text(t, x, y, s, fg, bg)
  t.setCursorPos(x, y)
  t.setTextColor(fg)
  t.setBackgroundColor(bg)
  t.write(s)
end

---------------------------------------------------------------- world: drone status cache + world map (/os/lib/world.lua)
-- loaded before the pocket server, which reads the shared status cache WardenOS.drones
local world
do
  local ok, m = pcall(dofile, "/os/lib/world.lua")
  if ok and type(m) == "table" then world = m WardenOS.drones = m.drones end
end

---------------------------------------------------------------- pocket server (WardenOS Pocket pairing + relay)
-- a broken module must never break the desktop: every call is protected
local psrv
do
  local ok, m = pcall(dofile, "/os/lib/pocketserver.lua")
  if ok and type(m) == "table" then psrv = m end
end
local function pocketPrompt()                   -- { id } of a pocket waiting for "Allow", or nil
  if not psrv then return nil end
  local ok, p = pcall(psrv.prompt)
  return ok and type(p) == "table" and p or nil
end
local function promptX() return W - math.min(W, 30) + 1 end
local function drawPocketPrompt()               -- small card at the top right: rows 2-3
  local p = pocketPrompt()
  if not p then return end
  local x, cw = promptX(), math.min(W, 30)
  fill(out, x, 2, cw, 2, T.panel)
  local msg = "Pocket #" .. tostring(p.id) .. " wants to connect"
  if #msg > cw - 2 then msg = "Pocket #" .. tostring(p.id) .. ": connect?" end
  text(out, x + 1, 2, msg:sub(1, cw - 2), T.warn, T.panel)
  text(out, x + 1, 3, " Allow ", T.bg, T.good)
  text(out, x + 9, 3, " Deny ", T.bg, T.bad)
end

local function clockStr()
  local t = os.time()
  local h = math.floor(t)
  return string.format("%02d:%02d", h % 24, math.floor((t - h) * 60))
end

-- the Warden (as big as fits) above a few centered lines: { { text, color }, ... }
local function splash(t, tw, th, lines)
  fill(t, 1, 1, tw, th, T.bg)
  local size = art and art.fit("warden", tw - 2, th - #lines - 2)
  local a = size and art.get("warden", size)
  local y = math.max(1, math.floor((th - (a and a.h + 1 or 0) - #lines) / 2) + 1)
  if a then
    art.draw(t, "warden", size, math.floor((tw - a.w) / 2) + 1, y)
    y = y + a.h + 1
  end
  for _, l in ipairs(lines) do
    local s = l[1]:sub(1, tw)
    text(t, math.floor((tw - #s) / 2) + 1, y, s, l[2], T.bg)
    y = y + 1
  end
end

-- computer screen while the desktop is on the monitor
local function drawStatus()
  if mode ~= "monitor" then return end
  scr.setCursorBlink(false)
  splash(scr, tw, th, {
    { cfg.name .. " " .. cfg.version, T.accent },
    { "Desktop is on monitor '" .. monSide .. "'", T.text },
    { "Keyboard types into the active window", T.dim },
    { "F12: exit to CraftOS", T.dim },
  })
end

-- shown for a moment before shutting down, rebooting or leaving to CraftOS
local function goodbye(msg)
  pcall(function()
    out.setCursorBlink(false)
    splash(out, W, H, { { cfg.name, T.accent }, { msg, T.dim } })
    if mode == "monitor" then splash(scr, tw, th, { { cfg.name, T.accent }, { msg, T.dim } }) end
  end)
  sleep(0.6)
end

local function topWin()
  for i = #wins, 1, -1 do if not wins[i].min then return wins[i] end end
end

local function focus(w)
  for i, v in ipairs(wins) do if v == w then table.remove(wins, i) break end end
  w.min = false
  wins[#wins + 1] = w
end

-- the WARDENOS menu: rows 2.. at the left, separators can't be tapped
local MW = 19
local function menuItems()
  local items = {
    { label = "Apps", act = "apps", icon = ":" },
    { label = "Settings", act = "settings", icon = "\15" },
    { sep = true },
  }
  if users then items[#items + 1] = { label = "Log out", act = "logout", icon = "\27" } end
  items[#items + 1] = { label = "Exit to CraftOS", act = "exit", icon = ">" }
  items[#items + 1] = { label = "Reboot", act = "reboot", icon = "\18" }
  items[#items + 1] = { label = "Shut down", act = "shutdown", bad = true, icon = "\7" }
  return items
end

-- dock: Apps button, pinned apps, then running apps that aren't pinned
local APPS_ICON = { name = "Apps", short = "Apps", icon = "::",
                    art = { { "    ", "0000", "9911" }, { "    ", "0000", "5544" } } }
local function dockEntries()
  local list, seen = { "@apps" }, {}
  for _, id in ipairs(settings.dock) do
    if apps[id] and not seen[id] then list[#list + 1] = id seen[id] = true end
  end
  for _, w in ipairs(wins) do
    if not seen[w.app] then list[#list + 1] = w.app seen[w.app] = true end
  end
  return list
end

-- rows per dock entry (3: 4x2 icon + label, 2: text icon + label) and the step between entries
local function dockLayout(n)
  local avail = H - 1
  if art then
    if n * 4 <= avail then return 3, 4 end
    if n * 3 <= avail then return 3, 3 end
  end
  if n * 3 <= avail then return 2, 3 end
  return 2, 2
end

-- an app's 4x2 icon: its pixel art, else a colored tile with the text icon (apps without `art`)
local function drawIcon(a, x, y)
  if art and art.icon(out, a, x, y, T.panel) then return end
  local c = a.color or T.accent
  if c == T.panel then c = T.dim end
  fill(out, x, y, 4, 2, c)
  local ic = tostring(a.icon or "?"):sub(1, 4)
  text(out, x + math.floor((4 - #ic) / 2), y, ic, T.bg, c)
end

local CLOCKW = 17                               -- bigfont width of "12:30"
local function drawDesktop()
  local x0, ww, hh = DW + 1, W - DW, H - 1
  if art then                                   -- sculk wallpaper, recolored for the theme
    local p, light = art.hex(T.panel), T.bg == colors.white
    art.wallpaper(out, x0, 2, ww, hh, T.bg, { ["7"] = p, ["6"] = light and p or "6", ["9"] = light and p or "6" })
  else
    fill(out, x0, 2, ww, hh, T.bg)
  end
  -- the Warden and the big clock: the biggest arrangement that fits (only one of them on small screens)
  local L
  for _, c in ipairs({ { "large", "stack" }, { "large", "side" }, { "medium", "stack" }, { "medium", "side" },
                       { nil, "clock" }, { "medium", "art" }, { "small", "art" } }) do
    local a = c[1] and art and art.get("warden", c[1])
    if a or not c[1] then
      local w, h
      if c[2] == "stack" then w, h = math.max(a.w, CLOCKW), a.h + 8
      elseif c[2] == "side" then w, h = a.w + 4 + CLOCKW, math.max(a.h, 7)
      elseif c[2] == "clock" then w, h = CLOCKW, 7
      else w, h = a.w, a.h + 2 end
      if w + 2 <= ww and h + 1 <= hh then L = { a = a, kind = c[2], size = c[1], w = w, h = h } break end
    end
  end
  if not L then return end
  local bx = x0 + math.floor((ww - L.w) / 2)
  local by = 2 + math.floor((hh - L.h) / 2)
  fill(out, bx - 1, by, L.w + 2, L.h, T.bg)       -- a calm area behind
  local nm = cfg.name:lower()
  local function clock(x, y)
    font.draw(out, clockStr(), x, y, T.panel)
    text(out, x + math.floor((CLOCKW - #nm) / 2), y + 6, nm, T.dim, T.bg)
  end
  local a = L.a
  if L.kind == "stack" then
    art.draw(out, "warden", L.size, x0 + math.floor((ww - a.w) / 2), by)
    clock(x0 + math.floor((ww - CLOCKW) / 2), by + a.h + 1)
  elseif L.kind == "side" then
    art.draw(out, "warden", L.size, bx, by + math.floor((L.h - a.h) / 2))
    clock(bx + a.w + 4, by + math.floor((L.h - 7) / 2))
  elseif L.kind == "clock" then
    clock(bx, by)
  else
    art.draw(out, "warden", L.size, bx, by)
    text(out, x0 + math.floor((ww - #nm) / 2), by + a.h + 1, nm, T.dim, T.bg)
  end
end

local function drawTitle(w, active)
  fill(out, w.x, w.y, w.w, 1, T.panel)
  if active then fill(out, w.x, w.y, 1, 1, T.accent) end
  local a = appInfo(w.app) or {}
  local x, room = w.x + 2, math.max(1, w.w - 12)
  local ic = tostring(a.icon or ""):sub(1, 3)
  if moving ~= w and #ic > 0 and room >= #ic + 5 then  -- the app's icon before the title
    text(out, x, w.y, ic, active and (a.color or T.accent) or T.dim, T.panel)
    x, room = x + #ic + 1, room - #ic - 1
  end
  local label = (moving == w and "place: tap a spot  " or "") .. w.title
  local col = (moving == w) and T.warn or (active and T.text or T.dim)
  text(out, x, w.y, label:sub(1, room), col, T.panel)
  local e = w.x + w.w - 1
  text(out, e - 8, w.y, " - ", T.dim, T.panel)
  text(out, e - 5, w.y, " + ", T.dim, T.panel)
  if active then text(out, e - 2, w.y, " x ", T.bg, T.bad)
  else text(out, e - 2, w.y, " x ", T.bad, T.panel) end
end

local function drawDock()
  fill(out, 1, 2, DW, H - 1, T.panel)
  local top = topWin()
  local list = dockEntries()
  local rows, step = dockLayout(#list)
  for i, id in ipairs(list) do
    local y0 = 2 + (i - 1) * step
    if y0 + rows - 1 > H then break end
    local a, mark, on
    if id == "@apps" then
      a, on = APPS_ICON, appView
      mark = appView and T.accent or T.panel
    else
      a = appInfo(id) or { name = id }
      local run = false
      for _, w in ipairs(wins) do if w.app == id then run = true end end
      on = not appView and top and top.app == id
      mark = on and T.accent or (run and T.dim or T.panel)
    end
    fill(out, 1, y0, 1, rows, mark)
    local label = tostring(a.short or a.name):sub(1, 5)
    local lx = 2 + math.floor((5 - #label) / 2)
    if rows == 3 then
      drawIcon(a, 2, y0)
      text(out, lx, y0 + 2, label, on and T.text or T.dim, T.panel)
    else
      local icon = tostring(a.icon or "?"):sub(1, 3)
      text(out, 2 + math.floor((5 - #icon) / 2), y0, icon, a.color or T.accent, T.panel)
      text(out, lx, y0 + 1, label, on and T.text or T.dim, T.panel)
    end
  end
end

-- Claude activity for the top bar: { long = "AI>#12 goto", short = "AI>#12", id = drone | nil } or nil.
-- Shown while Claude is busy or a drone runs a task Claude started (WardenOS.claude + WardenOS.drones).
local indZone                                   -- { x1, x2, id } of the indicator as last drawn
local function activity()
  local A = type(WardenOS.claude) == "table" and WardenOS.claude or {}
  local D = type(WardenOS.drones) == "table" and WardenOS.drones or {}
  local now, ids = os.clock(), {}
  for id, d in pairs(D) do
    if type(d) == "table" and type(d.by) == "table" and d.by.who == "claude" and d.state == "working"
       and now - (tonumber(d.seen) or -1e9) < 10 then
      ids[#ids + 1] = id
    end
  end
  local E = type(A.drones) == "table" and A.drones or {}
  if #ids == 0 and A.busy then                  -- busy: the drone it just sent a command to, if any
    local best, at
    for id, e in pairs(E) do
      if type(e) == "table" and tonumber(e.at) and now - e.at < 60 and (not at or e.at > at) then best, at = id, e.at end
    end
    ids[1] = best
  end
  if #ids == 0 and not A.busy then return nil end
  table.sort(ids)
  local id = ids[1]
  if not id then return { long = "AI busy", short = "AI" } end
  local e, d = E[id], D[id]
  local act = type(e) == "table" and tostring(e.action or "") or ""
  if act == "" and type(d) == "table" then act = "task " .. tostring(d.task or "") end
  local word = act:match("^task%s+(.+)$") or act:match("^(%S+)") or ""
  local more = #ids > 1 and (" +" .. (#ids - 1)) or ""
  return { long = ("AI>#%d %s%s"):format(id, word, more), short = "AI>#" .. id, id = id }
end
local lastAct = ""

-- top bar: menu button (icon + name), title of the active window, Claude activity, user and clock
local NAMEX = 4                                 -- the name starts here, after the menu icon
local NAME_END = NAMEX + #cfg.name - 1          -- last column of the menu button text
local function drawTop()
  fill(out, 1, 1, W, 1, T.panel)
  local mc = menuOpen and T.warn or T.accent
  text(out, 2, 1, "\4", mc, T.panel)
  text(out, NAMEX, 1, cfg.name:upper(), mc, T.panel)
  local t = topWin()
  local mid = appView and "Apps" or (t and t.title)
  local c = user.name .. "  " .. clockStr() .. " "
  local left = NAME_END + 2                     -- first column after the name and a gap
  local okA, act = pcall(activity)
  act = okA and act or nil
  lastAct = act and act.long or ""
  indZone = nil
  local ix                                      -- indicator start column
  if act then
    -- room between the name and the clock: drop the user name, then shorten the indicator
    local function room() return W - #c - left end
    if room() < #act.long + 1 then c = clockStr() .. " " end
    if room() < 2 then c = "" end
    local s = act.long
    if room() < #s + 1 then s = act.short end
    if room() < #s + 1 then s = s:sub(1, math.max(0, room() - 1)) end
    if #s > 0 then
      ix = W - #c - #s
      local pulse = math.floor(os.clock()) % 2 == 0
      text(out, ix, 1, s, T.bg, pulse and T.accent or T.warn)
      indZone = { ix, ix + #s - 1, act.id }
    end
  end
  if mid then
    local right = (ix and ix - 2 or W - #c)     -- last column the title may use
    local room = right - left - 1
    if not ix then room = W - NAME_END - #c - 5 end
    if room >= 4 then
      mid = mid:sub(1, room)
      local x = math.max(NAME_END + 3, math.floor((W - #mid) / 2) + 1)
      if x + #mid - 1 > right then x = math.max(left + 1, right - #mid + 1) end
      text(out, x, 1, mid, T.text, T.panel)
    end
  end
  if #c > 0 and #c + NAME_END + 2 <= W then
    local cx = W - #c + 1
    local u = c:find("  ", 1, true)
    if u then                                   -- user dim, clock bright
      text(out, cx, 1, c:sub(1, u + 1), T.dim, T.panel)
      text(out, cx + u + 1, 1, c:sub(u + 2), T.text, T.panel)
    else
      text(out, cx, 1, c, T.text, T.panel)
    end
  end
end

local function drawMenu()
  local items = menuItems()
  local w = math.min(MW, W)
  for i, it in ipairs(items) do
    local y = 1 + i
    if y > H then break end
    if it.sep then
      text(out, 1, y, (" " .. string.rep("-", w - 2) .. " "):sub(1, w), T.dim, T.panel)
    else
      text(out, 1, y, (" " .. it.icon .. " " .. it.label .. string.rep(" ", w)):sub(1, w), it.bad and T.bad or T.text, T.panel)
      text(out, 2, y, it.icon, it.bad and T.bad or T.accent, T.panel)
    end
  end
  if 2 + #items <= H then text(out, 1, 2 + #items, string.rep(" ", w), T.text, T.panel) end   -- bottom padding
end

-- app view: every app as a tile (3 rows high: icon + name, or 1 row when space is short)
local TW = 12                                   -- tile width incl. gap
local function viewLayout()
  local x0, y0 = DW + 2, 4
  local cols = math.max(1, math.floor((W - DW - 2) / TW))
  local th, gap = 3, 1
  if cols * math.floor((H - y0 + 2) / 4) < #order then th, gap = 1, 0 end   -- compact: one row per app
  local tiles = {}
  for i, id in ipairs(order) do
    local c, r = (i - 1) % cols, math.floor((i - 1) / cols)
    local y = y0 + r * (th + gap)
    if y + th - 1 <= H then
      tiles[#tiles + 1] = { id = id, x = x0 + c * TW, y = y, w = math.min(TW - 2, W - (x0 + c * TW)), h = th }
    end
  end
  return tiles
end

local function drawAppView()
  fill(out, DW + 1, 2, W - DW, H - 1, T.bg)
  text(out, DW + 2, 2, "Apps", T.text, T.bg)
  local n = " " .. #order
  if DW + 6 + #n < W - 3 then text(out, DW + 6, 2, n, T.dim, T.bg) end
  text(out, W - 2, 2, " x ", T.bad, T.bg)
  for _, t in ipairs(viewLayout()) do
    local a, w = apps[t.id], t.w
    if w >= 4 then
      fill(out, t.x, t.y, w, t.h, T.panel)
      if t.h == 1 then
        local icon = tostring(a.icon or "?"):sub(1, 3)
        text(out, t.x, t.y, icon, a.color or T.text, T.panel)
        local name = (#a.name > w - 4 and a.short or a.name):sub(1, w - 4)
        text(out, t.x + 4, t.y, name, T.text, T.panel)
      else
        local name = tostring(#a.name > w and a.short or a.name):sub(1, w)
        drawIcon(a, t.x + math.floor((w - 4) / 2), t.y)
        text(out, t.x + math.floor((w - #name) / 2), t.y + 2, name, T.text, T.panel)
      end
    end
  end
end

-- toast: a short message at the top right for ~3 s (os.queueEvent("os_toast", text))
local toast                                     -- { text =, timer = } or nil
local function drawToast()
  if not toast then return end
  local s = toast.text
  local cw = math.min(#s + 4, 40, W)
  s = s:sub(1, cw - 4)
  local x = math.max(1, W - cw)
  local y = pocketPrompt() and 5 or 2           -- below the pairing card
  if y + 2 > H then return end
  fill(out, x, y, cw, 3, T.panel)
  fill(out, x, y, 1, 3, T.accent)
  toast.zone = { x, x + cw - 1, y, y + 2 }
  text(out, x + 2, y + 1, s, T.text, T.panel)
end

local function drawAll()
  out.setCursorBlink(false)
  local top = topWin()
  if appView then
    for _, w in ipairs(wins) do w.win.setVisible(false) end
    drawAppView()
  else
    drawDesktop()
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
  end
  drawDock()
  drawTop()
  if menuOpen then drawMenu() end
  drawPocketPrompt()
  drawToast()
  if top and not menuOpen and not appView then top.win.restoreCursor() end
end

local function doLogin()
  if not users then return { name = "guest" } end
  drawStatus()
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
      pcall(function()                           -- System Monitor > Logs
        local L = rawget(_G, "WardenLog")
        if L then L.add("error", { source = tostring(p.title), text = tostring(res) }) end
      end)
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

local function broadcast(ev)
  for _, w in ipairs({ table.unpack(wins) }) do send(w, ev) end
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
  menuOpen, appView = false, false
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

local function open(id)                         -- dock / app view tap
  appView = false
  local mine
  for i = #wins, 1, -1 do if wins[i].app == id then mine = wins[i] break end end
  if not mine then spawn(id)
  elseif mine == topWin() then
    if apps[id] and apps[id].multi then spawn(id) else mine.min = true end
  else focus(mine) end
end

local function reloadSettings()
  local s = Settings.load()
  settings.dock = s.dock
  if s.theme ~= settings.theme and cfg.themes[s.theme] then
    setTheme(s.theme)
    broadcast({ "theme_changed", n = 1 })
    drawStatus()
  end
end

---------------------------------------------------------------- input
local function onTouch(x, y)
  if pocketPrompt() and (y == 2 or y == 3) and x >= promptX() then   -- the pairing card is on top
    local px = promptX()
    if y == 3 and x >= px + 1 and x <= px + 7 then pcall(psrv.decide, true)
    elseif y == 3 and x >= px + 9 and x <= px + 14 then pcall(psrv.decide, false) end
    return
  end
  local tz = toast and toast.zone                 -- tap a toast to dismiss it
  if tz and x >= tz[1] and x <= tz[2] and y >= tz[3] and y <= tz[4] then toast = nil return end
  if menuOpen then
    menuOpen = false
    local items = menuItems()
    if x <= math.min(MW, W) and y >= 2 and y < 2 + #items then
      local it = items[y - 1]
      if it.act == "apps" then appView = true
      elseif it.act == "settings" then open("settings")
      elseif it.act == "logout" then
        wins, moving, appView, toast = {}, nil, false, nil
        user = doLogin()
        clockTimer = os.startTimer(1)
      elseif it.act == "exit" then running = false
      elseif it.act == "reboot" then
        if world then pcall(world.flush) end
        goodbye("Restarting...")
        os.reboot()
      elseif it.act == "shutdown" then
        if world then pcall(world.flush) end
        goodbye("Shutting down...")
        os.shutdown()
      end
    end
    return
  end

  if y == 1 then
    if x <= NAME_END + 1 then menuOpen = true
    elseif indZone and x >= indZone[1] and x <= indZone[2] then   -- Claude activity: show that drone
      if indZone[3] then os.queueEvent("os_launch", "drones", indZone[3])
      else os.queueEvent("os_launch", "claude") end
    end
    return
  end

  if x <= DW then
    local list = dockEntries()
    local rows, step = dockLayout(#list)
    local i = math.floor((y - 2) / step) + 1
    if (y - 2) % step < rows and list[i] and 2 + (i - 1) * step + rows - 1 <= H then
      if list[i] == "@apps" then appView = not appView else open(list[i]) end
    end
    return
  end

  if appView then
    if y == 2 and x >= W - 2 then appView = false return end
    for _, t in ipairs(viewLayout()) do
      if x >= t.x and x < t.x + t.w and y >= t.y and y < t.y + t.h then
        open(t.id)
        return
      end
    end
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

---------------------------------------------------------------- network (rednet protocol "wardenos")
local PROTO = "wardenos"
local function openModems()
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n) == "modem" and not rednet.isOpen(n) then pcall(rednet.open, n) end
  end
end

local function netStatus()
  return { t = "status", kind = "computer", version = cfg.version, label = os.getComputerLabel(),
           user = user.name, display = mode }
end

---------------------------------------------------------------- main loop
openModems()
out.setBackgroundColor(colors.black)
out.clear()
user = doLogin()
drawStatus()
clockTimer = os.startTimer(1)
local lastClock = clockStr()
drawAll()

while running do
  local ev = table.pack(os.pullEventRaw())
  local name = ev[1]
  local redraw = false
  if world and name ~= "terminate" then pcall(world.event, ev) end  -- drone statuses, map, protected areas
  if psrv and name ~= "terminate" then                    -- pocket requests, relays, the pockets' Claude
    local okp, changed = pcall(psrv.event, ev)
    if okp and changed then redraw = true end
  end

  if name == "monitor_touch" then
    if ev[2] == monSide then onTouch(ev[3], ev[4]) redraw = true end

  elseif name == "mouse_click" and screenInput then     -- click on the computer screen
    if ev[2] == 1 then onTouch(ev[3], ev[4]) redraw = true end

  elseif name == "mouse_scroll" and screenInput then    -- wheel goes to the window under the pointer
    local t = topWin()
    local x, y = ev[3], ev[4]
    if t and not menuOpen and not appView and x >= t.x and x < t.x + t.w and y > t.y and y < t.y + t.h then
      send(t, { "mouse_scroll", ev[2], x - t.x + 1, y - t.y, n = 4 })
    end

  elseif name == "timer" and ev[2] == clockTimer then
    clockTimer = os.startTimer(1)
    local visible = 0
    for _, w in ipairs(wins) do if not w.min then visible = visible + 1 end end
    local c = clockStr()
    if c ~= lastClock or (visible > 1 and not appView) then
      lastClock = c
      redraw = true
    else
      drawTop()
      local t = topWin()
      if t and not menuOpen and not appView then t.win.restoreCursor() end
    end

  elseif name == "os_launch" then
    -- an app with openEvent that already runs gets the argument as an event instead of a second copy
    local app, mine = apps[ev[2]], nil
    if app and app.openEvent and not app.multi then
      for i = #wins, 1, -1 do if wins[i].app == ev[2] then mine = wins[i] break end end
    end
    if mine then
      menuOpen, appView = false, false
      focus(mine)
      if ev[3] ~= nil then send(mine, { app.openEvent, ev[3], n = 2 }) end
    else
      spawn(ev[2], ev[3])
    end
    redraw = true

  elseif name == "os_toast" then                         -- os.queueEvent("os_toast", text): a short message
    local s = tostring(ev[2] or ""):gsub("[%c]", " ")
    if s ~= "" then
      toast = { text = s, timer = os.startTimer(3) }
      redraw = true
    end

  elseif name == "timer" and toast and ev[2] == toast.timer then
    toast = nil
    redraw = true

  elseif name == "os_apps_changed" then                  -- the App Store installed or removed an app
    loadApps()
    broadcast(ev)
    redraw = true

  elseif name == "os_settings" then                      -- the Settings app saved something
    reloadSettings()
    redraw = true

  elseif name == "os_update" then                        -- the Settings app asks for an update
    running, exitAction = false, "update"

  elseif name == "monitor_resize" or name == "term_resize" then
    redraw = true

  elseif name == "rednet_message" and ev[4] == PROTO then  -- answer pings, apps get every message
    if type(ev[3]) == "table" and ev[3].t == "ping" then rednet.send(ev[2], netStatus(), PROTO) end
    broadcast(ev)
    if type(ev[3]) == "table" and ev[3].t == "status" then  -- a drone's task (Claude's?) started or ended
      local okA, a = pcall(activity)
      if okA and ((a and a.long) or "") ~= lastAct then redraw = true end
    end

  elseif name == "peripheral" then                         -- a modem attached later
    openModems()
    broadcast(ev)

  elseif name == "key" and ev[2] == keys.f12 then
    running = false

  elseif name == "key" or name == "key_up" or name == "char"
      or name == "paste" or name == "terminate" then
    local t = topWin()
    if t and not appView then send(t, ev) end

  elseif name:sub(1, 5) == "mouse" then
    -- other mouse events ignored

  else
    broadcast(ev)
  end

  if sweep() then
    redraw = true
    for id in pairs(ghosts) do                             -- a removed app's last window was closed
      local used = false
      for _, w in ipairs(wins) do if w.app == id then used = true end end
      if not used then ghosts[id] = nil end
    end
  end
  if redraw and running then
    drawAll()
  elseif running and (pocketPrompt() or toast) then        -- keep the card / toast above window updates
    drawPocketPrompt()
    drawToast()
    local t = topWin()
    if t and not menuOpen and not appView then t.win.restoreCursor() end
  end
end
goodbye(exitAction == "update" and "Updating..." or "Exiting to CraftOS...")

---------------------------------------------------------------- shutdown of the desktop
if world then pcall(world.flush) end
local function reset(t)
  for i = 0, 15 do
    local c = 2 ^ i
    t.setPaletteColour(c, term.nativePaletteColour(c))
  end
  t.setBackgroundColor(colors.black)
  t.setTextColor(colors.white)
  t.clear()
  t.setCursorBlink(false)
end
if mon then
  mon.setTextScale(0.5)
  reset(mon)
end
reset(scr)
term.redirect(scr)
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
  fn("update", cfg.branch, "-y")
  return
end
print(cfg.name .. " stopped. Reboot to start it again.")
