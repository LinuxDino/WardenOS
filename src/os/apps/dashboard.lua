-- Dashboard: a grid of widgets with live numbers from peripherals of other mods (energy, fluids, inventories,
-- Create, ME / RS storage, redstone, any method) and WardenOS itself (drones, map, computer, clock).
-- Saved in /os/dashboard.cfg. Every peripheral call is pcall-protected; values are sampled every 2 s.
local CFG = "/os/dashboard.cfg"
local HIST = 40                                   -- samples kept per widget (sparkline)

---------------------------------------------------------------- number formatting
local function fmt(n)
  n = tonumber(n)
  if not n then return "-" end
  local a = math.abs(n)
  for _, s in ipairs({ { 1e12, "T" }, { 1e9, "G" }, { 1e6, "M" }, { 1e3, "k" } }) do
    if a >= s[1] then
      local v = n / s[1]
      return (math.abs(v) >= 100 and ("%d"):format(math.floor(v + 0.5)) or ("%.1f"):format(v)) .. s[2]
    end
  end
  if a ~= math.floor(a) then return ("%.1f"):format(n) end
  return tostring(math.floor(n))
end
local function shortName(id)                      -- "minecraft:cobblestone" -> "cobblestone"
  id = tostring(id or "?")
  return (id:gsub("^[%w_%.%-]+:", ""):gsub("_", " "))
end
local function fluidAmount(mb)                    -- mB -> "500 mB" / "12.5 B" / "1.2k B"
  mb = tonumber(mb) or 0
  if mb < 1000 then return math.floor(mb) .. " mB" end
  return fmt(mb / 1000) .. " B"
end

---------------------------------------------------------------- peripheral access (never throws)
local function methodsOf(name)
  local ok, m = pcall(peripheral.getMethods, name)
  local set = {}
  if ok and type(m) == "table" then for _, v in ipairs(m) do set[v] = true end end
  return set, ok and type(m) == "table" and m or {}
