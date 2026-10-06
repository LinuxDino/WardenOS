-- Warden Screen server: the brain side of the slim screen clients (/os/screen/client.lua). Created by
-- /os/lib/world.lua (the kernel's world hook), which calls srv.event(ev) with every event, pcall-protected.
-- Nothing here blocks: ME / RS bridge calls (main-thread peripheral calls that yield) run in a coroutine owned by
-- this module and resumed with every event, like the MineView sampler.
--
--   local SS = dofile("/os/lib/screenserver.lua")
--   local srv = SS.new({ drones = cache, gpsHosts = cache, map = map, log = log })
--   srv.event(ev)            handles screen_who / screen_req on rednet "wardenos", resumes the ME worker
--   srv.build(page, w, h, req)  the data of one page (also used by the tests)
--   srv.screens              [id] = { page, w, h, seen = os.clock(), served } screens that asked recently
--
-- Pages (answer = { t = "screen_data", page, seq, brain = { id, label, version }, ... }):
--   drones  drones = { { id, label, online, ago, fuel (number | "unlimited"), fuelLimit, pos = {x, y, z}, gps, state, task, by,
--           phase, step, total, taskTime, last = { name, ok, info, by } }, ... }, count
--   map     rows (north first), legend = { {ch, name}, ... }, area = { x1, z1, x2, z2, zoom, scale }, marks,
--           note
--   me      bridge = { name, kind, connected } | nil, error, energy, storage, items = { {display, count} },
--           types, total, cpus, tasks, age (seconds since the sample), reading
--   claude  busy, status, drones = { { id, text, phase, step, total } }, recent = { { text, ago } },
--           calls, errors, last = { ago, ms, model, input, output, error }
--   gps     hosts = { { id, label, x, y, z, online, ago, served, self } }, grade, score, n, online, advice
local PROTO = "wardenos"
local ONLINE = 10                               -- seconds: a drone status newer than this is online
local GPS_OFFLINE = 120                         -- seconds: a GPS host not heard for this long is offline
local MIN_GAP = 0.8                             -- seconds between two answers to one screen
local CACHE = 1                                 -- seconds a built page is reused (several screens, same page)
local FORGET = 120                              -- seconds: a screen that stopped asking is dropped from the list
local ME_EVERY = 10                             -- seconds between ME samples (only while a screen shows it)
local ME_WANTED = 30                            -- seconds after the last "me" request the sampling stops
local MAX_DRONES, MAX_ITEMS, MAX_HOSTS = 32, 40, 24

local SS = {}

local function cut(s, n)
  s = tostring(s or "")
  s = s:gsub("[^\32-\126]", "?")
  if #s > n then s = s:sub(1, n - 2) .. ".." end
  return s
end
SS.cut = cut

local function osVersion()
  local ok, c = pcall(dofile, "/os/config.lua")
  return ok and type(c) == "table" and tostring(c.version) or "?"
end

local function count(t)
  local n = 0
  for _ in pairs(type(t) == "table" and t or {}) do n = n + 1 end
  return n
end

function SS.new(opts)
  opts = opts or {}
  local srv = { screens = {} }
  local me = os.getComputerID()
  local version = osVersion()
  local cache = {}                              -- [key] = { at, data }
  local function drones()
    if type(opts.drones) == "table" then return opts.drones end
    local W = rawget(_G, "WardenOS")
    return type(W) == "table" and type(W.drones) == "table" and W.drones or {}
  end
  local function gpsHosts()
    if type(opts.gpsHosts) == "table" then return opts.gpsHosts end
    local W = rawget(_G, "WardenOS")
    return type(W) == "table" and type(W.gpsHosts) == "table" and W.gpsHosts or {}
  end

  ------------------------------------------------ drones
  local function dronePos(d)
    if d.calibrated and type(d.abs) == "table" and tonumber(d.abs.x) then
      return { math.floor(d.abs.x), math.floor(tonumber(d.abs.y) or 0), math.floor(tonumber(d.abs.z) or 0) }, true
    end
    if type(d.pos) == "table" and tonumber(d.pos[1]) then
      return { math.floor(d.pos[1]), math.floor(tonumber(d.pos[2]) or 0), math.floor(tonumber(d.pos[3]) or 0) }, true
    end
    return nil, false
  end

  local function pageDrones()
    local now, list = os.clock(), {}
    for id, d in pairs(drones()) do
      if type(d) == "table" and type(id) == "number" then
        local ago = now - (tonumber(d.seen) or -1e9)
        local p = type(d.progress) == "table" and d.progress or {}
        local by = type(d.by) == "table" and d.by.who or nil
        local e = { id = id, label = d.label and cut(d.label, 20) or nil, online = ago < ONLINE,
                    ago = math.max(0, math.floor(ago)), fuel = tonumber(d.fuel) or (d.fuel == "unlimited" and "unlimited" or nil),
                    fuelLimit = tonumber(d.fuelLimit),
                    state = d.state and cut(d.state, 16) or nil, task = d.task and cut(d.task, 24) or nil,
                    by = by and cut(by, 10) or nil, phase = p.phase and cut(p.phase, 12) or nil,
                    step = tonumber(p.step), total = tonumber(p.total), taskTime = tonumber(d.taskTime) }
        e.pos = dronePos(d)
        if type(d.lastTask) == "table" then
          local lt = d.lastTask
          e.last = { name = cut(lt.name, 24), ok = lt.ok and true or false, info = lt.info and cut(lt.info, 80) or nil,
                     by = type(lt.by) == "table" and lt.by.who and cut(lt.by.who, 10) or nil }
        end
        list[#list + 1] = e
      end
    end
    table.sort(list, function(a, b)
      if a.online ~= b.online then return a.online end
      return a.id < b.id
    end)
    local total = #list
    while #list > MAX_DRONES do list[#list] = nil end
    return { drones = list, count = total }
  end

  ------------------------------------------------ map
  local function pageMap(w, h, req)
    local map = opts.map
    if type(map) ~= "table" or type(map.view) ~= "function" then return { error = "The world map is not available." } end
    w = math.max(4, math.min(map.MAXW or 60, math.floor(tonumber(w) or 30)))
    h = math.max(3, math.min(map.MAXH or 40, math.floor(tonumber(h) or 12)))
    local marks, xs, zs = {}, {}, {}
    for id, d in pairs(drones()) do
      if type(d) == "table" then
        local p = d.calibrated and type(d.abs) == "table" and tonumber(d.abs.x) and d.abs or nil
        if p then
          marks[#marks + 1] = { x = math.floor(p.x), z = math.floor(tonumber(p.z) or 0), ch = "D", id = id }
          xs[#xs + 1], zs[#zs + 1] = math.floor(p.x), math.floor(tonumber(p.z) or 0)
        end
        local o = type(d.origin) == "table" and tonumber(d.origin.x) and d.origin or nil
        if o then marks[#marks + 1] = { x = math.floor(o.x), z = math.floor(tonumber(o.z) or 0), ch = "H", id = id } end
      end
    end
    -- center: asked for, else the middle of the drones, else the middle of what is known
    local cx, cz, span, note
    local c = type(req) == "table" and type(req.center) == "table" and req.center or nil
    if c and tonumber(c.x) and tonumber(c.z) then
      cx, cz, span = math.floor(c.x), math.floor(c.z), 0
    elseif #xs > 0 then
      local x1, x2, z1, z2 = math.huge, -math.huge, math.huge, -math.huge
      for i = 1, #xs do
        x1, x2 = math.min(x1, xs[i]), math.max(x2, xs[i])
        z1, z2 = math.min(z1, zs[i]), math.max(z2, zs[i])
      end
      cx, cz = math.floor((x1 + x2) / 2), math.floor((z1 + z2) / 2)
      span = math.max((x2 - x1 + 4) / w, (z2 - z1 + 4) / h)
    else
      local okI, info = pcall(map.info)
      local b = okI and type(info) == "table" and info.bounds or nil
      if b then
        cx, cz = math.floor((b.x1 + b.x2) / 2), math.floor((b.z1 + b.z2) / 2)
        span = math.max((b.x2 - b.x1 + 1) / w, (b.z2 - b.z1 + 1) / h)
      else
        cx, cz, span = 0, 0, 0
      end
      note = "no calibrated drone"
    end
    local zoom = tonumber(type(req) == "table" and req.zoom)
    if not zoom then                               -- the smallest zoom that shows every drone (at most 16)
      zoom = 16
      for _, z in ipairs(map.ZOOMS or { 1, 2, 4, 8, 16 }) do
        if z >= span then zoom = z break end
      end
    end
    zoom = map.zoom and map.zoom(zoom) or 1
    local x1 = cx - math.floor(w / 2) * zoom
    local z1 = cz - math.floor(h / 2) * zoom
    local rows, _, area = map.view(x1, z1, x1 + w * zoom - 1, z1 + h * zoom - 1, nil, marks, zoom)
    local out = {}
    for i, r in ipairs(rows) do out[i] = r end
    local seen = {}
    for _, r in ipairs(out) do for ch in r:gmatch(".") do seen[ch] = true end end
    local legend = {}
    for _, l in ipairs(map.LEGEND or {}) do
      if seen[l[1]] then legend[#legend + 1] = { l[1], l[2] } end
    end
    local ms = {}
    for _, m in ipairs(marks) do
      if m.ch == "D" and #ms < MAX_DRONES then ms[#ms + 1] = { id = m.id, x = m.x, z = m.z } end
    end
    return { rows = out, legend = legend, marks = ms, note = note,
             area = { x1 = area.x1, z1 = area.z1, x2 = area.x2, z2 = area.z2, zoom = area.zoom, scale = area.scale,
                      cx = cx, cz = cz } }
  end

  ------------------------------------------------ me (sampled in a coroutine)
  local ME, meErr
  local meSnap, meAt                             -- last sample + os.clock() when it finished
  local meWanted = -1e9                          -- os.clock() of the last "me" request
  local worker, wfilter, wstart
  local lastStart = -1e9

  local function sampleMe()
    if not ME then
      local ok, m = pcall(dofile, "/os/lib/me.lua")
      if not ok or type(m) ~= "table" then return { error = "me.lua missing: " .. tostring(m) } end
      ME = m
    end
    local b, err = ME.open()
    if not b then return { error = err } end
    local s = { bridge = { name = b.name, kind = b.kind } }
    s.bridge.connected = b:connected()
    s.energy = b:energy()
    s.storage = b:storage()
    s.cpus = b:cpus()
    s.tasks = b:tasks()
    local items, ierr = b:items()
    if items then
      local total = 0
      for _, it in ipairs(items) do total = total + (tonumber(it.count) or 0) end
      table.sort(items, function(x, y)
        if x.count ~= y.count then return x.count > y.count end
        return tostring(x.name) < tostring(y.name)
      end)
      local top = {}
      for i = 1, math.min(MAX_ITEMS, #items) do
        top[i] = { display = cut(items[i].display or items[i].name, 32), count = items[i].count }
      end
      s.items, s.types, s.total = top, #items, total
    else
      s.itemsError = ierr and cut(ierr, 80) or "items not readable"
    end
    -- keep the CPU / job lists small
    if type(s.cpus) == "table" then
      local c = {}
      for i, v in ipairs(s.cpus) do
        if i > 16 then break end
        c[i] = { name = cut(v.name, 16), busy = v.busy, item = v.item and cut(v.item, 32) or nil, amount = v.amount,
                 progress = v.progress, total = v.total }
      end
      s.cpus = c
    end
    if type(s.tasks) == "table" then
      local c = {}
      for i, v in ipairs(s.tasks) do
        if i > 12 then break end
        c[i] = { item = v.item and cut(v.item, 32) or nil, amount = v.amount, progress = v.progress, total = v.total,
                 done = v.done }
      end
      s.tasks = c
    end
    return s
  end

  local function finish(ok, res)
    worker, wfilter = nil, nil
    if ok and type(res) == "table" then meSnap, meErr = res, nil
    else meSnap, meErr = nil, tostring(res) end
    meAt = os.clock()
  end

  local function stepWorker(ev)
    local now = os.clock()
    if worker then
      if now - wstart > 60 then finish(false, "the bridge did not answer") return end
      if wfilter == nil or wfilter == ev[1] or ev[1] == "terminate" then
        local okR, res = coroutine.resume(worker, table.unpack(ev, 1, ev.n or #ev))
        if not okR then finish(false, res)
        elseif coroutine.status(worker) == "dead" then finish(true, res)
        else wfilter = res end
      end
      return
    end
    if now - meWanted < ME_WANTED and now - lastStart >= ME_EVERY then
      lastStart, wstart = now, now
      worker, wfilter = coroutine.create(sampleMe), nil
      local okR, res = coroutine.resume(worker)
      if not okR then finish(false, res)
      elseif coroutine.status(worker) == "dead" then finish(true, res)
      else wfilter = res end
    end
  end
  srv._stepWorker = stepWorker

  local function pageMe()
    meWanted = os.clock()
    if not meSnap and not meErr then
      if not worker then stepWorker({ n = 0 }) end
      if not meSnap and not meErr then return { reading = true } end
    end
    if not meSnap then return { error = cut(meErr, 160) } end
    local d = {}
    for k, v in pairs(meSnap) do d[k] = v end
    d.error = meSnap.error and cut(meSnap.error, 160) or nil
    d.age = math.max(0, math.floor(os.clock() - (meAt or os.clock())))
    return d
  end

  ------------------------------------------------ claude
  local function pageClaude()
    local W = rawget(_G, "WardenOS")
    local A = type(W) == "table" and type(W.claude) == "table" and W.claude or {}
    local now = os.clock()
    local d = { busy = A.busy == true, status = A.status and cut(A.status, 60) or "" }
    -- the drones Claude is using: its own command entries + drones running a task Claude started
    local list, seenIds = {}, {}
    local cacheD = drones()
    local E = type(A.drones) == "table" and A.drones or {}
    local ids = {}
    for id in pairs(E) do if type(id) == "number" then ids[#ids + 1] = id seenIds[id] = true end end
    for id, dr in pairs(cacheD) do
      if type(id) == "number" and not seenIds[id] and type(dr) == "table" and type(dr.by) == "table"
         and dr.by.who == "claude" and now - (tonumber(dr.seen) or -1e9) < ONLINE then
        ids[#ids + 1] = id
      end
    end
    table.sort(ids)
    for _, id in ipairs(ids) do
      if #list >= 8 then break end
      local e, dr = E[id], cacheD[id]
      local running = type(dr) == "table" and type(dr.by) == "table" and dr.by.who == "claude"
      local p = running and type(dr.progress) == "table" and dr.progress or {}
      local action = type(e) == "table" and e.action or (type(dr) == "table" and dr.task and ("task " .. tostring(dr.task))) or "?"
      list[#list + 1] = { id = id, label = type(dr) == "table" and dr.label and cut(dr.label, 16) or nil,
                          text = cut(action, 40), phase = p.phase and cut(p.phase, 12) or nil, step = tonumber(p.step),
                          total = tonumber(p.total), running = running or nil,
                          pending = type(e) == "table" and e.pending or nil }
    end
    d.drones = list
    local recent = {}
    for i, r in ipairs(type(A.recent) == "table" and A.recent or {}) do
      if i > 8 then break end
      if type(r) == "table" then
        recent[#recent + 1] = { text = cut(r.text, 40), ago = math.max(0, math.floor(now - (tonumber(r.at) or now))) }
      end
    end
    d.recent = recent
    local log = opts.log
    if type(log) == "table" and type(log.list) == "function" then
      local calls = log.list("claude")
      local errs = 0
      for _, c in ipairs(calls) do if c.error then errs = errs + 1 end end
      d.calls = type(log.total) == "function" and log.total("claude") or #calls
      d.errors = errs
      local c = calls[1]
      if type(c) == "table" then
        d.last = { ago = math.max(0, math.floor(now - (tonumber(c.clock) or now))), ms = tonumber(c.ms),
                   model = c.model and cut((tostring(c.model):gsub("^claude%-", "")), 24) or nil,
                   input = tonumber(c.input), output = tonumber(c.output),
                   error = c.error and cut(c.error, 80) or nil }
      end
    end
    return d
  end

  ------------------------------------------------ gps
  local gpsx
  local function pageGps()
    local now, list, pts = os.clock(), {}, {}
    local all = {}
    for id, h in pairs(gpsHosts()) do all[id] = h end
    local W = rawget(_G, "WardenOS")
    local own = type(W) == "table" and W.gpsHost or nil
    if type(own) == "table" and type(own.status) == "function" then
      local ok, s = pcall(own.status)
      if ok and type(s) == "table" then s.seen = now s.self = true all[me] = s end
    end
    for id, h in pairs(all) do
      local x, y, z
      if type(h) == "table" then x, y, z = tonumber(h.x), tonumber(h.y), tonumber(h.z) end
      if x and y and z then
        local ago = now - (tonumber(h.seen) or now)
        local e = { id = id, label = h.label and cut(h.label, 16) or nil, x = math.floor(x), y = math.floor(y),
                    z = math.floor(z), online = ago <= GPS_OFFLINE, ago = math.max(0, math.floor(ago)),
                    served = tonumber(h.served), self = h.self or nil, modems = tonumber(h.modems) }
        list[#list + 1] = e
        if e.online then pts[#pts + 1] = { x = e.x, y = e.y, z = e.z } end
      end
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    local d = { n = #list, online = #pts }
    if not gpsx then
      local ok, g = pcall(dofile, "/os/lib/gpsx.lua")
      if ok and type(g) == "table" then gpsx = g end
    end
    if gpsx then
      local ok, a = pcall(gpsx.analyze, pts)
      if ok and type(a) == "table" then
        d.grade, d.score = a.grade, a.score
        local adv = {}
        for i, s in ipairs(a.advice or {}) do
          if i > 4 then break end
          adv[i] = cut(s, 200)
        end
        d.advice = adv
      end
    end
    while #list > MAX_HOSTS do list[#list] = nil end
    d.hosts = list
    return d
  end

  ------------------------------------------------ requests
  local BUILD = { drones = pageDrones, map = pageMap, me = pageMe, claude = pageClaude, gps = pageGps }

  function srv.build(page, w, h, req)
    local f = BUILD[page]
    if not f then return { error = "unknown page " .. tostring(page) } end
    local key = table.concat({ tostring(page), tostring(w), tostring(h),
      type(req) == "table" and type(req.center) == "table" and (tostring(req.center.x) .. "," .. tostring(req.center.z)) or "",
      type(req) == "table" and tostring(req.zoom) or "" }, "|")
    local c = cache[key]
    if c and os.clock() - c.at < CACHE and page ~= "me" then return c.data end
    local ok, d = pcall(f, w, h, req)
    if not ok then d = { error = "page failed: " .. cut(d, 120) } end
    cache[key] = { at = os.clock(), data = d }
    for k, v in pairs(cache) do if os.clock() - v.at > 10 then cache[k] = nil end end
    return d
  end

  local function reply(id, msg)
    if rednet.isOpen() then rednet.send(id, msg, PROTO) end
  end

  local function onRequest(from, msg)
    local now = os.clock()
    local s = srv.screens[from]
    if s and now - (s.answered or -1e9) < MIN_GAP then return end   -- rate limit per screen
    local page = type(msg.page) == "string" and msg.page or "drones"
    local w = math.max(1, math.min(200, math.floor(tonumber(msg.w) or 30)))
    local h = math.max(1, math.min(100, math.floor(tonumber(msg.h) or 12)))
    s = s or { served = 0 }
    s.page, s.w, s.h, s.seen, s.answered = page, w, h, now, now
    s.served = s.served + 1
    s.label = msg.label ~= nil and cut(msg.label, 20) or s.label
    srv.screens[from] = s
    local data = srv.build(page, w, h, msg)
    local out = {}
    for k, v in pairs(data) do out[k] = v end
    out.t, out.page, out.seq = "screen_data", page, msg.seq
    out.brain = { id = me, label = os.getComputerLabel(), version = version }
    reply(from, out)
  end

  function srv.event(ev)
    if ev[1] == "rednet_message" and ev[4] == PROTO and type(ev[3]) == "table" then
      local from, msg = ev[2], ev[3]
      if msg.t == "screen_req" and from ~= me then
        onRequest(from, msg)
      elseif msg.t == "screen_who" and from ~= me then
        reply(from, { t = "screen_here", id = me, label = os.getComputerLabel(), version = version,
                      drones = count(drones()) })
      end
    end
    stepWorker(ev)
    local now = os.clock()
    for id, s in pairs(srv.screens) do
      if now - (s.seen or 0) > FORGET then srv.screens[id] = nil end
    end
  end

  return srv
end

return SS
