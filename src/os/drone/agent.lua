-- WardenOS Drone agent (runs on a turtle)
-- Reports status over rednet (protocol "wardenos") and takes commands from its owner computer.
-- Installed by the WardenOS installer; started by /startup.lua.
local VERSION = "1.3.0"
local PROTO = "wardenos"
local CFG = "/os/drone/config"
local NAV = "/os/drone/nav"
local RAW = "https://raw.githubusercontent.com/LinuxDino/WardenOS/main/"

if not turtle then
  printError("The WardenOS drone agent only runs on turtles.")
  return
end

---------------------------------------------------------------- config
local cfg = {}
if fs.exists(CFG) then
  local f = fs.open(CFG, "r")
  local d = textutils.unserialize(f.readAll())
  f.close()
  if type(d) == "table" then cfg = d end
end
local function saveCfg()
  fs.makeDir(fs.getDir(CFG))
  local f = fs.open(CFG, "w")
  f.write(textutils.serialize(cfg))
  f.close()
end

---------------------------------------------------------------- state
local me = os.getComputerID()
local task, state = "manual", "ready"           -- what it is doing / ready, busy, error
local pos, hasGps = nil, false
local log = {}                                  -- newest first, what the drone did
local dirty = true
local job = nil                                 -- running task: { name, co, filter }
local lastTask = nil                            -- { name, ok, info } of the last finished task

---------------------------------------------------------------- dead reckoning (relative to home)
-- f: 0 = facing as when home was set, 1 = turned right once, 2 = back, 3 = left
local nav, homeSet = { x = 0, y = 0, z = 0, f = 0 }, false
if fs.exists(NAV) then
  local f = fs.open(NAV, "r")
  local d = textutils.unserialize(f.readAll())
  f.close()
  if type(d) == "table" and type(d.x) == "number" and type(d.y) == "number" and type(d.z) == "number"
     and type(d.f) == "number" then
    nav = { x = d.x, y = d.y, z = d.z, f = d.f % 4 }
    homeSet = d.homeSet == true
  end
end
local function saveNav()
  fs.makeDir(fs.getDir(NAV))
  local f = fs.open(NAV, "w")
  f.write(textutils.serialize({ x = nav.x, y = nav.y, z = nav.z, f = nav.f, homeSet = homeSet }))
  f.close()
end
local DX, DZ = { [0] = 0, 1, 0, -1 }, { [0] = -1, 0, 1, 0 }
local TRACK = {
  forward = function() nav.x, nav.z = nav.x + DX[nav.f], nav.z + DZ[nav.f] end,
  back = function() nav.x, nav.z = nav.x - DX[nav.f], nav.z - DZ[nav.f] end,
  up = function() nav.y = nav.y + 1 end,
  down = function() nav.y = nav.y - 1 end,
  turnRight = function() nav.f = (nav.f + 1) % 4 end,
  turnLeft = function() nav.f = (nav.f + 3) % 4 end,
}
-- wrap the global turtle API so manual commands, tasks and the home navigator all update nav.
-- The originals are kept on the turtle table so restarting the agent never wraps twice.
local rawMoves = rawget(turtle, "_wardenRaw")
if not rawMoves then
  rawMoves = {}
  for n in pairs(TRACK) do rawMoves[n] = turtle[n] end
  turtle._wardenRaw = rawMoves
end
for n, orig in pairs(rawMoves) do
  turtle[n] = function(...)
    local r = table.pack(orig(...))
    if r[1] then
      TRACK[n]()
      dirty = true
      pcall(saveNav)
    end
    return table.unpack(r, 1, r.n)
  end
end

local function clock()
  local t = os.time()
  local h = math.floor(t)
  return string.format("%02d:%02d", h % 24, math.floor((t - h) * 60))
end

local function note(s)
  table.insert(log, 1, clock() .. " " .. s)
  log[9] = nil
  dirty = true
end

local function modems()
  local n = 0
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      if not rednet.isOpen(name) then pcall(rednet.open, name) end
      if rednet.isOpen(name) then n = n + 1 end
    end
  end
  return n
end

local function locate(timeout)
  local x, y, z = gps.locate(timeout or 1)
  if x then
    pos, hasGps = { math.floor(x), math.floor(y), math.floor(z) }, true
  else
    pos, hasGps = nil, false
  end
  dirty = true
end

