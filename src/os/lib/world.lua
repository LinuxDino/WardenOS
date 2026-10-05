-- WardenOS world sync, run by the kernel (every call is pcall-protected there):
--   W.event(ev)    every event: caches turtle status messages, stores {t="map"} observations in the world map,
--                  sends the protected areas to drones of this computer that have an old copy, flushes the map
--   W.flush()      write the map and MineView's history now (the kernel calls it on exit)
--   W.mineview     the MineView sampler (/os/lib/mineview.lua), shared as WardenOS.mineview: it gets every event
--                  and samples the storage in its own coroutine (never blocks this handler)
--   W.drones       [id] = latest turtle status + seen (os.clock()); shared as WardenOS.drones with the apps,
--                  the pocket server and Claude
--   W.gpsHosts     [id] = latest Warden GPS host announcement + seen (os.clock()); shared as WardenOS.gpsHosts
--   W.gpsHost      the background Warden GPS host (/os/gps/core.lua) when /os/gps/host.cfg says mode = "desktop";
--                  shared as WardenOS.gpsHost. It answers GPS pings while the desktop runs
local PROTO = "wardenos"
local FLUSH_EVERY = 5                           -- seconds between map writes
local PUSH_EVERY = 10                           -- seconds between protect pushes to one drone

local W = { drones = {}, gpsHosts = {} }
local me = os.getComputerID()
local map
local okm, m = pcall(dofile, "/os/lib/map.lua")
if okm and type(m) == "table" then map = m end
W.map = map
local log                                       -- debug log (/os/lib/log.lua), optional
do
  local okl, l = pcall(dofile, "/os/lib/log.lua")
  if okl and type(l) == "table" then log = l end
end
W.log = log
local mineview                                  -- MineView sampler (optional, never breaks the world sync)
do
  local okv, mv = pcall(dofile, "/os/lib/mineview.lua")
  if okv and type(mv) == "table" and type(mv.new) == "function" then
    local oki, inst = pcall(mv.new, {})
    if oki and type(inst) == "table" then
      mineview = inst
      local G = rawget(_G, "WardenOS")
      if type(G) == "table" then G.mineview = inst end
    end
  end
end
W.mineview = mineview
local gpsHost                                   -- background Warden GPS host (optional)
do
  local okc, core = pcall(dofile, "/os/gps/core.lua")
  local cfg = okc and type(core) == "table" and core.read()
  if cfg and cfg.mode == "desktop" then
    local okn, h = pcall(core.new, cfg)
    if okn and type(h) == "table" then
      gpsHost = h
      pcall(h.open)
    end
  end
  local G = rawget(_G, "WardenOS")
  if type(G) == "table" then G.gpsHosts = W.gpsHosts G.gpsHost = gpsHost end
end
W.gpsHost = gpsHost

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

local function flushMap()
  lastFlush = os.clock()
  if map then map.flush() end
end

function W.flush()
  flushMap()
  if mineview then pcall(mineview.flush, true) end
end

function W.event(ev)
  if log then
    log.add("event", ev[1])
    if ev[1] == "rednet_message" then
      local msg = ev[3]
      local drone = W.drones[ev[2]] ~= nil or (type(msg) == "table" and msg.kind == "turtle")
      log.rednet(ev, { drone = drone or nil })
    end
  end
  if ev[1] == "rednet_message" and ev[4] == PROTO and type(ev[3]) == "table" then
    local from, msg = ev[2], ev[3]
    if msg.t == "status" and msg.kind == "turtle" and from ~= me then
      onStatus(from, msg)
    elseif msg.t == "map" and map and type(msg.obs) == "table" then
      map.add(msg.obs)
    elseif msg.t == "gps_host" and tonumber(msg.x) and tonumber(msg.y) and tonumber(msg.z) then
      local d = {}
      for k, v in pairs(msg) do d[k] = v end
      d.seen = os.clock()
      W.gpsHosts[from] = d
    end
  end
  if gpsHost then pcall(gpsHost.event, ev) end
  if mineview then pcall(mineview.event, ev) end
  if os.clock() - lastFlush >= FLUSH_EVERY then flushMap() end
end

-- for tests
W._lastPush = lastPush

return W
