#!/usr/bin/env python3
"""ME / RS bridge checks (/os/lib/me.lua + the me_* Claude tools). Run from anywhere:  python3 tests/test_me.py
(needs: pip install lupa). Exit code 1 on failure.

Fake Advanced Peripherals bridges in three API shapes:
  old  AE2 ME Bridge 0.7.x: listItems (amount), listCraftableItems, isItemCraftable/isItemCrafting, craftItem -> true
       (+ a "crafting" event; the job shows up on a CPU later, or never when ingredients are missing),
       exportItem(filter, direction) + exportItemToPeripheral, getCraftingCPUs, getEnergyStorage...
  new  ME Bridge 0.8+: getItems (count), getCraftableItems, isCraftable/isCrafting, craftItem -> craft job object,
       getCraftingTasks, exportItem(filter, direction | peripheral name), getStoredEnergy...
  rs   RS Bridge: like old, craftItem -> false when the calculation fails, starts at once otherwise
1. detection, search (display name, id, plural, fuzzy, ambiguous), counts
2. craft: craftable -> started -> confirmed (old: via the CPU / isItemCrafting, new: job object, rs: at once);
   not craftable; already crafting; missing ingredients (old: unconfirmed after the wait, new: job error,
   rs: refused); all CPUs busy; crafting event with failure
3. ensure, export (direction / peripheral name), import
4. Claude tools through /os/lib/claudetools.lua: offered (+ prompt part) only with a bridge, results, risky flags,
   approval card text, and one full round trip through the Claude app against a mocked Messages API
"""
import json, os, sys
import lupa.lua52 as lua

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
fail = []


def check(cond, msg):
    if not cond:
        fail.append(msg)
        print("FAIL", msg)


def read(rel):
    with open(os.path.join(ROOT, rel), "rb") as f:
        return f.read().decode("latin-1")


