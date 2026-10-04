-- WardenOS world map: what the drones have seen, stored on this computer, plus the player's protected areas.
-- One shared instance per computer (the kernel, the Map app and Claude all get the same tables):
--   local map = dofile("/os/lib/map.lua")
--
--   map.add(obs)                  obs = { {x, y, z, name} | {x=, y=, z=, name=}, ... } (absolute coordinates;
--                                 name = block id like "minecraft:stone", or "air"). Returns stored, dropped.
--   map.get(x, y, z)              block name, or nil if never seen
--   map.surface(x, z)             y, name of the highest known non-air block in that column (nil if none)
--   map.cell(x, z, y)             char, name, y for one map cell (y = nil: surface); chars are in map.LEGEND
--   map.view(x1, z1, x2, z2, y, marks)
--                                 rows (list of strings, north = first row, west = first column), legend text,
--                                 area {x1, z1, x2, z2}; max map.MAXW x map.MAXH (cut from x1/z1);
--                                 y = nil: surface view; marks = { {x=, z=, ch="D"}, ... } drawn on top
--   map.find(pattern, near, limit)
--                                 { {x, y, z, name, d}, ... } blocks whose name contains pattern (plain text,
--                                 any case), nearest to near = {x, y, z} first; limit default 20, max 100
--   map.info()                    { total, cap, full, chunks, bounds = {x1,y1,z1,x2,y2,z2} | nil,
--                                   counts = { [char] = n }, protect = {rev, boxes} }
--   map.category(name)            the map char of a block name
--   map.protected()               { rev = n, boxes = { {name, x1, y1, z1, x2, y2, z2}, ... } }
--   map.protect(box)              add a protected area (inclusive, min/max sorted, y default -64..320);
--                                 returns index | nil, why. rev goes up on every change.
--   map.unprotect(i)              remove area i (only the Map app does this: the player's decision)
--   map.isProtected(x, y, z)      the box containing that block, or nil
--   map.flush()                   write changed chunks to disk (the kernel calls this every few seconds)
--
-- Storage: /os/map/<cx>_<cz> per 16x16 column chunk (cx = floor(x / 16)), /os/map/index (blocks per chunk),
-- /os/map/protect. A chunk file is "WMAP1" then one line per block name: "<name>\t<positions>", each position
-- 3 characters (base 64 of ((y + 64) * 16 + z % 16) * 16 + x % 16). About 3 bytes per block on disk,
-- so the default cap of 120000 blocks is ~360 KB (+ 500 bytes minimum per file in CC: Tweaked).
-- New blocks are also refused when the disk has less than 96 KB free (computers have 1 MB by default).
-- Blocks already known are always updated, and "air" is stored too (it matters for paths).
local VERSION = 1
local shared = rawget(_G, "WardenMap")
if type(shared) == "table" and shared.VERSION == VERSION then return shared end

local DIR = "/os/map"
local INDEX, PROTECT = DIR .. "/index", DIR .. "/protect"
local YMIN, YMAX = -64, 320
local MIN_FREE = 96 * 1024
local MAX_BOXES = 64

local M = { VERSION = VERSION, DIR = DIR, YMIN = YMIN, YMAX = YMAX, CAP = 120000, MAXW = 60, MAXH = 40 }
M.full = false

---------------------------------------------------------------- categories
M.LEGEND = {
  { "?", "unknown" }, { ".", "air" }, { "#", "stone" }, { ":", "dirt/sand" }, { ",", "plants" },
  { "~", "water" }, { "^", "lava" }, { "T", "logs/leaves" }, { "o", "ore" }, { "=", "building/other" },
  { "P", "protected" }, { "D", "drone" }, { "H", "drone home" },
}
local function anyOf(s, list)
  for _, p in ipairs(list) do if s:find(p, 1, true) then return true end end
  return false
end
local AIR = { air = true, ["minecraft:air"] = true, ["minecraft:cave_air"] = true, ["minecraft:void_air"] = true }
local cats = {}
function M.category(name)
  if name == nil then return "?" end
  local c = cats[name]
  if c then return c end
  local s = tostring(name):lower()
  local short = s:match(":(.*)$") or s
  if AIR[s] or short == "air" then c = "."
  elseif anyOf(short, { "water", "bubble_column", "kelp", "seagrass", "ice" }) then c = "~"
  elseif short:find("lava", 1, true) or short == "magma_block" then c = "^"
  elseif short:find("_ore$") or short:find("^ore_") or short == "ancient_debris" then c = "o"
  elseif anyOf(short, { "polished", "smooth", "chiseled", "cut_", "brick", "planks", "glass", "wool", "concrete",
                        "terracotta", "stairs", "slab", "fence", "door", "wall", "carpet", "bed", "chest", "furnace",
                        "torch", "lantern", "lamp", "rail", "table", "barrel", "hopper", "shelf", "_block", "stripped", "redstone" })
         and not anyOf(short, { "grass_block", "snow_block", "dripstone_block", "moss_block", "mushroom_block", "bedrock", "moss_carpet" }) then
    c = "="
  elseif anyOf(short, { "_log", "_wood", "leaves", "_stem", "mushroom_block", "vine", "roots" }) then c = "T"
  elseif short:find("sandstone", 1, true) then c = "#"
  elseif anyOf(short, { "dirt", "grass_block", "podzol", "mycelium", "farmland", "mud", "sand", "gravel", "clay",
                        "snow", "soul_soil", "moss_block", "nylium" }) then c = ":"
  elseif anyOf(short, { "grass", "fern", "flower", "tulip", "poppy", "dandelion", "orchid", "allium", "bluet",
                        "daisy", "cornflower", "lily", "bush", "sapling", "mushroom", "cane", "cactus", "berry",
                        "dripleaf", "azalea", "moss_carpet", "seagrass" }) then c = ","
  elseif anyOf(short, { "stone", "deepslate", "granite", "diorite", "andesite", "tuff", "calcite", "netherrack",
                        "basalt", "blackstone", "bedrock", "obsidian", "dripstone", "end_stone", "amethyst" }) then c = "#"
  else c = "=" end                               -- anything else (machines, modded blocks) counts as built
  cats[name] = c
  return c
end

---------------------------------------------------------------- encoding
local ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local ENC, DEC = {}, {}
for i = 1, 64 do
  ENC[i - 1] = ALPHA:sub(i, i)
  DEC[ALPHA:byte(i)] = i - 1
end
local function pack(lx, y, lz) return ((y - YMIN) * 16 + lz) * 16 + lx end
local function unpackPos(p) return p % 16, math.floor(p / 256) + YMIN, math.floor(p / 16) % 16 end
local function enc(p) return ENC[math.floor(p / 4096)] .. ENC[math.floor(p / 64) % 64] .. ENC[p % 64] end

local function okName(n)
  return type(n) == "string" and #n > 0 and #n <= 64 and not n:find("[%c\t\n]")
end

---------------------------------------------------------------- files
local function readFile(p)
  if not fs.exists(p) or fs.isDir(p) then return nil end
  local f = fs.open(p, "r")
  if not f then return nil end
  local s = f.readAll()
  f.close()
  return s
end
local function writeFile(p, s)
  if not fs.exists(DIR) then fs.makeDir(DIR) end
  local f = fs.open(p, "w")
  if not f then return false end
  f.write(s)
  f.close()
  return true
end

---------------------------------------------------------------- chunks
local chunks = {}                               -- [key] = { cx, cz, b = {[pos] = name}, n, top = {}, known = {}, dirty }
local index = {}                                -- [key] = blocks in that chunk (also for chunks not loaded)
local total = 0
local indexDirty = false

local function keyOf(cx, cz) return cx .. "_" .. cz end

local function newChunk(cx, cz)
  return { cx = cx, cz = cz, b = {}, n = 0, top = {}, known = {}, dirty = false }
end

local function noteTop(c, p, name)
  local lx, y, lz = unpackPos(p)
  local col = lx + 16 * lz
  c.known[col] = true
  if name ~= "air" and (c.top[col] == nil or y > c.top[col]) then c.top[col] = y end
end

local function parseChunk(c, s)
  local first = true
  for line in s:gmatch("[^\n]+") do
    if first then
      first = false
      if line ~= "WMAP1" then return end
    else
      local name, codes = line:match("^([^\t]+)\t(.*)$")
      if name then
        for i = 1, #codes - 2, 3 do
          local a, b, d = DEC[codes:byte(i)], DEC[codes:byte(i + 1)], DEC[codes:byte(i + 2)]
          if a and b and d then
            local p = a * 4096 + b * 64 + d
            if c.b[p] == nil then c.n = c.n + 1 end
            c.b[p] = name
            noteTop(c, p, name)
          end
        end
      end
    end
  end
end

local missing = {}                             -- [key] = true: no file for that chunk (saves fs calls)
local function chunk(cx, cz, create)
  local key = keyOf(cx, cz)
  local c = chunks[key]
  if c then return c end
  if missing[key] and not create then return nil end
  local s = not missing[key] and readFile(DIR .. "/" .. key) or nil
  if not s and not create then missing[key] = true return nil end
  missing[key] = nil
  c = newChunk(cx, cz)
  if s then parseChunk(c, s) end
  chunks[key] = c
  return c
end

local function chunkAt(x, z, create)
  return chunk(math.floor(x / 16), math.floor(z / 16), create)
end

local function loadAll()
  if not fs.isDir(DIR) then return end
  for _, f in ipairs(fs.list(DIR)) do
    local cx, cz = f:match("^(%-?%d+)_(%-?%d+)$")
    if cx then chunk(tonumber(cx), tonumber(cz), false) end
  end
end

-- index: blocks per chunk; rebuilt from the chunk files if it is missing
do
  local d = textutils.unserialize(readFile(INDEX) or "")
  if type(d) == "table" then
    for k, n in pairs(d) do
      if type(k) == "string" and type(n) == "number" then index[k] = n total = total + n end
    end
  elseif fs.isDir(DIR) then
    loadAll()
    for k, c in pairs(chunks) do index[k] = c.n total = total + c.n end
    indexDirty = total > 0
  end
end

---------------------------------------------------------------- protected areas
local prot = { rev = 0, boxes = {} }
do
  local d = textutils.unserialize(readFile(PROTECT) or "")
  if type(d) == "table" and type(d.boxes) == "table" then
    prot.rev = tonumber(d.rev) or 0
    for _, b in ipairs(d.boxes) do
      if type(b) == "table" and tonumber(b.x1) and tonumber(b.x2) then prot.boxes[#prot.boxes + 1] = b end
    end
  end
end
local function saveProt()
  writeFile(PROTECT, textutils.serialize({ rev = prot.rev, boxes = prot.boxes }))
end

function M.protected() return prot end

function M.protect(box)
  if type(box) ~= "table" then return nil, "bad area" end
  if #prot.boxes >= MAX_BOXES then return nil, "too many protected areas (" .. MAX_BOXES .. ")" end
  local v = {}
  for _, k in ipairs({ "x1", "z1", "x2", "z2" }) do
    v[k] = tonumber(box[k])
    if not v[k] then return nil, "missing " .. k end
    v[k] = math.floor(v[k])
  end
  v.y1 = math.floor(tonumber(box.y1) or YMIN)
  v.y2 = math.floor(tonumber(box.y2) or YMAX)
  local b = {
    name = tostring(box.name or "area"):gsub("[%c]", ""):sub(1, 32),
    x1 = math.min(v.x1, v.x2), x2 = math.max(v.x1, v.x2),
    y1 = math.max(YMIN, math.min(v.y1, v.y2)), y2 = math.min(YMAX, math.max(v.y1, v.y2)),
    z1 = math.min(v.z1, v.z2), z2 = math.max(v.z1, v.z2),
  }
  if b.name == "" then b.name = "area" end
  prot.boxes[#prot.boxes + 1] = b
  prot.rev = prot.rev + 1
  saveProt()
  return #prot.boxes
end

function M.unprotect(i)
  if not prot.boxes[i] then return false end
  table.remove(prot.boxes, i)
  prot.rev = prot.rev + 1
  saveProt()
  return true
end

function M.isProtected(x, y, z)
  for _, b in ipairs(prot.boxes) do
    if x >= b.x1 and x <= b.x2 and z >= b.z1 and z <= b.z2 and (y == nil or (y >= b.y1 and y <= b.y2)) then
      return b
    end
  end
end

---------------------------------------------------------------- blocks
function M.add(obs)
  local stored, dropped = 0, 0
  if type(obs) ~= "table" then return 0, 0 end
  for i = 1, math.min(#obs, 512) do
    local o = obs[i]
    if type(o) == "table" then
      local x, y, z, name = tonumber(o.x or o[1]), tonumber(o.y or o[2]), tonumber(o.z or o[3]), o.name or o[4]
      if x and y and z and okName(name) and y >= YMIN and y <= YMAX then
        x, y, z = math.floor(x), math.floor(y), math.floor(z)
        if AIR[name] then name = "air" end
        local c = chunkAt(x, z, true)
        local p = pack(x - c.cx * 16, y, z - c.cz * 16)
        local old = c.b[p]
        if old == nil and (M.full or total >= M.CAP) then
          dropped = dropped + 1
        elseif old ~= name then
          if old == nil then
            c.n, total = c.n + 1, total + 1
            index[keyOf(c.cx, c.cz)] = c.n
          end
          c.b[p] = name
          c.dirty, indexDirty = true, true
          local col = (x - c.cx * 16) + 16 * (z - c.cz * 16)
          c.known[col] = true
          if name ~= "air" then
            if c.top[col] == nil or y > c.top[col] then c.top[col] = y end
          elseif c.top[col] == y then           -- the top block is gone: find the next one down
            c.top[col] = nil
            local lx, lz = col % 16, math.floor(col / 16)
            for yy = y - 1, YMIN, -1 do
              local n = c.b[pack(lx, yy, lz)]
              if n and n ~= "air" then c.top[col] = yy break end
            end
          end
          stored = stored + 1
        end
      end
    end
  end
  return stored, dropped
end

function M.get(x, y, z)
  local c = chunkAt(x, z, false)
  if not c then return nil end
  return c.b[pack(x - c.cx * 16, y, z - c.cz * 16)]
end

function M.surface(x, z)
  local c = chunkAt(x, z, false)
  if not c then return nil end
  local lx, lz = x - c.cx * 16, z - c.cz * 16
  local y = c.top[lx + 16 * lz]
  if y then return y, c.b[pack(lx, y, lz)] end
end

-- one map cell: char, block name (nil if unknown), y of that block
function M.cell(x, z, y)
  local c = chunkAt(x, z, false)
  if not c then return "?" end
  local lx, lz = x - c.cx * 16, z - c.cz * 16
  if y then
    local n = c.b[pack(lx, y, lz)]
    return M.category(n), n, y
  end
  local ty = c.top[lx + 16 * lz]
  if ty then
    local n = c.b[pack(lx, ty, lz)]
    return M.category(n), n, ty
  end
  if c.known[lx + 16 * lz] then return ".", "air" end
  return "?"
end

function M.legend()
  local parts = {}
  for _, l in ipairs(M.LEGEND) do parts[#parts + 1] = l[1] .. " " .. l[2] end
  return table.concat(parts, ", ")
end

function M.view(x1, z1, x2, z2, y, marks)
  x1, z1 = math.floor(tonumber(x1) or 0), math.floor(tonumber(z1) or 0)
  x2, z2 = math.floor(tonumber(x2) or x1), math.floor(tonumber(z2) or z1)
  if x2 < x1 then x1, x2 = x2, x1 end
  if z2 < z1 then z1, z2 = z2, z1 end
  x2, z2 = math.min(x2, x1 + M.MAXW - 1), math.min(z2, z1 + M.MAXH - 1)
  y = tonumber(y) and math.floor(tonumber(y)) or nil
  local over = {}
  for _, m in ipairs(type(marks) == "table" and marks or {}) do
    local mx, mz = tonumber(m.x), tonumber(m.z)
    if mx and mz then over[math.floor(mx) .. "," .. math.floor(mz)] = tostring(m.ch or "D"):sub(1, 1) end
  end
  local rows = {}
  for z = z1, z2 do
    local row = {}
    for x = x1, x2 do
      local ch = over[x .. "," .. z]
      if not ch then
        ch = M.cell(x, z, y)
        if #prot.boxes > 0 and M.isProtected(x, y, z) then ch = "P" end
      end
      row[#row + 1] = ch
    end
    rows[#rows + 1] = table.concat(row)
  end
  return rows, M.legend(), { x1 = x1, z1 = z1, x2 = x2, z2 = z2, y = y }
end

function M.find(pattern, near, limit)
  pattern = tostring(pattern or ""):lower()
  limit = math.max(1, math.min(100, math.floor(tonumber(limit) or 20)))
  if pattern == "" then return {} end
  local wantAir = pattern == "air"
  loadAll()
  local nx, ny, nz
  if type(near) == "table" then nx, ny, nz = tonumber(near.x or near[1]), tonumber(near.y or near[2]), tonumber(near.z or near[3]) end
  local out = {}
  local match = {}
  for _, c in pairs(chunks) do
    for p, name in pairs(c.b) do
      local m = match[name]
      if m == nil then
        m = (name ~= "air" or wantAir) and name:lower():find(pattern, 1, true) ~= nil
        match[name] = m
      end
      if m then
        local lx, y, lz = unpackPos(p)
        local x, z = c.cx * 16 + lx, c.cz * 16 + lz
        local d = nx and math.sqrt((x - nx) ^ 2 + (y - (ny or y)) ^ 2 + (z - (nz or z)) ^ 2) or 0
        if #out < limit or d < out[#out].d then
          local e = { x = x, y = y, z = z, name = name, d = d }
          local i = #out
          while i > 0 and out[i].d > d do i = i - 1 end
          table.insert(out, i + 1, e)
          if #out > limit then out[#out] = nil end
        end
      end
    end
  end
  return out
end

function M.info()
  loadAll()
  local counts, bounds, n = {}, nil, 0
  for _, c in pairs(chunks) do
    n = n + 1
    for p, name in pairs(c.b) do
      local ch = M.category(name)
      counts[ch] = (counts[ch] or 0) + 1
      local lx, y, lz = unpackPos(p)
      local x, z = c.cx * 16 + lx, c.cz * 16 + lz
      if not bounds then
        bounds = { x1 = x, y1 = y, z1 = z, x2 = x, y2 = y, z2 = z }
      else
        if x < bounds.x1 then bounds.x1 = x elseif x > bounds.x2 then bounds.x2 = x end
        if y < bounds.y1 then bounds.y1 = y elseif y > bounds.y2 then bounds.y2 = y end
        if z < bounds.z1 then bounds.z1 = z elseif z > bounds.z2 then bounds.z2 = z end
      end
    end
  end
  return { total = total, cap = M.CAP, full = M.full or total >= M.CAP, chunks = n, bounds = bounds,
           counts = counts, protect = prot }
end

function M.count() return total end

-- blocks per chunk file: { ["<cx>_<cz>"] = n } (a copy)
function M.chunks()
  local t = {}
  for k, n in pairs(index) do t[k] = n end
  return t
end

---------------------------------------------------------------- disk
function M.flush()
  local wrote = 0
  for key, c in pairs(chunks) do
    if c.dirty then
      local by = {}
      for p, name in pairs(c.b) do
        local l = by[name]
        if not l then l = {} by[name] = l end
        l[#l + 1] = enc(p)
      end
      local out = { "WMAP1" }
      for name, l in pairs(by) do out[#out + 1] = name .. "\t" .. table.concat(l) end
      if writeFile(DIR .. "/" .. key, table.concat(out, "\n") .. "\n") then
        c.dirty = false
        wrote = wrote + 1
      end
    end
  end
  if indexDirty then
    if writeFile(INDEX, textutils.serialize(index)) then indexDirty = false end
  end
  local okf, free = pcall(fs.getFreeSpace, DIR)
  if okf and type(free) == "number" then M.full = free < MIN_FREE end
  return wrote
end

rawset(_G, "WardenMap", M)
return M
