-- MineView sampler + storage: item counts of the storage system over time ("TradingView for resources").
--
-- The desktop kernel runs one recording instance through /os/lib/world.lua (WardenOS.mineview):
--   inst.event(ev)  every kernel event. Sampling runs in a coroutine owned by this module: inventory list() and
--                   bridge calls are main-thread peripheral calls that yield (task_complete), so they never run
--                   in the kernel's own event handler. The coroutine is resumed with every event, respecting
--                   the filter it yielded (like the pocket server's Claude coroutine). Nothing ever throws.
--   inst.flush(force)  write pending history (on its own at most every 5 minutes; force = now)
-- Apps use (any instance; MV.new({ readonly = true }) reads the stored history without recording):
--   items()                 { {name, display, current, ch1h, pct1h, ch24h, pct24h, prodH, consH, rate, pinned} }
--                           pinned first, then by amount
--   candles(item, tf)       tf "1m" "5m" "15m" (raw samples, last 24 h) "1h" "4h" "1d" (hourly candles, 30 days)
--                           -> { {t, o, h, l, c, prod, cons}, ... } oldest first
--   config() / setConfig(t) interval (20-300 s), mode, selected, limit (10-200 items), maxKB, pinned
--   pin(item, on), sources() (detected sources), status(), sampleNow(), clear(), flush(force)
--
-- Sources (config.mode):
--   auto         ME / RS bridges (Advanced Peripherals) when there is one, else every inventory. A bridge already
--                counts the chests of its network, and a computer can't tell which chests belong to it, so
--                bridges and chests are not mixed unless the player asks for it.
--   inventories  every inventory (anything with list(), also over wired modems; turtles/computers skipped)
--   bridges      only ME / RS bridges
--   all          both (counts an item twice when a chest is also part of the ME/RS network)
--   selected     only the peripherals in config.selected
--
-- Produced / consumed: for consecutive samples delta = count2 - count1, produced += max(delta, 0),
-- consumed += max(-delta, 0). When the set of sources that were read successfully differs between the two
-- samples (a chest was detached, a bridge failed), the delta is unreliable and skipped. Candles use the
-- previous sample as open (o = previous close), so c - o = produced - consumed when all deltas are reliable.
--
-- Storage (/os/mineview/), plain text, base36 numbers:
--   config      textutils.serialize(config)
--   raw.log     last 24 h of samples; only changed counts are written. Lines:
--                 T <t>                    time base (epoch seconds, decimal)
--                 N <id> <item> <display>  item id (this file)
--                 G <sig>                  the source set of the following samples
--                 <dt> [id=count,...]      a sample dt seconds after the previous one + the counts that changed
--   hourly.log  closed hours (30 days). Lines: N (as above), B <t> id:close;...  (closes before the first hour),
--                 H <t> [id:o,dh,dl,dc,prod,cons;...]  an hour with data; only candles that are not flat at the
--                 previous close are listed (o empty = previous close; h = o+dh, l = o-dl, c = o+dc)
--   Samples are appended (buffered, written at most every 5 min); the files are rewritten from memory when
--   old data drops out (about hourly), after a restart, and to stay within config.maxKB. Nothing is written
--   while the disk has less than 200 KB free (status().disk = "low").
local DIR = "/os/mineview"
local HOUR, DAY = 3600, 86400
local RAW_KEEP = DAY                            -- raw samples kept
local HOURLY_KEEP = 30 * DAY                    -- hourly candles kept
local FLUSH_EVERY = 300                         -- seconds between history writes
local LOW_DISK = 200 * 1024                     -- stop writing history below this much free space
local FIRST_DELAY = 3                           -- seconds after the desktop starts: first sample
local MODES = { auto = true, inventories = true, bridges = true, all = true, selected = true }
local TF = { ["1m"] = 60, ["5m"] = 300, ["15m"] = 900, ["1h"] = HOUR, ["4h"] = 4 * HOUR, ["1d"] = DAY }

local MV = { TIMEFRAMES = { "1m", "5m", "15m", "1h", "4h", "1d" }, TF = TF, DIR = DIR, LOW_DISK = LOW_DISK,
             MODES = { "auto", "inventories", "bridges", "all", "selected" } }

---------------------------------------------------------------- helpers
local floor, max, min = math.floor, math.max, math.min
local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"
local function b36(n)
  n = floor(tonumber(n) or 0)
  local neg = n < 0
  if neg then n = -n end
  if n == 0 then return "0" end
  local s = {}
  while n > 0 do
    local d = n % 36
    s[#s + 1] = DIGITS:sub(d + 1, d + 1)
    n = (n - d) / 36
  end
  return (neg and "-" or "") .. string.reverse(table.concat(s))
end
local function un36(s)
  if type(s) ~= "string" or s == "" then return nil end
  local neg = s:sub(1, 1) == "-"
  local v = tonumber(neg and s:sub(2) or s, 36)
  if not v then return nil end
  return neg and -v or v
end
MV.b36, MV.un36 = b36, un36

local function now()
  local ok, e = pcall(os.epoch, "utc")
  if ok and type(e) == "number" then return floor(e / 1000) end
  return floor(os.clock())
end
MV.now = now

local function hash(s)                          -- short signature of a source set
  local h = 5381
  for i = 1, #s do h = (h * 33 + s:byte(i)) % 2147483647 end
  return b36(h)
end

local function pretty(id)                       -- "minecraft:cobblestone" -> "Cobblestone"
  local s = tostring(id or "?"):gsub("^[%w_%.%-]+:", ""):gsub("_", " ")
  return (s:gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b end))
end
MV.pretty = pretty

local function cleanDisplay(d, name)
  d = type(d) == "string" and d:gsub("^%s*%[", ""):gsub("%]%s*$", "") or ""
  d = d:gsub("[%c]", ""):gsub("[^\32-\126]", "?")
  if d == "" then d = pretty(name) end
  return d:sub(1, 40)
end

local log
do
  local ok, l = pcall(dofile, "/os/lib/log.lua")
  if ok and type(l) == "table" then log = l end
end
local function note(kind, text)
  if log then pcall(log.add, kind, { source = "mineview", text = tostring(text) }) end
end

local function readFile(p)
  if not fs.exists(p) then return nil end
  local f = fs.open(p, "r")
  if not f then return nil end
  local s = f.readAll()
  f.close()
  return s
end
local function writeFile(p, s, mode)
  local f = fs.open(p, mode or "w")
  if not f then return false end
  f.write(s)
  f.close()
  return true
end
local function sizeOf(p)
  local ok, n = pcall(fs.getSize, p)
  return ok and tonumber(n) or 0
end
local function freeSpace()
  local ok, n = pcall(fs.getFreeSpace, fs.exists(DIR) and DIR or "/")
  return ok and tonumber(n) or 0
end

---------------------------------------------------------------- sources
local function typesOf(name)
  local ok, a, b, c, d = pcall(peripheral.getType, name)
  local t = {}
  if ok then for _, v in ipairs({ a, b, c, d }) do t[#t + 1] = tostring(v) end end
  return t
end
local function methodsOf(name)
  local ok, m = pcall(peripheral.getMethods, name)
  local set = {}
  if ok and type(m) == "table" then for _, v in ipairs(m) do set[v] = true end end
  return set
end

-- { name, kind = "inv" | "bridge", method } or nil
local function classify(name)
  local types = typesOf(name)
  if #types == 0 then return nil end
  local tl = table.concat(types, " "):lower()
  if tl:find("turtle") or tl:find("computer") or tl:find("pocket") or tl:find("modem") or tl:find("monitor") then
    return nil
  end
  local m = methodsOf(name)
  if tl:find("mebridge") or tl:find("me_bridge") or tl:find("rsbridge") or tl:find("rs_bridge")
     or ((m.listItems or m.getItems) and not m.list) then
    return { name = name, kind = "bridge", method = (m.listItems and "listItems") or (m.getItems and "getItems") or nil }
  end
  if m.list and (m.size or m.getItemDetail or tl:find("inventory")) then return { name = name, kind = "inv" } end
  return nil
end

function MV.detect()                            -- every usable source attached now
  local out = {}
  local ok, names = pcall(peripheral.getNames)
  if not ok or type(names) ~= "table" then return out end
  for _, n in ipairs(names) do
    local okc, s = pcall(classify, n)
    if okc and s then out[#out + 1] = s end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

local function choose(cfg, found)
  local inv, br = {}, {}
  for _, s in ipairs(found) do if s.kind == "bridge" then br[#br + 1] = s else inv[#inv + 1] = s end end
  local mode = cfg.mode
  if mode == "selected" then
    local by, out = {}, {}
    for _, s in ipairs(found) do by[s.name] = s end
    for _, n in ipairs(cfg.selected) do out[#out + 1] = by[n] or { name = n, kind = "missing" } end
    return out, "selected"
  elseif mode == "inventories" then return inv, "inventories"
  elseif mode == "bridges" then return br, "bridges"
  elseif mode == "all" then
    local out = {}
    for _, s in ipairs(br) do out[#out + 1] = s end
    for _, s in ipairs(inv) do out[#out + 1] = s end
    return out, "all"
  end
  if #br > 0 then return br, "bridges" end
  return inv, "inventories"
end

-- one source -> { [item] = count }, { [item] = display }; errors when it can't be read (may yield)
local function readSource(s)
  local counts, names = {}, {}
  if s.kind == "missing" then error("not attached", 0) end
  if s.kind == "inv" then
    local l = peripheral.call(s.name, "list")
    if type(l) ~= "table" then error("list() returned nothing", 0) end
    for _, it in pairs(l) do
      if type(it) == "table" and type(it.name) == "string" then
        counts[it.name] = (counts[it.name] or 0) + (tonumber(it.count) or 0)
      end
    end
    return counts, names
  end
  local l, err
  for _, m in ipairs(s.method and { s.method } or { "listItems", "getItems" }) do
    local ok, a, b = pcall(peripheral.call, s.name, m)
    if ok and type(a) == "table" then l = a break end
    err = ok and (b or "no items") or a
  end
  if type(l) ~= "table" then error(tostring(err or "bridge not readable"), 0) end
  for _, it in pairs(l) do
    if type(it) == "table" and type(it.name) == "string" then
      counts[it.name] = (counts[it.name] or 0) + floor(tonumber(it.amount) or tonumber(it.count) or 0)
      if it.displayName then names[it.name] = it.displayName end
    end
  end
  return counts, names
end

-- runs inside the sampling coroutine
local function collect(cfg)
  local t0 = now()
  local clock0 = os.clock()
  local srcs, using = choose(cfg, MV.detect())
  local counts, names, okNames, failed = {}, {}, {}, {}
  for _, s in ipairs(srcs) do
    local ok, c, n = pcall(readSource, s)
    if ok then
      for k, v in pairs(c) do counts[k] = (counts[k] or 0) + v end
      for k, v in pairs(n) do names[k] = v end
      okNames[#okNames + 1] = s.name
    else
      failed[s.name] = tostring(c)
    end
  end
  table.sort(okNames)
  return { t = t0, counts = counts, names = names, ok = okNames, failed = failed, sources = #srcs, using = using,
           ms = floor((os.clock() - clock0) * 1000 + 0.5) }
end

---------------------------------------------------------------- instance
function MV.new(opts)
  opts = opts or {}
  local readonly = opts.readonly and true or false
  local I = {}
  local cfg
  local S                                       -- history in memory (see reset)
  local stat = { lastT = nil, ms = nil, ok = {}, failed = {}, sources = 0, using = nil, disk = "ok", error = nil }
  local worker, wfilter, wstart
  local timer, started = nil, false
  local lastFlush = now()
  local needRewrite = true                      -- the files don't match memory: rewrite on the next flush
  local rawBuf, hourBuf = {}, {}                -- lines waiting to be appended
  local rawState, hourState                     -- append streams: { ids = {name=id}, next, lastT, sig, firstT }
  local lastFailed = {}

  local function reset()
    S = {
      t = {}, sig = {}, first = 1, last = 0,    -- raw samples by sequence number
      items = {},                               -- [name] = { name, display, ss = {seq...}, cs = {count...} }
      hours = {},                               -- closed hours with data, ascending
      hc = {},                                  -- [name] = { [hour] = candle } (only candles not flat)
      base = {},                                -- [name] = close before hours[1]
      close = {},                               -- [name] = close of the last closed hour
    }
    rawState, hourState = nil, nil
    rawBuf, hourBuf = {}, {}
  end
  reset()

  ------------------------------------------------ config
  local function normCfg(c)
    c = type(c) == "table" and c or {}
    local out = {
      interval = floor(min(300, max(20, tonumber(c.interval) or 60))),
      mode = MODES[c.mode] and c.mode or "auto",
      limit = floor(min(200, max(10, tonumber(c.limit) or 200))),
      maxKB = floor(min(4096, max(64, tonumber(c.maxKB) or 256))),
      selected = {}, pinned = {},
    }
    if type(c.selected) == "table" then
      for _, n in ipairs(c.selected) do if type(n) == "string" then out.selected[#out.selected + 1] = n end end
    end
    if type(c.pinned) == "table" then
      for k, v in pairs(c.pinned) do if type(k) == "string" and v then out.pinned[k] = true end end
    end
    return out
  end
  local function saveCfg()
    pcall(function()
      if not fs.exists(DIR) then fs.makeDir(DIR) end
      writeFile(DIR .. "/config", textutils.serialize(cfg))
    end)
  end
  do
    local s = readFile(DIR .. "/config")
    local ok, c = pcall(function() return s and textutils.unserialize(s) end)
    cfg = normCfg(ok and c or nil)
  end

  ------------------------------------------------ raw lookups
  local function lastValue(it) return it.cs[#it.cs] end
  -- last sample seq with t <= T (nil if none)
  local function seqAt(T)
    if S.last < S.first then return nil end
    if S.t[S.first] > T then return nil end
    local lo, hi = S.first, S.last
    while lo < hi do
      local mid = floor((lo + hi + 1) / 2)
      if S.t[mid] <= T then lo = mid else hi = mid - 1 end
    end
    return lo
  end
  local function valueAtSeq(it, seq)
    local lo, hi, v = 1, #it.ss, nil
    while lo <= hi do
      local mid = floor((lo + hi) / 2)
      if it.ss[mid] <= seq then v = it.cs[mid] lo = mid + 1 else hi = mid - 1 end
    end
    return v
  end

  -- candles of period P from the raw samples, buckets with start >= tFrom (and < tTo)
  local function changeIndex(it, seq)            -- index of the last change at or before seq (0 = none)
    local lo, hi, k = 1, #it.ss, 0
    while lo <= hi do
      local mid = floor((lo + hi) / 2)
      if it.ss[mid] <= seq then k = mid lo = mid + 1 else hi = mid - 1 end
    end
    return k
  end
  local function rawBuckets(it, P, tFrom, tTo)
    local out, cur = {}, nil
    local prevV, prevSig
    local s0 = seqAt(tFrom - 1) or S.first       -- the sample before the range: open of the first bucket
    local ss, cs = it.ss, it.cs
    local j = changeIndex(it, s0 - 1)
    for seq = s0, S.last do
      local t, sig = S.t[seq], S.sig[seq]
      if tTo and t >= tTo then break end
      while ss[j + 1] and ss[j + 1] <= seq do j = j + 1 end
      local v = j > 0 and cs[j] or nil
      if v ~= nil and t >= tFrom and (not tTo or t < tTo) then
        local b = floor(t / P) * P
        if not cur or cur.t ~= b then
          local o = prevV or v
          cur = { t = b, o = o, h = o, l = o, c = o, prod = 0, cons = 0 }
          out[#out + 1] = cur
        end
        if v > cur.h then cur.h = v end
        if v < cur.l then cur.l = v end
        cur.c = v
        if prevV ~= nil and prevSig == sig then
          local d = v - prevV
          if d > 0 then cur.prod = cur.prod + d else cur.cons = cur.cons - d end
        end
      end
      prevV, prevSig = v, sig
    end
    return out
  end

  local function hourlyList(name)
    local out, c = {}, S.base[name]
    local hc = S.hc[name] or {}
    for _, H in ipairs(S.hours) do
      local cd = hc[H]
      if cd then
        out[#out + 1] = { t = H, o = cd.o, h = cd.h, l = cd.l, c = cd.c, prod = cd.prod, cons = cd.cons }
        c = cd.c
      elseif c ~= nil then
        out[#out + 1] = { t = H, o = c, h = c, l = c, c = c, prod = 0, cons = 0 }
      end
    end
    return out
  end

  ------------------------------------------------ file streams
  local function newState() return { ids = {}, next = 0, lastT = nil, sig = nil } end
  local function idFor(st, name, buf)
    local id = st.ids[name]
    if not id then
      id = b36(st.next)
      st.next = st.next + 1
      st.ids[name] = id
      local it = S.items[name]
      buf[#buf + 1] = "N " .. id .. " " .. name .. " " .. (it and it.display or pretty(name))
    end
    return id
  end
  -- one sample line (and the N / G / T lines it needs) for the sample seq; changes = { {name, count}, ... }
  local function rawLines(st, buf, seq, changes)
    local t = S.t[seq]
    if not st.lastT then
      buf[#buf + 1] = "T " .. t
      st.lastT = t
      st.firstT = t
    end
    if st.sig ~= S.sig[seq] then
      buf[#buf + 1] = "G " .. S.sig[seq]
      st.sig = S.sig[seq]
    end
    local parts = {}
    for _, ch in ipairs(changes) do parts[#parts + 1] = idFor(st, ch[1], buf) .. "=" .. b36(ch[2]) end
    buf[#buf + 1] = b36(t - st.lastT) .. (#parts > 0 and (" " .. table.concat(parts, ",")) or "")
    st.lastT = t
  end
  local function candleField(cd, carry)
    return (carry == cd.o and "" or b36(cd.o)) .. "," .. b36(cd.h - cd.o) .. "," .. b36(cd.o - cd.l) .. ","
           .. b36(cd.c - cd.o) .. "," .. b36(cd.prod) .. "," .. b36(cd.cons)
  end
  -- the H line of hour H; carry = { [name] = close before this hour } (updated)
  local function hourLine(st, buf, H, carry)
    if not st.firstT then st.firstT = H end
    local parts, names = {}, {}
    for name, hc in pairs(S.hc) do if hc[H] then names[#names + 1] = name end end
    table.sort(names)
    for _, name in ipairs(names) do
      local cd = S.hc[name][H]
      parts[#parts + 1] = idFor(st, name, buf) .. ":" .. candleField(cd, carry[name])
      carry[name] = cd.c
    end
    buf[#buf + 1] = "H " .. H .. (#parts > 0 and (" " .. table.concat(parts, ";")) or "")
  end

  local function sortedNames()
    local n = {}
    for name in pairs(S.items) do n[#n + 1] = name end
    table.sort(n)
    return n
  end

  local function genRaw()
    local st, buf = newState(), {}
    if S.last < S.first then return "", st end
    local snap = {}
    for _, name in ipairs(sortedNames()) do
      local v = valueAtSeq(S.items[name], S.first)
      if v ~= nil then snap[#snap + 1] = { name, v } end
    end
    rawLines(st, buf, S.first, snap)
    local idx = {}
    for name, it in pairs(S.items) do
      local j = 1
      while it.ss[j] and it.ss[j] <= S.first do j = j + 1 end
      idx[name] = j
    end
    local names = sortedNames()
    for seq = S.first + 1, S.last do
      local ch = {}
      for _, name in ipairs(names) do
        local it, j = S.items[name], idx[name]
        if it.ss[j] == seq then ch[#ch + 1] = { name, it.cs[j] } idx[name] = j + 1 end
      end
      rawLines(st, buf, seq, ch)
    end
    return table.concat(buf, "\n") .. "\n", st
  end

  local function genHourly()
    local st, buf = newState(), {}
    if #S.hours == 0 then return "", st end
    local carry, parts = {}, {}
    for _, name in ipairs(sortedNames()) do
      local b = S.base[name]
      if b ~= nil then
        carry[name] = b
        parts[#parts + 1] = idFor(st, name, buf) .. ":" .. b36(b)
      end
    end
    buf[#buf + 1] = "B " .. S.hours[1] .. (#parts > 0 and (" " .. table.concat(parts, ";")) or "")
    st.firstT = S.hours[1]
    for _, H in ipairs(S.hours) do hourLine(st, buf, H, carry) end
    st.carry = carry
    return table.concat(buf, "\n") .. "\n", st
  end

  ------------------------------------------------ pruning
  local function dropRawBefore(seqNew)          -- keep samples seqNew..last
    if seqNew <= S.first then return end
    for seq = S.first, seqNew - 1 do S.t[seq], S.sig[seq] = nil, nil end
    S.first = seqNew
    for _, it in pairs(S.items) do
      local k = 0                               -- last change at or before the new first sample: keep it
      for j = 1, #it.ss do if it.ss[j] <= seqNew then k = j else break end end
      if k > 1 then
        local ss, cs = {}, {}
        for j = k, #it.ss do ss[#ss + 1], cs[#cs + 1] = it.ss[j], it.cs[j] end
        it.ss, it.cs = ss, cs
      end
    end
  end
  local function pruneRaw(tNow)
    local cut = tNow - RAW_KEEP
    local s = S.first
    while s < S.last and S.t[s + 1] and S.t[s + 1] <= cut do s = s + 1 end   -- keep one sample before the cut
    dropRawBefore(s)
  end
  local function dropHour()
    local H = table.remove(S.hours, 1)
    for name, hc in pairs(S.hc) do
      if hc[H] then S.base[name] = hc[H].c hc[H] = nil end
    end
  end
  local function pruneHourly(tNow)
    while S.hours[1] and S.hours[1] < tNow - HOURLY_KEEP do dropHour() end
  end
  local function dropItem(name)
    S.items[name], S.hc[name], S.base[name], S.close[name] = nil, nil, nil, nil
    needRewrite = true
  end

  ------------------------------------------------ loading
  local function loadRaw(text)
    local ids, cur, sig = {}, nil, ""
    for line in text:gmatch("[^\n]+") do
      local k = line:sub(1, 2)
      if k == "T " then cur = tonumber(line:sub(3))
      elseif k == "N " then
        local id, name, disp = line:match("^N (%S+) (%S+) ?(.*)$")
        if id then
          ids[id] = name
          local it = S.items[name]
          if not it then it = { name = name, ss = {}, cs = {} } S.items[name] = it end
          it.display = disp ~= "" and disp or pretty(name)
        end
      elseif k == "G " then sig = line:sub(3)
      elseif cur then
        local dt, rest = line:match("^(%-?[%w]+) ?(.*)$")
        dt = un36(dt)
        if dt then
          cur = cur + dt
          local seq = S.last + 1
          S.last, S.t[seq], S.sig[seq] = seq, cur, sig
          for id, v in rest:gmatch("([%w]+)=(%-?[%w]+)") do
            local name, n = ids[id], un36(v)
            local it = name and S.items[name]
            if it and n then
              if it.ss[#it.ss] == seq then it.cs[#it.cs] = n
              else it.ss[#it.ss + 1], it.cs[#it.cs + 1] = seq, n end
            end
          end
        end
      end
    end
  end
  local function loadHourly(text)
    local ids, carry = {}, {}
    for line in text:gmatch("[^\n]+") do
      local k = line:sub(1, 2)
      if k == "N " then
        local id, name, disp = line:match("^N (%S+) (%S+) ?(.*)$")
        if id then
          ids[id] = name
          if not S.items[name] then S.items[name] = { name = name, ss = {}, cs = {}, display = disp ~= "" and disp or pretty(name) } end
        end
      elseif k == "B " then
        for id, v in line:gmatch("([%w]+):(%-?[%w]+)") do
          local name, n = ids[id], un36(v)
          if name and n then S.base[name], carry[name] = n, n end
        end
      elseif k == "H " then
        local H = tonumber(line:match("^H (%d+)"))
        if H and (not S.hours[#S.hours] or H > S.hours[#S.hours]) then
          S.hours[#S.hours + 1] = H
          for id, o, dh, dl, dc, p, q in line:gmatch("([%w]+):(%-?[%w]*),(%-?[%w]+),(%-?[%w]+),(%-?[%w]+),(%-?[%w]+),(%-?[%w]+)") do
            local name = ids[id]
            local ov = o ~= "" and un36(o) or carry[name]
            if name and ov then
              local cd = { o = ov, h = ov + un36(dh), l = ov - un36(dl), c = ov + un36(dc), prod = un36(p), cons = un36(q) }
              S.hc[name] = S.hc[name] or {}
              S.hc[name][H] = cd
              carry[name] = cd.c
            end
          end
        end
      end
    end
    for name, c in pairs(carry) do S.close[name] = c end
  end
  local function load()
    reset()
    local r = readFile(DIR .. "/raw.log")
    if r then pcall(loadRaw, r) end
    local h = readFile(DIR .. "/hourly.log")
    if h then pcall(loadHourly, h) end
    local tl = S.t[S.last]
    if tl then pruneRaw(tl) pruneHourly(tl) end
    -- an item only known from old hourly data, no longer in the raw window: still listed (history)
    needRewrite = true
  end
  pcall(load)

  ------------------------------------------------ writing
  local function setDisk()
    local free = freeSpace()
    stat.free = free
    stat.disk = free < LOW_DISK and "low" or "ok"
    return stat.disk == "ok"
  end
  local function compact()
    local budget = cfg.maxKB * 1024
    local raw, rst = genRaw()
    local hourly, hst = genHourly()
    local guard = 0
    while #raw + #hourly > budget and guard < 400 do   -- over budget: drop the oldest raw samples, then hours
      guard = guard + 1
      local n = S.last - S.first + 1
      if #raw > budget * 0.6 and n > 2 then
        dropRawBefore(S.first + max(1, floor(n / 10)))
        raw, rst = genRaw()
      elseif #S.hours > 1 then
        for _ = 1, min(24, #S.hours - 1) do dropHour() end
        hourly, hst = genHourly()
      elseif n > 2 then
        dropRawBefore(S.first + max(1, floor(n / 10)))
        raw, rst = genRaw()
      else
        break
      end
    end
    if not fs.exists(DIR) then fs.makeDir(DIR) end
    writeFile(DIR .. "/raw.log", raw)
    writeFile(DIR .. "/hourly.log", hourly)
    rawState, hourState = rst, hst
    rawState.bytes, hourState.bytes = #raw, #hourly
    rawBuf, hourBuf = {}, {}
    needRewrite = false
  end

  function I.flush(force)
    if readonly then return false end
    local ok, err = pcall(function()
      lastFlush = now()
      if not setDisk() then                     -- keep recording in memory; rewrite when there is room again
        if #rawBuf > 0 or #hourBuf > 0 then needRewrite = true end
        rawBuf, hourBuf = {}, {}
        return
      end
      local due = needRewrite or not rawState or not hourState
      if not due and S.last >= S.first and rawState.firstT and S.t[S.first] > rawState.firstT + HOUR then due = true end
      if not due and S.hours[1] and hourState.firstT and S.hours[1] > hourState.firstT + DAY then due = true end
      if not due then
        local add = 0
        for _, l in ipairs(rawBuf) do add = add + #l + 1 end
        for _, l in ipairs(hourBuf) do add = add + #l + 1 end
        if (rawState.bytes or 0) + (hourState.bytes or 0) + add > cfg.maxKB * 1024 then due = true end
      end
      if due then
        compact()
      else
        if not fs.exists(DIR) then fs.makeDir(DIR) end
        if #rawBuf > 0 then
          local s = table.concat(rawBuf, "\n") .. "\n"
          writeFile(DIR .. "/raw.log", s, "a")
          rawState.bytes = (rawState.bytes or 0) + #s
        end
        if #hourBuf > 0 then
          local s = table.concat(hourBuf, "\n") .. "\n"
          writeFile(DIR .. "/hourly.log", s, "a")
          hourState.bytes = (hourState.bytes or 0) + #s
        end
        rawBuf, hourBuf = {}, {}
      end
      setDisk()
    end)
    if not ok then
      stat.error = "write: " .. tostring(err)
      note("error", stat.error)
      needRewrite = true
    end
    return ok
  end

  ------------------------------------------------ committing a sample
  local function closeHour(H)
    for name, it in pairs(S.items) do
      local cd = rawBuckets(it, HOUR, H, H + HOUR)[1]
      if cd then
        local carry = S.close[name]
        if not (cd.o == carry and cd.h == carry and cd.l == carry and cd.c == carry and cd.prod == 0 and cd.cons == 0) then
          S.hc[name] = S.hc[name] or {}
          S.hc[name][H] = cd
        end
        S.close[name] = cd.c
      end
    end
    S.hours[#S.hours + 1] = H
    if hourState and not needRewrite then
      local carry = hourState.carry or {}
      hourState.carry = carry
      if not hourState.firstT then
        hourBuf[#hourBuf + 1] = "B " .. H
        hourState.firstT = H
      end
      hourLine(hourState, hourBuf, H, carry)
    end
  end

  local function commit(r)
    local t = r.t
    if S.last >= S.first and t < S.t[S.last] then t = S.t[S.last] end   -- clock went back: keep order
    -- hours that ended since the last sample
    if S.last >= S.first then
      local H = floor(S.t[S.last] / HOUR) * HOUR
      if floor(t / HOUR) * HOUR > H and (not S.hours[#S.hours] or H > S.hours[#S.hours]) then closeHour(H) end
    end
    -- tracked items: pinned, then the largest amounts (items already tracked count double: no churn)
    local cand = {}
    for name, c in pairs(r.counts) do if c > 0 or S.items[name] then cand[name] = c end end
    for name in pairs(S.items) do if cand[name] == nil then cand[name] = 0 end end
    for name in pairs(cfg.pinned) do if cand[name] == nil then cand[name] = 0 end end
    local list = {}
    for name, c in pairs(cand) do
      local score = cfg.pinned[name] and math.huge or c * (S.items[name] and 2 or 1)
      list[#list + 1] = { name = name, score = score, old = S.items[name] ~= nil }
    end
    table.sort(list, function(a, b)
      if a.score ~= b.score then return a.score > b.score end
      if a.old ~= b.old then return a.old end
      return a.name < b.name
    end)
    local keep = {}
    for i = 1, min(#list, cfg.limit) do keep[list[i].name] = true end
    for name in pairs(cfg.pinned) do keep[name] = true end
    for name in pairs(S.items) do if not keep[name] then dropItem(name) end end
    -- the sample
    local seq = S.last + 1
    S.last, S.t[seq] = seq, t
    S.sig[seq] = hash(table.concat(r.ok, "\n"))
    local changes, names = {}, {}
    for name in pairs(keep) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
      local it = S.items[name]
      if not it then
        it = { name = name, ss = {}, cs = {}, display = cleanDisplay(r.names[name], name) }
        S.items[name] = it
      elseif r.names[name] then
        it.display = cleanDisplay(r.names[name], name)
      end
      local v = r.counts[name] or 0
      if it.cs[#it.cs] ~= v or #it.ss == 0 then
        it.ss[#it.ss + 1], it.cs[#it.cs + 1] = seq, v
        changes[#changes + 1] = { name, v }
      end
    end
    if not needRewrite then
      rawState = rawState or newState()
      rawLines(rawState, rawBuf, seq, changes)
    end
    pruneRaw(t)
    pruneHourly(t)
    -- status
    stat.lastT, stat.ms, stat.sources, stat.using = t, r.ms, r.sources, r.using
    stat.ok, stat.failed, stat.error = r.ok, r.failed, nil
    for n, e in pairs(r.failed) do
      if not lastFailed[n] then note("error", "source " .. n .. " skipped: " .. e) end
    end
    for n in pairs(lastFailed) do
      if not r.failed[n] then note("info", "source " .. n .. " readable again") end
    end
    lastFailed = r.failed
    pcall(os.queueEvent, "mineview_update")
  end
  I._commit = commit                            -- tests

  ------------------------------------------------ the sampling coroutine
  local function schedule(delay)
    timer = os.startTimer(max(1, delay))
    stat.nextT = now() + max(1, delay)
  end
  local function finish(ok, res)
    worker, wfilter = nil, nil
    if ok and type(res) == "table" then
      local okc, err = pcall(commit, res)
      if not okc then stat.error = "sample: " .. tostring(err) note("error", stat.error) end
    elseif not ok then
      stat.error = "sample: " .. tostring(res)
      note("error", stat.error)
    end
    local spent = now() - (wstart or now())
    schedule(cfg.interval - spent)
  end
  local function resume(ev)
    if not worker then return end
    if wfilter and ev[1] ~= wfilter and ev[1] ~= "terminate" then return end
    local ok, res = coroutine.resume(worker, table.unpack(ev, 1, ev.n or #ev))
    if not ok then finish(false, res)
    elseif coroutine.status(worker) == "dead" then finish(true, res)
    else wfilter = res end
  end
  local function startSample()
    if worker or readonly then return false end
    local c = cfg
    worker, wfilter, wstart = coroutine.create(function() return collect(c) end), nil, now()
    stat.busy = true
    resume({ n = 0 })
    return true
  end

  function I.event(ev)
    if readonly or type(ev) ~= "table" then return end
    local ok, err = pcall(function()
      if not started then
        started = true
        schedule(FIRST_DELAY)
      end
      local name, fresh = ev[1], false
      if name == "timer" and ev[2] == timer then
        timer = nil
        if worker then schedule(cfg.interval) else fresh = startSample() end
      elseif name == "mineview_sample" and not worker then
        fresh = startSample()
      end
      if worker and not fresh then resume(ev) end
      if worker and now() - wstart > max(60, cfg.interval * 2) then   -- a source that never answers
        worker, wfilter = nil, nil
        stat.error = "sample took too long, skipped"
        note("error", stat.error)
        schedule(cfg.interval)
      end
      stat.busy = worker ~= nil
      if not worker and now() - lastFlush >= FLUSH_EVERY then I.flush() end
    end)
    if not ok then
      worker, wfilter = nil, nil
      stat.error = tostring(err)
      note("error", "event: " .. tostring(err))
      if not timer then pcall(schedule, cfg.interval) end
    end
  end

  ------------------------------------------------ app API
  function I.config()
    local c = normCfg(cfg)
    return c
  end
  function I.setConfig(new)
    local merged = {}
    for k, v in pairs(cfg) do merged[k] = v end
    for k, v in pairs(type(new) == "table" and new or {}) do merged[k] = v end
    local old = cfg.interval
    cfg = normCfg(merged)
    saveCfg()
    if not readonly and started and cfg.interval ~= old and not worker then schedule(cfg.interval) end
    return I.config()
  end
  function I.pin(name, on)
    if type(name) ~= "string" then return end
    cfg.pinned[name] = on and true or nil
    saveCfg()
  end
  function I.sources()
    local out = {}
    local sel = {}
    for _, n in ipairs(cfg.selected) do sel[n] = true end
    for _, s in ipairs(MV.detect()) do
      out[#out + 1] = { name = s.name, kind = s.kind, selected = sel[s.name] or false }
      sel[s.name] = nil
    end
    for n in pairs(sel) do out[#out + 1] = { name = n, kind = "missing", selected = true } end
    return out
  end
  function I.sampleNow()
    if readonly then return false, "recording runs on the desktop" end
    if worker then return false, "sampling" end
    pcall(os.queueEvent, "mineview_sample")
    return true
  end
  function I.clear()
    reset()
    pcall(fs.delete, DIR .. "/raw.log")
    pcall(fs.delete, DIR .. "/hourly.log")
    needRewrite = true
    stat.lastT = nil
    return true
  end

  function I.status()
    local s = {}
    for k, v in pairs(stat) do s[k] = v end
    s.readonly, s.recording = readonly, not readonly
    s.busy = worker ~= nil
    s.interval, s.mode, s.limit, s.maxKB = cfg.interval, cfg.mode, cfg.limit, cfg.maxKB
    local n = 0
    for _ in pairs(S.items) do n = n + 1 end
    s.items = n
    s.samples = max(0, S.last - S.first + 1)
    s.hours = #S.hours
    s.firstT = S.t[S.first]
    s.lastSampleT = S.t[S.last]
    s.bytes = sizeOf(DIR .. "/raw.log") + sizeOf(DIR .. "/hourly.log") + sizeOf(DIR .. "/config")
    if s.free == nil then s.free = freeSpace() s.disk = s.free < LOW_DISK and "low" or "ok" end
    s.failedCount = 0
    for _ in pairs(s.failed or {}) do s.failedCount = s.failedCount + 1 end
    s.okCount = #(s.ok or {})
    return s
  end

  -- change of an item over `span` seconds before the last sample; produced / consumed in that window
  local function window(it, span, flows)
    local tl = S.t[S.last]
    local k = seqAt(tl - span) or S.first
    local j = changeIndex(it, k)
    if j == 0 then                              -- not tracked yet then: from its first sample
      if not it.ss[1] then return nil, 0, 0, 0 end
      k, j = max(k, it.ss[1]), 1
    end
    local v0 = it.cs[j]
    if not flows then return v0 end
    local p, q, prev, span = 0, 0, v0, 0
    local ss, cs = it.ss, it.cs
    for seq = k + 1, S.last do
      while ss[j + 1] and ss[j + 1] <= seq do j = j + 1 end
      local v = cs[j]
      if S.sig[seq] == S.sig[seq - 1] then     -- reliable: same sources read in both samples
        local d = v - prev
        if d > 0 then p = p + d else q = q - d end
        span = span + (S.t[seq] - S.t[seq - 1])
      end
      prev = v
    end
    return v0, p, q, span
  end

  function I.items()
    local out = {}
    for name, it in pairs(S.items) do
      local cur = lastValue(it)
      local e = { name = name, display = it.display or pretty(name), current = cur, pinned = cfg.pinned[name] or false }
      if cur ~= nil and S.last >= S.first then
        local v1, p, q, span = window(it, HOUR, true)
        local v24 = window(it, DAY)
        if v1 then e.ch1h = cur - v1 e.pct1h = v1 ~= 0 and (cur - v1) / v1 * 100 or (cur > 0 and 100 or 0) end
        if v24 then e.ch24h = cur - v24 e.pct24h = v24 ~= 0 and (cur - v24) / v24 * 100 or (cur > 0 and 100 or 0) end
        local f = span > 0 and HOUR / max(span, min(cfg.interval, HOUR)) or 0   -- per hour of reliable samples
        e.prodH, e.consH = floor(p * f + 0.5), floor(q * f + 0.5)
        e.rate = e.prodH - e.consH
      elseif cur == nil then
        local hl = hourlyList(name)
        if hl[#hl] then e.current = hl[#hl].c end
      end
      out[#out + 1] = e
    end
    table.sort(out, function(a, b)
      if a.pinned ~= b.pinned then return a.pinned end
      local x, y = a.current or -1, b.current or -1
      if x ~= y then return x > y end
      return a.name < b.name
    end)
    return out
  end

  function I.candles(name, tf)
    local P = TF[tf or "1h"]
    local it = S.items[name]
    if not P or not it then return {} end
    if P < HOUR then return rawBuckets(it, P, S.t[S.first] or 0) end
    local hl = hourlyList(name)
    local lastH = S.hours[#S.hours]
    local from = lastH and (lastH + HOUR) or (S.t[S.first] or 0)
    for _, cd in ipairs(rawBuckets(it, HOUR, from)) do hl[#hl + 1] = cd end
    if P == HOUR then return hl end
    local out, cur = {}, nil
    for _, cd in ipairs(hl) do
      local b = floor(cd.t / P) * P
      if not cur or cur.t ~= b then
        cur = { t = b, o = cd.o, h = cd.h, l = cd.l, c = cd.c, prod = 0, cons = 0 }
        out[#out + 1] = cur
      end
      cur.h, cur.l, cur.c = max(cur.h, cd.h), min(cur.l, cd.l), cd.c
      cur.prod, cur.cons = cur.prod + cd.prod, cur.cons + cd.cons
    end
    return out
  end

  I.readonly = readonly
  I._S = function() return S end                -- tests
  I._timer = function() return timer end
  I.reload = function() if readonly then pcall(load) end end
  return I
end

return MV
