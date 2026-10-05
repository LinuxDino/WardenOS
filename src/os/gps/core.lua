-- Warden GPS host logic. Answers standard CC GPS pings exactly like `gps host` (so plain gps.locate() works), and
-- announces itself to WardenOS on rednet (protocol "wardenos") so the GPS app can list and check the hosts.
-- Used by /os/gps/host.lua (dedicated host) and by the WardenOS desktop (background host, /os/lib/world.lua).
--
--   C.read([path])     -> cfg, or nil + reason   (/os/gps/host.cfg: { x, y, z, mode = "dedicated" | "desktop" })
--   C.write(cfg[, path])
--   C.new(cfg)         -> host h:
--     h.open()           open the GPS channel (and rednet) on every wireless/ender modem, returns how many
--     h.event(ev)        handle one event (ev = table.pack(os.pullEvent())); true when the status changed
--     h.status()         { t = "gps_host", x, y, z, served, uptime, version, label, modems, mode }
--     h.announce([id])   broadcast the status (or send it to one computer)
local C = {}
C.FILE = "/os/gps/host.cfg"
C.CHANNEL = (type(gps) == "table" and gps.CHANNEL_GPS) or 65534
C.PROTO = "wardenos"
C.ANNOUNCE_EVERY = 30                           -- seconds between announcements

function C.read(path)
  path = path or C.FILE
  if not fs.exists(path) then return nil, "not set up" end
  local f = fs.open(path, "r")
  if not f then return nil, "cannot read " .. path end
  local d = textutils.unserialize(f.readAll() or "")
  f.close()
  if type(d) ~= "table" then return nil, path .. " is broken" end
  local x, y, z = tonumber(d.x), tonumber(d.y), tonumber(d.z)
  if not (x and y and z) then return nil, path .. " has no x y z" end
  d.x, d.y, d.z = math.floor(x), math.floor(y), math.floor(z)
  d.mode = d.mode == "desktop" and "desktop" or "dedicated"
  return d
end

function C.write(cfg, path)
  path = path or C.FILE
  local dir = fs.getDir(path)
  if dir ~= "" then fs.makeDir(dir) end
  local f = assert(fs.open(path, "w"))
  f.write(textutils.serialize({ x = cfg.x, y = cfg.y, z = cfg.z, mode = cfg.mode }))
  f.close()
end

local function osVersion()
  local ok, c = pcall(dofile, "/os/config.lua")
  return ok and type(c) == "table" and tostring(c.version) or "?"
end

local function wireless(n)
  if peripheral.getType(n) ~= "modem" then return false end
  local ok, w = pcall(peripheral.call, n, "isWireless")
  return ok and w == true
end

function C.new(cfg)
  local h = { x = cfg.x, y = cfg.y, z = cfg.z, mode = cfg.mode, served = 0, started = os.clock(),
              modems = {}, version = osVersion() }

  function h.open()
    h.modems = {}
    for _, n in ipairs(peripheral.getNames()) do
      if wireless(n) then
        local ok = pcall(peripheral.call, n, "open", C.CHANNEL)
        if ok then h.modems[#h.modems + 1] = n end
        if not rednet.isOpen(n) then pcall(rednet.open, n) end
      end
    end
    return #h.modems
  end

  function h.status()
    return { t = "gps_host", x = h.x, y = h.y, z = h.z, served = h.served, mode = h.mode,
             uptime = math.floor(os.clock() - h.started), version = h.version, label = os.getComputerLabel(),
             modems = #h.modems }
  end

  function h.announce(to)
    if not rednet.isOpen() then return false end
    h.lastAnnounce = os.clock()
    if to then return rednet.send(to, h.status(), C.PROTO) end
    rednet.broadcast(h.status(), C.PROTO)
    return true
  end

  function h.event(ev)
    local e, changed = ev[1], false
    if e == "modem_message" then
      local side, ch, reply, msg, dist = ev[2], ev[3], ev[4], ev[5], ev[6]
      -- like rom/programs/gps.lua: only wireless messages (they carry a distance)
      if ch == C.CHANNEL and msg == "PING" and dist then
        pcall(peripheral.call, side, "transmit", reply, C.CHANNEL, { h.x, h.y, h.z })
        h.served = h.served + 1
        h.last = { dist = dist, at = os.clock() }
        changed = true
      end
    elseif e == "rednet_message" and ev[4] == C.PROTO and type(ev[3]) == "table" and ev[3].t == "gps_who" then
      h.announce(ev[2])
    elseif e == "peripheral" or e == "peripheral_detach" then
      h.open()
      changed = true
    end
    if not h.lastAnnounce or os.clock() - h.lastAnnounce >= C.ANNOUNCE_EVERY then h.announce() end
    return changed
  end

  return h
end

return C
