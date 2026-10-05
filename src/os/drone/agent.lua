-- WardenOS Drone agent (runs on a turtle)
-- Reports status over rednet (protocol "wardenos") and takes commands from its owner computer.
-- Installed by the WardenOS installer; started by /startup.lua.
local VERSION = "1.8.2"
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
local job = nil                                 -- running task: { name, co, filter, builtin, by, started, progress }
local running = nil                             -- the job whose coroutine is executing right now
local lastTask = nil                            -- { name, ok, info, by } of the last finished task
local cmdBy = nil                               -- who sent the command being run: { id, who = "claude" | "player" }
local lastBc = -100                             -- os.clock() of the last status broadcast

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

---------------------------------------------------------------- block memory (for the path finder)
-- What the drone knows about the world, in the RELATIVE nav frame (works uncalibrated):
-- mem["x,y,z"] = "air" | block name. Filled by every inspection, dig and move; mapdata merges the computer's map.
-- temp["x,y,z"] = clock time until which the cell counts as blocked (mobs, other turtles).
-- hard["x,y,z"] = true: a dig there failed for an unknown reason (cleared when the cell is seen again).
-- tagCache[name] = tags from the last inspection of that block name (lets the planner use the dig rules).
local MEMFILE = "/os/drone/memory"
local MEM_CAP, MEM_SAVE = 30000, 8000           -- cells kept in RAM / written to disk (the nearest ones)
local mem, memN, memDirty, temp, hard, tagCache = {}, 0, false, {}, {}, {}

local function now() return os.clock() end
local function ckey(x, y, z) return x .. "," .. y .. "," .. z end

