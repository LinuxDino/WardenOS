-- WardenOS Pocket: a small touch UI for Advanced Pocket Computers (26x20 screen).
--   connected mode  a paired WardenOS computer (the "server") runs drones and Claude; the pocket is its remote
--   local mode      the pocket talks to drones itself and runs Claude with its own API key
-- Needs a wireless or ender modem upgrade for anything on the network (rednet protocol "wardenos").
local OS = dofile("/os/config.lua")
local PROTO = "wardenos"
local CONF = "/os/pocket/config"
local ONLINE = 10                               -- seconds: a drone that reported since then is online
local PAIR_WAIT = 60
local CMD_WAIT = 20

local native = term.current()
local W, H = native.getSize()
local me = os.getComputerID()
local clock = os.clock

---------------------------------------------------------------- config (/os/pocket/config)
local conf = { theme = OS.default }             -- mode = "server" | "local" (nil = ask), server = computer id
do
  local f = fs.exists(CONF) and fs.open(CONF, "r")
  local d = f and textutils.unserialize(f.readAll())
  if f then f.close() end
  if type(d) == "table" then
    if d.mode == "server" or d.mode == "local" then conf.mode = d.mode end
    conf.server = tonumber(d.server)
    if type(d.serverLabel) == "string" then conf.serverLabel = d.serverLabel end
    if OS.themes[d.theme] then conf.theme = d.theme end
  end
end
local function saveConf()
  fs.makeDir(fs.getDir(CONF))
  local f = fs.open(CONF, "w")
  if not f then return end
  f.write(textutils.serialize({ mode = conf.mode, server = conf.server, serverLabel = conf.serverLabel, theme = conf.theme }))
  f.close()
end

---------------------------------------------------------------- theme (same palettes as the desktop)
local T = {}
local function applyTheme()
  local th = OS.themes[conf.theme] or OS.themes[OS.default]
  for k in pairs(T) do T[k] = nil end
  for k, v in pairs(th) do if k ~= "palette" then T[k] = v end end
  for c, hex in pairs(th.palette) do native.setPaletteColour(c, hex) end
end
applyTheme()

---------------------------------------------------------------- Claude (local mode runs it here)
local core, coreErr, engine
local function getCore()
  if core == nil then
    local ok, m = pcall(dofile, "/os/pocket/claudecore.lua")
    if ok and type(m) == "table" then core = m else core, coreErr = false, tostring(m) end
  end
  return core or nil
end
local function getEngine()
  if not engine and getCore() then engine = core.new({ where = "pocket" }) end
  return engine
end

---------------------------------------------------------------- state
local screen = conf.mode and "home" or "setup"
local zones = {}
local note, noteColor = "", nil
local running, exitAction = true, nil
local serverSeen, notPaired = nil, false
local servers = {}                              -- discovered WardenOS computers [id] = { label, user, seen }
local serversBack = "setup"
local devices = {}                              -- local mode: turtles heard directly [id] = status + seen
local remote = {}                               -- connected mode: drone list from the server
local sel, listScroll = nil, 0
local seq, pending = 0, {}                      -- drone commands waiting for an answer
local pairing                                   -- { id, label, started, state = waiting | denied | timeout }
local remoteChat = { log = {}, busy = false, status = "" }
local chatWaiting = false
local input, chatScroll = "", 0
local shellCo, shellWin, shellFilter
local ticks = 0

local function setNote(s, c) note, noteColor = s or "", c end

---------------------------------------------------------------- network
local function openModems()
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n) == "modem" and not rednet.isOpen(n) then pcall(rednet.open, n) end
  end
end
local function send(id, msg)
  if not rednet.isOpen() then return false end
  return rednet.send(id, msg, PROTO)
end
local function ping()
  if rednet.isOpen() then rednet.broadcast({ t = "ping" }, PROTO) end
end
local function connected() return conf.mode == "server" end
local function toServer(msg)
  if not conf.server then return false end
  return send(conf.server, msg)
end
local function controller() return connected() and conf.server or me end