# ---------------------------------------------------------------- fake bridges (Lua)
FAKE = r"""
-- fake clock + timers: pulling an event with nothing queued fires the next timer and advances the world
CLOCK, TIMERS, QUEUE, TICKS = 0, {}, {}, 0
local tid = 100
os.clock = function() return CLOCK end
os.startTimer = function(s) tid = tid + 1 TIMERS[#TIMERS + 1] = { id = tid, at = CLOCK + (s or 0) } return tid end
os.queueEvent = function(...) QUEUE[#QUEUE + 1] = table.pack(...) end
os.pullEvent = function(filter)
  while true do
    local e = table.remove(QUEUE, 1)
    if not e then
      table.sort(TIMERS, function(a, b) return a.at < b.at end)
      local t = table.remove(TIMERS, 1)
      if not t then error("no event to wait for", 0) end
      CLOCK = math.max(CLOCK, t.at)
      TICKS = TICKS + 1
      for _, b in pairs(BRIDGES) do b.tick() end
      e = table.pack("timer", t.id)
    end
    if not filter or e[1] == filter then return table.unpack(e, 1, e.n) end
  end
end
os.pullEventRaw = os.pullEvent
sleep = function(s) local t = os.startTimer(s) repeat local _, id = os.pullEvent("timer") until id == t end

BRIDGES, CALLS = {}, {}
local DISPLAY = { ["minecraft:iron_ingot"] = "Iron Ingot", ["minecraft:torch"] = "Torch",
  ["minecraft:oak_planks"] = "Oak Planks", ["minecraft:birch_planks"] = "Birch Planks",
  ["minecraft:iron_block"] = "Block of Iron", ["minecraft:stick"] = "Stick", ["minecraft:chest"] = "Chest",
  ["minecraft:redstone"] = "Redstone Dust", ["ae2:printed_silicon"] = "Printed Silicon" }

-- shape: "old" | "new" | "rs"; opts.delay = ticks until a started job shows up; opts.cpus = n (busy = opts.busy)
function makeBridge(name, shape, opts)
  opts = opts or {}
  local B = { name = name, shape = shape, opts = opts }
  B.stock = { ["minecraft:iron_ingot"] = 64, ["minecraft:oak_planks"] = 20, ["minecraft:birch_planks"] = 5,
              ["minecraft:stick"] = 3, ["minecraft:redstone"] = 0 }
  -- patterns: true = can craft; "missing" = pattern but ingredients missing
  B.patterns = { ["minecraft:torch"] = true, ["minecraft:stick"] = true, ["minecraft:iron_block"] = "missing",
                 ["minecraft:chest"] = true }
  B.crafting = {}                                -- [id] = { left = ticks, count }
  B.cpus = {}
  for i = 1, opts.cpus or 2 do B.cpus[i] = { name = "CPU" .. i, busy = (opts.busy or 0) >= i } end
  B.exported = {}
  local countKey = shape == "new" and "count" or "amount"
  local function obj(id)
    return { name = id, [countKey] = B.stock[id] or 0, displayName = DISPLAY[id] or id, isCraftable = B.patterns[id] ~= nil,
             fingerprint = "FP" .. id, tags = {} }
  end
  local function list()
    local t = {}
    for id, n in pairs(B.stock) do if n > 0 then t[#t + 1] = obj(id) end end
    -- an NBT variant of iron ingots (counts add up)
    if (B.stock["minecraft:iron_ingot"] or 0) > 0 then local v = obj("minecraft:iron_ingot") v[countKey] = 1 t[#t + 1] = v end
    return t
  end
  local function craftables()
    local t = {}
    for id in pairs(B.patterns) do t[#t + 1] = obj(id) end
    return t
  end
  local function crafting(f) return B.crafting[f.name] ~= nil and B.crafting[f.name].running == true end
  local function freeCpu()
    for _, c in ipairs(B.cpus) do if not c.busy then return c end end
  end
  local function start(id, n)
    local job = { left = opts.delay or 2, count = n, running = false }
    B.crafting[id] = job
    return job
  end
  function B.tick()
    for id, j in pairs(B.crafting) do
      if B.patterns[id] == "missing" then
        j.failed = true
      elseif not j.running then
        j.left = j.left - 1
        if j.left <= 0 then
          local c = freeCpu()
          if c then j.running, j.cpu = true, c c.busy, c.job = true, { id = id, n = j.count } end
        end
      end
    end
  end
  local M = {}
  if shape == "new" then
    M.getItems = list
    M.getCraftableItems = craftables
    M.isCraftable = function(f) return B.patterns[f.name] ~= nil end
    M.isCrafting = crafting
    M.getStoredEnergy = function() return 5000 end
    M.getEnergyCapacity = function() return 8000 end
    M.getCraftingTasks = function()
      local t = {}
      for id, j in pairs(B.crafting) do
        if j.running then t[#t + 1] = { resource = { name = id, count = j.count }, quantity = j.count, isDone = false } end
      end
      return t
    end
    M.craftItem = function(f)
      if not B.patterns[f.name] then return nil, "NOT_CRAFTABLE" end
      local j = start(f.name, f.count or 1)
      return { getId = function() return 1 end,
               isCalculationNotSuccessful = function() return j.failed == true end,
               getDebugMessage = function() return j.failed and "Missing ingredients: 9x minecraft:iron_ingot" or "" end,
               isCraftingStarted = function() return j.running end,
               isDone = function() return false end }
    end
    M.exportItem = function(f, target)
      local have = B.stock[f.name] or 0
      local n = math.min(have, f.count or 1)
      if target ~= "up" and target ~= "minecraft:chest_3" then return 0, "Target inventory does not exist" end
      B.stock[f.name] = have - n
      B.exported[#B.exported + 1] = { f.name, n, target }
      return n
    end
    M.importItem = function(f, target) B.stock[f.name] = (B.stock[f.name] or 0) + (f.count or 1) return f.count or 1 end
  else
    M.listItems = list
    M.listCraftableItems = craftables
    M.isItemCraftable = function(f) return B.patterns[f.name] ~= nil end
    M.isItemCrafting = crafting
    M.isConnected = function() return B.offline ~= true end
    M.getItem = function(f)
      if B.stock[f.name] or B.patterns[f.name] then return obj(f.name) end
      return nil, "NOT_FOUND"
    end
    M.getEnergyStorage = function() return 1200 end
    M.getMaxEnergyStorage = function() return 1600 end
    M.getEnergyUsage = function() return 12.5 end
    M.getUsedItemStorage = function() return 4096 end
    M.getTotalItemStorage = function() return 65536 end
    if shape == "old" then
      M.getCraftingCPUs = function()
        local t = {}
        for _, c in ipairs(B.cpus) do
          t[#t + 1] = { name = c.name, isBusy = c.busy, storage = 65536, coProcessors = 1,
                        craftingJob = c.job and { storage = { name = c.job.id, amount = c.job.n }, progress = 0, totalItem = c.job.n } or nil }
        end
        return t
      end
      M.craftItem = function(f)
        if not B.patterns[f.name] then return nil, "NOT_CRAFTABLE" end
        start(f.name, f.count or 1)
        os.queueEvent("crafting", true, "Started calculation of the recipe.")
        return true
      end
    else -- rs: synchronous calculation
      M.craftItem = function(f)
        if not B.patterns[f.name] then return nil, "NOT_CRAFTABLE" end
        if B.patterns[f.name] == "missing" then return false end
        local j = start(f.name, f.count or 1)
        j.running = true
        return true
      end
    end
    M.exportItem = function(f, dir)
      if dir ~= "up" and dir ~= "down" then return 0, "Target Inventory does not exist" end
      local have = B.stock[f.name] or 0
      local n = math.min(have, f.count or 1)
      B.stock[f.name] = have - n
      B.exported[#B.exported + 1] = { f.name, n, dir }
      return n
    end
    M.exportItemToPeripheral = function(f, p)
      if p ~= "minecraft:chest_3" then return 0, "The target inventory does not exist." end
      local have = B.stock[f.name] or 0
      local n = math.min(have, f.count or 1)
      B.stock[f.name] = have - n
      B.exported[#B.exported + 1] = { f.name, n, p }
      return n
    end
    M.importItem = function(f, dir) B.stock[f.name] = (B.stock[f.name] or 0) + (f.count or 1) return f.count or 1 end
    M.importItemFromPeripheral = M.importItem
  end
  B.methods = M
  BRIDGES[name] = B
  return B
end

local TYPES = { old = "meBridge", new = "me_bridge", rs = "rsBridge" }
peripheral = {
  getNames = function()
    local t = { "left" }
    for n in pairs(BRIDGES) do t[#t + 1] = n end
    table.sort(t)
    return t
  end,
  getType = function(n)
    if n == "left" then return "minecraft:chest", "inventory" end
    local b = BRIDGES[n]
    if b then return TYPES[b.shape] end
  end,
  getMethods = function(n)
    if n == "left" then return { "list", "size", "pushItems" } end
    local b = BRIDGES[n]
    if not b then return nil end
    local t = {}
    for k in pairs(b.methods) do t[#t + 1] = k end
    table.sort(t)
    return t
  end,
  isPresent = function(n) return n == "left" or BRIDGES[n] ~= nil end,
  call = function(n, m, ...)
    local b = BRIDGES[n]
    CALLS[#CALLS + 1] = n .. "." .. tostring(m)
    if not b or not b.methods[m] then error("No such method " .. tostring(m), 0) end
    return b.methods[m](...)
  end,
}
"""