local function pruneMem(keep)
  local list = {}
  for k in pairs(mem) do
    local x, y, z = k:match("^(-?%d+),(-?%d+),(-?%d+)$")
    list[#list + 1] = { math.abs(x - nav.x) + math.abs(y - nav.y) + math.abs(z - nav.z), k }
  end
  table.sort(list, function(a, b) return a[1] < b[1] end)
  for i = keep + 1, #list do mem[list[i][2]] = nil end
  memN = math.min(#list, keep)
  return list
end

local function memSet(x, y, z, name)
  local k = ckey(x, y, z)
  hard[k] = nil
  if type(name) == "string" and name:find("^computercraft:turtle") then   -- other turtles move: block briefly
    temp[k] = now() + 20
    name = nil
  elseif temp[k] then
    temp[k] = nil
  end
  if mem[k] == name then return end
  if mem[k] == nil then memN = memN + 1 elseif name == nil then memN = memN - 1 end
  mem[k] = name
  memDirty = true
  if memN > MEM_CAP then pruneMem(math.floor(MEM_CAP * 0.9)) end
end

-- current nav position becomes 0,0,0 facing 0 (sethome): re-key everything into the new frame
local function rebaseMem()
  local function move(t)
    local out = {}
    for k, v in pairs(t) do
      local x, y, z = k:match("^(-?%d+),(-?%d+),(-?%d+)$")
      if x then
        local rx, rz = rot(x - nav.x, z - nav.z, 4 - nav.f)
        out[ckey(rx, y - nav.y, rz)] = v
      end
    end
    return out
  end
  mem, temp, hard = move(mem), move(temp), move(hard)
  memDirty = true
end

-- disk format: "WMEM1\n" .. names joined by "|" .. "\n" .. "x,y,z,i\n"... (i = index into the names)
local function saveMem()
  if not memDirty then return end
  memDirty = false
  local list
  if memN > MEM_SAVE then
    list = pruneMem(MEM_CAP)                    -- sorted by distance, nothing dropped
  else
    list = {}
    for k in pairs(mem) do list[#list + 1] = { 0, k } end
  end
  local names, idx, out = {}, {}, {}
  for i = 1, math.min(#list, MEM_SAVE) do
    local k = list[i][2]
    local v = mem[k]
    if not idx[v] then names[#names + 1] = v idx[v] = #names end
    out[#out + 1] = k .. "," .. idx[v]
  end
  pcall(function()
    fs.makeDir(fs.getDir(MEMFILE))
    local f = fs.open(MEMFILE, "w")
    f.write("WMEM1\n" .. table.concat(names, "|") .. "\n" .. table.concat(out, "\n"))
    f.close()
  end)
end

local function loadMem()
  if not fs.exists(MEMFILE) then return end
  local f = fs.open(MEMFILE, "r")
  local s = f and f.readAll() or ""
  if f then f.close() end
  local head, names, body = s:match("^(WMEM1)\n([^\n]*)\n?(.*)$")
  if not head then return end
  local list = {}
  for n in names:gmatch("[^|]+") do list[#list + 1] = n end
  for x, y, z, i in body:gmatch("(-?%d+),(-?%d+),(-?%d+),(%d+)") do
    local v = list[tonumber(i)]
    if v and memN < MEM_CAP then
      local k = ckey(tonumber(x), tonumber(y), tonumber(z))
      if not mem[k] then memN = memN + 1 end
      mem[k] = v
    end
  end
end
pcall(loadMem)

---------------------------------------------------------------- observations (for the shared world map)
local pending, pendingN = {}, 0                 -- "x,y,z" -> { x, y, z, name }
local quiet = false                             -- true: moves do not inspect (scan, GPS calibration)
local sensing = false                           -- true while the path follower runs: moves inspect even uncalibrated
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

-- relative (nav) position of the neighbour block on that side
local function relNeighbour(side)
  if side == "up" then return nav.x, nav.y + 1, nav.z end
  if side == "down" then return nav.x, nav.y - 1, nav.z end
  return nav.x + DX[nav.f], nav.y, nav.z + DZ[nav.f]
end

-- inspect one side, remember it, and record it for the map (only when calibrated); returns the block name
local function observe(side)
  local name, d = peek(side)
  if name then
    if d and type(d.tags) == "table" then tagCache[name] = d.tags end
    local rx, ry, rz = relNeighbour(side)
    memSet(rx, ry, rz, name)
    if origin then
      local x, y, z = neighbour(side)
      record(x, y, z, name)
    end
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
-- vanilla blocks that carry one of the tags above, for when only the name is known (map data from the computer)
NATURAL.untagged = {
  "minecraft:stone", "minecraft:granite", "minecraft:diorite", "minecraft:andesite", "minecraft:deepslate",
  "minecraft:dirt", "minecraft:grass_block", "minecraft:podzol", "minecraft:coarse_dirt", "minecraft:rooted_dirt",
  "minecraft:mycelium", "minecraft:sand", "minecraft:red_sand", "minecraft:suspicious_sand",
  "minecraft:crimson_nylium", "minecraft:warped_nylium", "minecraft:ice", "minecraft:packed_ice",
}
NATURAL.untaggedSuffix = "_leaves"
local NATURAL_TAG, NATURAL_NAME, NATURAL_UNTAGGED = {}, {}, {}
for _, t in ipairs(NATURAL.tags) do NATURAL_TAG[t] = true end
for _, n in ipairs(NATURAL.names) do NATURAL_NAME[n] = true end
for _, n in ipairs(NATURAL.untagged) do NATURAL_UNTAGGED[n] = true end

local function isNatural(d)
  local name = d.name or ""
  if NATURAL_NAME[name] or name:sub(-#NATURAL.nameSuffix) == NATURAL.nameSuffix then return true end
  if d.tags == nil and (NATURAL_UNTAGGED[name] or name:sub(-#NATURAL.untaggedSuffix) == NATURAL.untaggedSuffix) then
    return true
  end
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

-- Never dug, not even with safe dig off: storage, machines, computers, spawners, beds, valuable blocks.
-- An entry starting with "^" matches the start of the block name, any other one anywhere in it (plain text).
-- Ores ("..._ore") are always allowed (mods put ores in their own namespace).
local NEVER_DIG = { "chest", "barrel", "shulker_box", "hopper", "dispenser", "dropper", "furnace", "smoker",
  "spawner", "beacon", "_bed", "brewing_stand", "enchanting_table", "anvil", "lectern", "jukebox", "respawn_anchor",
  "lodestone", "conduit", "drawer", "crate", "^computercraft:", "^ae2:", "^appliedenergistics2:", "^refinedstorage:",
  "minecraft:diamond_block", "minecraft:emerald_block", "minecraft:gold_block", "minecraft:iron_block",
  "minecraft:netherite_block", "minecraft:lapis_block" }
local neverCache = {}
local function neverDig(name)
  name = tostring(name)
  local v = neverCache[name]
  if v == nil then
    v = false
    if name:sub(-4) ~= "_ore" then
      for _, p in ipairs(NEVER_DIG) do
        if p:sub(1, 1) == "^" and name:sub(1, #p - 1) == p:sub(2) or p:sub(1, 1) ~= "^" and name:find(p, 1, true) then
          v = true
          break
        end
      end
    end
    neverCache[name] = v
  end
  return v
end

local function protectBoxes() return type(cfg.protect) == "table" and type(cfg.protect.boxes) == "table" and cfg.protect.boxes or {} end
local function safeDig() return cfg.safeDig ~= false end

-- THE dig rule (dig wrappers and path finder): nil if block d (inspect data; name-only is fine) in a cell may be
-- dug, else the reason "protected: ...". inBox = name of the protected area the cell is in (or nil).
local function refusal(d, inBox)
  if inBox then return "protected: " .. tostring(inBox) end
  if neverDig(d.name) then return "protected: " .. tostring(d.name) .. " (never dug)" end
  if safeDig() and not isNatural(d) then return "protected: " .. tostring(d.name) .. " (safe dig)" end
end

-- nil if digging that side is allowed, else the reason "protected: ..."
local function digRefusal(side)
  local name, d = peek(side)
  if not d then return nil end                  -- air / can't inspect: dig fails or works on its own
  local inBox
  if origin then
    local x, y, z = neighbour(side)
    for _, b in ipairs(protectBoxes()) do
      if x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 and z >= b.z1 and z <= b.z2 then
        inBox = b.name
        break
      end
    end
  end
  return refusal(d, inBox)
end

---------------------------------------------------------------- path finding (A* over the block memory)
-- Costs: forward/up/down = 1, each 90 degree turn = 1 (no back(): it can't see or dig what is behind).
-- Entering a cell adds: known air / passable (fluids, grass...) 0, unknown 1 (optimistic: probably air),
-- unknown inside a protected area 3, known block that may be dug 4, anything else impassable (not diggable
-- under the dig rule, inside a protected area, bedrock & co, lava, other turtles, recently blocked cells).
-- An unknown cell next to a known block costs C_NEAR_HARD (block it may not dig) / C_NEAR_DIG (diggable) more.
local C_UNKNOWN, C_UNKNOWN_BOX, C_DIG, C_NEAR_HARD, C_NEAR_DIG = 1, 3, 4, 3, 1
-- During one trip every cell the drone already went through costs C_VISIT more per visit: stops it from
-- swinging back and forth while it feels its way along a wall (LRTA*-style learning).
local C_VISIT = 2
local NEAR = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }
-- heuristic = 2 * Manhattan + turns: exact for unknown space (2 per step), so the search runs straight at the
-- target; over known air (1 per step) it is greedy (weighted A*: paths at most 2x the best, usually the best).
local H_WEIGHT = 2
local UNBREAKABLE = { ["minecraft:bedrock"] = true, ["minecraft:barrier"] = true, ["minecraft:end_portal_frame"] = true,
  ["minecraft:end_portal"] = true, ["minecraft:nether_portal"] = true, ["minecraft:reinforced_deepslate"] = true,
  ["minecraft:command_block"] = true, ["minecraft:structure_block"] = true, ["minecraft:light"] = true,
  ["minecraft:lava"] = true, ["minecraft:flowing_lava"] = true }
-- enterable without digging (air and vanilla "replaceable" blocks, for when only the name is known)
local PASSABLE = {}
for _, n in ipairs { "air", "minecraft:air", "minecraft:cave_air", "minecraft:void_air", "minecraft:water",
                     "minecraft:bubble_column", "minecraft:short_grass", "minecraft:grass", "minecraft:tall_grass",
                     "minecraft:fern", "minecraft:large_fern", "minecraft:dead_bush", "minecraft:vine", "minecraft:snow",
                     "minecraft:seagrass", "minecraft:tall_seagrass", "minecraft:glow_lichen", "minecraft:fire" } do
  PASSABLE[n] = true
end
local Y_MIN, Y_MAX = -64, 319                   -- world build limits (absolute)

-- can the turtle move into a block with this name (air or replaceable, but never lava)?
local function enterable(name)
  if PASSABLE[name] then return true end
  if UNBREAKABLE[name] then return false end
  local tags = tagCache[name]
  return type(tags) == "table" and (tags["minecraft:replaceable"] == true or tags["minecraft:replaceable_by_trees"] == true)
end

-- planning context: protected boxes in the relative frame, y limits
local function planCtx()
  local ctx = { boxes = {}, t = now() }
  if origin then
    for _, b in ipairs(protectBoxes()) do
      local p = toRel({ x = b.x1, y = b.y1, z = b.z1 })
      local q = toRel({ x = b.x2, y = b.y2, z = b.z2 })
      ctx.boxes[#ctx.boxes + 1] = { name = b.name, x1 = math.min(p.x, q.x), x2 = math.max(p.x, q.x), y1 = p.y, y2 = q.y,
                                    z1 = math.min(p.z, q.z), z2 = math.max(p.z, q.z) }
    end
    ctx.ylo, ctx.yhi = Y_MIN - origin.y, Y_MAX - origin.y
  end
  return ctx
end

-- extra cost of entering relative cell x y z, or nil if impassable
local function cellCost(x, y, z, ctx)
  if ctx.ylo and (y < ctx.ylo or y > ctx.yhi) then return nil end
  local k = ckey(x, y, z)
  local t = temp[k]
  if t then
    if t > ctx.t then return nil end
    temp[k] = nil
  end
  if hard[k] then return nil end
  local extra = ctx.visits and (ctx.visits[k] or 0) * C_VISIT or 0
  local inBox
  for _, b in ipairs(ctx.boxes) do
    if x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 and z >= b.z1 and z <= b.z2 then inBox = b.name break end
  end
  local v = mem[k]
  if v == nil then
    -- walls and rock go on: an unknown cell next to known blocks is probably a block too
    local near = 0
    for i = 1, 6 do
      local o = NEAR[i]
      local w = mem[ckey(x + o[1], y + o[2], z + o[3])]
      if w and not enterable(w) then
        near = (w == "solid?" or UNBREAKABLE[w] or refusal({ name = w, tags = tagCache[w] }, inBox)) and C_NEAR_HARD
               or math.max(near, C_NEAR_DIG)
        if near == C_NEAR_HARD then break end
      end
    end
    return (inBox and C_UNKNOWN_BOX or C_UNKNOWN) + near + extra
  end
  if enterable(v) then return extra end
  if v == "solid?" or UNBREAKABLE[v] then return nil end
  if refusal({ name = v, tags = tagCache[v] }, inBox) then return nil end
  return C_DIG + extra
end

-- give CC a chance to run other things (works in a task coroutine and in the main loops)
local function breathe()
  os.queueEvent("wardenos_yield")
  os.pullEvent("wardenos_yield")
end

local function searchOnce(s, t, margin, maxExp, ctx, partial)
  local x0, x1 = math.min(s.x, t.x) - margin, math.max(s.x, t.x) + margin
  local y0, y1 = math.min(s.y, t.y) - margin, math.max(s.y, t.y) + margin
  local z0, z1 = math.min(s.z, t.z) - margin, math.max(s.z, t.z) + margin
  if ctx.ylo then y0, y1 = math.max(y0, ctx.ylo), math.min(y1, ctx.yhi) end
  local SY, SZ = y1 - y0 + 1, z1 - z0 + 1
  local tx, ty, tz = t.x, t.y, t.z
  local costs, g, from, closed = {}, {}, {}, {}   -- per state: g cost, previous state
  local hk, hp, hn = {}, {}, 0                  -- binary heap: state, priority
  local function push(k, p)
    hn = hn + 1
    local i = hn
    while i > 1 do
      local up = (i - i % 2) / 2
      if hp[up] <= p then break end
      hk[i], hp[i] = hk[up], hp[up]
      i = up
    end
    hk[i], hp[i] = k, p
  end
  local function pop()
    local k = hk[1]
    local lk, lp = hk[hn], hp[hn]
    hk[hn], hp[hn] = nil, nil
    hn = hn - 1
    local i = 1
    while true do
      local c = i * 2
      if c > hn then break end
      if c < hn and hp[c + 1] < hp[c] then c = c + 1 end
      if hp[c] >= lp then break end
      hk[i], hp[i] = hk[c], hp[c]
      i = c
    end
    if hn > 0 then hk[i], hp[i] = lk, lp end
    return k
  end
  local function cost(ci, x, y, z)
    local c = costs[ci]
    if c == nil then
      c = cellCost(x, y, z, ctx) or false
      costs[ci] = c
    end
    return c
  end
  -- heuristic: weighted Manhattan distance + the turns still needed (facing f)
  local function h(x, y, z, f)
    local dx, dz = tx - x, tz - z
    local turns = 0
    if dx ~= 0 or dz ~= 0 then
      local a = dx > 0 and 1 or dx < 0 and 3 or nil          -- needed facings
      local b = dz > 0 and 2 or dz < 0 and 0 or nil
      if a and b then turns = (f == a or f == b) and 1 or 2
      else turns = ((a or b) - f) % 4 == 2 and 2 or (a or b) == f and 0 or 1 end
    end
    return H_WEIGHT * (math.abs(dx) + math.abs(y - ty) + math.abs(dz)) + turns
  end
  local function relax(ns, ng, x, y, z, f, prev)
    if not closed[ns] and (g[ns] == nil or ng < g[ns]) then
      g[ns], from[ns] = ng, prev
      push(ns, ng + h(x, y, z, f) - ng * 1e-6)    -- ties: prefer the node further along
    end
  end
  local start = (((s.x - x0) * SY + (s.y - y0)) * SZ + (s.z - z0)) * 4 + s.f
  -- state -> list of steps from the start
  local function steps(st)
    local out, cur = {}, st
    while cur ~= start do
      local pf = cur % 4
      local pci = (cur - pf) / 4
      local pz = pci % SZ
      local pr = (pci - pz) / SZ
      local py = pr % SY
      local px = (pr - py) / SY
      local step = { x = px + x0, y = py + y0, z = pz + z0 }
      local prev = from[cur]
      local qci = (prev - prev % 4) / 4
      if qci == pci - SZ then step.up = true          -- y + 1
      elseif qci == pci + SZ then step.down = true
      else step.dir = pf end
      table.insert(out, 1, step)
      cur = prev
    end
    return out
  end
  -- closest state to the target seen so far (partial path when the search runs out of budget)
  local bestD, bestSt = math.abs(tx - s.x) + math.abs(ty - s.y) + math.abs(tz - s.z), nil
  g[start] = 0
  push(start, h(s.x, s.y, s.z, s.f))
  local exp = 0
  while hn > 0 do
    local st = pop()
    if not closed[st] then
      closed[st] = true
      exp = exp + 1
      if exp % 200 == 0 then breathe() end
      if exp > maxExp then
        if partial and bestSt then return steps(bestSt), "partial", exp end
        return nil, "search limit", exp
      end
      local f = st % 4
      local ci = (st - f) / 4
      local zz = ci % SZ
      local r = (ci - zz) / SZ
      local yy = r % SY
      local xx = (r - yy) / SY
      local x, y, z = xx + x0, yy + y0, zz + z0
      if x == tx and y == ty and z == tz then
        return steps(st), nil, exp
      end
      local d = math.abs(tx - x) + math.abs(ty - y) + math.abs(tz - z)
      if d < bestD then bestD, bestSt = d, st end
      local gs = g[st]
      for d = 0, 3 do
        local nx, nz = x + DX[d], z + DZ[d]
        if nx >= x0 and nx <= x1 and nz >= z0 and nz <= z1 then
          local nci = ci + DX[d] * SY * SZ + DZ[d]
          local c = cost(nci, nx, y, nz)
          if c then
            local turn = (d - f) % 4
            local ns = nci * 4 + d
            relax(ns, gs + (turn == 2 and 2 or turn == 0 and 0 or 1) + 1 + c, nx, y, nz, d, st)
          end
        end
      end
      for dy = -1, 1, 2 do
        local ny = y + dy
        if ny >= y0 and ny <= y1 then
          local nci = ci + dy * SZ
          local c = cost(nci, x, ny, z)
          if c then
            relax(nci * 4 + f, gs + 1 + c, x, ny, z, f, st)
          end
        end
      end
    end
  end
  return nil, "no path", exp
end

-- A* from relative position from (x, y, z, f) to relative cell to (x, y, z).
-- opts: margin (default 8, grown to 24 when nothing is found), maxExpand (default 20000), ctx, partial (true: when
-- the search budget runs out, return the path to the closest cell reached, plus "partial").
-- Returns a list of steps { x, y, z, dir = 0-3 (relative facing for a forward move) | up = true | down = true }
-- (the cell entered by each move) [, "partial"] or nil, reason ("target blocked", "no path", "search limit").
local function findPath(from, to, opts)
  opts = opts or {}
  local ctx = opts.ctx or planCtx()
  local s = { x = from.x, y = from.y, z = from.z, f = (from.f or 0) % 4 }
  local t = { x = to.x, y = to.y, z = to.z }
  if s.x == t.x and s.y == t.y and s.z == t.z then return {} end
  if not cellCost(t.x, t.y, t.z, ctx) then return nil, "target blocked" end
  local open = false
  for _, o in ipairs { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } } do
    local nx, ny, nz = t.x + o[1], t.y + o[2], t.z + o[3]
    if (nx == s.x and ny == s.y and nz == s.z) or cellCost(nx, ny, nz, ctx) then open = true break end
  end
  if not open then return nil, "no path" end
  local margin, maxExp = opts.margin or 8, opts.maxExpand or 20000
  local steps, why = searchOnce(s, t, margin, maxExp, ctx, opts.partial)
  if not steps and why == "no path" and margin < 24 then steps, why = searchOnce(s, t, 24, maxExp, ctx, opts.partial) end
  return steps, why
end

---------------------------------------------------------------- fuel
local FUEL_HINTS = { "coal", "charcoal", "lava_bucket", "blaze_rod", "log", "planks" }
-- real fuel, burnt first; other burnable items (logs, planks, wool...) may be building material: only in need
local REAL_FUEL = { "coal", "charcoal", "lava_bucket", "blaze_rod", "dried_kelp_block" }
local fuelCache = {}                            -- item name -> refuel(0) said it burns
local FUEL_SPARE, COAL = 20, 80                 -- fuel kept in reserve; fuel per coal

local function realFuel(name)
  for _, h in ipairs(REAL_FUEL) do
    if name:find(h, 1, true) then return true end
  end
  return false
end

-- fuel level as a number (math.huge when fuel is off in the server config)
local function fuelLevel()
  local l = turtle.getFuelLevel()
  return type(l) == "number" and l or math.huge
end

-- burn items from the inventory until the fuel level reaches want (real fuel first; other burnable items too
-- when any = true). Returns the fuel level.
local function burnTo(want, any)
  local lvl = fuelLevel()
  if lvl >= want then return lvl end
  local limit = turtle.getFuelLimit and turtle.getFuelLimit()
  if type(limit) == "number" and limit > 0 then want = math.min(want, limit) end
  local sel, changed = turtle.getSelectedSlot(), false
  for pass = 1, any and 2 or 1 do
    for i = 1, 16 do
      if lvl >= want then break end
      local d = turtle.getItemDetail(i)
      if d and fuelCache[d.name] ~= false and (pass == 1) == realFuel(d.name) then
        if turtle.getSelectedSlot() ~= i then turtle.select(i) changed = true end
        local burns = turtle.refuel(0) and true or false
        fuelCache[d.name] = burns
        while burns and lvl < want and turtle.getItemCount(i) > 0 do
          if not turtle.refuel(1) then break end
          lvl = fuelLevel()
        end
      end
    end
  end
  if changed then turtle.select(sel) end
  return lvl
end

-- before every move: below 200 fuel, burn real fuel up to 1000 (anything burnable when nearly empty)
local function autoRefuel()
  local lvl = fuelLevel()
  if lvl >= 200 then return end
  burnTo(1000, lvl < 50)
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
local digCount = 0                                   -- blocks dug since the agent started (job statistics)
local sinceFix = 0                                   -- moves since the last GPS check

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
      if MOVED[n] then
        memSet(nav.x, nav.y, nav.z, "air")      -- where it stands now is passable
        sinceFix = sinceFix + 1
      end
      if (origin or (sensing and running)) and not quiet then
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
    if r[1] then
      digCount = digCount + 1
      local rx, ry, rz = relNeighbour(side)
      memSet(rx, ry, rz, "air")
      if origin then
        local x, y, z = neighbour(side)
        record(x, y, z, "air")
      end
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

-- GPS position (rounded: gps.locate can answer 63.9999 for 64) from 3 samples that must agree; nil if there
-- is no GPS (hasGps = false) or the samples disagree (a GPS host moved or answers wrong)
local function gpsFix(timeout)
  local p
  for i = 1, 3 do
    local x, y, z = gps.locate(timeout or 1)
    if not x then
      if i == 1 then pos, hasGps, dirty = nil, false, true end
      return nil
    end
    local q = { x = math.floor(x + 0.5), y = math.floor(y + 0.5), z = math.floor(z + 0.5) }
    if p and (p.x ~= q.x or p.y ~= q.y or p.z ~= q.z) then return nil, "GPS answers disagree" end
    p = q
  end
  pos, hasGps, dirty = { p.x, p.y, p.z }, true, true
  return p
end

local function locate(timeout)
  gpsFix(timeout or 1)
  dirty = true
end

-- status broadcast. While a task runs it also has: by = { id = computer that started it, who = "claude" |
-- "player" } (from the cmd message's optional by = "claude"), taskTime (whole seconds since it started) and
-- progress = { phase = "planning" | "moving" | "digging" | "waiting" | "working", step, total, target, replans }
-- (step/total/target/replans only while the path follower moves; mining jobs: phase "mining", step/total =
-- cells). jobId = the running task's number; lastTask = { name, ok, info, by, n = its number }.
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
    known = memN, safeDig = safeDig(), protectRev = type(cfg.protect) == "table" and tonumber(cfg.protect.rev) or 0,
    by = job and job.by or nil, jobId = job and job.n or nil,
    taskTime = job and math.max(0, math.floor(os.clock() - job.started)) or nil,
    progress = job and job.progress or nil,
  }
end

-- broadcast the status now
local function bcast()
  lastBc = os.clock()
  rednet.broadcast(status(), PROTO)
end

-- while a task runs: broadcast the status (live progress) at most every second
local function liveStatus()
  if job and os.clock() - lastBc >= 1 and rednet.isOpen() then bcast() end
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
    rebaseMem()
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

local function dirOf(dx, dz)
  if dx == 0 and dz == -1 then return 0 end
  if dx == 1 and dz == 0 then return 1 end
  if dx == 0 and dz == 1 then return 2 end
  if dx == -1 and dz == 0 then return 3 end
end

-- GPS: locate, step forward (or back) to see which way it faces, step back again
local function gpsCalibrate()
  local p, why = gpsFix(2)
  if not p then return false, why or "no GPS" end
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

-- GPS check while travelling (calibrated, GPS seen): is the drone where dead reckoning says? A mismatch (pushed
-- by a piston, a wrong calibration, a lost move) corrects the position (home stays where it is), then one step
-- forward and back (or back and forward) checks the facing. Returns nil (fine / no GPS) or a note for the log.
local function gpsVerify()
  if not origin or not hasGps then return nil end
  local p = gpsFix(1)
  if not p then return nil end
  sinceFix = 0
  local a = toAbs(nav)
  if p.x == a.x and p.y == a.y and p.z == a.z then return nil end
  local function put(q)
    local r = toRel(q)
    nav.x, nav.y, nav.z = r.x, r.y, r.z
  end
  put(p)
  local f
  quiet = true
  pcall(function()
    if rawMoves.forward() then
      local q = gpsFix(1)
      if q then f = dirOf(q.x - p.x, q.z - p.z) end
      if not rawMoves.back() and q then put(q) end
    elseif rawMoves.back() then
      local q = gpsFix(1)
      if q then f = dirOf(p.x - q.x, p.z - q.z) end
      if not rawMoves.forward() and q then put(q) end
    end
  end)
  quiet = false
  if f then nav.f = (f - origin.f) % 4 end
  memSet(nav.x, nav.y, nav.z, "air")
  pcall(saveNav)
  dirty = true
  local now_ = toAbs(nav)
  return ("GPS: position corrected to %d %d %d %s"):format(now_.x, now_.y, now_.z, FACE_NAMES[now_.f])
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
-- A task is Lua code sent by the owner ("run" command) or a built-in job. It runs as a coroutine driven by
-- worker(). Every task gets a number (status.jobId while it runs, lastTask.n afterwards, ack.job when started).
--
-- Helpers in the task environment (besides the normal APIs; turtle.* is tracked, mapped and dig-protected):
--   whereAmI()          -> { x, y, z, f, rel = { x, y, z, f }, calibrated = bool }; x/y/z/f are absolute when
--                          calibrated (f: 0 north, 1 east, 2 south, 3 west), rel is the position relative to home.
--   face(dir)           dir = 0-3 or "north"/"east"/"south"/"west"; absolute when calibrated, else relative to
--                          the home facing. Turns the shortest way.
--   moveTo(x, y, z)     absolute (error "not calibrated" if not). Path finds in 3D (A* over what the drone has
--                          seen + the map the computer sent with "mapdata"): goes around buildings, protected
--                          areas and blocks it may not dig, digs natural blocks when that is cheaper (dig = 4 moves).
--                          Replans when it finds something new in the way, waits for mobs and other turtles,
--                          follows partial paths when the target is too far for one search, checks GPS (when
--                          there is GPS) every 32 moves and on arrival. Returns true, or raises "no path to x y z
--                          [: why]" / "blocked at x y z: no progress ..." / "out of fuel ...".
--   moveRel(x, y, z)    the same, relative to home (works uncalibrated; error "no home set" without home).
--   pathTo(x, y, z)     absolute, plan only: -> number of moves (forward/up/down, turns not counted), or
--                          nil, reason ("not calibrated", "no path", "target blocked", "search limit").
--   findItem(pattern)   -> slot of the first item whose name contains pattern (plain text), or nil.
--   selectItem(pattern) -> selects that slot, returns true/false.
--   inspectAll()        -> { front = name|"air", up = ..., down = ... }, recorded for the map.
--   goHome()            path home, face the home facing (raises "not enough fuel to get home ..." if short).
--   unload([keepFuel])  go home and put everything (but one stack of fuel) into the chest at home.
--   refuelTo(n)         burn fuel items until the fuel level is n -> fuel level.
--   print(...), report(...) write to the drone's log (report also broadcasts the status).
-- Digging refuses protected areas, containers/machines/computers/valuable blocks (always) and (with safe dig)
-- blocks that are not natural: false, "protected: ...".
-- A task stops with "low fuel: returning home" when fuel runs short of the way home + 20 (it then goes home).
-- Commands "home", "goto" ({ x, y, z [, rel = true] [, face = dir] }), "tunnel", "quarry" and "unload" run as
-- built-in tasks ("home", "goto x y z", "tunnel 20", "quarry 5x4x5", "unload"): busy rules, "stop" and lastTask
-- apply. goto, tunnel and quarry refuse at once (ack ok = false, "not enough fuel: ...") when the fuel for the
-- way there and back home is missing.
local jobN = 0

local function finish(j, ok, info, msg)
  if job ~= j then return end
  job = nil
  task, state = "manual", "ready"
  lastTask = { name = j.name, ok = ok, info = cut(info or "", 200), by = j.by, n = j.n }
  note(cut(msg, 60))
  pcall(saveMem)
  bcast()
end

local function say(...)
  local t = {}
  for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end
  note(cut(table.concat(t, " "), 60))
end

-- by: who started it ({ id, who }); default: the sender of the command being run
local function startJob(name, fn, builtin, by)
  sensing = false                               -- a stopped trip never got to switch it off
  jobN = jobN + 1
  job = { name = name, co = coroutine.create(fn), builtin = builtin, by = by or cmdBy, started = os.clock(),
          progress = { phase = "working" }, n = jobN }
  task, state = name, "working"
  os.queueEvent("wardenos_task")
  return true, "started"
end

local function turnTo(f)
  local d = (f - nav.f) % 4
  if d == 1 then turtle.turnRight()
  elseif d == 2 then turtle.turnRight() turtle.turnRight()
  elseif d == 3 then turtle.turnLeft() end
end

-- "x y z" of relative cell r (default: the current position): absolute when calibrated
local function here(r)
  r = r or nav
  local a = origin and toAbs(r) or r
  return ("%d %d %d"):format(a.x, a.y, a.z)
end

local function manhattan(a, x, y, z) return math.abs(a.x - x) + math.abs(a.y - y) + math.abs(a.z - z) end
local function homeDist(x, y, z) return math.abs(x) + math.abs(y) + math.abs(z) end

-- nil if the fuel (after burning real fuel from the inventory) lasts for `there` moves and then `back` moves
-- home, plus a spare; else the reason
local function fuelFor(there, back)
  back = homeSet and back or 0
  local spare = FUEL_SPARE + math.ceil((there + back) / 10)
  local need = there + back + spare
  local lvl = burnTo(need)
  if lvl >= need then return nil end
  return ("not enough fuel: needs about %d (%d there%s + %d spare), has %d; bring %d coal"):format(need, there,
    back > 0 and (" + " .. back .. " back home") or "", spare, lvl, math.ceil((need - lvl) / COAL))
end

local MAX_REPLANS, MOB_WAITS, MOB_BUDGET = 40, 5, 10
local GPS_EVERY, TEMP_WAITS = 32, 5

-- try to move into the next cell of a path; false if it can't (the reason is now in the memory, and what was
-- in the way in trip.obstacle)
local function enter(step, trip)
  local move, dig, side = turtle.forward, turtle.dig, "front"
  if step.up then move, dig, side = turtle.up, turtle.digUp, "up"
  elseif step.down then move, dig, side = turtle.down, turtle.digDown, "down"
  else turnTo(step.dir) end
  local k = ckey(step.x, step.y, step.z)
  local where = here(step)
  local waits = 0
  for _ = 1, 24 do                              -- falling gravel/sand: dig again
    local ok, err = move()
    if ok then
      trip.visits[k] = (trip.visits[k] or 0) + 1
      return true
    end
    err = type(err) == "string" and err:lower() or ""
    if err:find("fuel", 1, true) then error("out of fuel at " .. here(), 0) end
    if err:find("too high", 1, true) or err:find("too low", 1, true) or err:find("leave", 1, true)
       or err:find("border", 1, true) or err:find("protected area", 1, true) then
      hard[k] = true
      trip.obstacle = "the world's limit at " .. where
      return false
    end
    local name = observe(side)
    local prog = trip.progress
    if name == nil then                         -- can't inspect: try to dig blind
      if prog then prog.phase = "digging" end
      if not dig() then
        mem[k] = mem[k] or "solid?" hard[k] = true
        trip.obstacle = "a block it can't dig at " .. where
        return false
      end
    elseif name == "air" or enterable(name) then
      -- nothing (or only something replaceable) there but the move failed: a mob or player
      if waits < MOB_WAITS and trip.waits < MOB_BUDGET then
        waits, trip.waits = waits + 1, trip.waits + 1
        if prog then prog.phase = "waiting" end
        liveStatus()
        sleep(0.5)
      else
        temp[k] = now() + 20
        trip.obstacle = "a mob or player at " .. where
        return false
      end
    elseif temp[k] then                         -- another turtle (memSet blocked it for a while)
      trip.obstacle = "another turtle at " .. where
      return false
    else
      if prog then prog.phase = "digging" end
      local dug, why = dig()
      if not dug then                           -- the dig rule refused, or it can't be dug
        if not (type(why) == "string" and why:find("^protected")) then hard[k] = true end
        trip.obstacle = ("%s at %s (%s)"):format(name, where, tostring(why or "can't dig"))
        return false
      end
    end
  end
  hard[k] = true
  trip.obstacle = "blocks that keep falling at " .. where
  return false
end

-- is any cell blocked for a while (other turtles, mobs)?
local function anyTemp(ctx)
  for _, t in pairs(temp) do
    if t > ctx.t then return true end
  end
  return false
end

-- why travel can't reach relative cell t (findPath said why), for the error
local function noPathText(why, tx, ty, tz, label, ctx, trip)
  local s
  if why == "target blocked" then
    local k = ckey(tx, ty, tz)
    local v = mem[k]
    local what = "a cell it can't enter"
    if ctx.ylo and (ty < ctx.ylo or ty > ctx.yhi) then what = "outside the world's height"
    elseif temp[k] then what = "taken by another turtle or a mob"
    elseif v == "solid?" or hard[k] then what = "a block it could not dig"
    elseif v and UNBREAKABLE[v] then what = v .. " (never entered or dug)"
    elseif v then
      local inBox
      for _, b in ipairs(ctx.boxes) do
        if tx >= b.x1 and tx <= b.x2 and ty >= b.y1 and ty <= b.y2 and tz >= b.z1 and tz <= b.z2 then
          inBox = b.name
          break
        end
      end
      what = v .. " (" .. tostring(refusal({ name = v, tags = tagCache[v] }, inBox) or "can't dig") .. ")"
    end
    s = ("no path to %s: the target is %s"):format(label, what)
  elseif why == "search limit" then
    s = ("no path to %s (search limit)"):format(label)
  else
    s = ("no path to %s: walled in by blocks it may not dig"):format(label)
  end
  if trip.obstacle then s = s .. "; last obstacle: " .. trip.obstacle end
  return s
end

-- follow A* paths to relative cell (tx, ty, tz), replanning when something new is in the way
-- progress (status.progress of the running job): { phase = "planning" | "moving" | "digging" | "waiting" |
-- "working", step, total, target = { x, y, z } (absolute when calibrated, else relative), replans }
-- opts.fuel = true: before the first move, check the fuel for the planned path and the way home.
-- opts.quick = true: short hop (mining): GPS check on arrival only when one is due anyway.
local function travel(tx, ty, tz, label, opts)
  opts = opts or {}
  local j = running or job
  local tgt = origin and toAbs({ x = tx, y = ty, z = tz }) or { x = tx, y = ty, z = tz }
  local prog = { phase = "planning", step = 0, total = 0, target = { x = tgt.x, y = tgt.y, z = tgt.z }, replans = 0 }
  if j then j.progress = prog end
  local trip = { waits = 0, visits = {}, progress = prog }
  -- stale: replans since the drone last got closer than ever (a long trip may replan often while it gets on)
  local replans, stale, best, tempWaits, fixes = 0, 0, math.huge, 0, 0
  local fuelChecked = not opts.fuel
  local was = sensing
  sensing = true
  local ok, err = pcall(function()
    while true do
      if nav.x == tx and nav.y == ty and nav.z == tz then
        -- arrived; GPS may say it is not really there
        local fixed = fixes < 3 and sinceFix > 0 and (not opts.quick or sinceFix >= GPS_EVERY) and gpsVerify()
        if not fixed then break end
        fixes = fixes + 1
        note(fixed)
      else
        prog.phase = "planning"
        liveStatus()
        local ctx = planCtx()
        ctx.visits = trip.visits
        local steps, why = findPath(nav, { x = tx, y = ty, z = tz }, { ctx = ctx, partial = true })
        if not steps then
          if why ~= "search limit" and tempWaits < TEMP_WAITS and anyTemp(ctx) then
            tempWaits = tempWaits + 1             -- another turtle or a mob in the way: wait, then plan again
            prog.phase = "waiting"
            liveStatus()
            sleep(2)
            for k in pairs(temp) do temp[k] = nil end   -- they move: look again
          else
            error(noPathText(why, tx, ty, tz, label, ctx, trip), 0)
          end
        else
          if not fuelChecked then
            fuelChecked = true
            local short = fuelFor(why == "partial" and manhattan(nav, tx, ty, tz) or #steps, homeDist(tx, ty, tz))
            if short then error(short, 0) end
          end
          prog.total, prog.step = #steps, 0
          for i, s in ipairs(steps) do
            prog.phase, prog.step = "moving", i
            liveStatus()
            -- sense - replan: something seen on the way made the next cell impassable
            if not cellCost(s.x, s.y, s.z, ctx) or not enter(s, trip) then
              replans = replans + 1
              prog.replans = replans
              break
            end
            if sinceFix >= GPS_EVERY then
              local fixed = gpsVerify()
              if fixed then note(fixed) break end
            end
          end
          local d = manhattan(nav, tx, ty, tz)
          if d < best then
            best, stale = d, 0
          else
            stale = stale + 1
            if stale > MAX_REPLANS or replans > 10 * MAX_REPLANS then
              error(("blocked at %s: no progress towards %s after %d replans%s"):format(here(), label, replans,
                    trip.obstacle and ("; last obstacle: " .. trip.obstacle) or ""), 0)
            end
          end
        end
      end
    end
  end)
  sensing = was
  if j then j.progress = { phase = "working" } end
  if not ok then error(err, 0) end
  return true
end

-- built-in task "home": path to 0,0,0, then face f = 0
local function goHome()
  local need = homeDist(nav.x, nav.y, nav.z) + 5
  local lvl = burnTo(need, true)
  if lvl < need then
    error(("not enough fuel to get home: needs about %d, has %d; bring %d coal"):format(need, lvl,
          math.ceil((need - lvl) / COAL)), 0)
  end
  travel(0, 0, 0, "home")
  turnTo(0)
  note("arrived home")
  return "arrived home"
end

-- before each move of a (non built-in) task: enough fuel to get home? Else stop it and go home.
fuelGuard = function()
  local j = running
  if not j or j.builtin or job ~= j then return end
  local fuel = turtle.getFuelLevel()
  if type(fuel) ~= "number" or fuel >= homeDist(nav.x, nav.y, nav.z) + FUEL_SPARE then return end
  local msg = "low fuel: returning home"
  killed[j.co] = true
  job = nil
  task, state = "manual", "ready"
  lastTask = { name = j.name, ok = false, info = msg, by = j.by, n = j.n }
  note(msg)
  if homeSet then startJob("home", goHome, true, j.by) end
  bcast()
  error(msg, 0)
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

-- x, y, z -> integers or nil
local function cell3(x, y, z)
  x, y, z = tonumber(x), tonumber(y), tonumber(z)
  if not (isNum(x) and isNum(y) and isNum(z)) then return nil end
  return math.floor(x), math.floor(y), math.floor(z)
end

local function moveTo(tx, ty, tz)
  if not origin then error("not calibrated", 2) end
  tx, ty, tz = cell3(tx, ty, tz)
  if not tx then error("bad position", 2) end
  local r = toRel({ x = tx, y = ty, z = tz })
  return travel(r.x, r.y, r.z, ("%d %d %d"):format(tx, ty, tz))
end

local function moveRel(tx, ty, tz)
  if not homeSet then error("no home set", 2) end
  tx, ty, tz = cell3(tx, ty, tz)
  if not tx then error("bad position", 2) end
  return travel(tx, ty, tz, ("%d %d %d"):format(tx, ty, tz))
end

local function pathTo(tx, ty, tz)
  if not origin then return nil, "not calibrated" end
  tx, ty, tz = cell3(tx, ty, tz)
  if not tx then return nil, "bad position" end
  local steps, why = findPath(nav, toRel({ x = tx, y = ty, z = tz }))
  if not steps then return nil, why end
  return #steps
end

-- command "goto": { x, y, z [, rel = true] [, face = dir] } -> built-in task "goto x y z"
local function startGoto(arg)
  if type(arg) ~= "table" then return false, "bad position" end
  local x, y, z = cell3(arg.x, arg.y, arg.z)
  if not x then return false, "bad position" end
  local f
  if arg.face ~= nil then
    f = parseFacing(arg.face)
    if not f then return false, "bad facing" end
  end
  local rel = arg.rel == true
  if rel and not homeSet then return false, "no home set" end
  if not rel and not origin then return false, "not calibrated" end
  local label = ("%d %d %d"):format(x, y, z)
  local r = rel and { x = x, y = y, z = z } or toRel({ x = x, y = y, z = z })
  local short = fuelFor(manhattan(nav, r.x, r.y, r.z), homeDist(r.x, r.y, r.z))
  if short then return false, short end
  return startJob("goto " .. label, function()
    travel(r.x, r.y, r.z, label, { fuel = true })
    if f then turnTo(rel and f or (f - origin.f) % 4) end
    note("arrived " .. label)
    return "arrived " .. label
  end, false)
end

---------------------------------------------------------------- built-in jobs: tunnel, quarry, unload
-- Mining jobs walk every third layer and dig the layers above and below from there. They never dig what the
-- dig rule refuses (they skip it and say so), go home to unload into the chest there when the inventory is
-- full (or drop junk first with drop_junk), and come back to where they started.
-- (one table: the agent's main chunk is near Lua's limit of 200 locals)
local JOBS = { junk = {}, containers = { "chest", "barrel", "shulker_box", "hopper", "drawer", "crate" },
               drop = { front = "drop", up = "dropUp", down = "dropDown" },
               pside = { front = "front", up = "top", down = "bottom" } }
for _, n in ipairs { "minecraft:cobblestone", "minecraft:cobbled_deepslate", "minecraft:dirt", "minecraft:gravel",
                     "minecraft:netherrack", "minecraft:tuff", "minecraft:granite", "minecraft:diorite",
                     "minecraft:andesite", "minecraft:calcite", "minecraft:sand", "minecraft:blackstone",
                     "minecraft:basalt", "minecraft:stone", "minecraft:deepslate" } do
  JOBS.junk[n] = true
end

local function freeSlots()
  local n = 0
  for i = 1, 16 do if turtle.getItemCount(i) == 0 then n = n + 1 end end
  return n
end

-- the inventory block next to the drone: side, name (nil if none)
local function findContainer()
  for _, side in ipairs { "front", "down", "up" } do
    local name = peek(side)
    if name and name ~= "air" then
      for _, c in ipairs(JOBS.containers) do
        if name:find(c, 1, true) then return side, name end
      end
      local ok, inv = pcall(function()
        return peripheral.hasType and peripheral.hasType(JOBS.pside[side], "inventory")
      end)
      if ok and inv then return side, name end
    end
  end
end

-- put everything into the container next to the drone, but keep one stack of real fuel (keepFuel)
-- -> moved, left, side, name | nil, why
local function unloadHere(keepFuel)
  local side, name = findContainer()
  if not side then return nil, "no chest at home: put a chest in front of, above or below the home spot" end
  local drop = turtle[JOBS.drop[side]]
  if not drop then return nil, "this turtle can't drop items " .. side end
  local sel, moved, left, kept = turtle.getSelectedSlot(), 0, 0, false
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d then
      if keepFuel and not kept and realFuel(d.name) then
        kept = true
      else
        turtle.select(i)
        drop()
        local rest = turtle.getItemCount(i)
        moved, left = moved + d.count - rest, left + rest
      end
    end
  end
  turtle.select(sel)
  return moved, left, side, name
end

-- throw away cobblestone, dirt, gravel... -> stacks dropped
local function dropJunk()
  local sel, n = turtle.getSelectedSlot(), 0
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d and JOBS.junk[d.name] then
      turtle.select(i)
      if turtle.drop() then n = n + 1 end
    end
  end
  turtle.select(sel)
  return n
end

local function unloadJob(keepFuel)
  if not homeSet then error("no home set", 0) end
  goHome()
  local moved, left, side, name = unloadHere(keepFuel ~= false)
  if not moved then error(left, 0) end
  if left > 0 then
    error(("chest full: put %d items into %s, %d still in the drone"):format(moved, name, left), 0)
  end
  local msg = ("unloaded %d items into %s (%s)"):format(moved, name, side)
  note(cut(msg, 60))
  return msg
end

-- walking layers of a box from y2 down to y1: each one also digs the layer above and below
local function bandsOf(y1, y2)
  local out, yw = {}, y2 - 1
  while true do
    if yw < y1 then yw = y1 end
    out[#out + 1] = yw
    if yw - 1 <= y1 then return out end
    yw = yw - 3
  end
end

-- a travel error that only means "this cell can't be reached" (the job skips it); others end the job
local function skippable(e)
  return type(e) == "string" and (e:find("^no path to") or e:find("^blocked at")) and true or false
end

-- mine every cell of box b (relative, inclusive) the dig rules allow. o: dropJunk, unload (false: never go
-- home to unload). -> { dug, skipped, why (first reason something was skipped), trips }
local function mineBox(b, o)
  local st = { dug = 0, skipped = 0, trips = 0 }
  local dug0 = digCount
  local j = running or job
  local function skip(why)
    st.skipped = st.skipped + 1
    st.why = st.why or tostring(why):gsub("; last obstacle: .*$", "")
  end
  local function digSide(side)
    local dig = side == "up" and turtle.digUp or turtle.digDown
    for _ = 1, 16 do                             -- gravel and sand keep falling in
      local name = observe(side)
      if name == nil or name == "air" or PASSABLE[name] then return end
      if UNBREAKABLE[name] then return skip(name .. " can't be dug") end
      local ok, why = dig()
      if not ok then return skip(name .. ": " .. tostring(why or "can't dig")) end
    end
  end
  local function roomCheck()
    if freeSlots() > 0 then return end
    if o.dropJunk and dropJunk() > 0 and freeSlots() > 0 then return end
    if o.unload == false or not homeSet then error("inventory full at " .. here(), 0) end
    local back = { x = nav.x, y = nav.y, z = nav.z }
    goHome()
    local moved, left = unloadHere(true)
    if not moved then error("inventory full; " .. left, 0) end
    if freeSlots() == 0 then error("inventory full and the chest at home is full", 0) end
    st.trips = st.trips + 1
    note("unloaded, back to work")
    travel(back.x, back.y, back.z, here(back), { fuel = true })
  end
  local bands = bandsOf(b.y1, b.y2)
  local nx, nz = b.x2 - b.x1 + 1, b.z2 - b.z1 + 1
  local total, done, flip = #bands * nx * nz, 0, false
  for bi, y in ipairs(bands) do
    for xi = 0, nx - 1 do
      local x = bi % 2 == 1 and b.x1 + xi or b.x2 - xi
      for zi = 0, nz - 1 do
        local z = flip and b.z2 - zi or b.z1 + zi
        roomCheck()
        local ok, e = pcall(travel, x, y, z, here({ x = x, y = y, z = z }), { quick = true })
        if ok then
          if y + 1 <= b.y2 then digSide("up") end
          if y - 1 >= b.y1 then digSide("down") end
        elseif skippable(e) then
          skip(e)
        else
          error(e, 0)
        end
        done = done + 1
        if j then j.progress = { phase = "mining", step = done, total = total } end
        liveStatus()
      end
      flip = not flip
    end
  end
  st.dug = digCount - dug0
  return st
end

local function jobSummary(what, st)
  if st.dug == 0 and st.skipped > 0 then error(what .. ": mined nothing; " .. tostring(st.why), 0) end
  local s = ("%s done: dug %d blocks"):format(what, st.dug)
  if st.trips > 0 then s = s .. (", %d unload trips"):format(st.trips) end
  if st.skipped > 0 then s = s .. (", skipped %d (first: %s)"):format(st.skipped, tostring(st.why)) end
  return s
end

-- integer argument in lo..hi (default def when missing) -> n | nil
local function intArg(v, lo, hi, def)
  if v == nil then return def end
  v = tonumber(v)
  if not isNum(v) then return nil end
  v = math.floor(v)
  if v < lo or v > hi then return nil end
  return v
end

-- command "tunnel": { length, width = 1, height = 2, dir (facing; default: the current one), back = true,
-- drop_junk } -> task "tunnel N": mines from the cell in front of the drone, width to its right, height up
local function startTunnel(arg)
  if type(arg) ~= "table" then arg = { length = arg } end
  local len, w, h = intArg(arg.length, 1, 512), intArg(arg.width, 1, 8, 1), intArg(arg.height, 1, 8, 2)
  if not len then return false, "bad length (1-512)" end
  if not w then return false, "bad width (1-8)" end
  if not h then return false, "bad height (1-8)" end
  local f = nav.f
  if arg.dir ~= nil then
    f = parseFacing(arg.dir)
    if not f then return false, "bad direction" end
    if origin then f = (f - origin.f) % 4 end
  end
  local r = (f + 1) % 4
  local ax, az = nav.x + DX[f], nav.z + DZ[f]
  local bx, bz = nav.x + DX[f] * len + DX[r] * (w - 1), nav.z + DZ[f] * len + DZ[r] * (w - 1)
  local box = { x1 = math.min(ax, bx), x2 = math.max(ax, bx), y1 = nav.y, y2 = nav.y + h - 1,
                z1 = math.min(az, bz), z2 = math.max(az, bz) }
  local back = arg.back ~= false
  local walk = len * w * #bandsOf(box.y1, box.y2)
  local short = fuelFor(walk + (back and len + w or 0),
                        back and homeDist(nav.x, nav.y, nav.z) or homeDist(bx, nav.y, bz))
  if short then return false, short end
  local start = { x = nav.x, y = nav.y, z = nav.z, f = f }
  return startJob(("tunnel %d"):format(len), function()
    local st = mineBox(box, { dropJunk = arg.drop_junk == true, unload = arg.unload })
    if back then
      travel(start.x, start.y, start.z, "the tunnel start")
      turnTo(start.f)
    end
    local msg = jobSummary(("tunnel %d x %d x %d"):format(len, w, h), st)
    note(cut(msg, 60))
    return msg
  end, false)
end

-- command "quarry": { x1, y1, z1, x2, y2, z2 [, rel = true] [, back = true] [, drop_junk] } -> task "quarry WxHxD"
-- mines the box from the top down, then returns to where it started
local function startQuarry(arg)
  if type(arg) ~= "table" then return false, "bad box" end
  local a = { cell3(arg.x1, arg.y1, arg.z1) }
  local c = { cell3(arg.x2, arg.y2, arg.z2) }
  if not a[1] or not c[1] then return false, "bad box" end
  local rel = arg.rel == true
  if rel and not homeSet then return false, "no home set" end
  if not rel and not origin then return false, "not calibrated" end
  local p = rel and { x = a[1], y = a[2], z = a[3] } or toRel({ x = a[1], y = a[2], z = a[3] })
  local q = rel and { x = c[1], y = c[2], z = c[3] } or toRel({ x = c[1], y = c[2], z = c[3] })
  local box = { x1 = math.min(p.x, q.x), x2 = math.max(p.x, q.x), y1 = math.min(p.y, q.y), y2 = math.max(p.y, q.y),
                z1 = math.min(p.z, q.z), z2 = math.max(p.z, q.z) }
  local sx, sy, sz = box.x2 - box.x1 + 1, box.y2 - box.y1 + 1, box.z2 - box.z1 + 1
  if sx > 64 or sz > 64 or sx * sy * sz > 65536 then
    return false, "box too big (max 64 x 64 wide, 65536 blocks)"
  end
  local back = arg.back ~= false
  -- fuel to get there, mine the first walking layer (more as coal turns up) and get home
  local there = manhattan(nav, box.x1, box.y2, box.z1) + math.min(sx * sz * #bandsOf(box.y1, box.y2), 400)
  local short = fuelFor(there, homeDist(box.x1, box.y2, box.z1))
  if short then return false, short end
  local start = { x = nav.x, y = nav.y, z = nav.z, f = nav.f }
  local dims = ("%dx%dx%d"):format(sx, sy, sz)
  return startJob("quarry " .. dims, function()
    local st = mineBox(box, { dropJunk = arg.drop_junk == true, unload = arg.unload })
    if back then
      travel(start.x, start.y, start.z, "the quarry start")
      turnTo(start.f)
    end
    local msg = jobSummary("quarry " .. dims, st)
    note(cut(msg, 60))
    return msg
  end, false)
end

-- command "mapdata": { blocks = { { x, y, z, name }, ... } } absolute -> merged into the block memory
local function mapData(arg)
  if not origin then return false, "not calibrated" end
  if type(arg) ~= "table" or type(arg.blocks) ~= "table" then return false, "bad blocks" end
  local list = arg.blocks
  if #list > 5000 then return false, "too many blocks (max 5000)" end
  local n = 0
  for _, b in ipairs(list) do
    if type(b) == "table" and type(b[4]) == "string" and #b[4] <= 100 then
      local x, y, z = cell3(b[1], b[2], b[3])
      if x then
        local r = toRel({ x = x, y = y, z = z })
        memSet(r.x, r.y, r.z, b[4])
        n = n + 1
      end
    end
  end
  return true, n .. " blocks"
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
  env.report = function(...)                    -- broadcasts at most every second (keeps rednet quiet)
    say(...)
    if os.clock() - lastBc >= 1 then bcast() end
  end
  env.turtle = turtle
  env.whereAmI, env.face, env.moveTo, env.moveRel, env.pathTo = whereAmI, faceDir, moveTo, moveRel, pathTo
  env.findItem, env.selectItem, env.inspectAll = findItem, selectItem, inspectAll
  env.goHome, env.unload = goHome, unloadJob
  env.refuelTo = function(n) return burnTo(tonumber(n) or 0, true) end
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
local WHILE_BUSY = { stop = true, claim = true, release = true, label = true, locate = true, mapdata = true }

-- arg: nil = burn everything burnable; a number (or { to = n }) = burn fuel items until the fuel level is n
local function refuel(arg)
  local sel, gained = turtle.getSelectedSlot(), 0
  local before = turtle.getFuelLevel()
  if before == "unlimited" then return true end
  local target = tonumber(type(arg) == "table" and arg.to or arg)
  if target then
    local limit = turtle.getFuelLimit()
    target = math.floor(math.min(target, type(limit) == "number" and limit > 0 and limit or target))
    local lvl = burnTo(target, true)
    if lvl >= target then return true, ("fuel %d (+%d)"):format(lvl, lvl - before) end
    return false, ("fuel %d (+%d): out of fuel items before %d; bring %d coal"):format(lvl, lvl - before, target,
                                                                                    math.ceil((target - lvl) / COAL))
  end
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
    return refuel(arg)
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
    rebaseMem()                                 -- and what it remembers
    nav, homeSet = { x = 0, y = 0, z = 0, f = 0 }, true
    saveNav()
    note("home set")
    return true
  elseif cmd == "home" then
    if not homeSet then return false, "no home set" end
    return startJob("home", goHome, true)
  elseif cmd == "goto" then
    return startGoto(arg)
  elseif cmd == "tunnel" then
    return startTunnel(arg)
  elseif cmd == "quarry" then
    return startQuarry(arg)
  elseif cmd == "unload" then
    if not homeSet then return false, "no home set" end
    local keep = not (type(arg) == "table" and arg.keep_fuel == false)
    return startJob("unload", function() return unloadJob(keep) end, false)
  elseif cmd == "mapdata" then
    return mapData(arg)
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
        cmdBy = { id = from, who = msg.by == "claude" and "claude" or "player" }   -- a task started now keeps it
        local before = job
        local ok, res, info = pcall(run, from, msg.cmd, msg.arg)
        cmdBy = nil
        if not ok then info, res = res, false end  -- run() crashed: report the error
        state = job and "working" or "ready"
        note(cut(msg.cmd .. (res and " ok" or " failed") .. (info and (": " .. tostring(info)) or ""), 60))
        rednet.send(from, { t = "ack", seq = msg.seq, cmd = msg.cmd, ok = res and true or false,
                            info = info and tostring(info) or nil,
                            job = res and job and job ~= before and job.n or nil }, PROTO)   -- the task it started
        bcast()
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
      bcast()
    end
    dirty = true
    tick = tick + 1
    sleep(3)
  end
end

-- sends what the drone saw to the map, at most every 2 seconds
-- and saves the block memory at most every ~30 s (and when a task ends)
local function mapper()
  local tick = 0
  while true do
    sleep(2)
    if pendingN > 0 and modems() > 0 then flushObs() end
    tick = tick + 1
    if tick % 15 == 0 and memDirty and not job then pcall(saveMem) end
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
