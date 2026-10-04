-- WardenOS Drone agent (runs on a turtle)
-- Reports status over rednet (protocol "wardenos") and takes commands from its owner computer.
-- Installed by the WardenOS installer or an install disk; started by /startup.lua.
local VERSION = "1.2.0"
local PROTO = "wardenos"
local CFG = "/os/drone/config"
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
    log = log,
  }
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
  elseif cmd == "stop" then
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
        state = "busy"
        dirty = true
        local ok, res, info = pcall(run, from, msg.cmd, msg.arg)
        if not ok then info, res = res, false end  -- run() crashed: report the error
        state = "ready"
        note(msg.cmd .. (res and " ok" or " failed") .. (info and (": " .. tostring(info)) or ""))
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
parallel.waitForAny(listen, beacon, screen)
