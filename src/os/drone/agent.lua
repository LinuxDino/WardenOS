-- WardenOS Drone agent (runs on a turtle)
-- Reports status over rednet (protocol "wardenos") and takes commands from its owner computer.
-- Installed by the WardenOS installer; started by /startup.lua.
local VERSION = "1.3.1"
local PROTO = "wardenos"
local CFG = "/os/drone/config"
local NAV = "/os/drone/nav"
local RAW = "https://raw.githubusercontent.com/LinuxDino/WardenOS/main/"

if not turtle then
  printError("The WardenOS drone agent only runs on turtles.")
  return
end

---------------------------------------------------------------- config
-- cfg: owner = computer id, safeDig = false to allow digging built blocks, protect = { rev, boxes }
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
local job = nil                                 -- running task: { name, co, filter, builtin }
local running = nil                             -- the job whose coroutine is executing right now
local lastTask = nil                            -- { name, ok, info } of the last finished task

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

---------------------------------------------------------------- dead reckoning (relative to home)
-- f: 0 = facing as when home was set, 1 = turned right once, 2 = back, 3 = left
-- origin: absolute position and facing of home (nil = not calibrated).
-- Facings (absolute and relative): 0 = north (-z), 1 = east (+x), 2 = south (+z), 3 = west (-x).
local nav, homeSet, origin = { x = 0, y = 0, z = 0, f = 0 }, false, nil
local function isNum(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end
if fs.exists(NAV) then
  local f = fs.open(NAV, "r")
  local d = textutils.unserialize(f.readAll())
  f.close()
  if type(d) == "table" and isNum(d.x) and isNum(d.y) and isNum(d.z) and isNum(d.f) then
    nav = { x = d.x, y = d.y, z = d.z, f = d.f % 4 }
    homeSet = d.homeSet == true
    local o = d.origin
    if type(o) == "table" and isNum(o.x) and isNum(o.y) and isNum(o.z) and isNum(o.f) then
      origin = { x = o.x, y = o.y, z = o.z, f = o.f % 4 }
    end
  end
end
local function saveNav()
  fs.makeDir(fs.getDir(NAV))
  local f = fs.open(NAV, "w")
  f.write(textutils.serialize({ x = nav.x, y = nav.y, z = nav.z, f = nav.f, homeSet = homeSet, origin = origin }))
  f.close()
end
local DX, DZ = { [0] = 0, 1, 0, -1 }, { [0] = -1, 0, 1, 0 }
local FACES = { north = 0, east = 1, south = 2, west = 3 }
local FACE_NAMES = { [0] = "north", "east", "south", "west" }

-- facing number 0-3 or name -> 0-3 (nil if invalid)
local function parseFacing(v)
  if type(v) == "string" then
    if FACES[v:lower()] then return FACES[v:lower()] end
    v = tonumber(v)
  end
  if isNum(v) and v == math.floor(v) then return v % 4 end
end

-- rotate (x, z) clockwise by n quarter turns: (x, z) -> (-z, x) per turn
local function rot(x, z, n)
  for _ = 1, n % 4 do x, z = 0 - z, x end
  return x, z
end
-- relative (nav) point -> absolute; needs origin
local function toAbs(r)
  local x, z = rot(r.x, r.z, origin.f)
  return { x = origin.x + x, y = origin.y + r.y, z = origin.z + z, f = (origin.f + (r.f or 0)) % 4 }
end
-- absolute point -> relative (nav); needs origin
local function toRel(a)
  local x, z = rot(a.x - origin.x, a.z - origin.z, 4 - origin.f)
  return { x = x, y = a.y - origin.y, z = z, f = a.f and (a.f - origin.f) % 4 or nil }
end

---------------------------------------------------------------- observations (for the shared world map)
local pending, pendingN = {}, 0                 -- "x,y,z" -> { x, y, z, name }
local quiet = false                             -- true: moves do not inspect (scan, GPS calibration)
local INSPECT = { front = "inspect", up = "inspectUp", down = "inspectDown" }

-- name of the block on that side ("air" if none), plus the inspect data; nil if the turtle can't inspect
local function peek(side)
  local fn = turtle[INSPECT[side]]
  if not fn then return nil end
  local ok, d = fn()
  if ok and type(d) == "table" and type(d.name) == "string" then return d.name, d end
  return "air"
end

-- absolute position of the neighbour block on that side (needs origin)
local function neighbour(side)
  local a = toAbs(nav)
  if side == "up" then return a.x, a.y + 1, a.z end
  if side == "down" then return a.x, a.y - 1, a.z end
  return a.x + DX[a.f], a.y, a.z + DZ[a.f]
end

local function record(x, y, z, name)
  local k = x .. "," .. y .. "," .. z
  if not pending[k] then
    if pendingN >= 4000 then pending, pendingN = {}, 0 end   -- nobody is listening: forget old ones
    pendingN = pendingN + 1
  end
  pending[k] = { x, y, z, name }
end

-- inspect one side and record it (only when calibrated); returns the block name
local function observe(side)
  local name, d = peek(side)
  if name and origin then
    local x, y, z = neighbour(side)
    record(x, y, z, name)
  end
  return name, d
end

local function flushObs()
  if pendingN == 0 or not rednet.isOpen() then return 0 end
  local list, n = {}, 0
  for _, o in pairs(pending) do
    list[#list + 1] = o
    if #list >= 200 then
      rednet.broadcast({ t = "map", obs = list }, PROTO)
      n, list = n + #list, {}
    end
  end
  if #list > 0 then rednet.broadcast({ t = "map", obs = list }, PROTO) n = n + #list end
  pending, pendingN = {}, 0
  return n
end

---------------------------------------------------------------- dig protection
-- Blocks that count as "natural" (safe dig lets the drone break only these).  KEEP IN ONE PLACE.
local NATURAL = {
  tags = {
    "minecraft:base_stone_overworld", "minecraft:base_stone_nether", "minecraft:dirt", "minecraft:sand",
    "minecraft:leaves", "minecraft:flowers", "minecraft:replaceable", "minecraft:replaceable_by_trees",
    "minecraft:snow", "minecraft:ice", "minecraft:nylium", "c:ores", "forge:ores",
  },
  tagSuffix = "_ores",                          -- any tag ending in this
  names = {
    "minecraft:gravel", "minecraft:clay", "minecraft:snow", "minecraft:snow_block", "minecraft:short_grass",
    "minecraft:grass", "minecraft:tall_grass", "minecraft:fern", "minecraft:large_fern", "minecraft:dead_bush",
    "minecraft:vine", "minecraft:moss_block", "minecraft:moss_carpet", "minecraft:mud", "minecraft:netherrack",
    "minecraft:end_stone", "minecraft:magma_block", "minecraft:soul_sand", "minecraft:soul_soil",
    "minecraft:basalt", "minecraft:blackstone", "minecraft:calcite", "minecraft:tuff",
    "minecraft:dripstone_block", "minecraft:pointed_dripstone",
  },
  nameSuffix = "_ore",                          -- any block name ending in this
}
local NATURAL_TAG, NATURAL_NAME = {}, {}
for _, t in ipairs(NATURAL.tags) do NATURAL_TAG[t] = true end
for _, n in ipairs(NATURAL.names) do NATURAL_NAME[n] = true end

local function isNatural(d)
  local name = d.name or ""
  if NATURAL_NAME[name] or name:sub(-#NATURAL.nameSuffix) == NATURAL.nameSuffix then return true end
  if type(d.tags) == "table" then
    for k, v in pairs(d.tags) do
      local tag = type(k) == "string" and v and k or v           -- { [tag] = true } (CC: Tweaked) or { tag, ... }
      if type(tag) == "string" and (NATURAL_TAG[tag] or tag:sub(-#NATURAL.tagSuffix) == NATURAL.tagSuffix) then
        return true
      end
    end
  end
  return false
end

local function protectBoxes() return type(cfg.protect) == "table" and type(cfg.protect.boxes) == "table" and cfg.protect.boxes or {} end
local function safeDig() return cfg.safeDig ~= false end

-- nil if digging that side is allowed, else the reason "protected: ..."
local function digRefusal(side)
  local name, d = peek(side)
  if not d then return nil end                  -- air / can't inspect: dig fails or works on its own
  if origin then
    local x, y, z = neighbour(side)
    for _, b in ipairs(protectBoxes()) do
      if x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 and z >= b.z1 and z <= b.z2 then
        return "protected: " .. tostring(b.name)
      end
    end
  end
  if safeDig() and not isNatural(d) then return "protected: " .. name .. " (safe dig)" end
end

---------------------------------------------------------------- fuel
local FUEL_HINTS = { "coal", "charcoal", "lava_bucket", "blaze_rod", "log", "planks" }
local fuelCache = {}                            -- item name -> refuel(0) said it burns

local function autoRefuel()
  local lvl = turtle.getFuelLevel()
  if type(lvl) ~= "number" or lvl >= 200 then return end
  local sel, changed = turtle.getSelectedSlot(), false
  for i = 1, 16 do
    if lvl >= 1000 then break end
    local d = turtle.getItemDetail(i)
    if d and fuelCache[d.name] ~= false then
      if turtle.getSelectedSlot() ~= i then turtle.select(i) changed = true end
      local burns = turtle.refuel(0) and true or false
      fuelCache[d.name] = burns
      while burns and lvl < 1000 and turtle.getItemCount(i) > 0 do
        if not turtle.refuel(1) then break end
        lvl = turtle.getFuelLevel()
        if type(lvl) ~= "number" then break end
      end
    end
  end
  if changed then turtle.select(sel) end
end

local function fuelItems()
  local n = 0
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d then
      local burns = fuelCache[d.name]
      if burns == nil then
        burns = false
        for _, h in ipairs(FUEL_HINTS) do
          if d.name:find(h, 1, true) then burns = true break end
        end
      end
      if burns then n = n + d.count end
    end
  end
  return n
end

---------------------------------------------------------------- turtle API wrappers
local TRACK = {
  forward = function() nav.x, nav.z = nav.x + DX[nav.f], nav.z + DZ[nav.f] end,
  back = function() nav.x, nav.z = nav.x - DX[nav.f], nav.z - DZ[nav.f] end,
  up = function() nav.y = nav.y + 1 end,
  down = function() nav.y = nav.y - 1 end,
  turnRight = function() nav.f = (nav.f + 1) % 4 end,
  turnLeft = function() nav.f = (nav.f + 3) % 4 end,
}
local DIGS = { dig = "front", digUp = "up", digDown = "down" }
local MOVED = { forward = true, back = true, up = true, down = true }
local killed = setmetatable({}, { __mode = "k" })   -- coroutines of tasks stopped by the fuel guard
local fuelGuard                                      -- defined with the tasks

-- wrap the global turtle API so manual commands, tasks and the home navigator all update nav, map what they
-- pass and never dig protected blocks. The originals are kept on the turtle table so restarting the agent
-- never wraps twice.
local rawMoves = rawget(turtle, "_wardenRaw")
if not rawMoves then
  rawMoves = {}
  turtle._wardenRaw = rawMoves
end
for n in pairs(TRACK) do if not rawMoves[n] then rawMoves[n] = turtle[n] end end
for n in pairs(DIGS) do if not rawMoves[n] then rawMoves[n] = turtle[n] end end
for n in pairs(TRACK) do
  local orig = rawMoves[n]
  turtle[n] = function(...)
    if killed[coroutine.running()] then error("task stopped", 0) end
    if MOVED[n] then
      autoRefuel()
      if fuelGuard then fuelGuard() end
    end
    local r = table.pack(orig(...))
    if r[1] then
      TRACK[n]()
      dirty = true
      pcall(saveNav)
      if origin and not quiet then
        observe("front")
        if MOVED[n] then observe("up") observe("down") end
      end
    end
    return table.unpack(r, 1, r.n)
  end
end
for n, side in pairs(DIGS) do
  local orig = rawMoves[n]
  turtle[n] = function(...)
    if killed[coroutine.running()] then error("task stopped", 0) end
    local why = digRefusal(side)
    if why then return false, why end
    local r = table.pack(orig(...))
    if r[1] and origin then
      local x, y, z = neighbour(side)
      record(x, y, z, "air")
    end
    return table.unpack(r, 1, r.n)
  end
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
  local abs = origin and toAbs(nav) or nil
  return {
    t = "status", kind = "turtle", version = VERSION,
    label = os.getComputerLabel(), owner = cfg.owner,
    fuel = turtle.getFuelLevel(), fuelLimit = turtle.getFuelLimit(), fuelItems = fuelItems(),
    pos = pos, task = task, state = state,
    slots = used, selected = turtle.getSelectedSlot(), items = items,
    log = log, lastTask = lastTask,
    nav = { x = nav.x, y = nav.y, z = nav.z, f = nav.f }, homeSet = homeSet,
    calibrated = origin ~= nil, abs = abs,
    origin = origin and { x = origin.x, y = origin.y, z = origin.z, f = origin.f } or nil,
    safeDig = safeDig(), protectRev = type(cfg.protect) == "table" and tonumber(cfg.protect.rev) or 0,
  }
end

local function cut(s, n)
  s = tostring(s)
  if #s > n then s = s:sub(1, n - 3) .. "..." end
  return s
end

---------------------------------------------------------------- calibration
-- the turtle is now at absolute x y z facing f: compute origin (and set home here if there is none)
local function calibrateAt(x, y, z, f)
  if not homeSet then
    nav, homeSet = { x = 0, y = 0, z = 0, f = 0 }, true
    note("home set")
  end
  local of = (f - nav.f) % 4
  local rx, rz = rot(nav.x, nav.z, of)
  origin = { x = x - rx, y = y - nav.y, z = z - rz, f = of }
  saveNav()
  dirty = true
  observe("front") observe("up") observe("down")
  return true, ("calibrated %d %d %d %s"):format(x, y, z, FACE_NAMES[f])
end

local function gpsFix(timeout)
  local x, y, z = gps.locate(timeout)
  if not x then return nil end
  local p = { x = math.floor(x + 0.5), y = math.floor(y + 0.5), z = math.floor(z + 0.5) }
  pos, hasGps, dirty = { p.x, p.y, p.z }, true, true
  return p
end

local function dirOf(dx, dz)
  if dx == 0 and dz == -1 then return 0 end
  if dx == 1 and dz == 0 then return 1 end
  if dx == 0 and dz == 1 then return 2 end
  if dx == -1 and dz == 0 then return 3 end
end

-- GPS: locate, step forward (or back) to see which way it faces, step back again
local function gpsCalibrate()
  local p = gpsFix(2)
  if not p then return false, "no GPS" end
  quiet = true
  local ok, f, here, q = pcall(function()
    if turtle.forward() then
      local q = gpsFix(2)
      local back = turtle.back()
      return q and dirOf(q.x - p.x, q.z - p.z), back and p or q, q
    elseif turtle.back() then
      local q = gpsFix(2)
      local fwd = turtle.forward()
      return q and dirOf(p.x - q.x, p.z - q.z), fwd and p or q, q
    end
    return nil, nil, "stuck"
  end)
  quiet = false
  if not ok then error(f, 0) end
  if q == "stuck" then return false, "can't move to find facing" end
  if not q or not here then return false, "no GPS" end
  if not f then return false, "GPS gave no clear facing" end
  return calibrateAt(here.x, here.y, here.z, f)
end

local function calibrate(arg)
  if arg == nil then return gpsCalibrate() end
  if type(arg) ~= "table" then return false, "bad position" end
  local x, y, z = tonumber(arg.x), tonumber(arg.y), tonumber(arg.z)
  if not (isNum(x) and isNum(y) and isNum(z)) then return false, "bad position" end
  local f = parseFacing(arg.facing)
  if not f then return false, "bad facing" end
  return calibrateAt(math.floor(x), math.floor(y), math.floor(z), f)
end

-- scan: look around (front, up, down, then the other three sides) and send it to the map right away
local function scan()
  if not origin then return false, "not calibrated" end
  local seen = {}
  local function look(side)
    local name = observe(side)
    if name then seen[table.concat({ neighbour(side) }, ",")] = true end
  end
  look("front") look("up") look("down")
  quiet = true
  local ok, err = pcall(function()
    for i = 1, 4 do
      turtle.turnRight()
      if i < 4 then look("front") end        -- the 4th turn faces the first side again
    end
  end)
  quiet = false
  if not ok then error(err, 0) end
  local n = 0
  for _ in pairs(seen) do n = n + 1 end
  if modems() > 0 then flushObs() end
  return true, n .. " blocks"
end

local function setProtect(arg)
  if type(arg) ~= "table" or type(arg.boxes) ~= "table" then return false, "bad areas" end
  local boxes = {}
  for i, b in ipairs(arg.boxes) do
    local v = {}
    for _, k in ipairs { "x1", "y1", "z1", "x2", "y2", "z2" } do
      v[k] = type(b) == "table" and tonumber(b[k])
      if not isNum(v[k]) then return false, "bad area " .. i end
    end
    boxes[#boxes + 1] = {
      name = type(b.name) == "string" and b.name:sub(1, 40) or ("area " .. i),
      x1 = math.min(v.x1, v.x2), x2 = math.max(v.x1, v.x2),
      y1 = math.min(v.y1, v.y2), y2 = math.max(v.y1, v.y2),
      z1 = math.min(v.z1, v.z2), z2 = math.max(v.z1, v.z2),
    }
  end
  cfg.protect = { rev = tonumber(arg.rev) or 0, boxes = boxes }
  saveCfg()
  return true, #boxes .. " areas"
end

---------------------------------------------------------------- tasks
-- A task is Lua code sent by the owner ("run" command). It runs as a coroutine driven by worker().
--
-- Helpers in the task environment (besides the normal APIs; turtle.* is tracked, mapped and dig-protected):
--   whereAmI()          -> { x, y, z, f, rel = { x, y, z, f }, calibrated = bool }; x/y/z/f are absolute when
--                          calibrated (f: 0 north, 1 east, 2 south, 3 west), rel is the position relative to home.
--   face(dir)           dir = 0-3 or "north"/"east"/"south"/"west"; absolute when calibrated, else relative to
--                          the home facing. Turns the shortest way.
--   moveTo(x, y, z)     absolute (error "not calibrated" if not). Goes up to max(current y, y), then along x,
--                          then z, then down/up to y. A blocked move digs once (safely), else goes up one and
--                          goes on (max 20 detours); error "blocked at x y z" if stuck. Returns true.
--   findItem(pattern)   -> slot of the first item whose name contains pattern (plain text), or nil.
--   selectItem(pattern) -> selects that slot, returns true/false.
--   inspectAll()        -> { front = name|"air", up = ..., down = ... }, recorded for the map.
--   print(...), report(...) write to the drone's log (report also broadcasts the status).
-- Digging refuses protected areas and (with safe dig) blocks that are not natural: false, "protected: ...".
-- A task stops with "low fuel: returning home" when fuel runs short of the way home + 20 (it then goes home).
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

local function startJob(name, fn, builtin)
  job = { name = name, co = coroutine.create(fn), builtin = builtin }
  task, state = name, "working"
  os.queueEvent("wardenos_task")
  return true, "started"
end

-- built-in task "home": x to 0, then z, then y, then face f = 0
local function goHome()
  autoRefuel()
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

-- before each move of a (non built-in) task: enough fuel to get home? Else stop it and go home.
fuelGuard = function()
  local j = running
  if not j or j.builtin or job ~= j then return end
  local fuel = turtle.getFuelLevel()
  if type(fuel) ~= "number" or fuel >= math.abs(nav.x) + math.abs(nav.y) + math.abs(nav.z) + 20 then return end
  local msg = "low fuel: returning home"
  killed[j.co] = true
  job = nil
  task, state = "manual", "ready"
  lastTask = { name = j.name, ok = false, info = msg }
  note(msg)
  if homeSet then startJob("home", goHome, true) end
  rednet.broadcast(status(), PROTO)
  error(msg, 0)
end

local function turnTo(f)
  local d = (f - nav.f) % 4
  if d == 1 then turtle.turnRight()
  elseif d == 2 then turtle.turnRight() turtle.turnRight()
  elseif d == 3 then turtle.turnLeft() end
end

local function whereAmI()
  local r = { x = nav.x, y = nav.y, z = nav.z, f = nav.f }
  local t = origin and toAbs(nav) or { x = nav.x, y = nav.y, z = nav.z, f = nav.f }
  t.rel, t.calibrated = r, origin ~= nil
  return t
end

local function faceDir(dir)
  local f = parseFacing(dir)
  if not f then error("bad direction: " .. tostring(dir), 2) end
  if origin then f = (f - origin.f) % 4 end
  turnTo(f)
  return true
end

local function moveTo(tx, ty, tz)
  if not origin then error("not calibrated", 2) end
  tx, ty, tz = tonumber(tx), tonumber(ty), tonumber(tz)
  if not (isNum(tx) and isNum(ty) and isNum(tz)) then error("bad position", 2) end
  tx, ty, tz = math.floor(tx), math.floor(ty), math.floor(tz)
  local top = math.max(toAbs(nav).y, ty)
  local detours = 0
  local function stuck()
    local a = toAbs(nav)
    error(("blocked at %d %d %d"):format(a.x, a.y, a.z), 0)
  end
  local function step(move, dig)
    if move() then return true end
    dig()
    return move() and true or false
  end
  while true do
    local a = toAbs(nav)
    if a.y < top then
      if not step(turtle.up, turtle.digUp) then stuck() end
    elseif a.x ~= tx or a.z ~= tz then
      if a.x ~= tx then turnTo((a.x < tx and 1 or 3) - origin.f) else turnTo((a.z < tz and 2 or 0) - origin.f) end
      if not step(turtle.forward, turtle.dig) then
        detours = detours + 1
        if detours > 20 or not step(turtle.up, turtle.digUp) then stuck() end
      end
    elseif a.y > ty then
      if not step(turtle.down, turtle.digDown) then stuck() end
    elseif a.y < ty then
      if not step(turtle.up, turtle.digUp) then stuck() end
    else
      return true
    end
  end
end

local function findItem(pattern)
  pattern = tostring(pattern)
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d and d.name:find(pattern, 1, true) then return i end
  end
  return nil
end

local function selectItem(pattern)
  local i = findItem(pattern)
  if not i then return false end
  turtle.select(i)
  return true
end

local function inspectAll()
  return { front = observe("front") or "air", up = observe("up") or "air", down = observe("down") or "air" }
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
  env.whereAmI, env.face, env.moveTo = whereAmI, faceDir, moveTo
  env.findItem, env.selectItem, env.inspectAll = findItem, selectItem, inspectAll
  local fn, err = load(arg.code, "=" .. name, "t", env)
  if not fn then return false, "syntax error: " .. tostring(err) end
  return startJob(name, fn)
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
        running = j
        local r = table.pack(coroutine.resume(j.co, table.unpack(ev, 1, ev.n)))
        running = nil
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
    if origin then origin = toAbs(nav) end      -- keep absolute coordinates valid
    nav, homeSet = { x = 0, y = 0, z = 0, f = 0 }, true
    saveNav()
    note("home set")
    return true
  elseif cmd == "home" then
    if not homeSet then return false, "no home set" end
    return startJob("home", goHome, true)
  elseif cmd == "calibrate" then
    return calibrate(arg)
  elseif cmd == "scan" then
    return scan()
  elseif cmd == "protect" then
    return setProtect(arg)
  elseif cmd == "safedig" then
    if type(arg) ~= "boolean" then return false, "bad value" end
    cfg.safeDig = arg
    saveCfg()
    return true, arg and "safe dig on" or "safe dig off"
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

-- sends what the drone saw to the map, at most every 2 seconds
local function mapper()
  while true do
    sleep(2)
    if pendingN > 0 and modems() > 0 then flushObs() end
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
      local a = origin and toAbs(nav)
      line(6, "Pos   " .. (a and ("%d %d %d %s"):format(a.x, a.y, a.z, FACE_NAMES[a.f])
                          or pos and table.concat(pos, " ") or "not calibrated"))
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
parallel.waitForAny(listen, beacon, screen, worker, mapper)
