-- WardenOS world sync, run by the kernel (every call is pcall-protected there):
--   W.event(ev)    every event: caches turtle status messages, stores {t="map"} observations in the world map,
--                  sends the protected areas to drones of this computer that have an old copy, flushes the map
--   W.flush()      write the map now (the kernel calls it on exit)
--   W.drones       [id] = latest turtle status + seen (os.clock()); shared as WardenOS.drones with the apps,
--                  the pocket server and Claude
local PROTO = "wardenos"
local FLUSH_EVERY = 5                           -- seconds between map writes
local PUSH_EVERY = 10                           -- seconds between protect pushes to one drone

local W = { drones = {} }
local me = os.getComputerID()
local map
local okm, m = pcall(dofile, "/os/lib/map.lua")
if okm and type(m) == "table" then map = m end
W.map = map

local seq = 3000000 + math.random(0, 99999) * 10   -- far from the Drones app, Claude and the pocket relay
local lastPush = {}                             -- [drone id] = os.clock() of the last protect push
local lastFlush = os.clock()

local function pushProtect(id)
  if not map or not rednet.isOpen() then return end
  local p = map.protected()
  local boxes = {}
  for i, b in ipairs(p.boxes) do
    boxes[i] = { name = b.name, x1 = b.x1, y1 = b.y1, z1 = b.z1, x2 = b.x2, y2 = b.y2, z2 = b.z2 }
  end
  seq = seq + 1
  rednet.send(id, { t = "cmd", to = id, seq = seq, cmd = "protect", arg = { rev = p.rev, boxes = boxes } }, PROTO)
end

local function onStatus(from, msg)
  local d = {}
  for k, v in pairs(msg) do d[k] = v end
  d.seen = os.clock()
  W.drones[from] = d
  if map and msg.owner == me and type(msg.protectRev) == "number" and msg.protectRev ~= map.protected().rev then
    local last = lastPush[from]
    if not last or os.clock() - last >= PUSH_EVERY then
      lastPush[from] = os.clock()
      pushProtect(from)
    end
  end
end

function W.flush()
  lastFlush = os.clock()
  if map then map.flush() end
end

function W.event(ev)
  if ev[1] == "rednet_message" and ev[4] == PROTO and type(ev[3]) == "table" then
    local from, msg = ev[2], ev[3]
    if msg.t == "status" and msg.kind == "turtle" and from ~= me then
      onStatus(from, msg)
    elseif msg.t == "map" and map and type(msg.obs) == "table" then
      map.add(msg.obs)
    end
  end
  if os.clock() - lastFlush >= FLUSH_EVERY then W.flush() end
end

-- for tests
W._lastPush = lastPush

return W
