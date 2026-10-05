-- ME / RS storage networks through an Advanced Peripherals bridge (Applied Energistics 2 "meBridge",
-- Refined Storage "rsBridge"): stock, search, autocrafting with verification, export / import.
--
-- The bridge API changed between Advanced Peripherals versions, so every call goes through a compatibility
-- layer that looks at peripheral.getMethods() and uses whichever name exists:
--   items        listItems (0.7)            | getItems (0.8+)
--   craftables   listCraftableItems         | getCraftableItems
--   is craftable isItemCraftable            | isCraftable
--   is crafting  isItemCrafting             | isCrafting
--   craft        craftItem(filter[, cpu]) -> true | false/nil, "NOT_CRAFTABLE" ... (0.7) | a craft job object (0.8+)
--   export       exportItem(filter, direction) + exportItemToPeripheral(filter, name) (0.7) | exportItem(filter, target)
--   import       importItem / importItemFromPeripheral, same pattern
--   energy       getStoredEnergy | getEnergyStorage, getEnergyCapacity | getMaxEnergyStorage, getEnergyUsage
--   cells        getUsedItemStorage, getTotalItemStorage, getAvailableItemStorage
--   cpus / jobs  getCraftingCPUs, getCraftingTasks (when present)
-- Items come back as { name, amount | count, displayName, isCraftable, ... }; this module normalises them to
-- { name = "minecraft:iron_ingot", display = "Iron Ingot", count = 123, craftable = true | false | nil }.
-- Every peripheral call is pcall-wrapped: nothing here throws.
--
--   local ME = dofile("/os/lib/me.lua")
--   ME.find()                 { { name, kind = "me" | "rs", methods = { [m] = true } }, ... } (AE first)
--   local b, err = ME.open(name)   the named bridge, or the first one
--   b:items()  b:craftables()  b:search(query, limit)  b:resolve(query, wantCraftable)
--   b:count(id)  b:isCraftable(id)  b:isCrafting(id)  b:cpus()  b:tasks()  b:energy()  b:storage()  b:status()
--   b:craft(query, count, { wait = seconds, force = true })  -> result (see craft below)
--   b:ensure(query, count, opts)   craft the difference when stock < count
--   b:export(query, count, target) / b:import(query, count, source)  target: direction or peripheral name
-- Waiting (craft confirmation) uses os.startTimer + os.pullEvent: call it from a coroutine that gets events.
local ME = {}

local DIRS = { up = true, down = true, north = true, south = true, east = true, west = true,
               top = true, bottom = true, left = true, right = true, front = true, back = true }
ME.DIRS = DIRS

local function pretty(id)                       -- "minecraft:iron_ingot" -> "Iron Ingot"
  local s = tostring(id or "?"):gsub("^[%w_%.%-]+:", ""):gsub("_", " ")
  return (s:gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b end))
end
ME.pretty = pretty

local function clean(s)                         -- display names: printable ASCII, no [brackets]
  s = type(s) == "string" and s:gsub("^%s*%[", ""):gsub("%]%s*$", "") or ""
  return (s:gsub("[%c]", ""):gsub("[^\32-\126]", "?"))
end

---------------------------------------------------------------- detection
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

-- { name, kind, methods } or nil
function ME.classify(name)
  local tl = table.concat(typesOf(name), " "):lower()
  local m = methodsOf(name)
  local rs = tl:find("rsbridge") or tl:find("rs_bridge")
  local me = tl:find("mebridge") or tl:find("me_bridge")
  if not (rs or me) then
    -- an unknown bridge-like block: items + autocrafting methods
    if not ((m.listItems or m.getItems) and m.craftItem and not m.list) then return nil end
  end
  return { name = name, kind = rs and "rs" or "me", methods = m }
end