local function droneList()
  if connected() then return remote end
  local out, now = {}, clock()
  for _, d in pairs(devices) do
    d.online = (now - d.seen) < ONLINE
    out[#out + 1] = d
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end
local function findDrone(id)
  for _, d in ipairs(droneList()) do if d.id == id then return d end end
end

local function command(id, cmd, arg)
  if not rednet.isOpen() then setNote("No modem on this pocket", T.bad) return end
  if connected() and not conf.server then setNote("Pick a server in Settings", T.warn) return end
  seq = seq + 1
  pending[seq] = { cmd = cmd, drone = id, at = clock() }
  if connected() then
    toServer({ t = "pocket_cmd", drone = id, cmd = cmd, arg = arg, seq = seq })
  else
    send(id, { t = "cmd", to = id, seq = seq, cmd = cmd, arg = arg })
  end
  setNote("#" .. id .. " > " .. cmd, T.dim)
end
local function showAck(p, ok, info)
  setNote(("#%d %s %s%s"):format(p.drone, p.cmd, ok and "ok" or "failed", info and (": " .. tostring(info)) or ""),
          ok and T.good or T.bad)
end

local function startPair(id, label)
  pairing = { id = id, label = label, started = clock(), state = "waiting" }
  send(id, { t = "pocket_pair" })
  screen = "pair"
end

local function go(s)
  screen, zones = s, {}
  if s == "drones" or s == "drone" then
    if connected() then toServer({ t = "pocket_drones" }) else ping() end
  elseif s == "servers" then
    servers = {}
    ping()
  elseif s == "claude" then
    chatScroll = 0
    if connected() and conf.server then
      chatWaiting = true
      toServer({ t = "pocket_claude", op = "poll" })
    end
  end
end

-- returns true when the screen should be redrawn
local function onNet(from, m)
  local t = m.t
  if from == conf.server then serverSeen = clock() end
  if t == "status" then
    if m.kind == "computer" then
      servers[from] = { id = from, label = m.label, user = m.user, version = m.version, seen = clock() }
      return screen == "servers"
    elseif m.kind == "turtle" then
      local d = devices[from] or { id = from }
      for k, v in pairs(m) do d[k] = v end
      d.id, d.seen = from, clock()
      devices[from] = d
      return not connected() and (screen == "drones" or screen == "drone" or screen == "home")
    end
    return false
  elseif t == "ack" then                        -- local mode: a drone answers this pocket
    local p = pending[m.seq]
    if p and not connected() and p.drone == from and p.cmd == m.cmd then
      pending[m.seq] = nil
      showAck(p, m.ok, m.info)
      return true
    end
    return false
  elseif t == "pocket_paired" then
    if not (pairing and pairing.id == from and pairing.state == "waiting") then return false end
    if m.ok then
      conf.mode, conf.server, conf.serverLabel = "server", from, pairing.label
      saveConf()
      notPaired, serverSeen, pairing = false, clock(), nil
      remote, remoteChat = {}, { log = {}, busy = false, status = "" }
      go("home")
      setNote("Paired with computer #" .. from, T.good)
    else
      pairing.state = m.info == "timed out" and "timeout" or "denied"
    end
    return true
  end
  if from ~= conf.server or not connected() then return false end
  if t == "pocket_drones" then
    remote = type(m.drones) == "table" and m.drones or {}
    notPaired = false
    return screen == "drones" or screen == "drone" or screen == "home"
  elseif t == "pocket_ack" then
    local p = pending[m.seq]
    if not p then return false end
    pending[m.seq] = nil
    showAck(p, m.ok, m.info)
    return true
  elseif t == "pocket_claude" then
    remoteChat = m
    if type(remoteChat.log) ~= "table" then remoteChat.log = {} end
    chatWaiting, notPaired = false, false
    return screen == "claude" or screen == "home"
  elseif t == "pocket_error" then
    if m.info == "not paired" then notPaired = true end
    if m.seq then pending[m.seq] = nil end
    if m.req == "pocket_claude" then chatWaiting = false remoteChat.busy = false end
    setNote("Server: " .. tostring(m.info), T.bad)
    return true
  end
  return false
end

local function onTick()
  ticks = ticks + 1
  if pairing and pairing.state == "waiting" and clock() - pairing.started > PAIR_WAIT then pairing.state = "timeout" end
  for s, p in pairs(pending) do
    if clock() - p.at > CMD_WAIT then
      pending[s] = nil
      setNote(("#%d %s: no answer"):format(p.drone, p.cmd), T.bad)
    end
  end
  if screen == "servers" and ticks % 2 == 0 then ping() end
  if connected() then
    if screen == "drones" or screen == "drone" then toServer({ t = "pocket_drones" }) end
    if screen == "claude" and (remoteChat.busy or chatWaiting) then toServer({ t = "pocket_claude", op = "poll" }) end
    if ticks % 3 == 0 then toServer({ t = "ping" }) end      -- keeps the connection dot honest
  elseif (screen == "drones" or screen == "drone") and ticks % 2 == 0 then
    ping()
  end
end

---------------------------------------------------------------- drawing
local function put(x, y, s, fg, bg)
  s = tostring(s)
  if y < 1 or y > H then return end
  if x < 1 then s, x = s:sub(2 - x), 1 end
  if x > W or s == "" then return end
  native.setCursorPos(x, y)
  native.setTextColor(fg or T.text)
  native.setBackgroundColor(bg or T.bg)
  native.write(s:sub(1, W - x + 1))
end
local function fill(y, h, bg, x, w)
  x, w = x or 1, w or W
  for r = y, y + h - 1 do put(x, r, string.rep(" ", w), T.text, bg) end
end
local function zone(x, y, w, h, fn) zones[#zones + 1] = { x, y, x + w - 1, y + h - 1, fn } end
local function button(x, y, label, fn, fg, bg)
  label = " " .. label .. " "
  put(x, y, label, fg or T.text, bg or T.panel)
  zone(x, y, #label, 1, fn)
  return x + #label + 1
end
-- buttons flow from x = 2 and wrap; returns the next free row
local function buttons(y, items)
  local x = 2
  for _, b in ipairs(items) do
    if x > 2 and x + #b[1] + 1 > W - 1 then x, y = 2, y + 1 end
    x = button(x, y, b[1], b[2], b.fg, b.bg)
  end
  return y + 1
end

local function ascii(s) return (tostring(s):gsub("[\192-\255][\128-\191]*", "?")) end
local function wrap(text, width)
  local out = {}
  for para in (ascii(text) .. "\n"):gmatch("(.-)\n") do
    local line = ""
    for word in para:gmatch("%S+") do
      while #word > width do
        if line ~= "" then out[#out + 1] = line line = "" end
        out[#out + 1] = word:sub(1, width)
        word = word:sub(width + 1)
      end
      if line == "" then line = word
      elseif #line + 1 + #word <= width then line = line .. " " .. word
      else out[#out + 1] = line line = word end
    end
    out[#out + 1] = line
  end
  while #out > 0 and out[#out] == "" do out[#out] = nil end
  return out
end
local function para(y, text, fg, x)              -- wrapped text, returns the next free row
  x = x or 2
  for _, l in ipairs(wrap(text, W - x)) do put(x, y, l, fg) y = y + 1 end
  return y
end

local function modeLabel()
  if conf.mode == "server" then return conf.server and ("#" .. conf.server) or "no srv" end
  if conf.mode == "local" then return "local" end
  return ""
end
local function connColor()
  if not rednet.isOpen() then return T.bad end
  if connected() then
    if not conf.server or notPaired then return T.bad end
    return (serverSeen and clock() - serverSeen < 12) and T.good or T.warn
  end
  return T.good
end

-- row 1: title (with < back), mode and connection dot; returns the column where the mode label starts
local function header(title, back)
  fill(1, 1, T.panel)
  local x = 2
  if back then
    put(1, 1, " < ", T.accent, T.panel)
    zone(1, 1, 3, 1, back)
    x = 4
  end
  local right = modeLabel()
  local rx = W - 2 - #right
  put(rx, 1, right, T.dim, T.panel)
  put(W - 1, 1, "\7", connColor(), T.panel)
  put(x, 1, title:sub(1, math.max(0, rx - x - 1)), back and T.text or T.accent, T.panel)
  return rx
end
local function footer()
  if note ~= "" then put(1, H, note:sub(1, W), noteColor or T.warn) end
end

-- a big tap target: panel rows with text lines, from x = 2 to W - 1; returns the next free row
local function tile(y, lines, fn)
  local rows = {}
  for _, l in ipairs(lines) do
    for _, s in ipairs(wrap(l[1], W - 3)) do rows[#rows + 1] = { s, l[2] } end
  end
  fill(y, #rows + 2, T.panel, 2, W - 2)
  for i, r in ipairs(rows) do put(3, y + i, r[1], r[2] or T.text, T.panel) end
  zone(2, y, W - 2, #rows + 2, fn)
  return y + #rows + 2
end

---------------------------------------------------------------- screens
local function back(to) return function() go(to) end end

local function drawSetup()
  header("WardenOS Pocket")
  put(2, 3, "Welcome!", T.accent)
  local y = para(4, "How should this pocket computer work?", T.text) + 1
  y = tile(y, { { "Connect to a WardenOS computer" }, { "(recommended)", T.good } }, function()
    conf.mode = "server"
    saveConf()
    serversBack = "setup"
    go("servers")
  end) + 1
  y = tile(y, { { "Run on this pocket only" }, { "standalone", T.dim } }, function()
    conf.mode = "local"
    saveConf()
    go("home")
  end) + 1
  para(y, "You can change this later in Settings.", T.dim)
end

local function onlineCount()
  local n = 0
  for _, d in ipairs(droneList()) do if d.online then n = n + 1 end end
  return n
end

local function claudeInfo()
  if connected() then
    if remoteChat.approval then return "needs OK" end
    return remoteChat.busy and "busy" or ""
  end
  if engine and engine.approval then return "needs OK" end
  if engine and engine.busy then return "busy" end
  if getCore() and not core.api.getKey() then return "no key" end
  return ""
end

local function openTerminal()
  shellWin = window.create(native, 1, 1, W, H, true)
  shellCo = coroutine.create(function()
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(T.accent)
    print("WardenOS Pocket terminal")
    term.setTextColor(T.dim)
    print("Type exit to go back.")
    term.setTextColor(colors.white)
    os.run(setmetatable({ shell = shell, multishell = false }, { __index = _G }), "/rom/programs/shell.lua")
  end)
  shellFilter = nil
  screen = "terminal"
end

local function drawHome()
  header("WardenOS Pocket")
  local items = {
    { "(T)", "Drones", colors.orange, function() go("drones") end },
    { " * ", "Claude", colors.orange, function() go("claude") end },
    { ">_", "Terminal", T.accent, openTerminal },
    { "[=]", "Settings", T.dim, function() go("settings") end },
  }
  local dinfo
  if not rednet.isOpen() then dinfo = "no modem"
  elseif connected() and not conf.server then dinfo = "no server"
  else dinfo = onlineCount() .. " online" end
  local info = { dinfo, claudeInfo(), "shell", "" }
  local y = 3
  for i, it in ipairs(items) do
    fill(y, 3, T.panel, 2, W - 2)
    put(3, y + 1, it[1], it[3], T.panel)
    put(7, y + 1, it[2], T.text, T.panel)
    local s = info[i]:sub(1, W - 18)
    put(W - 1 - #s, y + 1, s, T.dim, T.panel)
    zone(2, y, W - 2, 3, it[4])
    y = y + 4
  end
  local line
  if connected() then
    if not conf.server then line = "Not paired: see Settings"
    elseif notPaired then line = "#" .. conf.server .. " forgot this pocket"
    else line = "Server: #" .. conf.server .. " " .. (conf.serverLabel or "") end
  else
    line = "Local mode"
  end
  put(2, H - 1, line:sub(1, W - 2), T.dim)
  if note ~= "" then footer() else put(2, H, "F12: exit to CraftOS", T.dim) end
end

local function drawServers()
  header("Pick server", back(serversBack))
  if not rednet.isOpen() then
    para(3, "No modem. Put a wireless or ender modem upgrade on this pocket computer.", T.bad)
    footer()
    return
  end
  local y = para(3, "Tap your WardenOS computer:", T.dim) + 1
  local list = {}
  for _, s in pairs(servers) do list[#list + 1] = s end
  table.sort(list, function(a, b) return a.id < b.id end)
  if #list == 0 then
    y = para(y, "Searching...", T.dim) + 1
    para(y, "The computer must run WardenOS 1.3 or newer and be in modem range.", T.dim)
  end
  for _, s in ipairs(list) do
    if y + 1 > H - 2 then break end
    fill(y, 2, T.panel, 2, W - 2)
    put(3, y, ("#%d %s"):format(s.id, s.label or "computer"):sub(1, W - 4), T.text, T.panel)
    put(3, y + 1, ("user %s  v%s"):format(tostring(s.user or "?"), tostring(s.version or "?")):sub(1, W - 4), T.dim, T.panel)
    zone(2, y, W - 2, 2, function() startPair(s.id, s.label) end)
    y = y + 3
  end
  button(2, H - 1, "Refresh", function() servers = {} ping() end)
  footer()
end

local function drawPair()
  header("Pairing")
  local p = pairing
  if not p then go("servers") return end
  local y
  if p.state == "waiting" then
    y = para(3, ("Waiting for approval on computer #%d..."):format(p.id), T.text) + 1
    y = para(y, "Tap Allow on that computer's screen.", T.dim) + 1
    put(2, y, ("%ds left"):format(math.max(0, math.ceil(PAIR_WAIT - (clock() - p.started)))), T.dim)
    button(2, y + 2, "Cancel", function()
      send(p.id, { t = "pocket_unpair" })      -- drops the request on the computer
      pairing = nil
      go("servers")
    end, T.text, T.panel)
  else
    y = para(3, p.state == "denied" and ("Computer #%d said no."):format(p.id)
                 or ("No answer from computer #%d in %ds."):format(p.id, PAIR_WAIT), T.bad) + 1
    y = para(y, "Is it running WardenOS and in modem range?", T.dim) + 1
    buttons(y, {
      { "Try again", function() startPair(p.id, p.label) end, fg = T.bg, bg = T.accent },
      { "Back", function() pairing = nil go("servers") end },
    })
  end
  footer()
end

local function fuelText(d)
  if d.fuel == "unlimited" then return "unlimited" end
  if type(d.fuel) ~= "number" then return "?" end
  if type(d.fuelLimit) == "number" then return d.fuel .. "/" .. d.fuelLimit end
  return tostring(d.fuel)
end

local function notReady(title)                 -- common "can't do this yet" screens; true if shown
  if connected() and not conf.server then
    header(title, back("home"))
    local y = para(3, "Not connected to a WardenOS computer yet.", T.text) + 1
    button(2, y, "Pick server", function() serversBack = "home" go("servers") end, T.bg, T.accent)
    footer()
    return true
  end
  if not rednet.isOpen() and title ~= "Claude" or (connected() and not rednet.isOpen()) then
    header(title, back("home"))
    para(3, "No modem. Put a wireless or ender modem upgrade on this pocket computer.", T.bad)
    footer()
    return true
  end
  return false
end

local function drawDrones()
  if notReady("Drones") then return end
  header("Drones", back("home"))
  local list = droneList()
  local mine = controller()
  buttons(2, {
    { "All home", function()
      local n = 0
      for _, d in ipairs(droneList()) do
        if d.online and d.owner == mine then command(d.id, "home") n = n + 1 end
      end
      setNote(n > 0 and ("Calling %d drone(s) home"):format(n) or "No drones of yours online", T.warn)
    end, fg = T.bg, bg = T.accent },
    { "Refresh", function() go("drones") setNote("Searching...", T.dim) end },
  })
  local rows = math.floor((H - 4) / 2)
  listScroll = math.max(0, math.min(listScroll, #list - rows))
  if #list == 0 then
    local y = para(4, connected() and "No drones seen by the computer yet." or "No drones found yet.", T.dim) + 1
    para(y, "Install the drone agent on a turtle: pastebin get CeQfPV78 install", T.dim)
  end
  for i = 1, rows do
    local d = list[listScroll + i]
    if not d then break end
    local y = 4 + (i - 1) * 2
    put(2, y, "\7", d.online and T.good or T.dim)
    put(4, y, ("#%d %s"):format(d.id, tostring(d.label or "drone")):sub(1, W - 4), d.online and T.text or T.dim)
    local sub
    if d.owner ~= mine then
      sub = d.owner and ("owned by #" .. d.owner) or "free: tap to claim"
    else
      sub = tostring(d.task or "?") .. "  fuel " .. fuelText(d)
    end
    put(4, y + 1, sub:sub(1, W - 4), T.dim)
    zone(1, y, W, 2, function() sel = d.id go("drone") end)
  end
  footer()
end

local function drawDrone()
  local d = sel and findDrone(sel)
  if not d then screen = "drones" return drawDrones() end
  header(("#%d %s"):format(d.id, tostring(d.label or "drone")), back("drones"))
  local mine = controller()
  put(2, 3, "Task", T.dim) put(8, 3, (tostring(d.task) .. " (" .. tostring(d.state) .. ")"):sub(1, W - 8))
  put(2, 4, "Fuel", T.dim) put(8, 4, fuelText(d), type(d.fuel) == "number" and d.fuel < 100 and T.bad or T.text)
  local nav = type(d.nav) == "table" and d.homeSet and ("%s %s %s"):format(tostring(d.nav.x), tostring(d.nav.y), tostring(d.nav.z))
  put(2, 5, "Home", T.dim) put(8, 5, nav or "not set", nav and T.text or T.dim)
  local owner = d.owner == mine and (connected() and "server" or "you") or (d.owner and ("#" .. d.owner) or "nobody")
  put(2, 6, "Owner", T.dim) put(8, 6, owner, d.owner == mine and T.good or T.warn)
  put(W - 7, 6, d.online and " online" or "offline", d.online and T.good or T.bad)
  if type(d.lastTask) == "table" then
    put(2, 7, "Last", T.dim)
    put(8, 7, (tostring(d.lastTask.name) .. (d.lastTask.ok and " ok" or " failed")):sub(1, W - 8),
        d.lastTask.ok and T.text or T.bad)
  end
  local function cmd(c) return function() command(d.id, c) end end
  local y = 9
  if d.owner ~= mine then
    y = buttons(y, { { "Claim", cmd("claim"), fg = T.bg, bg = T.accent } })
  else
    y = buttons(y, {
      { "Go home", cmd("home"), fg = T.bg, bg = T.accent },
      { "Stop", cmd("stop"), fg = T.bad },
      { "Set home", cmd("sethome") },
    })
    y = buttons(y, { { "Up", cmd("up") }, { "Fwd", cmd("forward") }, { "Down", cmd("down") } })
    y = buttons(y, { { "Left", cmd("turnLeft") }, { "Back", cmd("back") }, { "Right", cmd("turnRight") } })
    if not connected() and getCore() then
      local given = core.api.getDrones()[d.id]
      y = buttons(y, { { given and "Take from Claude" or "Give to Claude", function()
        core.api.setDrone(d.id, not given)
        setNote(given and "Claude no longer has it" or "Claude can use it now", T.warn)
      end, fg = given and T.warn or T.accent } })
    end
  end
  y = y + 1
  if y < H then put(2, y, "Activity", T.dim) end
  local log = type(d.log) == "table" and d.log or {}
  for i = 1, H - 1 - y do
    if not log[i] then break end
    put(2, y + i, tostring(log[i]):sub(1, W - 2))
  end
  footer()
end

local function chatData()
  if connected() then return remoteChat end
  if not engine then return { log = {}, busy = false, status = "" } end
  return { log = engine.log, busy = engine.busy, status = engine.status, approval = engine.approval }
end

local function decide(c)
  if connected() then
    remoteChat.approval = nil
    toServer({ t = "pocket_claude", op = "decision", choice = c })
  elseif engine then
    engine.decide(c)
  end
end

local function submit()
  local text = input
  if not text:match("%S") then return end
  if connected() then
    if remoteChat.busy or chatWaiting or remoteChat.approval then return end
    input, chatScroll = "", 0
    remoteChat.log[#remoteChat.log + 1] = { kind = "user", text = text }
    remoteChat.busy, remoteChat.status, remoteChat.error = true, "Sending...", nil
    chatWaiting = true
    toServer({ t = "pocket_claude", op = "send", text = text })
  else
    local c = getEngine()
    if not c then setNote("Claude missing: " .. tostring(coreErr), T.bad) return end
    if c.busy then return end
    input, chatScroll = "", 0
    local ok, why = c.send(text, core.api.getKey())
    if not ok and why then setNote(why, T.bad) end
  end
end

local function needsKey() return not connected() and getCore() and not core.api.getKey() end
local function canType()
  if screen ~= "claude" then return false end
  if needsKey() then return true end
  local d = chatData()
  return not d.busy and not d.approval and not (connected() and chatWaiting)
end

local COLORS = { user = "accent", claude = "text", tool = "warn", info = "dim", error = "bad" }
local function drawClaude()
  if notReady("Claude") then return end
  if not connected() and not getCore() then
    header("Claude", back("home"))
    para(3, "Claude is not available: " .. tostring(coreErr), T.bad)
    return
  end
  if needsKey() then
    header("Claude", back("home"))
    local y = para(3, "Paste an Anthropic API key (console.anthropic.com) and press Enter. Use is billed to that key.", T.dim) + 1
    y = para(y, "Saved in /os/claude/key on this pocket.", T.warn) + 1
    local shown = input == "" and "paste key here" or (input:sub(1, 7) .. string.rep("*", math.max(0, #input - 7)))
    put(2, y, (" " .. shown:sub(-(W - 4)) .. string.rep(" ", W)):sub(1, W - 2), input == "" and T.dim or T.text, T.panel)
    footer()
    return
  end
  local d = chatData()
  local rx = header("Claude", back("home"))
  if not d.busy then
    button(rx - 6, 1, "new", function()
      if connected() then toServer({ t = "pocket_claude", op = "new" }) remoteChat.log = {}
      elseif engine then engine.reset() end
      chatScroll = 0
    end, T.text, T.panel)
  end
  local lines = {}
  for _, e in ipairs(d.log or {}) do
    local prefix = e.kind == "user" and "> " or (e.kind == "tool" and "# " or "")
    for _, l in ipairs(wrap(prefix .. tostring(e.text), W - 1)) do
      lines[#lines + 1] = { l, T[COLORS[e.kind]] or T.text }
    end
    lines[#lines + 1] = { "", T.text }
  end
  if #(d.log or {}) == 0 then
    local who = connected() and ("computer #" .. conf.server) or "this pocket"
    for _, l in ipairs(wrap("Ask Claude anything. It runs on " .. who .. " and can use its files, peripherals and the drones you gave it, asking you first.", W - 2)) do
      lines[#lines + 1] = { " " .. l, T.dim }
    end
  end
  local bottom = H - 2
  local cardH = 0
  local body
  if d.approval then
    body = wrap(tostring(d.approval.text), W - 2)
    cardH = math.min(#body, math.max(1, H - 11)) + 3
    bottom = H - 1 - cardH
  end
  local rows = bottom - 1
  chatScroll = math.max(0, math.min(chatScroll, #lines - rows))
  local first = math.max(1, #lines - rows + 1 - chatScroll)
  for i = 0, rows - 1 do
    local l = lines[first + i]
    if l then put(1, 2 + i, l[1], l[2]) end
  end
  if d.approval then
    local y = bottom + 1
    fill(y, cardH, T.panel)
    put(2, y, ("Run %s?"):format(tostring(d.approval.name)):sub(1, W - 2), T.warn, T.panel)
    for i = 1, cardH - 3 do put(2, y + i, (body[i] or ""):sub(1, W - 2), T.text, T.panel) end
    local bx = button(2, y + cardH - 2, "Allow", function() decide("allow") end, T.bg, T.good)
    bx = button(bx, y + cardH - 2, "Always", function() decide("always") end)
    button(bx, y + cardH - 2, "Deny", function() decide("deny") end, T.bg, T.bad)
  end
  if note ~= "" then
    put(1, H - 1, note:sub(1, W), noteColor or T.warn)
  elseif d.error and not d.busy then
    put(1, H - 1, tostring(d.error):sub(1, W), T.bad)
  elseif d.busy and d.status and d.status ~= "" then
    put(1, H - 1, tostring(d.status):sub(1, W), T.dim)
  end
  local busy = not canType()
  local shown = busy and "(wait...)" or input
  if #shown > W - 3 then shown = shown:sub(-(W - 3)) end
  fill(H, 1, T.panel)
  put(1, H, "> ", T.accent, T.panel)
  put(3, H, shown, busy and T.dim or T.text, T.panel)
end

local function drawSettings()
  header("Settings", back("home"))
  local function pick(on) return on and T.bg or T.text, on and T.accent or T.panel end
  put(2, 3, "Mode", T.dim)
  local fg, bg = pick(conf.mode == "server")
  local x = button(2, 4, "Connect", function()
    conf.mode = "server"
    saveConf()
    if not conf.server then serversBack = "settings" go("servers") end
  end, fg, bg)
  fg, bg = pick(conf.mode == "local")
  button(x, 4, "Local", function() conf.mode = "local" saveConf() end, fg, bg)

  put(2, 6, "Server", T.dim)
  put(9, 6, (conf.server and ("#" .. conf.server .. " " .. (conf.serverLabel or "")) or "none"):sub(1, W - 9),
      conf.server and T.text or T.dim)
  buttons(7, {
    { "Pick server", function() serversBack = "settings" go("servers") end },
    { "Forget", function()
      if conf.server then
        toServer({ t = "pocket_unpair" })
        setNote("Forgot computer #" .. conf.server, T.warn)
        conf.server, conf.serverLabel, remote = nil, nil, {}
        remoteChat = { log = {}, busy = false, status = "" }
        saveConf()
      end
    end, fg = T.bad },
  })

  put(2, 9, "Theme", T.dim)
  fg, bg = pick(conf.theme == "dark")
  x = button(2, 10, "Dark", function() conf.theme = "dark" saveConf() applyTheme() end, fg, bg)
  fg, bg = pick(conf.theme == "light")
  button(x, 10, "Light", function() conf.theme = "light" saveConf() applyTheme() end, fg, bg)

  button(2, 12, "Update WardenOS", function() exitAction, running = "update", false end)
  button(2, 14, "Exit to CraftOS", function() running = false end)
  if not connected() and getCore() and core.api.getKey() then
    button(2, 16, "Forget Claude key", function() core.api.forgetKey() setNote("Claude key removed", T.warn) end, T.bad)
  end
  put(2, H - 1, ("WardenOS Pocket %s  #%d"):format(OS.version, me):sub(1, W - 2), T.dim)
  footer()
end

local DRAW = { setup = drawSetup, home = drawHome, servers = drawServers, pair = drawPair, drones = drawDrones,
               drone = drawDrone, claude = drawClaude, settings = drawSettings }

local function draw()
  zones = {}
  native.setCursorBlink(false)
  native.setBackgroundColor(T.bg)
  native.clear()
  local f = DRAW[screen] or drawHome
  f()
  if screen == "claude" and canType() then
    if needsKey() then return end
    native.setCursorPos(math.min(W, 3 + math.min(#input, W - 3)), H)
    native.setTextColor(T.text)
    native.setBackgroundColor(T.panel)
    native.setCursorBlink(true)
  end
end

---------------------------------------------------------------- input
local function click(x, y)
  for i = #zones, 1, -1 do                      -- the last drawn zone is on top
    local z = zones[i]
    if x >= z[1] and x <= z[3] and y >= z[2] and y <= z[4] then
      setNote("")
      z[5]()
      return true
    end
  end
end

local function onKey(e, a)
  if screen == "setup" and e == "char" then
    if a == "1" then zones = {} drawSetup() zones[1][5]() end   -- same as tapping the tiles
    if a == "2" then zones = {} drawSetup() zones[2][5]() end
    return true
  end
  if screen ~= "claude" then return false end
  if e == "char" or e == "paste" then
    if canType() then input = input .. a return true end
  elseif e == "key" then
    if a == keys.backspace then input = input:sub(1, -2) return true
    elseif a == keys.enter then
      if needsKey() then
        if input:match("%S") then core.api.setKey(input) input = "" end
      elseif canType() then
        submit()
      end
      return true
    elseif a == keys.up or a == keys.pageUp then chatScroll = chatScroll + (a == keys.up and 1 or 5) return true
    elseif a == keys.down or a == keys.pageDown then
      chatScroll = math.max(0, chatScroll - (a == keys.down and 1 or 5))
      return true
    end
  end
  return false
end

local function resumeShell(ev)
  if not shellCo then return end
  if shellFilter and ev[1] ~= shellFilter and ev[1] ~= "terminate" then return end
  local old = term.redirect(shellWin)
  local ok, f = coroutine.resume(shellCo, table.unpack(ev, 1, ev.n or #ev))
  term.redirect(old)
  if not ok or coroutine.status(shellCo) == "dead" then
    shellCo, shellWin, shellFilter = nil, nil, nil
    if not ok and not tostring(f):find("Terminated") then setNote("shell: " .. tostring(f), T.bad) end
    go("home")
  else
    shellFilter = f
  end
end

---------------------------------------------------------------- main loop
openModems()
local tick = os.startTimer(2)
draw()
while running do
  local ev = table.pack(os.pullEventRaw())
  local e = ev[1]
  local redraw = false

  if engine then
    engine.resume(ev)
    if engine.dirty then
      engine.dirty = false
      redraw = screen == "claude" or screen == "home"
    end
  end

  if e == "rednet_message" then
    if ev[4] == PROTO and type(ev[3]) == "table" and onNet(ev[2], ev[3]) then redraw = true end
  elseif e == "timer" and ev[2] == tick then
    tick = os.startTimer(2)
    onTick()
    redraw = true
  elseif e == "peripheral" or e == "peripheral_detach" then
    openModems()
    redraw = true
  end

  if screen == "terminal" then
    if shellCo then resumeShell(ev) else openTerminal() resumeShell({ n = 0 }) end
    if screen ~= "terminal" then redraw = true end
  elseif e == "terminate" or (e == "key" and ev[2] == keys.f12) then
    running = false
  elseif e == "mouse_click" then
    if click(ev[3], ev[4]) then redraw = true end
    if screen == "terminal" then resumeShell({ n = 0 }) end
  elseif e == "mouse_scroll" then
    if screen == "claude" then chatScroll = math.max(0, chatScroll - ev[2]) else listScroll = listScroll + ev[2] end
    redraw = true
  elseif e == "char" or e == "paste" or e == "key" then
    if onKey(e, ev[2]) then redraw = true end
  elseif e == "term_resize" then
    W, H = native.getSize()
    redraw = true
  end

  if redraw and running and screen ~= "terminal" then draw() end
end

---------------------------------------------------------------- leave
for i = 0, 15 do
  local c = 2 ^ i
  native.setPaletteColour(c, term.nativePaletteColour(c))
end
term.redirect(native)
native.setBackgroundColor(colors.black)
native.setTextColor(colors.white)
native.clear()
native.setCursorPos(1, 1)
native.setCursorBlink(false)

if exitAction == "update" then
  print("Updating WardenOS Pocket...")
  local url = ("https://raw.githubusercontent.com/%s/%s/install.lua"):format(OS.repo, OS.branch)
  local h, err = http and http.get(url)
  if not h then
    printError("Download failed: " .. tostring(err or "http API disabled"))
    return
  end
  local src = h.readAll()
  h.close()
  local fn, lerr = load(src, "=install.lua", "t", setmetatable({ shell = shell }, { __index = _G }))
  if not fn then printError(lerr) return end
  fn("update", OS.branch, "-y")
  return
end
print("WardenOS Pocket stopped. Reboot to start it again.")
