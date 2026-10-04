-- WardenOS debug log: small in-memory ring buffers, one shared instance per computer (_G.WardenLog),
-- shown by the System Monitor. Nothing is written to disk; memory stays bounded; no call ever throws.
--   log.add(kind, entry)   kind: "rednet" | "error" | "claude" | "info" (entry: table or string)
--                                "event" (entry: the event name) counts events
--   log.list(kind)         entries newest first (a copy); "event": { {name, count, rate}, ... } busiest first
--   log.count(name)        total, per-minute rate of an event name (log.count() = all events)
--   log.rate(kind)         entries of a kind added in the last 60 s ("rednet", "error", ...)
--   log.clear(kind)        clear one kind (nil = everything)
--   log.rednet(ev, extra)  add a "rednet_message" event { "rednet_message", from, msg, protocol }, summarised
--   log.summary(msg)       short text for a rednet message
local L = rawget(_G, "WardenLog")
if type(L) == "table" and L.add then return L end

L = { LIMITS = { rednet = 150, error = 60, claude = 40, info = 60 } }
local rings = {}                                  -- kind -> { n = total added, [slot] = entry }
local counts, total = {}, 0                       -- event name -> { n, buckets }
local MAXNAMES = 64
local SLOT = 10                                   -- seconds per rate bucket, 6 buckets = 1 minute
local allBuckets, kindBuckets = {}, {}

local function now() return os.clock() end
local function epoch()
  local ok, t = pcall(os.epoch, "utc")
  return ok and t or 0
end

-- rolling per-minute counter: { [slot index] = { stamp, n } }
local function bump(b)
  local s = math.floor(now() / SLOT)
  local i = s % 6
  local c = b[i]
  if not c or c[1] ~= s then b[i] = { s, 1 } else c[2] = c[2] + 1 end
end
local function perMinute(b)
  if not b then return 0 end
  local s, n = math.floor(now() / SLOT), 0
  for _, c in pairs(b) do if s - c[1] < 6 then n = n + c[2] end end
  return n
end

local function cut(s, n)
  s = tostring(s)
  if #s > n then s = s:sub(1, n - 2) .. ".." end
  return s
end

-- rough serialized size of a value (bounded work)
local function size(v)
  local n, seen, budget = 0, {}, 3000
  local function walk(x)
    budget = budget - 1
    if budget < 0 then return end
    local t = type(x)
    if t == "string" then n = n + #x + 2
    elseif t == "number" then n = n + 6
    elseif t == "boolean" then n = n + 5
    elseif t == "table" then
      if seen[x] then return end
      seen[x] = true
      n = n + 2
      for k, y in pairs(x) do
        if budget < 0 then return end
        n = n + 3
        walk(k)
        walk(y)
      end
    end
  end
  walk(v)
  return n, budget < 0
end
L.size = size

function L.summary(msg)
  if type(msg) ~= "table" then return cut(type(msg) == "string" and msg or ("<" .. type(msg) .. ">"), 40) end
  local t = msg.t
  if t == "cmd" then
    local a = msg.arg
    local s = "cmd " .. tostring(msg.cmd)
    if type(a) == "table" then
      if msg.cmd == "protect" and type(a.boxes) == "table" then s = s .. " rev " .. tostring(a.rev) .. ", " .. #a.boxes .. " areas"
      elseif a.name or a.task then s = s .. " " .. tostring(a.name or a.task) end
    elseif a ~= nil then s = s .. " " .. tostring(a) end
    return cut(s .. " #" .. tostring(msg.seq), 60)
  elseif t == "ack" then
    return cut(("ack %s %s%s"):format(tostring(msg.cmd), msg.ok and "ok" or "FAIL",
      msg.ok == false and msg.err and (": " .. tostring(msg.err)) or ""), 60)
  elseif t == "status" then
    if msg.kind == "turtle" then
      return cut(("status %s/%s fuel %s"):format(tostring(msg.task), tostring(msg.state), tostring(msg.fuel)), 60)
    end
    return cut("status " .. tostring(msg.kind) .. " v" .. tostring(msg.version), 60)
  elseif t == "map" then
    return "map " .. (type(msg.obs) == "table" and #msg.obs or 0) .. " obs"
  elseif t ~= nil then
    return cut(tostring(t), 40)
  end
  local keys = {}
  for k in pairs(msg) do
    keys[#keys + 1] = tostring(k)
    if #keys >= 4 then break end
  end
  return cut("{" .. table.concat(keys, ",") .. "}", 40)
end

function L.add(kind, entry)
  pcall(function()
    if kind == "event" then
      local name = tostring(entry)
      total = total + 1
      bump(allBuckets)
      local c = counts[name]
      if not c then
        local n = 0
        for _ in pairs(counts) do n = n + 1 end
        if n >= MAXNAMES then name = "(other)" c = counts[name] end
        if not c then c = { n = 0, b = {} } counts[name] = c end
      end
      c.n = c.n + 1
      bump(c.b)
      return
    end
    local limit = L.LIMITS[kind]
    if not limit then kind, limit = "info", L.LIMITS.info end
    if type(entry) ~= "table" then entry = { text = cut(entry, 200) } end
    entry.time = entry.time or epoch()
    entry.clock = entry.clock or now()
    local r = rings[kind]
    if not r then r = { n = 0 } rings[kind] = r end
    r.n = r.n + 1
    r[(r.n - 1) % limit + 1] = entry
    kindBuckets[kind] = kindBuckets[kind] or {}
    bump(kindBuckets[kind])
  end)
end

function L.list(kind)
  local out = {}
  pcall(function()
    if kind == "event" then
      for name, c in pairs(counts) do out[#out + 1] = { name = name, count = c.n, rate = perMinute(c.b) } end
      table.sort(out, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.name < b.name
      end)
      return
    end
    local r, limit = rings[kind], L.LIMITS[kind]
    if not r or not limit then return end
    for i = r.n, math.max(1, r.n - limit + 1), -1 do out[#out + 1] = r[(i - 1) % limit + 1] end
  end)
  return out
end

function L.count(name)
  if name == nil then return total, perMinute(allBuckets) end
  local c = counts[tostring(name)]
  if not c then return 0, 0 end
  return c.n, perMinute(c.b)
end

function L.rate(kind) return perMinute(kindBuckets[kind]) end

function L.total(kind)                            -- entries ever added (also the ones already dropped)
  local r = rings[kind]
  return r and r.n or 0
end

function L.clear(kind)
  pcall(function()
    if kind == nil or kind == "event" then counts, total, allBuckets = {}, 0, {} end
    if kind == nil then rings, kindBuckets = {}, {}
    elseif kind ~= "event" then rings[kind], kindBuckets[kind] = nil, nil end
  end)
end

-- a rednet_message event -> "rednet" entry (extra: fields to add, e.g. drone = true)
function L.rednet(ev, extra)
  pcall(function()
    local msg = ev[3]
    local e = { from = ev[2], protocol = ev[4] ~= nil and tostring(ev[4]) or nil, summary = L.summary(msg) }
    if type(msg) == "table" then
      e.t = msg.t ~= nil and tostring(msg.t) or nil
      e.to = tonumber(msg.to)
      e.kind = msg.kind ~= nil and tostring(msg.kind) or nil
    end
    local n, more = size(msg)
    e.size = n
    e.big = more or nil
    if type(extra) == "table" then for k, v in pairs(extra) do e[k] = v end end
    L.add("rednet", e)
  end)
end

rawset(_G, "WardenLog", L)
return L