end
local function typesOf(name)
  local ok, a, b, c = pcall(peripheral.getType, name)
  local t = {}
  if ok then for _, v in ipairs({ a, b, c }) do t[#t + 1] = tostring(v) end end
  return t
end
local function present(name)
  local ok, p = pcall(peripheral.isPresent, name)
  return ok and p
end
local function call(name, method, ...)
  local r = table.pack(pcall(peripheral.call, name, method, ...))
  if not r[1] then return nil, tostring(r[2]) end
  return table.unpack(r, 2, r.n)
end
local function hasType(types, pat)
  for _, t in ipairs(types) do if t:lower():find(pat) then return true end end
  return false
end

---------------------------------------------------------------- widget kinds
local KINDS = {
  energy    = { title = "Energy",          h = 4 },
  fluid     = { title = "Fluid tanks",     h = 4 },
  inventory = { title = "Inventory",       h = 5 },
  create    = { title = "Create stress/speed", h = 4 },
  storage   = { title = "ME / RS storage", h = 5 },
  redstone  = { title = "Redstone input",  h = 3 },
  custom    = { title = "Custom method",   h = 5 },
  drones    = { title = "Drones",          h = 5, builtin = true },
  map       = { title = "World map",       h = 4, builtin = true },
  computer  = { title = "Computer",        h = 5, builtin = true },
  clock     = { title = "Clock",           h = 3, builtin = true },
}

-- kinds that fit a peripheral, best first
local function detect(name)
  local m = methodsOf(name)
  local types = typesOf(name)
  local out = {}
  local function add(k) for _, v in ipairs(out) do if v == k then return end end out[#out + 1] = k end
  if hasType(types, "mebridge") or hasType(types, "rsbridge") or hasType(types, "me_bridge") or hasType(types, "rs_bridge")
     or ((m.listItems or m.getItems) and (m.getEnergyUsage or m.getUsedItemStorage or m.getTotalItemStorage)) then
    add("storage")
  end
  if (m.getEnergy and (m.getEnergyCapacity or m.getMaxEnergy)) or (m.getEnergyStored and m.getMaxEnergyStored)
     or m.getTransferRate then
    add("energy")
  end
  if m.tanks then add("fluid") end
  if m.getStress or m.getSpeed then add("create") end
  if m.list and (m.size or m.getItemDetail) then add("inventory") end
  if hasType(types, "redstone_integrator") or (m.getAnalogInput and m.getInput) then add("redstone") end
  add("custom")
  return out
end

-- energy: first matching method pair; Mekanism (getMaxEnergy) reports Joules, the CC generic API FE
local function sampleEnergy(w)
  local m = methodsOf(w.periph)
  local d = {}
  if m.getEnergy and m.getEnergyCapacity then
    d.value, d.max, d.unit = call(w.periph, "getEnergy"), call(w.periph, "getEnergyCapacity"), "FE"
  elseif m.getEnergy and m.getMaxEnergy then
    d.value, d.max, d.unit = call(w.periph, "getEnergy"), call(w.periph, "getMaxEnergy"), "J"
    if m.getEnergyFilledPercentage then
      local p = tonumber((call(w.periph, "getEnergyFilledPercentage")))
      if p then d.frac = p > 1 and p / 100 or p end
    end
  elseif m.getEnergyStored and m.getMaxEnergyStored then
    d.value, d.max, d.unit = call(w.periph, "getEnergyStored"), call(w.periph, "getMaxEnergyStored"), "FE"
  elseif m.getTransferRate then                 -- Advanced Peripherals energy detector
    d.value, d.unit, d.rate = call(w.periph, "getTransferRate"), "FE/t", true
    if m.getTransferRateLimit then d.max = call(w.periph, "getTransferRateLimit") end
  else
    return { err = "no energy methods" }
  end
  d.value, d.max = tonumber(d.value), tonumber(d.max)
  if not d.value then return { err = "no reading" } end
  if not d.frac and d.max and d.max > 0 then d.frac = d.value / d.max end
  d.hist = d.value
  return d
end

local function sampleFluid(w)
  local t, err = call(w.periph, "tanks")
  if type(t) ~= "table" then return { err = err or "no tanks()" } end
  local d = { tanks = {} }
  local capAll = nil
  local m = methodsOf(w.periph)
  if m.getCapacity then capAll = tonumber((call(w.periph, "getCapacity"))) end   -- Mekanism tanks
  local sum = 0
  for i, tk in ipairs(t) do
    if type(tk) == "table" then
      local cap = tonumber(tk.capacity) or capAll
      d.tanks[#d.tanks + 1] = { name = tk.name, amount = tonumber(tk.amount) or 0, cap = cap }
      sum = sum + (tonumber(tk.amount) or 0)
    end
    if i >= 8 then break end
  end
  d.hist = sum
  return d
end

local function sampleInventory(w)
  local items, err = call(w.periph, "list")
  if type(items) ~= "table" then return { err = err or "no list()" } end
  local size = tonumber((call(w.periph, "size")))
  local d = { used = 0, total = 0, size = size }
  local by = {}
  for _, it in pairs(items) do
    if type(it) == "table" then
      d.used = d.used + 1
      local c = tonumber(it.count) or 0
      d.total = d.total + c
      local n = tostring(it.name)
      by[n] = (by[n] or 0) + c
    end
  end
  local top = {}
  for n, c in pairs(by) do top[#top + 1] = { name = n, count = c } end
  table.sort(top, function(a, b) if a.count ~= b.count then return a.count > b.count end return a.name < b.name end)
  d.top, d.types = { top[1], top[2], top[3] }, #top
  d.badge = fmt(d.total) .. " items"
  if size and size > 0 then d.frac = d.used / size end
  d.hist = d.total
  return d
end

local function sampleCreate(w)
  local m = methodsOf(w.periph)
  local d = {}
  if m.getStress then
    d.stress, d.cap = tonumber((call(w.periph, "getStress"))), tonumber((call(w.periph, "getStressCapacity")))
    if d.stress and d.cap and d.cap > 0 then d.frac = d.stress / d.cap end
    d.hist = d.stress
  end
  if m.getSpeed then
    d.speed = tonumber((call(w.periph, "getSpeed")))
    d.hist = d.hist or d.speed
  end
  if not d.stress and not d.speed then return { err = "no Create methods" } end
  return d
end

local function sampleStorage(w)
  local m = methodsOf(w.periph)
  local d = {}
  local items = m.listItems and call(w.periph, "listItems") or (m.getItems and call(w.periph, "getItems"))
  if type(items) == "table" then
    d.types, d.items = 0, 0
    for _, it in pairs(items) do
      if type(it) == "table" then
        d.types = d.types + 1
        d.items = d.items + (tonumber(it.amount) or tonumber(it.count) or 0)
      end
    end
  end
  if m.getUsedItemStorage and m.getTotalItemStorage then
    d.used, d.cap = tonumber((call(w.periph, "getUsedItemStorage"))), tonumber((call(w.periph, "getTotalItemStorage")))
    if d.used and d.cap and d.cap > 0 then d.frac = d.used / d.cap end
  end
  if m.getEnergyUsage then d.usage = tonumber((call(w.periph, "getEnergyUsage"))) end
  local se = m.getStoredEnergy and "getStoredEnergy" or (m.getEnergyStorage and "getEnergyStorage")
  if se then d.energy = tonumber((call(w.periph, se))) end
  if m.getMaxEnergyStorage then d.maxEnergy = tonumber((call(w.periph, "getMaxEnergyStorage"))) end
  if not d.types and not d.used and not d.usage then return { err = "storage not readable" } end
  d.hist = d.items or d.used
  return d
end

local function sampleRedstone(w)
  local side = w.side or "back"
  local v, on
  if w.periph then
    v = tonumber((call(w.periph, "getAnalogInput", side)))
    if v == nil then on = call(w.periph, "getInput", side) end
  elseif redstone then
    local ok, a = pcall(redstone.getAnalogInput, side)
    v = ok and tonumber(a) or nil
  end
  if v == nil and on == nil then return { err = "no reading" } end
  v = v or (on and 15 or 0)
  return { value = v, hist = v, frac = v / 15 }
end

local function parseArgs(s)
  local out = {}
  for part in tostring(s or ""):gmatch("[^,]+") do
    part = part:gsub("^%s+", ""):gsub("%s+$", "")
    if part == "true" then out[#out + 1] = true
    elseif part == "false" then out[#out + 1] = false
    elseif tonumber(part) then out[#out + 1] = tonumber(part)
    elseif part ~= "" then out[#out + 1] = (part:gsub('^"(.*)"$', "%1")) end
  end
  return out
end

-- any value -> up to `n` short lines
local function describe(v, n)
  local t = type(v)
  if t == "number" then return { fmt(v) } end
  if t ~= "table" then return { tostring(v) } end
  local lines, count, keys = {}, 0, {}
  for k in pairs(v) do count = count + 1 keys[#keys + 1] = k end
  if #v > 0 and #v == count then
    lines[1] = count .. " entries"
    for i = 1, math.min(#v, n - 1) do
      local x = v[i]
      if type(x) == "table" then
        local name = x.name or x.displayName or x.label or x.id
        local amt = x.amount or x.count
        lines[#lines + 1] = (name and shortName(name) or "{..}") .. (amt and (" " .. fmt(amt)) or "")
      else
        lines[#lines + 1] = type(x) == "number" and fmt(x) or tostring(x)
      end
    end
    return lines
  end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, k in ipairs(keys) do
    if #lines >= n then break end
    local x = v[k]
    lines[#lines + 1] = tostring(k) .. ": " .. (type(x) == "number" and fmt(x) or (type(x) == "table" and "{..}" or tostring(x)))
  end
  if #lines == 0 then lines[1] = "{}" end
  return lines
end

local function sampleCustom(w)
  if not w.method then return { err = "no method" } end
  local r = table.pack(pcall(peripheral.call, w.periph, w.method, table.unpack(parseArgs(w.args))))
  if not r[1] then return { err = tostring(r[2]) } end
  local v = r[2]
  return { value = v, hist = tonumber(v) }
end

-- online / working (a task running) / low fuel / AI (task started by Claude: status.by.who == "claude")
local function sampleDrones()
  local d = { total = 0, online = 0, working = 0, low = 0, offline = 0, ai = 0 }
  for _, s in pairs(type(WardenOS.drones) == "table" and WardenOS.drones or {}) do
    if type(s) == "table" then
      d.total = d.total + 1
      local on = type(s.seen) == "number" and os.clock() - s.seen < 10
      if on then d.online = d.online + 1 else d.offline = d.offline + 1 end
      local busy = s.state == "working" or (s.task ~= nil and s.task ~= "idle" and s.task ~= "manual")
      if on and busy then d.working = d.working + 1 end
      if on and type(s.by) == "table" and s.by.who == "claude" then d.ai = d.ai + 1 end
      if type(s.fuel) == "number" and s.fuel < 200 then d.low = d.low + 1 end
    end
  end
  d.hist = d.online
  return d
end

local mapLib
local function sampleMap()
  if mapLib == nil then
    local ok, m = pcall(dofile, "/os/lib/map.lua")
    mapLib = ok and type(m) == "table" and m or false
  end
  if not mapLib then return { err = "map library missing" } end
  local d = {}
  local ok, n = pcall(mapLib.count)
  d.blocks = ok and tonumber(n) or 0
  d.cap = tonumber(mapLib.CAP)
  d.full = mapLib.full == true or (d.cap and d.blocks >= d.cap)
  local okp, p = pcall(mapLib.protected)
  d.areas = okp and type(p) == "table" and type(p.boxes) == "table" and #p.boxes or 0
  if d.cap and d.cap > 0 then d.frac = d.blocks / d.cap end
  d.hist = d.blocks
  return d
end

local function sampleComputer()
  local free = fs.getFreeSpace("/")
  local okc, cap = pcall(function() return fs.getCapacity and fs.getCapacity("/") end)
  local d = { uptime = os.clock(), free = free, day = os.day(), time = os.time() }
  if okc and type(cap) == "number" and cap > 0 then d.cap = cap d.frac = (cap - free) / cap end
  return d
end

local SAMPLE = {
  energy = sampleEnergy, fluid = sampleFluid, inventory = sampleInventory, create = sampleCreate,
  storage = sampleStorage, redstone = sampleRedstone, custom = sampleCustom,
  drones = sampleDrones, map = sampleMap, computer = sampleComputer, clock = function() return {} end,
}

local function sample(w)
  if w.periph and not present(w.periph) then return { missing = true } end
  local f = SAMPLE[w.kind]
  if not f then return { err = "unknown kind " .. tostring(w.kind) } end
  local ok, d = pcall(f, w)
  if not ok then return { err = tostring(d) } end
  return type(d) == "table" and d or { err = "no data" }
end

---------------------------------------------------------------- config
local function loadCfg()
  local widgets = {}
  if fs.exists(CFG) then
    local f = fs.open(CFG, "r")
    if f then
      local d = textutils.unserialize(f.readAll() or "")
      f.close()
      if type(d) == "table" and type(d.widgets) == "table" then
        for _, w in ipairs(d.widgets) do
          if type(w) == "table" and KINDS[w.kind] then widgets[#widgets + 1] = w end
        end
      end
    end
  end
  return widgets
end
local function saveCfg(widgets)
  local out = {}
  for i, w in ipairs(widgets) do
    out[i] = { kind = w.kind, label = w.label, periph = w.periph, side = w.side, method = w.method, args = w.args }
  end
  local f = fs.open(CFG, "w")
  if f then
    f.write(textutils.serialize({ widgets = out }))
    f.close()
  end
end

return {
  name = "Dashboard", short = "Dash", icon = "[=]", color = colors.lime, order = 5,
  w = 50, h = 20,
  main = function()
    local T = WardenOS.theme
    local widgets = loadCfg()
    local data, hist = {}, {}                     -- [widget] = latest sample / list of numbers
    local view = "grid"                           -- grid | pick | kind | side | method | input
    local edit = false
    local scroll, maxScroll = 0, 0
    local listScroll = 0
    local pending                                 -- widget being added
    local input                                   -- { prompt, text, done = fn(text) }
    local zones = {}
    local W, H = term.getSize()
    local msg = ""

    local function save() saveCfg(widgets) end
    local function refresh(w)
      local d = sample(w)
      data[w] = d
      local hv = tonumber(d.hist)
      if hv then
        local h = hist[w] or {}
        h[#h + 1] = hv
        while #h > HIST do table.remove(h, 1) end
        hist[w] = h
      end
    end
    local function refreshAll() for _, w in ipairs(widgets) do refresh(w) end end

    ------------------------------------------------ drawing helpers (clipped to the view)
    local clipTop, clipBottom = 1, H
    local function put(x, y, s, fg, bg)
      if y < clipTop or y > clipBottom or x > W then return end
      s = tostring(s)
      if x < 1 then s = s:sub(2 - x) x = 1 end
      s = s:sub(1, W - x + 1)
      if s == "" then return end
      term.setCursorPos(x, y)
      term.setTextColor(fg or T.text)
      term.setBackgroundColor(bg or T.bg)
      term.write(s)
    end
    local function fill(x, y, w, h, bg)
      for i = 0, h - 1 do put(x, y + i, string.rep(" ", math.max(0, w)), bg, bg) end
    end
    local function zone(x, y, w, fn)
      if y >= clipTop and y <= clipBottom then zones[#zones + 1] = { x, x + w - 1, y, fn } end
    end
    local function button(x, y, label, fn, fg, bg)
      label = " " .. label .. " "
      put(x, y, label, fg or T.bg, bg or T.accent)
      zone(x, y, #label, fn)
      return x + #label + 1
    end
    local function cut(s, n)
      s = tostring(s)
      if n <= 0 then return "" end
      if #s > n then return s:sub(1, math.max(1, n - 1)) .. "~" end
      return s
    end
    local function bar(x, y, w, frac, col)
      if w <= 0 then return end
      frac = math.max(0, math.min(1, tonumber(frac) or 0))
      local n = math.floor(w * frac + 0.5)
      put(x, y, string.rep(" ", n), col, col)
      put(x + n, y, string.rep(" ", w - n), T.bg, T.bg)
    end
    local function levelColor(frac)
      if frac > 0.9 then return T.bad elseif frac > 0.7 then return T.warn end
      return T.good
    end
    -- sparkline of the last 2*w samples in one row (teletext characters: 2 samples per cell, 3 levels)
    local function spark(x, y, w, h_, col, bg)
      if not h_ or #h_ < 2 or w <= 0 then return end
      local lo, hi = math.huge, -math.huge
      for _, v in ipairs(h_) do lo, hi = math.min(lo, v), math.max(hi, v) end
      local n = math.min(#h_, w * 2)
      local first = #h_ - n + 1
      local function lvl(v)
        if hi == lo then return 2 end
        return 1 + math.floor((v - lo) / (hi - lo) * 2 + 0.5)
      end
      local LEFT = { 16, 16 + 4, 16 + 4 + 1 }       -- bottom-up pixel bits of the left column
      local RIGHT = { 32, 32 + 8, 32 + 8 + 2 }
      local cells = math.ceil(n / 2)
      local cx = x + w - cells
      for c = 0, cells - 1 do
        local i = first + c * 2
        local mask = LEFT[lvl(h_[i])] + (h_[i + 1] and RIGHT[lvl(h_[i + 1])] or 0)
        if mask >= 32 then                        -- bottom-right pixel: draw the inverse with swapped colors
          put(cx + c, y, string.char(128 + (63 - mask)), bg, col)
        else
          put(cx + c, y, string.char(128 + mask), col, bg)
        end
      end
    end
    local function trend(h_)
      if not h_ or #h_ < 2 then return " " end
      local a, b = h_[math.max(1, #h_ - 2)], h_[#h_]
      if b > a then return "^" elseif b < a then return "v" end
      return "="
    end

    ------------------------------------------------ cards
    local function cardBody(w, x, y, cw, ch)
      local d, hs = data[w] or {}, hist[w]
      local iw = cw - 2
      local x1 = x + 1
      local P = T.panel
      if d.missing then
        put(x1, y + 1, cut("peripheral missing", iw), T.warn, P)
        put(x1, y + 2, cut(tostring(w.periph), iw), T.dim, P)
        return
      end
      if d.err then
        put(x1, y + 1, cut("error:", iw), T.bad, P)
        put(x1, y + 2, cut(d.err, iw), T.dim, P)
        return
      end
      local k = w.kind
      if k == "energy" then
        local pct = d.frac and (" " .. math.floor(d.frac * 100 + 0.5) .. "%") or ""
        if d.frac then
          bar(x1, y + 1, iw - #pct, d.frac, d.rate and T.accent or levelColor(1 - d.frac))
          put(x1 + iw - #pct, y + 1, pct, T.text, P)
        end
        local v = fmt(d.value) .. (d.max and not d.rate and (" / " .. fmt(d.max)) or "") .. " " .. d.unit
        put(x1, d.frac and y + 2 or y + 1, cut(v, iw - 2), T.text, P)
        put(x + cw - 2, d.frac and y + 2 or y + 1, trend(hs), T.accent, P)
        spark(x1, y + 3, iw, hs, T.accent, P)
      elseif k == "fluid" then
        local rows = ch - 1
        if #d.tanks == 0 then put(x1, y + 1, "empty", T.dim, P) end
        for i, tk in ipairs(d.tanks) do
          if i > rows then break end
          local ry = y + i
          local name = tk.amount > 0 and shortName(tk.name) or "empty"
          local amt = fluidAmount(tk.amount)
          if tk.cap and tk.cap > 0 then
            local frac = tk.amount / tk.cap
            local pct = " " .. math.floor(frac * 100 + 0.5) .. "%"
            local nw = math.max(0, math.floor(iw / 2))
            put(x1, ry, cut(name, nw - 1), T.text, P)
            bar(x1 + nw, ry, iw - nw - #pct, frac, T.accent)
            put(x1 + iw - #pct, ry, pct, T.text, P)
          else
            put(x1, ry, cut(name, iw - #amt - 1), T.text, P)
            put(x1 + iw - #amt, ry, amt, T.dim, P)
          end
        end
        if #d.tanks == 1 and rows >= 2 then
          local tk = d.tanks[1]
          put(x1, y + 2, cut(fluidAmount(tk.amount) .. (tk.cap and (" / " .. fluidAmount(tk.cap)) or ""), iw), T.dim, P)
          spark(x1, y + 3, iw, hs, T.accent, P)
        end
      elseif k == "inventory" then
        local slots = d.size and (d.used .. "/" .. d.size) or (d.used .. " used")
        local pct = d.frac and (" " .. math.floor(d.frac * 100 + 0.5) .. "%") or ""
        local right = " " .. slots .. pct
        if d.frac then bar(x1, y + 1, iw - #right, d.frac, levelColor(d.frac)) end
        put(x1 + math.max(0, iw - #right), y + 1, cut(right, iw), T.text, P)
        for i = 1, 3 do
          local it = d.top[i]
          if it and y + 1 + i < y + ch then
            local c = fmt(it.count)
            put(x1, y + 1 + i, cut(shortName(it.name), iw - #c - 1), T.dim, P)
            put(x1 + iw - #c, y + 1 + i, c, T.text, P)
          end
        end
      elseif k == "create" then
        local ry = y + 1
        if d.stress then
          local pct = d.frac and (" " .. math.floor(d.frac * 100 + 0.5) .. "%") or ""
          if d.frac then
            bar(x1, ry, iw - #pct, d.frac, levelColor(d.frac))
            put(x1 + iw - #pct, ry, pct, d.frac > 1 and T.bad or T.text, P)
            ry = ry + 1
          end
          put(x1, ry, cut(fmt(d.stress) .. (d.cap and (" / " .. fmt(d.cap)) or "") .. " su", iw), T.text, P)
          ry = ry + 1
        end
        if d.speed then put(x1, ry, cut(fmt(d.speed) .. " RPM", iw), T.text, P) end
      elseif k == "storage" then
        local ry = y + 1
        if d.frac then
          local pct = " " .. math.floor(d.frac * 100 + 0.5) .. "%"
          bar(x1, ry, iw - #pct, d.frac, levelColor(d.frac))
          put(x1 + iw - #pct, ry, pct, T.text, P)
          ry = ry + 1
        end
        if d.types then
          put(x1, ry, cut(fmt(d.items) .. " items, " .. fmt(d.types) .. " types", iw), T.text, P)
          ry = ry + 1
        end
        if d.used and d.cap then
          put(x1, ry, cut(fmt(d.used) .. " / " .. fmt(d.cap) .. " bytes", iw), T.dim, P)
          ry = ry + 1
        end
        if d.usage or d.energy then
          local e = (d.usage and (fmt(d.usage) .. " FE/t") or "")
          if d.energy then e = e .. (e ~= "" and "  " or "") .. fmt(d.energy) .. (d.maxEnergy and ("/" .. fmt(d.maxEnergy)) or "") end
          put(x1, ry, cut(e, iw), T.dim, P)
        end
      elseif k == "redstone" then
        local s = tostring(w.side or "back") .. ": " .. d.value .. (d.value > 0 and " ON" or " off")
        put(x1, y + 1, cut(s, iw), d.value > 0 and T.good or T.dim, P)
        bar(x1 + math.min(iw, #s + 1), y + 1, iw - #s - 1, d.frac, T.bad)
      elseif k == "custom" then
        put(x1, y + 1, cut(w.method .. "(" .. (w.args or "") .. ")", iw), T.dim, P)
        local lines = describe(d.value, ch - 2)
        for i, l in ipairs(lines) do
          if i > ch - 2 then break end
          put(x1, y + 1 + i, cut(l, iw - (i == 1 and 2 or 0)), T.text, P)
        end
        if d.hist then put(x + cw - 2, y + 2, trend(hs), T.accent, P) end
      elseif k == "drones" then
        put(x1, y + 1, cut(("%d drones, %d online"):format(d.total, d.online), iw), T.text, P)
        put(x1, y + 2, cut(("%d busy, %d offline"):format(d.working, d.offline), iw), d.offline > 0 and T.warn or T.dim, P)
        put(x1, y + 3, cut(("%d low fuel, %d AI"):format(d.low, d.ai), iw), d.low > 0 and T.bad or T.dim, P)
      elseif k == "map" then
        local pct = d.frac and (" " .. math.floor(d.frac * 100 + 0.5) .. "%") or ""
        if d.frac then
          bar(x1, y + 1, iw - #pct, d.frac, levelColor(d.frac))
          put(x1 + iw - #pct, y + 1, pct, T.text, P)
        end
        put(x1, y + 2, cut(fmt(d.blocks) .. " / " .. fmt(d.cap) .. " blocks" .. (d.full and " FULL" or ""), iw), d.full and T.bad or T.text, P)
        put(x1, y + 3, cut(d.areas .. " protected areas", iw), T.dim, P)
      elseif k == "computer" then
        put(x1, y + 1, cut(("#%d %s"):format(os.getComputerID(), os.getComputerLabel() or ""), iw), T.text, P)
        local up = math.floor(d.uptime)
        put(x1, y + 2, cut(("up %dh %02dm %02ds"):format(math.floor(up / 3600), math.floor(up / 60) % 60, up % 60), iw), T.dim, P)
        put(x1, y + 3, cut(("day %d  %s"):format(d.day, textutils.formatTime(d.time, true)), iw), T.dim, P)
        if d.frac then
          local s = " " .. fmt(d.free / 1024) .. "K free"
          bar(x1, y + 4, iw - #s, d.frac, levelColor(d.frac))
          put(x1 + iw - #s, y + 4, cut(s, iw), T.text, P)
        end
      elseif k == "clock" then
        local t = os.time()
        local s = textutils.formatTime(t, true) .. "  day " .. os.day()
        put(x + math.max(1, math.floor((cw - #s) / 2)), y + 1, cut(s, iw), T.accent, P)
      end
    end

    local function drawCard(w, i, x, y, cw, ch)
      fill(x, y, cw, ch, T.panel)
      local label = w.label or KINDS[w.kind].title
      if edit then
        local bx = x + cw - 8
        put(x + 1, y, cut(label, cw - 10), T.text, T.panel)
        put(bx, y, "<", i > 1 and T.accent or T.dim, T.panel)
        zone(bx, y, 1, function()
          if i > 1 then widgets[i], widgets[i - 1] = widgets[i - 1], widgets[i] save() end
        end)
        put(bx + 2, y, ">", i < #widgets and T.accent or T.dim, T.panel)
        zone(bx + 2, y, 1, function()
          if i < #widgets then widgets[i], widgets[i + 1] = widgets[i + 1], widgets[i] save() end
        end)
        put(bx + 4, y, "r", T.warn, T.panel)
        zone(bx + 4, y, 1, function()
          input = { title = "Rename", prompt = "Label for this widget", text = label, done = function(t)
            if t ~= "" then w.label = t:sub(1, 30) save() end
          end }
          view = "input"
        end)
        put(bx + 6, y, "x", T.bad, T.panel)
        zone(bx + 6, y, 1, function()
          table.remove(widgets, i)
          data[w], hist[w] = nil, nil
          save()
          msg = "removed " .. label
        end)
      else
        local badge = data[w] and not data[w].missing and data[w].badge
        if badge and #badge + 6 <= cw - 2 then
          put(x + cw - 1 - #badge, y, badge, T.text, T.panel)
          put(x + 1, y, cut(label, cw - 3 - #badge), T.dim, T.panel)
        else
          put(x + 1, y, cut(label, cw - 2), T.dim, T.panel)
        end
      end
      local ok, err = pcall(cardBody, w, x, y, cw, ch)
      if not ok then put(x + 1, y + 1, cut("draw error: " .. tostring(err), cw - 2), T.bad, T.panel) end
    end

    ------------------------------------------------ views
    local function header(title, back)
      fill(1, 1, W, 1, T.panel)
      local x = 1
      if back then
        put(1, 1, " < ", T.accent, T.panel)
        zone(1, 1, 3, back)
        x = 4
      end
      put(x + 1, 1, cut(title, W - x - 1), T.text, T.panel)
    end

    local function drawGrid()
      fill(1, 1, W, 1, T.panel)
      put(2, 1, "Dashboard", T.text, T.panel)
      local bx = W - 13
      if W >= 26 then
        button(bx, 1, "+ add", function() view, listScroll = "pick", 0 end, T.bg, T.accent)
        button(bx + 8, 1, edit and "done" or "edit", function() edit = not edit end,
          edit and T.bg or T.text, edit and T.warn or T.panel)
      else
        button(W - 4, 1, "+", function() view, listScroll = "pick", 0 end, T.bg, T.accent)
        button(W - 2, 1, "e", function() edit = not edit end, T.text, edit and T.warn or T.panel)
      end
      if #widgets == 0 then
        put(2, 3, "No widgets yet.", T.text)
        put(2, 4, cut("Tap '+ add' to show energy, fluids,", W - 2), T.dim)
        put(2, 5, cut("items, Create, ME/RS storage, redstone", W - 2), T.dim)
        put(2, 6, cut("or any peripheral method.", W - 2), T.dim)
        return
      end
      local cols = math.max(1, math.min(4, math.floor((W + 1) / 22)))
      local cw = math.floor((W - (cols + 1)) / cols)
      local x0 = math.floor((W - (cols * cw + (cols - 1))) / 2) + 1
      -- rows of cards; a row is as high as its tallest card
      local y, rowH = 0, 0
      local placed = {}
      for i, w in ipairs(widgets) do
        local c = (i - 1) % cols
        if c == 0 then y = y + rowH + (i > 1 and 1 or 0) rowH = 0 end
        local ch = KINDS[w.kind].h
        if w.kind == "fluid" and data[w] and type(data[w].tanks) == "table" then
          ch = math.max(3, math.min(5, #data[w].tanks + 1))
          if #data[w].tanks == 1 then ch = 4 end
        end
        rowH = math.max(rowH, ch)
        placed[i] = { x = x0 + c * (cw + 1), y = y, row = y, ch = ch }
      end
      for i = 1, #widgets do                      -- same height across a row
        local p = placed[i]
        local h = 0
        for j = 1, #widgets do if placed[j].row == p.row then h = math.max(h, placed[j].ch) end end
        p.ch = h
      end
      local contentH = y + rowH
      local viewH = H - 2                          -- rows 3..H
      maxScroll = math.max(0, contentH - viewH)
      scroll = math.max(0, math.min(scroll, maxScroll))
      clipTop, clipBottom = 3, H
      for i, w in ipairs(widgets) do
        local p = placed[i]
        local sy = 3 + p.y - scroll
        if sy + p.ch - 1 >= 3 and sy <= H then drawCard(w, i, p.x, sy, cw, p.ch) end
      end
      clipTop, clipBottom = 1, H
      if maxScroll > 0 then
        put(W, 3, "^", scroll > 0 and T.accent or T.dim, T.bg)
        zone(W, 3, 1, function() scroll = math.max(0, scroll - viewH + 1) end)
        put(W, H, "v", scroll < maxScroll and T.accent or T.dim, T.bg)
        zone(W, H, 1, function() scroll = math.min(maxScroll, scroll + viewH - 1) end)
      end
      if msg ~= "" then put(2, 2, cut(msg, W - 3), T.warn) end
    end

    -- a scrollable list of choices: items { label, sub, fn, color }
    local function choices(y, items)
      local rows = H - y + 1
      local top = math.max(0, #items - rows)
      listScroll = math.max(0, math.min(listScroll, top))
      for i = 1, rows do
        local it = items[listScroll + i]
        if not it then break end
        local ry = y + i - 1
        fill(1, ry, W, 1, (i % 2 == 0) and T.bg or T.panel)
        local bg = (i % 2 == 0) and T.bg or T.panel
        put(2, ry, cut(it.label, math.max(4, W - 3 - (it.sub and math.min(#it.sub, 18) + 1 or 0))), it.color or T.text, bg)
        if it.sub then
          local s = cut(it.sub, 18)
          put(W - #s, ry, s, T.dim, bg)
        end
        zone(1, ry, W - 1, it.fn)
      end
      if top > 0 then
        put(W, y, "^", T.accent, T.panel)
        zone(W, y, 1, function() listScroll = math.max(0, listScroll - rows) end)
        put(W, H, "v", T.accent, T.panel)
        zone(W, H, 1, function() listScroll = math.min(top, listScroll + rows) end)
      end
    end

    local function finishAdd()
      local w = pending
      pending = nil
      widgets[#widgets + 1] = w
      save()
      refresh(w)
      view, listScroll, msg = "grid", 0, "added " .. (w.label or w.kind)
      -- scroll to the new card
      scroll = 1e9
    end

    local function drawPick()
      header("Add a widget: pick a source", function() view, pending = "grid", nil end)
      local items = {}
      for _, k in ipairs({ "drones", "map", "computer", "clock" }) do
        items[#items + 1] = { label = KINDS[k].title, sub = "built-in", color = T.accent, fn = function()
          pending = { kind = k, label = KINDS[k].title }
          finishAdd()
        end }
      end
      if redstone then
        items[#items + 1] = { label = "Redstone (this computer)", sub = "built-in", color = T.accent, fn = function()
          pending = { kind = "redstone", label = "Redstone" }
          view, listScroll = "side", 0
        end }
      end
      local okn, names = pcall(peripheral.getNames)
      names = okn and type(names) == "table" and names or {}
      table.sort(names)
      for _, n in ipairs(names) do
        local types = typesOf(n)
        if types[1] ~= "monitor" and types[1] ~= "modem" then
          items[#items + 1] = { label = n, sub = types[1], fn = function()
            pending = { periph = n, label = n }
            view, listScroll = "kind", 0
          end }
        end
      end
      choices(2, items)
    end

    local function drawKind()
      header("Widget for " .. pending.periph, function() view, listScroll = "pick", 0 end)
      local kinds = detect(pending.periph)
      local items = {}
      for i, k in ipairs(kinds) do
        local label = (i == 1 and k ~= "custom") and ("* " .. KINDS[k].title) or ("  " .. KINDS[k].title)
        items[#items + 1] = { label = label, sub = (i == 1 and k ~= "custom") and "suggested" or nil,
          color = (i == 1 and k ~= "custom") and T.accent or T.text, fn = function()
          pending.kind = k
          if k == "redstone" then view, listScroll = "side", 0
          elseif k == "custom" then view, listScroll = "method", 0
          else finishAdd() end
        end }
      end
      choices(2, items)
    end

    local SIDES = { "top", "bottom", "left", "right", "front", "back" }
    local function drawSide()
      header("Redstone: which side?", function() view, listScroll = pending.periph and "kind" or "pick", 0 end)
      local items = {}
      for _, s in ipairs(SIDES) do
        items[#items + 1] = { label = s, fn = function()
          pending.side = s
          pending.label = (pending.periph and pending.label or "Redstone") .. " " .. s
          finishAdd()
        end }
      end
      choices(2, items)
    end

    local function drawMethod()
      header("Method of " .. pending.periph, function() view, listScroll = "kind", 0 end)
      local _, list = methodsOf(pending.periph)
      local sorted = {}
      for _, m in ipairs(list) do sorted[#sorted + 1] = m end
      table.sort(sorted)
      local items = {}
      for _, m in ipairs(sorted) do
        items[#items + 1] = { label = m, fn = function()
          pending.method = m
          pending.label = m
          input = { prompt = "Arguments for " .. m .. " (comma separated, empty = none)", text = "", done = function(t)
            pending.args = t ~= "" and t or nil
            finishAdd()
          end, cancel = function() view = "method" end }
          view = "input"
        end }
      end
      if #items == 0 then put(2, 3, "This peripheral has no methods.", T.dim) end
      choices(2, items)
    end

    local function drawInput()
      header(input.title or "Add a widget", nil)
      put(2, 3, cut(input.prompt, W - 2), T.dim)
      fill(2, 5, W - 2, 1, T.panel)
      local shown = input.text
      if #shown > W - 5 then shown = shown:sub(-(W - 5)) end
      put(2, 5, "> " .. shown, T.text, T.panel)
      local x = button(2, 7, "ok", function()
        local i = input
        input = nil
        view = "grid"
        i.done(i.text)
      end)
      button(x, 7, "cancel", function()
        local i = input
        input = nil
        view = "grid"
        if i.cancel then i.cancel() else pending = nil end
      end, T.text, T.panel)
      put(2, 9, cut("Type, then Enter.", W - 2), T.dim)
      term.setCursorPos(math.min(W, 4 + #shown), 5)
    end

    local VIEWS = { grid = drawGrid, pick = drawPick, kind = drawKind, side = drawSide, method = drawMethod, input = drawInput }

    local function draw()
      W, H = term.getSize()
      clipTop, clipBottom = 1, H
      zones = {}
      fill(1, 1, W, H, T.bg)
      local ok, err = pcall(VIEWS[view] or drawGrid)
      if not ok then
        put(2, 3, cut("error: " .. tostring(err), W - 2), T.bad)
        view = "grid"
      end
    end

    local function render()
      local parent = term.current()
      local w, h = parent.getSize()
      local buf = window.create(parent, 1, 1, w, h, false)
      term.redirect(buf)
      draw()
      term.redirect(parent)
      buf.setVisible(true)
      parent.setCursorBlink(view == "input")
      if view == "input" then
        local cx, cy = buf.getCursorPos()
        parent.setCursorPos(cx, cy)
      end
    end

    ------------------------------------------------ loop
    refreshAll()
    local timer = os.startTimer(2)
    render()
    while true do
      local e, a, x, y = os.pullEvent()
      local dirty = false
      if e == "timer" and a == timer then
        timer = os.startTimer(2)
        if view == "grid" then refreshAll() dirty = true end
      elseif e == "mouse_click" then
        msg = ""
        for _, z in ipairs(zones) do
          if y == z[3] and x >= z[1] and x <= z[2] then z[4]() break end
        end
        dirty = true
      elseif e == "mouse_scroll" then
        if view == "grid" then scroll = math.max(0, math.min(maxScroll, scroll + a))
        else listScroll = math.max(0, listScroll + a) end
        dirty = true
      elseif e == "char" and view == "input" then
        if #input.text < 120 then input.text = input.text .. a end
        dirty = true
      elseif e == "paste" and view == "input" then
        input.text = (input.text .. tostring(a)):sub(1, 120)
        dirty = true
      elseif e == "key" then
        if view == "input" then
          if a == keys.backspace then input.text = input.text:sub(1, -2)
          elseif a == keys.enter then
            local i = input
            input = nil
            view = "grid"
            i.done(i.text)
          end
        elseif a == keys.up then if view == "grid" then scroll = math.max(0, scroll - 1) else listScroll = math.max(0, listScroll - 1) end
        elseif a == keys.down then if view == "grid" then scroll = math.min(maxScroll, scroll + 1) else listScroll = listScroll + 1 end
        end
        dirty = true
      elseif e == "peripheral" or e == "peripheral_detach" then
        refreshAll()
        dirty = true
      elseif e == "theme_changed" or e == "term_resize" then
        dirty = true
      end
      if dirty then render() end
    end
  end,
}