def fresh():
    rt = lua.LuaRuntime(unpack_returned_tuples=True)
    g = rt.globals()
    g.HOST_READ = lambda p: None
    g.CW, g.CH, g.MW, g.MH = 51, 19, 0, 0
    g.SCRIPT_EVENTS = rt.table_from([])
    g.SCRIPT_LINES = rt.table_from([])
    M = rt.execute(read("tests/mock_cc.lua"))
    for p in ("os/lib/me.lua", "os/lib/claude.lua", "os/lib/claudetools.lua", "os/lib/json.lua"):
        M.FS["/" + p] = read("src/" + p)
    for d in ("/os", "/os/lib"):
        M.FS[d] = True
    rt.execute(FAKE)
    return rt, M


def L(rt, code):
    return rt.execute(code)


# ---------------------------------------------------------------- 1. detection + search
rt, M = fresh()
r = L(rt, """
makeBridge("meBridge_0", "old")
makeBridge("rsBridge_1", "rs")
local ME = dofile("/os/lib/me.lua")
local f = ME.find()
local b = assert(ME.open())
local s = {}
local function first(q) local h = b:search(q, 5) return h and h[1] and h[1].item.name or "none" end
s.n, s.first, s.kind1, s.kind2 = #f, f[1].name, f[1].kind, f[2].kind
s.byName = first("iron ingot")
s.byId = first("minecraft:torch")
s.plural = first("torches")
s.path = first("iron_block")
s.fuzzy = first("block iron")
s.none = first("netherite")
local it, why = b:resolve("planks")
s.ambig = why or "picked"
local it2 = b:resolve("oak planks")
s.oak = it2 and it2.name
s.count = b:count("minecraft:iron_ingot")
s.countZero = b:count("minecraft:torch")
local all = b:items()
s.types = #all
local iron = b:item("minecraft:iron_ingot")
s.ironDisplay = iron.display
local c = b:catalog()
local torch
for _, x in ipairs(c) do if x.name == "minecraft:torch" then torch = x end end
s.torchCraftable, s.torchCount = torch and torch.craftable, torch and torch.count
s.rsOpen = assert(ME.open("rsBridge_1")).kind
local nb, err = ME.open("nope")
s.badOpen = err
return s
""")
check(r.n == 2 and r.first == "meBridge_0" and r.kind1 == "me" and r.kind2 == "rs", "detection %r %r" % (r.n, r.first))
check(r.byName == "minecraft:iron_ingot", "search by display name: %s" % r.byName)
check(r.byId == "minecraft:torch", "search by id: %s" % r.byId)
check(r.plural == "minecraft:torch", "plural search: %s" % r.plural)
check(r.path == "minecraft:iron_block", "search by id path: %s" % r.path)
check(r.fuzzy == "minecraft:iron_block", "word search: %s" % r.fuzzy)
check(r.none == "none", "no match: %s" % r.none)
check("several items" in r.ambig and "Oak Planks" in r.ambig and "Birch Planks" in r.ambig, "ambiguous: %s" % r.ambig)
check(r.oak == "minecraft:oak_planks", "resolve oak: %s" % r.oak)
check(r.count == 65 and r.countZero == 0, "counts %r %r (NBT variants add up)" % (r.count, r.countZero))
check(r.types == 4 and r.ironDisplay == "Iron Ingot", "items %r %r" % (r.types, r.ironDisplay))
check(r.torchCraftable is True and r.torchCount == 0, "craftable without stock in catalog")
check(r.rsOpen == "rs" and "No bridge named" in r.badOpen, "open by name")

