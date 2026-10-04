-- WardenOS world map: what the drones have seen, stored on this computer, plus the player's protected areas.
-- One shared instance per computer (the kernel, the Map app and Claude all get the same tables):
--   local map = dofile("/os/lib/map.lua")
--
--   map.add(obs)                  obs = { {x, y, z, name} | {x=, y=, z=, name=}, ... } (absolute coordinates;
--                                 name = block id like "minecraft:stone", or "air"). Returns stored, dropped.
--   map.get(x, y, z)              block name, or nil if never seen
--   map.surface(x, z)             y, name of the highest known non-air block in that column (nil if none)
--   map.cell(x, z, y)             char, name, y for one map cell (y = nil: surface); chars are in map.LEGEND
--   map.view(x1, z1, x2, z2, y, marks, zoom)
--                                 rows (list of strings, north = first row, west = first column), legend text,
--                                 area {x1, z1, x2, z2, y, zoom, w, h, scale, ylo, yhi}; max map.MAXW x map.MAXH
--                                 characters (cut from x1/z1); y = nil: surface view;
--                                 marks = { {x=, z=, ch="D"}, ... } drawn on top; zoom = blocks per char
--                                 (1, 2, 4, 8, 16; others -> nearest): each char shows the most important
--                                 block of its zoom x zoom columns (see M.grid), the legend says the scale
--   map.grid(x1, z1, x2, z2, y, zoom)  the cached cell grid behind view() (chars, names, protected cells)
--   map.zoom(z), map.scale(z)     normalized zoom; "1 char = 4x4 blocks"
--   map.rev                       goes up on every map or protected-area change
--   map.find(pattern, near, limit)
--                                 { {x, y, z, name, d}, ... } blocks whose name contains pattern (plain text,
--                                 any case), nearest to near = {x, y, z} first; limit default 20, max 100
--   map.box(x1, y1, z1, x2, y2, z2, limit)
--                                 { {x, y, z, name}, ... } known blocks in that box, solid first, then air
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
-- The cap follows the computer's disk size: about 60% of it for the map, between 120000 blocks (1 MB disk,
-- the CC: Tweaked default) and 400000 (find/info walk every block in memory, so more gets slow).
-- New blocks are also refused when the disk has less than 96 KB free.
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
do                                              -- cap from the disk size (servers can raise the 1 MB default)
  local ok, cap = pcall(fs.getCapacity, "/")
  if ok and type(cap) == "number" and cap > 0 then
    M.CAP = math.max(120000, math.min(400000, math.floor(cap * 0.6 / 3.5)))
  end
end

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
  M.rev = M.rev + 1
  saveProt()
  return #prot.boxes
end

function M.unprotect(i)
  if not prot.boxes[i] then return false end
  table.remove(prot.boxes, i)
  prot.rev = prot.rev + 1
  M.rev = M.rev + 1
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
  if stored > 0 then M.rev = M.rev + 1 end
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

---------------------------------------------------------------- views (any zoom)
-- zoom = blocks per character. Each character shows the most important thing among its zoom x zoom columns
-- (surface: the highest known block of each column; layer: the block at that y):
--   P protected > D drone > H home > = building > o ore > ^ lava > ~ water > T trees > # stone > : dirt
--   > , plants > . air > ? unknown        (so any known block beats unknown)
M.ZOOMS = { 1, 2, 4, 8, 16 }
local RANK = { ["?"] = 1, ["."] = 2, [","] = 3, [":"] = 4, ["#"] = 5, ["T"] = 6, ["~"] = 7, ["^"] = 8, ["o"] = 9,
               ["="] = 10, ["H"] = 11, ["D"] = 12, ["P"] = 13 }
M.RANK = RANK

-- nearest of 1, 2, 4, 8, 16 (ties go to the smaller one); anything that is not a number is 1
function M.zoom(z)
  z = tonumber(z)
  if not z or z ~= z then return 1 end
  local best = 1
  for _, v in ipairs(M.ZOOMS) do
    if math.abs(v - z) < math.abs(best - z) then best = v end
  end
  return best
end

function M.scale(zoom)
  zoom = M.zoom(zoom)
  return zoom == 1 and "1 char = 1 block" or ("1 char = %dx%d blocks"):format(zoom, zoom)