function ME.find()
  local out = {}
  local ok, names = pcall(peripheral.getNames)
  if not ok or type(names) ~= "table" then return out end
  for _, n in ipairs(names) do
    local okc, b = pcall(ME.classify, n)
    if okc and b then out[#out + 1] = b end
  end
  table.sort(out, function(a, b)
    if a.kind ~= b.kind then return a.kind == "me" end
    return a.name < b.name
  end)
  return out
end

---------------------------------------------------------------- normalising
local function num(v) return tonumber(v) end

local function norm(it)
  if type(it) ~= "table" or type(it.name) ~= "string" then return nil end
  local c = tonumber(it.amount) or tonumber(it.count) or tonumber(it.size) or 0
  local craftable = it.isCraftable
  if craftable ~= nil then craftable = craftable == true end
  local d = clean(it.displayName or it.display_name or it.label)
  return { name = it.name, display = d ~= "" and d:sub(1, 48) or pretty(it.name), count = math.floor(c),
           craftable = craftable, fingerprint = it.fingerprint }
end
ME.norm = norm

-- list -> merged by item id (NBT variants add up), keeps order of first appearance
local function merge(list)
  local by, out = {}, {}
  for _, raw in pairs(type(list) == "table" and list or {}) do
    local it = norm(raw)
    if it then
      local e = by[it.name]
      if e then
        e.count = e.count + it.count
        if it.craftable then e.craftable = true end
      else
        by[it.name] = it
        out[#out + 1] = it
      end
    end
  end
  return out, by
end

---------------------------------------------------------------- one bridge
local B = {}
B.__index = B

function ME.open(name)
  local all = ME.find()
  if #all == 0 then
    return nil, "No ME or RS bridge found. An Advanced Peripherals ME Bridge (or RS Bridge) must touch this computer or be on its wired modem network."
  end
  if name and name ~= "" then
    for _, b in ipairs(all) do
      if b.name == name then return setmetatable(b, B) end
    end
    local names = {}
    for _, b in ipairs(all) do names[#names + 1] = b.name end
    return nil, ("No bridge named %q. Bridges: %s"):format(tostring(name), table.concat(names, ", "))
  end
  return setmetatable(all[1], B)
end

-- first method name that exists (or nil)
function B:has(...)
  for i = 1, select("#", ...) do
    local m = select(i, ...)
    if self.methods[m] then return m end
  end
end

-- call a method: value | nil, error text. Bridges answer nil/false + "NOT_CONNECTED" etc. on failure.
function B:call(method, ...)
  if not method then return nil, "not supported by this bridge" end
  local r = table.pack(pcall(peripheral.call, self.name, method, ...))
  if not r[1] then return nil, tostring(r[2]) end
  if r[2] == nil and type(r[3]) == "string" then return nil, r[3] end
  return r[2], r[3]
end

function B:filter(id, count)
  local f = { name = id }
  if count then f.count = count end
  return f
end

function B:items()
  local l, err = self:call(self:has("listItems", "getItems"))
  if type(l) ~= "table" then return nil, err or "items not readable" end
  return (merge(l))
end

function B:craftables()
  local m = self:has("listCraftableItems", "getCraftableItems")
  if not m then return nil, "this bridge can't list craftable items" end
  local l, err = self:call(m)
  if type(l) ~= "table" then return nil, err or "craftable items not readable" end
  local out = merge(l)
  for _, it in ipairs(out) do it.craftable = true end
  return out
end

-- every known item: stock merged with craftables (craftable flag set where known)
function B:catalog()
  local items, err = self:items()
  local craft = self:craftables()
  local by, out = {}, {}
  for _, it in ipairs(items or {}) do by[it.name] = it out[#out + 1] = it end
  if craft then
    for _, it in ipairs(out) do if it.craftable == nil then it.craftable = false end end
    for _, c in ipairs(craft) do
      local e = by[c.name]
      if e then e.craftable = true
      else
        c.count = 0                          -- craftable entries report the stock; none in the item list
        by[c.name] = c
        out[#out + 1] = c
      end
    end
  end
  if not items and not craft then return nil, err end
  return out, by, craft ~= nil
end

---------------------------------------------------------------- search
local function words(s)
  local t = {}
  for w in tostring(s):lower():gsub("[_:%-%.]", " "):gmatch("%S+") do t[#t + 1] = w end
  return t
end
local function singular(w)
  if #w > 3 and w:sub(-3) == "ies" then return w:sub(1, -4) .. "y" end
  if #w > 3 and (w:sub(-3):match("^[sxz]es$") or w:sub(-4):match("^[cs]hes$")) then return w:sub(1, -3) end
  if #w > 2 and w:sub(-1) == "s" and w:sub(-2, -2) ~= "s" then return w:sub(1, -2) end
  return w
end

-- 0 = no match
local function score(it, q)
  local ql = q:lower():gsub("^%s+", ""):gsub("%s+$", "")
  if ql == "" then return 1 end
  local id, path, disp = it.name:lower(), it.name:lower():gsub("^[^:]+:", ""), it.display:lower()
  local qs = ql:gsub("%s+", "_")
  if id == ql then return 100 end
  if path == qs or disp == ql then return 95 end
  local qw = words(ql)
  for i, w in ipairs(qw) do qw[i] = singular(w) end
  local sq = table.concat(qw, " ")
  local dw = words(disp)
  for i, w in ipairs(dw) do dw[i] = singular(w) end
  local sd = table.concat(dw, " ")
  if sd == sq or path == sq:gsub(" ", "_") then return 90 end
  if disp:sub(1, #ql) == ql then return 72 end
  if path:sub(1, #qs) == qs then return 70 end
  if disp:find(ql, 1, true) or path:find(qs, 1, true) then return 60 end
  local hay = sd .. " " .. table.concat(words(id), " ")
  local all = true
  for _, w in ipairs(qw) do if not hay:find(w, 1, true) then all = false break end end
  if all then return 40 end
  return 0
end
ME.score = score

-- { {item, score}, ... } best first; nil, err when the bridge can't be read
function B:search(query, limit)
  local cat, err = self:catalog()
  if not cat then return nil, err end
  local hits = {}
  for _, it in ipairs(cat) do
    local s = score(it, tostring(query or ""))
    if s > 0 then hits[#hits + 1] = { item = it, score = s } end
  end
  table.sort(hits, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    if (a.item.craftable == true) ~= (b.item.craftable == true) then return a.item.craftable == true end
    if a.item.count ~= b.item.count then return a.item.count > b.item.count end
    return a.item.name < b.item.name
  end)
  local out = {}
  for i = 1, math.min(#hits, limit or 20) do out[i] = hits[i] end
  return out, #hits
end

-- one item for a query: item | nil, why, candidates
function B:resolve(query, wantCraftable)
  query = tostring(query or "")
  if not query:match("%S") then return nil, "no item given" end
  local hits, err = self:search(query, 50)
  if not hits then return nil, err end
  if #hits == 0 then
    if query:find(":") then                    -- an exact id that is neither stored nor craftable
      return { name = query, display = pretty(query), count = 0, craftable = false, unknown = true }
    end
    return nil, ("Nothing matching %q is stored in or craftable by the system."):format(query)
  end
  local best = hits[1].score
  local top = {}
  for _, h in ipairs(hits) do if h.score == best then top[#top + 1] = h.item end end
  if #top == 1 or best >= 95 then return top[1] end
  if wantCraftable then
    local c = {}
    for _, it in ipairs(top) do if it.craftable then c[#c + 1] = it end end
    if #c == 1 then return c[1] end
  end
  local names = {}
  for i = 1, math.min(#top, 8) do names[i] = ("%s (%s)"):format(top[i].display, top[i].name) end
  return nil, ("%q matches several items: %s. Say which (use the id)."):format(query, table.concat(names, ", ")), top
end

---------------------------------------------------------------- single facts
function B:item(id)
  if self:has("getItem") then
    local it = self:call("getItem", self:filter(id))
    if type(it) == "table" then
      local n = norm(it)
      if n then return n end
    end
  end
  local cat = self:catalog()
  for _, it in ipairs(cat or {}) do if it.name == id then return it end end
  return nil
end

function B:count(id)                           -- the whole list: NBT variants of an item add up
  local m = self:has("listItems", "getItems")
  if m then
    local l = self:call(m)
    if type(l) == "table" then
      local _, by = merge(l)
      return by[id] and by[id].count or 0
    end
  end
  local it = self:item(id)
  return it and it.count or nil
end

-- true | false | nil (unknown)
function B:isCraftable(id)
  local m = self:has("isItemCraftable", "isCraftable")
  if m then
    local v = self:call(m, self:filter(id))
    if type(v) == "boolean" then return v end
  end
  local craft = self:craftables()
  if craft then
    for _, it in ipairs(craft) do if it.name == id then return true end end
    return false
  end
  local it = self:item(id)
  if it and it.craftable ~= nil then return it.craftable end
  return nil
end

function B:isCrafting(id)
  local m = self:has("isItemCrafting", "isCrafting")
  if m then
    local v = self:call(m, self:filter(id))
    if type(v) == "boolean" then return v end
  end
  for _, t in ipairs(self:tasks() or {}) do
    if t.item == id and not t.done then return true end
  end
  for _, c in ipairs(self:cpus() or {}) do
    if c.busy and c.item == id then return true end
  end
  return nil
end

local function jobItem(j)
  if type(j) ~= "table" then return nil end
  local s = j.storage or j.resource or j.item or j.output
  if type(s) == "table" then return s.name, tonumber(s.amount) or tonumber(s.count) end
  if type(s) == "string" then return s, tonumber(j.amount) or tonumber(j.count) end
end

-- { { name, busy, storage, coProcessors, item, amount, progress, total }, ... } | nil (no CPU info)
function B:cpus()
  local m = self:has("getCraftingCPUs")
  if not m then return nil end
  local l, err = self:call(m)
  if type(l) ~= "table" then return nil, err end
  local out = {}
  for i, c in ipairs(l) do
    if type(c) == "table" then
      local job = c.craftingJob or c.job
      local item, amount = jobItem(job)
      out[#out + 1] = { name = tostring(c.name or ("CPU " .. i)), busy = c.isBusy == true or c.busy == true,
                        storage = num(c.storage), coProcessors = num(c.coProcessors), item = item, amount = amount,
                        progress = type(job) == "table" and num(job.progress) or nil,
                        total = type(job) == "table" and num(job.totalItem or job.totalItems) or nil }
    end
  end
  return out
end

-- running jobs: { { item, amount, progress, total, done }, ... } | nil
function B:tasks()
  local m = self:has("getCraftingTasks", "getCraftingJobs")
  if not m then return nil end
  local l = self:call(m)
  if type(l) ~= "table" then return nil end
  local out = {}
  for _, t in pairs(l) do
    if type(t) == "table" then
      local item, amount = jobItem(t)
      out[#out + 1] = { item = item, amount = amount or num(t.quantity), progress = num(t.progress),
                        total = num(t.totalItem or t.totalItems), done = t.isDone == true or t.done == true }
    end
  end
  return out
end

function B:energy()
  local e = {}
  e.stored = num((self:call(self:has("getStoredEnergy", "getEnergyStorage"))))
  e.max = num((self:call(self:has("getEnergyCapacity", "getMaxEnergyStorage"))))
  e.usage = num((self:call(self:has("getEnergyUsage", "getAvgPowerUsage"))))
  e.unit = self.kind == "me" and "AE" or "FE"
  return e
end

function B:storage()
  local s = {}
  s.used = num((self:call(self:has("getUsedItemStorage"))))
  s.total = num((self:call(self:has("getTotalItemStorage", "getMaxItemDiskStorage"))))
  s.available = num((self:call(self:has("getAvailableItemStorage"))))
  return s
end

-- connected to a working network? true | false | nil (unknown)
function B:connected()
  local m = self:has("isConnected", "isOnline")
  if not m then return nil end
  local v = self:call(m)
  if type(v) == "boolean" then return v end
end

---------------------------------------------------------------- crafting
-- craft job objects (Advanced Peripherals 0.8+): tables of functions, called without self
local function jcall(job, ...)
  for i = 1, select("#", ...) do
    local f = job[select(i, ...)]
    if type(f) == "function" then
      local ok, v = pcall(f)
      if ok then return v end
    end
  end
end
local function jobState(job)
  if type(job) ~= "table" then return nil end
  local failed = jcall(job, "isCalculationNotSuccessful", "hasErrorOccurred", "isFailed")
  local msg = jcall(job, "getDebugMessage", "getError", "getErrorMessage")
  if failed == true then return "failed", msg end
  if jcall(job, "isCanceled", "isCancelled") == true then return "failed", msg or "the job was canceled" end
  if jcall(job, "isDone", "isFinished") == true then return "done" end
  if jcall(job, "isCraftingStarted", "isStarted") == true then return "crafting" end
  return nil, msg
end

local ERRORS = {
  NOT_CRAFTABLE = "not_craftable", NOT_CONNECTED = "not_connected", EMPTY_FILTER = "error",
  NOT_FOUND = "not_craftable",
}

local function busyCount(cpus)
  local n = 0
  for _, c in ipairs(cpus or {}) do if c.busy then n = n + 1 end end
  return n
end

-- craft count of query. Result:
-- { ok = bool, status = "crafting" | "done" | "started" | "already_crafting" | "not_craftable" | "not_found"
--   | "no_cpu" | "missing" | "failed" | "not_connected" | "error", item = id, display, count, before, after,
--   message = text for the player / Claude }
--   crafting: a job is confirmed running; done: the items arrived; started: the bridge accepted it, no job seen
--   within the wait (AE2 drops jobs with missing ingredients without telling the bridge)
function B:craft(query, count, opts)
  opts = opts or {}
  count = math.floor(tonumber(count) or 1)
  if count < 1 then return { ok = false, status = "error", message = "count must be at least 1" } end
  local it, why = self:resolve(query, true)
  if not it then
    return { ok = false, status = "not_found", message = why or "item not found" }
  end
  local r = { item = it.name, display = it.display, count = count }
  local function done(ok, status, msg) r.ok, r.status, r.message = ok, status, msg return r end
  if self:connected() == false then
    return done(false, "not_connected", "The bridge is not connected to a powered ME/RS network.")
  end
  r.before = self:count(it.name) or it.count or 0

  local craftable = self:isCraftable(it.name)
  if craftable == false then
    return done(false, "not_craftable", ("%s has no crafting pattern in the system: it can't be autocrafted. In stock: %d.")
      :format(it.display, r.before))
  end
  if not opts.force and self:isCrafting(it.name) == true then
    return done(true, "already_crafting", ("%s is already being crafted. In stock: %d."):format(it.display, r.before))
  end
  local cpus = self:cpus()
  if cpus then
    if #cpus == 0 and self.kind == "me" then
      return done(false, "no_cpu", "The ME system has no crafting CPU (build a Crafting Storage + Crafting Unit multiblock).")
    end
    if #cpus > 0 and busyCount(cpus) == #cpus then
      return done(false, "no_cpu", ("All %d crafting CPUs are busy; try again when one is free."):format(#cpus))
    end
  end
  local busy0 = busyCount(cpus)

  if not self.methods.craftItem then return done(false, "error", "This bridge has no craftItem method.") end
  local res, err = self:call("craftItem", self:filter(it.name, count))
  local job
  if type(res) == "table" then
    job = res
  elseif res ~= true then
    local code = type(err) == "string" and err or nil
    if code and ERRORS[code] then
      local st = ERRORS[code]
      return done(false, st, st == "not_craftable" and (it.display .. " has no crafting pattern: it can't be autocrafted.")
        or st == "not_connected" and "The bridge is not connected to a powered network." or ("craftItem failed: " .. code))
    end
    if code and code:lower():find("cpu") then return done(false, "no_cpu", code) end
    if code then return done(false, "failed", "craftItem failed: " .. code) end
    -- RS (and older AE) answer false when the calculation fails: missing ingredients or no free CPU
    return done(false, "missing", ("The system refused to craft %d %s: ingredients are missing (or no crafting CPU is free).")
      :format(count, it.display))
  end

  -- confirm: crafting event (AE2 0.7), job object (0.8+), isCrafting, a CPU becoming busy, the stock growing
  local waits = math.max(0, math.floor((tonumber(opts.wait) or 4) * 2 + 0.5))
  local eventMsg
  local function check()
    if job then
      local st, msg = jobState(job)
      if st == "failed" then return "failed", msg end
      if st == "done" then return "done" end
      if st == "crafting" then return "crafting" end
      eventMsg = msg or eventMsg
    end
    local now = self:count(it.name)
    if now then r.after = now end
    if now and now >= r.before + count then return "done" end
    if self:isCrafting(it.name) == true then return "crafting" end
    local c2 = cpus and self:cpus()
    if c2 and busyCount(c2) > busy0 then return "crafting" end
  end
  local state, msg = check()
  local i = 0
  while not state and i < waits do
    i = i + 1
    local timer = os.startTimer(0.5)
    while true do
      local e, a, b = os.pullEvent()
      if e == "timer" and a == timer then break end
      if e == "crafting" then                  -- Advanced Peripherals 0.7: (success, message)
        if a == false then state, msg = "failed", tostring(b or "crafting failed") break end
        eventMsg = type(b) == "string" and b or eventMsg
      end
    end
    if not state then state, msg = check() end
  end

  local what = ("%d %s (%s)"):format(count, it.display, it.name)
  if state == "failed" then
    local m = tostring(msg or "unknown reason")
    local st = m:lower():find("missing") and "missing" or (m:lower():find("cpu") and "no_cpu" or "failed")
    return done(false, st, ("Crafting %s failed: %s"):format(what, m))
  end
  if state == "done" then
    return done(true, "done", ("Crafted %s: now %d in stock (was %d)."):format(what, r.after or 0, r.before))
  end
  if state == "crafting" then
    return done(true, "crafting", ("Autocrafting %s: the job is running. In stock now: %d."):format(what, r.after or r.before))
  end
  return done(true, "started", ("The system accepted the request for %s, but no running job showed up yet%s. If the stock does not grow, ingredients are probably missing (AE2 drops such jobs silently): check the ingredients with me_find or the ME terminal.")
    :format(what, eventMsg and (" (" .. eventMsg .. ")") or ""))
end

-- keep at least count in stock: crafts the difference
function B:ensure(query, count, opts)
  count = math.floor(tonumber(count) or 0)
  local it, why = self:resolve(query, true)
  if not it then return { ok = false, status = "not_found", message = why } end
  local have = self:count(it.name) or it.count or 0
  if have >= count then
    return { ok = true, status = "enough", item = it.name, display = it.display, before = have, count = 0,
             message = ("%s: %d in stock, at least %d wanted: nothing to craft."):format(it.display, have, count) }
  end
  local r = self:craft(it.name, count - have, opts)
  r.message = ("%s: %d in stock, %d wanted -> craft %d. %s"):format(it.display, have, count, count - have, r.message or "")
  return r
end

---------------------------------------------------------------- moving items
-- move count of query out of the system into target (direction relative to the bridge, or a peripheral name)
-- -> moved | nil, why
function B:move(dir, query, count, target)
  local it, why = self:resolve(query)
  if not it then return nil, why end
  target = tostring(target or "")
  if target == "" then return nil, "no target: give a direction (up, down, north, ...) or a peripheral name" end
  count = math.max(1, math.floor(tonumber(count) or 1))
  local f = self:filter(it.name, count)
  local m
  local isDir = DIRS[target:lower()]
  if dir == "export" then
    m = (not isDir and self:has("exportItemToPeripheral")) or self:has("exportItem")
  else
    m = (not isDir and self:has("importItemFromPeripheral")) or self:has("importItem")
  end
  if not m then return nil, "this bridge can't " .. dir .. " items" end
  local n, err = self:call(m, f, isDir and target:lower() or target)
  if type(n) == "table" then n = n.count or n.amount end
  n = tonumber(n)
  if not n then return nil, tostring(err or (dir .. " failed")) end
  if n == 0 then
    return 0, err and tostring(err) or (dir == "export" and ("none moved: %s not in stock, or the target is full or not an inventory"):format(it.display)
      or ("none moved: no %s in the source, or the system is full"):format(it.display)), it
  end
  return n, nil, it
end

function B:export(query, count, target) return self:move("export", query, count, target) end
function B:import(query, count, source) return self:move("import", query, count, source) end

---------------------------------------------------------------- overview
function B:status()
  local s = { name = self.name, kind = self.kind, connected = self:connected(), energy = self:energy(),
              storage = self:storage(), cpus = self:cpus(), tasks = self:tasks() }
  local items = self:items()
  s.types = items and #items or nil
  if items then
    local n = 0
    for _, it in ipairs(items) do n = n + it.count end
    s.items = n
  end
  local craft = self:craftables()
  s.craftables = craft and #craft or nil
  return s
end

return ME