# no bridge
r = L(rt, """BRIDGES = {} local ME = dofile("/os/lib/me.lua") local b, e = ME.open() return e""")
check(r and "No ME or RS bridge" in r, "no bridge: %r" % r)

# new API shape: search + counts
rt, M = fresh()
r = L(rt, """
makeBridge("me_bridge_2", "new")
local ME = dofile("/os/lib/me.lua")
local b = assert(ME.open())
local h = b:search("iron", 5)
return b.kind, h[1].item.name, h[1].item.count, b:count("minecraft:stick"), b:isCraftable("minecraft:chest"),
  b:isCraftable("minecraft:iron_ingot")
""")
check(r == ("me", "minecraft:iron_ingot", 65, 3, True, False), "new shape search/count %r" % (r,))

# ---------------------------------------------------------------- 2. craft flows
CRAFT = """
local shape, item, n, opts, setup = ...
BRIDGES = {}
local b0 = makeBridge("br", shape, opts)
if setup then setup(b0) end
local ME = dofile("/os/lib/me.lua")
local b = assert(ME.open())
TICKS = 0
local r = b:craft(item, n, { wait = 4 })
return r.ok, r.status, r.message, TICKS, r.item
"""


def craft(shape, item, n=1, opts=None, setup=None):
    rt, M = fresh()
    f = rt.eval("function(...) " + CRAFT + " end")
    o = rt.table_from(opts or {})
    s = rt.eval(setup) if setup else None
    return f(shape, item, n, o, s), rt