local function status()
  local items, used = {}, 0
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d then
      used = used + 1
      items[#items + 1] = { slot = i, name = d.name, count = d.count }
    end
  end
  return {
    t = "status", kind = "turtle", version = VERSION,
    label = os.getComputerLabel(), owner = cfg.owner,
    fuel = turtle.getFuelLevel(), fuelLimit = turtle.getFuelLimit(),
    pos = pos, task = task, state = state,
    slots = used, selected = turtle.getSelectedSlot(), items = items,
    log = log, lastTask = lastTask,
    nav = { x = nav.x, y = nav.y, z = nav.z, f = nav.f }, homeSet = homeSet,
  }
end

local function cut(s, n)
  s = tostring(s)
  if #s > n then s = s:sub(1, n - 3) .. "..." end
  return s
end

---------------------------------------------------------------- tasks
-- A task is Lua code sent by the owner ("run" command). It runs as a coroutine driven by worker().
local function finish(j, ok, info, msg)
  if job ~= j then return end
  job = nil
  task, state = "manual", "ready"
  lastTask = { name = j.name, ok = ok, info = cut(info or "", 200) }
  note(cut(msg, 60))
  rednet.broadcast(status(), PROTO)
end

local function say(...)
  local t = {}
  for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end
  note(cut(table.concat(t, " "), 60))
end

local function startJob(name, fn)
  job = { name = name, co = coroutine.create(fn) }
  task, state = name, "working"
  os.queueEvent("wardenos_task")
  return true, "started"
end

local function startTask(arg)
  if type(arg) ~= "table" or type(arg.name) ~= "string" or arg.name == "" or type(arg.code) ~= "string" then
    return false, "bad task"
  end
  local name = arg.name:sub(1, 32)
  local env = setmetatable({}, { __index = _G })
  env.print, env.write = say, say
  env.report = function(...)
    say(...)
    rednet.broadcast(status(), PROTO)
  end
  env.turtle = turtle
  local fn, err = load(arg.code, "=" .. name, "t", env)
  if not fn then return false, "syntax error: " .. tostring(err) end
  return startJob(name, fn)
end

-- built-in task "home": x to 0, then z, then y, then face f = 0
local function goHome()
  local fuel = turtle.getFuelLevel()
  if type(fuel) == "number" and fuel < math.abs(nav.x) + math.abs(nav.y) + math.abs(nav.z) + 10 then
    error("not enough fuel", 0)
  end
  local detours = 0
  local function face(f)
    while nav.f ~= f do
      if (nav.f + 1) % 4 == f then turtle.turnRight() else turtle.turnLeft() end
    end
  end
  local function step(move, dig)
    if move() then return true end
    dig()
    return move() and true or false
  end
  while nav.x ~= 0 or nav.z ~= 0 or nav.y ~= 0 do
    local ok
    if nav.x ~= 0 then
      face(nav.x > 0 and 3 or 1)
      ok = step(turtle.forward, turtle.dig)
    elseif nav.z ~= 0 then
      face(nav.z > 0 and 0 or 2)
      ok = step(turtle.forward, turtle.dig)
    elseif nav.y > 0 then
      ok = step(turtle.down, turtle.digDown)
    else
      ok = step(turtle.up, turtle.digUp)
    end
    if not ok then
      detours = detours + 1
      if detours > 10 or not step(turtle.up, turtle.digUp) then
        error(("blocked at %d %d %d"):format(nav.x, nav.y, nav.z), 0)
      end
    end
  end
  face(0)
  note("arrived home")
  return "arrived home"
end

local function stopTask()
  if job then finish(job, false, "stopped", "task " .. job.name .. " stopped") end
end

local function worker()
  while true do
    if not job then os.pullEvent("wardenos_task") end
    local j, ev = job, { n = 0 }
    while j and job == j do
      -- the task never sees "terminate": that stops the whole agent (os.pullEvent below raises it)
      if ev.n == 0 or j.filter == nil or ev[1] == j.filter then
        local r = table.pack(coroutine.resume(j.co, table.unpack(ev, 1, ev.n)))
        if not r[1] then
          local e = tostring(r[2])
          finish(j, false, e, "task " .. j.name .. " failed: " .. e)
        elseif coroutine.status(j.co) == "dead" then
          local out = {}
          for i = 2, r.n do out[#out + 1] = tostring(r[i]) end
          finish(j, true, table.concat(out, ", "), "task " .. j.name .. " done")
        else
          j.filter = type(r[2]) == "string" and r[2] or nil
        end
      end
      if job == j then ev = table.pack(os.pullEvent()) end
    end
  end
end

---------------------------------------------------------------- commands
local MOVES = {
  forward = turtle.forward, back = turtle.back, up = turtle.up, down = turtle.down,
  turnLeft = turtle.turnLeft, turnRight = turtle.turnRight,
  dig = turtle.dig, digUp = turtle.digUp, digDown = turtle.digDown,
  place = turtle.place, placeUp = turtle.placeUp, placeDown = turtle.placeDown,
  suck = turtle.suck, drop = turtle.drop,
}
local MOVED = { forward = true, back = true, up = true, down = true }
local WHILE_BUSY = { stop = true, claim = true, release = true, label = true, locate = true }

local function refuel()
  local sel, gained = turtle.getSelectedSlot(), 0
  local before = turtle.getFuelLevel()
  if before == "unlimited" then return true end
  for i = 1, 16 do
    if turtle.getItemCount(i) > 0 then
      turtle.select(i)
      turtle.refuel()
    end
  end
  turtle.select(sel)
  gained = turtle.getFuelLevel() - before
  if gained <= 0 then return false, "no fuel items" end
  return true, "+" .. gained
end

local function update()
  if not http then return false, "http API disabled" end
  local h, err = http.get(RAW .. "src/os/drone/agent.lua?t=" .. os.epoch("utc"))
  if not h then return false, tostring(err) end
  local src = h.readAll()
  h.close()
  if not src or not load(src, "=agent.lua", "t", {}) then return false, "download is broken" end
  local f = fs.open("/os/drone/agent.lua", "w")
  f.write(src)
  f.close()
  return true, "rebooting"
end

-- returns ok, info
local function run(from, cmd, arg)
  if cmd == "claim" then
    if cfg.owner and cfg.owner ~= from then return false, "owned by #" .. cfg.owner end
    cfg.owner = from
    saveCfg()
    return true, "owner #" .. from
  end
  if cfg.owner ~= from then
    return false, cfg.owner and ("owned by #" .. cfg.owner) or "claim it first"
  end
  if job and not WHILE_BUSY[cmd] then return false, "busy: " .. job.name end
  if cmd == "release" then
    cfg.owner = nil
    saveCfg()
    return true
  elseif MOVES[cmd] then
    local ok, err = MOVES[cmd]()
    if ok and MOVED[cmd] and hasGps then locate(0.5) end
    return ok, err
  elseif cmd == "refuel" then
    return refuel()
  elseif cmd == "select" then
    local n = tonumber(arg)
    if not n or n < 1 or n > 16 then return false, "bad slot" end
    turtle.select(n)
    return true
  elseif cmd == "locate" then
    locate(2)
    return hasGps, hasGps and table.concat(pos, " ") or "no GPS"
  elseif cmd == "run" then
    return startTask(arg)
  elseif cmd == "sethome" then
    nav, homeSet = { x = 0, y = 0, z = 0, f = 0 }, true
    saveNav()
    note("home set")
    return true
  elseif cmd == "home" then
    if not homeSet then return false, "no home set" end
    return startJob("home", goHome)
  elseif cmd == "stop" then
    stopTask()
    task, state = "manual", "ready"
    return true
  elseif cmd == "label" then
    if type(arg) ~= "string" or arg == "" then return false, "bad label" end
    os.setComputerLabel(arg:sub(1, 32))
    return true
  elseif cmd == "update" then
    return update()
  end
  return false, "unknown command"
end

---------------------------------------------------------------- loops
local function listen()
  while true do
    local from, msg = rednet.receive(PROTO)
    if type(msg) == "table" then
      if msg.t == "ping" then
        rednet.send(from, status(), PROTO)
      elseif msg.t == "cmd" and msg.to == me and type(msg.cmd) == "string" then
        if not job then state = "busy" end
        dirty = true
        local ok, res, info = pcall(run, from, msg.cmd, msg.arg)
        if not ok then info, res = res, false end  -- run() crashed: report the error
        state = job and "working" or "ready"
        note(cut(msg.cmd .. (res and " ok" or " failed") .. (info and (": " .. tostring(info)) or ""), 60))
        rednet.send(from, { t = "ack", seq = msg.seq, cmd = msg.cmd, ok = res and true or false,
                            info = info and tostring(info) or nil }, PROTO)
        rednet.broadcast(status(), PROTO)
        if res and msg.cmd == "update" then
          sleep(0.5)
          os.reboot()
        end
      end
    end
  end
end

local function beacon()
  local tick = 0
  while true do
    if modems() > 0 then
      if tick % 10 == 0 and not hasGps then locate(1) end       -- look for GPS every ~30s
      rednet.broadcast(status(), PROTO)
    end
    dirty = true
    tick = tick + 1
    sleep(3)
  end
end

local function screen()
  while true do
    if dirty then
      dirty = false
      local w, h = term.getSize()
      local color = term.isColour()
      local function line(y, s, c)
        term.setCursorPos(1, y)
        term.clearLine()
        if color and c then term.setTextColor(c) else term.setTextColor(colors.white) end
        term.write(s:sub(1, w))
      end
      term.setBackgroundColor(colors.black)
      term.clear()
      line(1, "WardenOS Drone " .. VERSION, colors.cyan)
      line(2, ("#%d %s"):format(me, os.getComputerLabel() or ""), colors.lightGray)
      local fuel = turtle.getFuelLevel()
      line(4, ("Task  %s (%s)"):format(task, state))
      line(5, "Fuel  " .. (fuel == "unlimited" and "unlimited" or (fuel .. " / " .. turtle.getFuelLimit())),
           (type(fuel) == "number" and fuel < 100) and colors.red or nil)
      line(6, "Pos   " .. (pos and table.concat(pos, " ") or "no GPS"))
      line(7, "Owner " .. (cfg.owner and ("#" .. cfg.owner) or "none - claim it in the Drones app"))
      local n = modems()
      line(8, n > 0 and "Network online" or "No modem! Attach a wireless modem.", n > 0 and colors.green or colors.red)
      for i = 1, math.max(0, h - 10) do
        line(9 + i, log[i] or "", colors.lightGray)
      end
      line(h, "Ctrl+T: stop the agent", colors.gray)
    end
    sleep(0.5)
  end
end

modems()
note("agent started")
parallel.waitForAny(listen, beacon, screen, worker)
