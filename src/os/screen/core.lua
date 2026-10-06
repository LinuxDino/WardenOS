-- Warden Screen: shared logic of the slim screen client (/os/screen/client.lua) and the installer's setup.
-- A Warden Screen is an extra computer + monitor that shows ONE page of the main WardenOS computer (the "brain")
-- live. It asks the brain over rednet (protocol "wardenos"); the brain answers in /os/lib/screenserver.lua.
--
--   C.PAGES                     { { id, name, about }, ... }  drones | map | me | claude | gps
--   C.page(id)                  that page entry (or nil); C.pageIndex(id) its number
--   C.read([path])              cfg, or nil + reason  (/os/screen/screen.cfg)
--       cfg = { page, monitor = side name | "term" | nil (auto: the biggest monitor, else this computer),
--               brain = computer ID | nil (auto: the first WardenOS computer that answers),
--               interval = seconds between requests (1-30, default 2), touch = true (touch cycles pages),
--               center = { x, z } | nil (map page: center there instead of on the drones), zoom = n | nil }
--   C.write(cfg[, path])
--   C.monitors()                { { name, w, h, colour, area }, ... } biggest first (size at text scale 0.5)
--   C.openModems()              open rednet on every modem (wireless first), returns how many
--   C.discover(timeout)         { { id, label, version, drones }, ... } WardenOS computers that answered
--
-- Messages: screen -> brain { t = "screen_who" } | { t = "screen_req", page, w, h, seq, center, zoom }
--           brain -> screen { t = "screen_here", id, label, version, drones } |
--                           { t = "screen_data", page, seq, brain = { id, label, version }, ...page data }
local C = {}
C.FILE = "/os/screen/screen.cfg"
C.PROTO = "wardenos"
C.PAGES = {
  { id = "drones", name = "Drones", about = "every drone live: task, progress, fuel, position" },
  { id = "map", name = "Map", about = "top-down map around the drones" },
  { id = "me", name = "Storage", about = "ME / RS storage: top items, energy, crafting" },
  { id = "claude", name = "Claude", about = "what Claude is doing, its tools and drones" },
  { id = "gps", name = "GPS", about = "the GPS hosts and the constellation grade" },
}

function C.page(id)
  for _, p in ipairs(C.PAGES) do if p.id == id then return p end end
end
function C.pageIndex(id)
  for i, p in ipairs(C.PAGES) do if p.id == id then return i end end
end

local function clampInterval(v)
  v = tonumber(v) or 2
  return math.max(1, math.min(30, v))
end

function C.read(path)
  path = path or C.FILE
  if not fs.exists(path) then return nil, "not set up" end
  local f = fs.open(path, "r")
  if not f then return nil, "cannot read " .. path end
  local d = textutils.unserialize(f.readAll() or "")
  f.close()
  if type(d) ~= "table" then return nil, path .. " is broken" end
  if not C.page(d.page) then d.page = "drones" end
  if type(d.monitor) ~= "string" or d.monitor == "" or d.monitor == "auto" then d.monitor = nil end
  d.brain = tonumber(d.brain)
  d.interval = clampInterval(d.interval)
  d.touch = d.touch ~= false
  if type(d.center) == "table" and tonumber(d.center.x) and tonumber(d.center.z) then
    d.center = { x = math.floor(tonumber(d.center.x)), z = math.floor(tonumber(d.center.z)) }
  else
    d.center = nil
  end
  d.zoom = tonumber(d.zoom)
  return d
end

function C.write(cfg, path)
  path = path or C.FILE
  local dir = fs.getDir(path)
  if dir ~= "" then fs.makeDir(dir) end
  local f = assert(fs.open(path, "w"))
  f.write(textutils.serialize({ page = cfg.page, monitor = cfg.monitor, brain = cfg.brain,
                                interval = clampInterval(cfg.interval), touch = cfg.touch ~= false,
                                center = cfg.center, zoom = cfg.zoom }))
  f.close()
end

function C.monitors()
  local out = {}
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n) == "monitor" then
      local m = peripheral.wrap(n)
      if m then
        pcall(m.setTextScale, 0.5)
        local okS, w, h = pcall(m.getSize)
        local okC, col = pcall(m.isColour or m.isColor)
        if okS and w then
          out[#out + 1] = { name = n, w = w, h = h, area = w * h, colour = okC and col == true }
        end
      end
    end
  end
  table.sort(out, function(a, b)
    if a.area ~= b.area then return a.area > b.area end
    return a.name < b.name
  end)
  return out
end

function C.openModems()
  local n = 0
  local wired = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      local okW, w = pcall(peripheral.call, name, "isWireless")
      if okW and w then
        if not rednet.isOpen(name) then pcall(rednet.open, name) end
        if rednet.isOpen(name) then n = n + 1 end
      else
        wired[#wired + 1] = name
      end
    end
  end
  for _, name in ipairs(wired) do                -- wired modems work too (same network as the brain)
    if not rednet.isOpen(name) then pcall(rednet.open, name) end
    if rednet.isOpen(name) then n = n + 1 end
  end
  return n
end

-- broadcast screen_who and collect the answers until the timeout (seconds); uses os.pullEvent
function C.discover(timeout)
  local found, byId = {}, {}
  if not rednet.isOpen() then return found end
  local timer = os.startTimer(timeout or 2)
  rednet.broadcast({ t = "screen_who" }, C.PROTO)
  while true do
    local ev = table.pack(os.pullEvent())
    if ev[1] == "timer" and ev[2] == timer then break end
    if ev[1] == "rednet_message" and ev[4] == C.PROTO and type(ev[3]) == "table" and ev[3].t == "screen_here" then
      local id, m = ev[2], ev[3]
      if not byId[id] and id ~= os.getComputerID() then
        byId[id] = true
        found[#found + 1] = { id = id, label = m.label ~= nil and tostring(m.label) or nil,
                              version = m.version ~= nil and tostring(m.version) or "?", drones = tonumber(m.drones) }
      end
    end
  end
  table.sort(found, function(a, b) return a.id < b.id end)
  return found
end

return C