for shape in ("old", "new", "rs"):
    (ok, st, msg, ticks, item), rt = craft(shape, "torch", 8)
    check(ok is True and st == "crafting" and item == "minecraft:torch" and "8 Torch" in msg,
          "%s craftable -> crafting: %r %r %r" % (shape, ok, st, msg))
    if shape == "rs":
        check(ticks == 0, "rs: confirmed at once (no wait), %d ticks" % ticks)
    else:
        check(1 <= ticks <= 4, "%s: confirmed after the job showed up (%d ticks)" % (shape, ticks))
    calls = [rt.globals().CALLS[i] for i in range(1, len(rt.globals().CALLS) + 1)]
    check(sum(1 for c in calls if c.endswith(".craftItem")) == 1, "%s: craftItem called once: %r" % (shape, calls))

    (ok, st, msg, ticks, _), _ = craft(shape, "iron ingot", 4)
    check(ok is False and st == "not_craftable" and "no crafting pattern" in msg and "In stock: 65" in msg,
          "%s not craftable: %r %r" % (shape, st, msg))

    (ok, st, msg, ticks, _), rt = craft(shape, "minecraft:stick", 4,
                                        setup="function(b) b.crafting['minecraft:stick'] = { running = true, count = 1 } end")
    calls = [rt.globals().CALLS[i] for i in range(1, len(rt.globals().CALLS) + 1)]
    check(ok is True and st == "already_crafting" and not any(c.endswith(".craftItem") for c in calls),
          "%s already crafting: %r %r" % (shape, st, calls))

    (ok, st, msg, ticks, _), _ = craft(shape, "block of iron", 1)
    if shape == "old":
        check(ok is True and st == "started" and "ingredients are probably missing" in msg and ticks >= 8,
              "old missing ingredients -> unconfirmed after the wait: %r %r %d" % (st, msg, ticks))
    elif shape == "new":
        check(ok is False and st == "missing" and "Missing ingredients" in msg, "new missing: %r %r" % (st, msg))
    else:
        check(ok is False and st == "missing" and "ingredients are missing" in msg, "rs missing: %r %r" % (st, msg))

    (ok, st, msg, _, _), _ = craft(shape, "netherite ingot", 1)
    check(ok is False and st == "not_found" and "Nothing matching" in msg, "%s unknown item: %r %r" % (shape, st, msg))

(ok, st, msg, _, _), rt = craft("old", "torch", 2, {"busy": 2})
calls = [rt.globals().CALLS[i] for i in range(1, len(rt.globals().CALLS) + 1)]
check(ok is False and st == "no_cpu" and "busy" in msg and not any(c.endswith(".craftItem") for c in calls),
      "all CPUs busy: %r %r" % (st, msg))
(ok, st, msg, _, _), _ = craft("old", "torch", 2, {"cpus": 0})
check(ok is False and st == "no_cpu" and "no crafting CPU" in msg, "no CPU at all: %r %r" % (st, msg))
(ok, st, msg, _, _), _ = craft("old", "torch", 2, setup="function(b) b.offline = true end")
check(ok is False and st == "not_connected", "offline: %r %r" % (st, msg))
(ok, st, msg, _, _), _ = craft("old", "torch", 2, setup="""function(b)
  b.methods.craftItem = function() os.queueEvent("crafting", false, "minecraft:torch is not craftable") return true end
end""")
check(ok is False and st == "failed" and "is not craftable" in msg, "crafting event failure: %r %r" % (st, msg))
(ok, st, msg, _, _), _ = craft("old", "torch", 2, setup="""function(b)
  b.methods.craftItem = function() return nil, "NOT_CRAFTABLE" end
end""")
check(ok is False and st == "not_craftable", "NOT_CRAFTABLE answer: %r" % st)
(ok, st, msg, _, _), _ = craft("old", "torch", 2, setup="""function(b)
  b.methods.craftItem = function() error("Java exception thrown: boom", 0) end
end""")
check(ok is False and st == "failed" and "boom" in msg, "craftItem error: %r %r" % (st, msg))
(ok, st, msg, _, _), _ = craft("old", "torch", 2, setup="""function(b)
  local orig = b.methods.craftItem
  b.methods.craftItem = function(f) orig(f) b.stock["minecraft:torch"] = 2 b.crafting["minecraft:torch"] = nil return true end
end""")
check(ok is True and st == "done" and "now 2 in stock" in msg, "done at once: %r %r" % (st, msg))