end

local function protOverlay(g)                   -- g.prot[i] = true where any column of cell i is protected
  local W, H, zoom, y = g.w, g.h, g.zoom, g.y
  for _, b in ipairs(prot.boxes) do
    if b.x2 >= g.x1 and b.x1 <= g.x2 and b.z2 >= g.z1 and b.z1 <= g.z2 and (y == nil or (y >= b.y1 and y <= b.y2)) then
      local c1 = math.floor((math.max(b.x1, g.x1) - g.x1) / zoom)
      local c2 = math.min(W - 1, math.floor((math.min(b.x2, g.x2) - g.x1) / zoom))
      local r1 = math.floor((math.max(b.z1, g.z1) - g.z1) / zoom)
      local r2 = math.min(H - 1, math.floor((math.min(b.z2, g.z2) - g.z1) / zoom))
      for r = r1, r2 do
        for c = c1, c2 do g.prot[r * W + c + 1] = true end
      end
    end
  end
end

-- the aggregated grid behind view(): { w, h (characters), x1, z1, x2, z2 (blocks), y, zoom,
--   ch = {[i] = char}, name = {[i] = block name}, by = {[i] = y of that block}, prot = {[i] = true},
--   ylo, yhi (surface y range of the known columns, surface view only) }, i = row * w + col + 1 (0-based row/col).
-- The area is cut to MAXW x MAXH characters. Exact (every known column counts, no sampling): it walks the
-- known columns of each chunk once, so the cost is bounded by the known columns in the area (at most 614400
-- at zoom 16, in practice the blocks the drones have seen) and never reads a chunk file it has no index entry for.
-- The last grid is cached until the map or the protected areas change (M.rev / protect rev): don't modify it.
M.rev = 0
local lastGrid, lastKey
function M.grid(x1, z1, x2, z2, y, zoom)
  zoom = M.zoom(zoom)
  x1, z1 = math.floor(tonumber(x1) or 0), math.floor(tonumber(z1) or 0)
  x2, z2 = math.floor(tonumber(x2) or x1), math.floor(tonumber(z2) or z1)
  if x2 < x1 then x1, x2 = x2, x1 end
  if z2 < z1 then z1, z2 = z2, z1 end
  x2, z2 = math.min(x2, x1 + M.MAXW * zoom - 1), math.min(z2, z1 + M.MAXH * zoom - 1)
  y = tonumber(y) and math.floor(tonumber(y)) or nil
  local key = table.concat({ x1, z1, x2, z2, y or "s", zoom, M.rev, prot.rev, #prot.boxes }, ",")
  if lastKey == key then return lastGrid end
  local W, H = math.floor((x2 - x1) / zoom) + 1, math.floor((z2 - z1) / zoom) + 1
  local rank, names, ys = {}, {}, {}
  for i = 1, W * H do rank[i] = 0 end
  local ylo, yhi
  local cellX, cellZ = {}, {}
  for cx = math.floor(x1 / 16), math.floor(x2 / 16) do
    for cz = math.floor(z1 / 16), math.floor(z2 / 16) do
      local key2 = keyOf(cx, cz)
      local c = chunks[key2] or (index[key2] and chunk(cx, cz, false))
      if c and next(c.known) then
        local bx, bz = cx * 16, cz * 16
        for l = 0, 15 do                        -- local column -> cell offset (false: outside the area)
          local x, z = bx + l, bz + l
          cellX[l] = x >= x1 and x <= x2 and math.floor((x - x1) / zoom) + 1 or false
          cellZ[l] = z >= z1 and z <= z2 and math.floor((z - z1) / zoom) * W or false
        end
        local b, top = c.b, c.top
        for col in pairs(c.known) do
          local lx = col % 16
          local lz = (col - lx) / 16
          local ox, oz = cellX[lx], cellZ[lz]
          if ox and oz then
            local i = oz + ox
            local best = rank[i]
            if best < 10 then                   -- a building already wins over any block
              local name, ny
              if y then
                ny = y
                name = b[((y - YMIN) * 16 + lz) * 16 + lx]
              else
                ny = top[col]
                if ny then
                  name = b[((ny - YMIN) * 16 + lz) * 16 + lx]
                  if not ylo or ny < ylo then ylo = ny end
                  if not yhi or ny > yhi then yhi = ny end
                else
                  name = "air"
                end
              end
              local r = name and RANK[cats[name] or M.category(name)] or 1
              if r > best then rank[i], names[i], ys[i] = r, name, ny end
            elseif not y then
              local ny = top[col]
              if ny then
                if not ylo or ny < ylo then ylo = ny end
                if not yhi or ny > yhi then yhi = ny end
              end
            end
          end
        end
      end
    end
  end
  local CH = {}
  for ch, r in pairs(RANK) do CH[r] = ch end
  CH[0] = "?"
  local chars = {}
  for i = 1, W * H do chars[i] = CH[rank[i]] end
  local g = { w = W, h = H, x1 = x1, z1 = z1, x2 = x2, z2 = z2, y = y, zoom = zoom, ch = chars, name = names,
              by = ys, prot = {}, ylo = ylo, yhi = yhi }
  if #prot.boxes > 0 then protOverlay(g) end
  lastGrid, lastKey = g, key
  return g
end

-- rows (north first, west first), legend, area {x1, z1, x2, z2 (blocks), y, zoom, w, h (characters), scale, ylo, yhi}
-- zoom 1: marks are drawn on top of everything (as always); zoom > 1: by priority (protected beats a drone)
function M.view(x1, z1, x2, z2, y, marks, zoom)
  local g = M.grid(x1, z1, x2, z2, y, zoom)
  zoom = g.zoom
  local W = g.w
  local cell = {}
  for i = 1, W * g.h do
    local ch = g.ch[i]
    if g.prot[i] then ch = "P" end
    cell[i] = ch
  end
  for _, m in ipairs(type(marks) == "table" and marks or {}) do
    local mx, mz = tonumber(m.x), tonumber(m.z)
    if mx and mz then
      mx, mz = math.floor(mx), math.floor(mz)
      if mx >= g.x1 and mx <= g.x2 and mz >= g.z1 and mz <= g.z2 then
        local i = math.floor((mz - g.z1) / zoom) * W + math.floor((mx - g.x1) / zoom) + 1
        local ch = tostring(m.ch or "D"):sub(1, 1)
        if zoom == 1 or (RANK[ch] or 11) > (RANK[cell[i]] or 0) then cell[i] = ch end
      end
    end
  end
  local rows = {}
  for r = 0, g.h - 1 do rows[r + 1] = table.concat(cell, "", r * W + 1, r * W + W) end
  local legend = M.legend()
  if zoom > 1 then
    legend = legend .. "; " .. M.scale(zoom) .. ", each char shows the most important block in it"
      .. " (P > D > H > = > o > ^ > ~ > T > # > : > , > . > ?)"
  end
  return rows, legend, { x1 = g.x1, z1 = g.z1, x2 = g.x2, z2 = g.z2, y = g.y, zoom = zoom, w = W, h = g.h,
                         scale = M.scale(zoom), ylo = g.ylo, yhi = g.yhi }
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

-- known blocks inside a box (inclusive): solid ones first, then air, at most limit (default 5000)
function M.box(x1, y1, z1, x2, y2, z2, limit)
  limit = math.floor(tonumber(limit) or 5000)
  x1, x2 = math.min(x1, x2), math.max(x1, x2)
  y1, y2 = math.max(YMIN, math.min(y1, y2)), math.min(YMAX, math.max(y1, y2))
  z1, z2 = math.min(z1, z2), math.max(z1, z2)
  local solid, air = {}, {}
  for cx = math.floor(x1 / 16), math.floor(x2 / 16) do
    for cz = math.floor(z1 / 16), math.floor(z2 / 16) do
      local c = chunk(cx, cz, false)
      if c then
        for p, name in pairs(c.b) do
          local lx, y, lz = unpackPos(p)
          local x, z = cx * 16 + lx, cz * 16 + lz
          if x >= x1 and x <= x2 and y >= y1 and y <= y2 and z >= z1 and z <= z2 then
            local l = name == "air" and air or solid
            if #l < limit then l[#l + 1] = { x, y, z, name } end
          end
        end
      end
    end
  end
  for _, o in ipairs(air) do
    if #solid >= limit then break end
    solid[#solid + 1] = o
  end
  return solid
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