# ---------------------------------------------------------------- 3. ensure, export, import
rt, M = fresh()
r = L(rt, """
makeBridge("br", "old")
local ME = dofile("/os/lib/me.lua")
local b = assert(ME.open())
local out = {}
local e1 = b:ensure("stick", 2)
out.e1 = e1.status .. "|" .. e1.message
local e2 = b:ensure("stick", 10)
out.e2 = e2.status .. "|" .. e2.message
local craftCount
for id, j in pairs(BRIDGES.br.crafting) do if id == "minecraft:stick" then craftCount = j.count end end
out.craftCount = craftCount
local n1, w1 = b:export("iron ingot", 10, "up")
local n2, w2 = b:export("iron ingot", 5, "minecraft:chest_3")
local n3, w3 = b:export("iron ingot", 5, "minecraft:chest_9")
local n4, w4 = b:export("minecraft:redstone", 5, "up")
local n5 = b:import("minecraft:stick", 7, "down")
out.ex = table.concat({ tostring(n1), tostring(n2), tostring(n3), tostring(w3), tostring(n4), tostring(w4), tostring(n5) }, "|")
out.left = BRIDGES.br.stock["minecraft:iron_ingot"]
out.sticks = BRIDGES.br.stock["minecraft:stick"]
return out
""")
check(r.e1.startswith("enough|") and "nothing to craft" in r.e1, "ensure enough: %s" % r.e1)
check(r.e2.startswith("crafting|") and "3 in stock, 10 wanted -> craft 7" in r.e2 and r.craftCount == 7,
      "ensure crafts the difference: %s (%r)" % (r.e2, r.craftCount))
ex = r.ex.split("|")
check(ex[0] == "10" and ex[1] == "5" and ex[2] == "0" and "does not exist" in ex[3], "export %r" % ex)
check(ex[4] == "0" and "none moved" in ex[5] and "Redstone" in ex[5], "export of an item not in stock %r" % ex)
check(ex[6] == "7" and r.sticks == 10 and r.left == 49, "import / stock after export %r %r %r" % (ex, r.sticks, r.left))

rt, M = fresh()
r = L(rt, """
makeBridge("br", "new")
local ME = dofile("/os/lib/me.lua")
local b = assert(ME.open())
local n1 = b:export("iron ingot", 3, "minecraft:chest_3")
local n2 = b:export("iron ingot", 2, "UP")
return n1, n2, BRIDGES.br.exported[1][3], BRIDGES.br.exported[2][3]
""")
check(r == (3, 2, "minecraft:chest_3", "up"), "new shape export target %r" % (r,))

# ---------------------------------------------------------------- 4. Claude tools (kit)
KIT = """
local K = dofile("/os/lib/claudetools.lua")
local api = dofile("/os/lib/claude.lua")
local kit = K.new({ where = "desktop", api = api })
local names = {}
for _, t in ipairs(kit.TOOLS) do names[#names + 1] = t.name end
return kit, table.concat(names, ","), api.json.encode(kit.TOOLS), kit.system
"""
rt, M = fresh()
kit, names, tj, system = L(rt, KIT)
check("me_" not in names and "ME/RS" not in system, "ME tools offered without a bridge: %s" % names)

rt, M = fresh()
L(rt, 'makeBridge("meBridge_0", "old")')
kit, names, tj, system = L(rt, KIT)
for t in ("me_status", "me_find", "me_craft", "me_ensure", "me_export"):
    check(t in names.split(","), "tool %s missing" % t)
tools = json.loads(tj)
for t in tools:
    s = t["input_schema"]
    check(set(t) == {"name", "description", "input_schema"} and s["type"] == "object"
          and isinstance(s["properties"], dict) and all(x in s["properties"] for x in s["required"]),
          "schema of %s" % t["name"])
check('"properties":[]' not in tj and '"required":{}' not in tj, "empty schema part with the wrong JSON type")
check("AUTOCRAFT" in system and "me_find" in system and "me_craft" in system, "prompt part missing")
check(all(ord(c) < 128 for c in system + tj), "non-ASCII in tools / prompt")
check(kit.RISKY["me_craft"] and kit.RISKY["me_ensure"] and kit.RISKY["me_export"]
      and not kit.RISKY["me_find"] and not kit.RISKY["me_status"], "risky flags")


def tool(name, inp):
    f = rt.eval("""function(kit, name, s)
      local api = dofile("/os/lib/claude.lua")
      local text, bad = kit.RUN[name](api.json.decode(s))
      return text, bad == true
    end""")
    return f(kit, name, json.dumps(inp))


t, err = tool("me_find", {"query": "torch"})
check(not err and "Torch (minecraft:torch) x0, craftable" in t, "me_find torch: %r" % t)
t, err = tool("me_find", {"query": "iron"})
check(not err and "Iron Ingot (minecraft:iron_ingot) x65" in t and "Block of Iron" in t, "me_find iron: %r" % t)
t, err = tool("me_find", {"query": "*", "craftable_only": True, "limit": 2})
check(not err and t.count("craftable") == 2 and "(2 more" in t, "me_find craftable_only: %r" % t)
t, err = tool("me_find", {"query": "netherite"})
check(not err and "Nothing matching" in t and "no pattern" in t, "me_find nothing: %r" % t)
t, err = tool("me_status", {})
check(not err and "Applied Energistics 2" in t and "Crafting CPUs: 2, 0 busy" in t and "Energy: 1200 / 1600 AE" in t
      and "craftable items (patterns): 4" in t, "me_status: %r" % t)
t, err = tool("me_craft", {"item": "minecraft:torch", "count": 16})
check(not err and t.startswith("crafting:") and "16 Torch" in t, "me_craft: %r %r" % (t, err))
t, err = tool("me_status", {})
check("1 busy" in t and "crafting 16 minecraft:torch" in t, "me_status shows the job: %r" % t)
t, err = tool("me_craft", {"item": "Iron Ingot", "count": 1, "wait_seconds": None})
check(err and t.startswith("not_craftable:"), "me_craft not craftable: %r" % t)
t, err = tool("me_ensure", {"item": "stick", "count": 2})
check(not err and t.startswith("enough:"), "me_ensure: %r" % t)
t, err = tool("me_export", {"item": "iron ingot", "count": 5, "to": "up"})
check(not err and "exported 5 Iron Ingot" in t, "me_export: %r" % t)
t, err = tool("me_export", {"item": "iron ingot", "count": 5, "to": "minecraft:chest_9"})
check(err and "not exported" in t, "me_export bad target: %r" % t)
t, err = tool("me_status", {"bridge": "nope"})
check(err and "No bridge named" in t, "bad bridge name: %r" % t)
d = rt.eval("""function(kit) local api = dofile("/os/lib/claude.lua")
  return kit.describe("me_craft", api.json.decode('{"item":"minecraft:torch","count":4}')),
         kit.describe("me_export", api.json.decode('{"item":"x","to":"up"}')) end""")(kit)
check(d == ("autocraft minecraft:torch x4", "export x x1 to up"), "describe %r" % (d,))

# ---------------------------------------------------------------- 4b. round trip through the Claude app
CW, CH, ENTER = 48, 18, 28


def typed(text):
    return [["char", c] for c in text] + [["key", ENTER]]


def reply(content, stop="end_turn"):
    body = {"id": "msg_1", "type": "message", "role": "assistant", "model": "claude-opus-5-5", "content": content,
            "stop_reason": stop, "stop_sequence": None,
            "usage": {"input_tokens": 10, "output_tokens": 5, "cache_read_input_tokens": 0}}
    return (200, json.dumps(body).encode("utf-8"), None)


def app_round_trip():
    rt = lua.LuaRuntime(unpack_returned_tuples=True)
    g = rt.globals()
    responses = [
        reply([{"type": "tool_use", "id": "u1", "name": "me_find", "input": {"query": "torches"}}], "tool_use"),
        reply([{"type": "tool_use", "id": "u2", "name": "me_craft", "input": {"item": "minecraft:torch", "count": 32}}],
              "tool_use"),
        reply([{"type": "text", "text": "Crafting 32 torches."}]),
    ]
    bodies, problems = [], []

    def api(body, headers):
        bodies.append(json.loads(body))
        if not responses:
            problems.append("extra request")
            return (400, b'{"type":"error","error":{"type":"x","message":"no more"}}', None)
        return responses.pop(0)

    M = {}

    def host_event(name, *args):
        if name == "click":
            t = M["M"].native
            for y in range(2, t.h + 1):
                i = t.rows[y].find(args[0])
                if i >= 0:
                    return rt.table_from(["mouse_click", 1, i + 1, y])
            problems.append("button %r not on screen" % args[0])
        if name == "snap":
            t = M["M"].native
            M["snap"] = "\n".join(t.rows[y] for y in range(1, t.h + 1))
        return None

    g.HOST_READ = lambda p: None
    g.CW, g.CH, g.MW, g.MH = CW, CH, 0, 0
    g.MODEM = False
    events = typed("make torches") + [["host", "snap"], ["host", "click", " Allow "]]
    g.SCRIPT_EVENTS = rt.table_from([rt.table_from(e) for e in events])
    g.SCRIPT_LINES = rt.table_from([])
    g.HOST_API = api
    g.HOST_EVENT = host_event
    mock = rt.execute(read("tests/mock_cc.lua"))
    M["M"] = mock
    for p in ("os/apps/claude.lua", "os/lib/claude.lua", "os/lib/claudetools.lua", "os/lib/json.lua", "os/lib/me.lua"):
        mock.FS["/" + p] = read("src/" + p)
    for d in ("/os", "/os/apps", "/os/lib", "/os/claude"):
        mock.FS[d] = True
    mock.FS["/os/claude/key"] = "sk-ant-test"
    # the app's own event loop stays (mock): only the peripherals are faked; an RS bridge confirms at once
    prelude = FAKE.split("BRIDGES, CALLS = {}, {}", 1)[1]
    g.WardenOS = rt.eval("""{ theme = { bg = colors.black, panel = colors.gray, text = colors.white,
        dim = colors.lightGray, accent = colors.cyan, good = colors.green, bad = colors.red, warn = colors.yellow },
        version = "1.3.0" }""")
    f = rt.eval("function(pre) local p = assert(load(pre, '=prelude', 't', _G)) p() "
                "BRIDGES, CALLS = BRIDGES or {}, CALLS or {} "
                "return pcall(function() dofile('/os/apps/claude.lua').main() end) end")
    ok, err = f("BRIDGES, CALLS = {}, {}\n" + prelude + '\nmakeBridge("rsBridge_0", "rs")')
    if ok or err != "SCRIPT_END":
        problems.append("app did not run to the end: %r" % (err,))
    written = "".join(mock.written[i] for i in range(1, len(mock.written) + 1))
    if "crashed" in written:
        problems.append("the app crashed")
    if len(bodies) != 3:
        return problems + ["%d requests" % len(bodies)]
    names = {t["name"] for t in bodies[0]["tools"]}
    if not {"me_find", "me_craft", "me_status", "me_ensure", "me_export"} <= names:
        problems.append("ME tools not sent: %r" % sorted(names))
    if "AUTOCRAFT" not in bodies[0]["system"][0]["text"]:
        problems.append("ME prompt part not sent")
    r1 = bodies[1]["messages"][-1]["content"][0]
    if not (r1["tool_use_id"] == "u1" and "Torch (minecraft:torch) x0, craftable" in r1["content"] and r1["is_error"] is False):
        problems.append("me_find result %r" % r1)
    if "Claude wants to use me_craft" not in M.get("snap", ""):
        problems.append("no approval card for me_craft:\n" + M.get("snap", ""))
    r2 = bodies[2]["messages"][-1]["content"][0]
    if not (r2["tool_use_id"] == "u2" and r2["content"].startswith("crafting:") and "32 Torch" in r2["content"]
            and r2["is_error"] is False):
        problems.append("me_craft result %r" % r2)
    b = rt.eval("BRIDGES.rsBridge_0")
    if not (b.crafting["minecraft:torch"] and b.crafting["minecraft:torch"].count == 32):
        problems.append("the bridge did not get the craft request")
    if "Crafting 32 torches." not in written:
        problems.append("final text not shown")
    return problems


try:
    for p in app_round_trip():
        check(False, "app round trip: " + p)
except Exception as e:
    import traceback
    check(False, "app round trip exception: %s\n%s" % (e, traceback.format_exc()))

src = read("src/os/lib/me.lua")
check(all(ord(c) < 128 for c in src), "me.lua contains non-ASCII characters")

print("me: %d failed" % len(fail))
sys.exit(1 if fail else 0)
