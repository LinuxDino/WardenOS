#!/usr/bin/env python3
"""Debug log, System Monitor and Dashboard checks. Run from anywhere:  python3 tests/test_dashboard.py
(needs: pip install lupa). Exit code 1 on failure.

1. /os/lib/log.lua: one shared instance, ring buffers stay bounded, newest first, event counts + rates, clear,
   never throws; message summaries
2. /os/lib/world.lua logs every rednet message (any protocol) and counts events
3. /os/lib/claude.lua logs every API call: tokens, stop reason, retries, errors (fake Messages API)
4. System Monitor: every tab renders at 45x17, 45x18 and 52x22 without drawing outside the window,
   the Drones tab flags an offline / low-fuel / outdated drone, Net filter + pause, Logs clear
5. Dashboard: every widget kind added through the UI (taps + keys) with fake peripherals of other mods,
   values (bar %, units), config saved and reloaded, rename, remove, detached peripheral, maximized layout
"""
import json, os, sys
import lupa.lua52 as lua

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENTER, BACKSPACE, DOWN, UP = 28, 14, 208, 200
fail = []


def check(cond, msg):
    if not cond:
        fail.append(msg)
        print("FAIL", msg)


def read(rel):
    p = os.path.join(ROOT, rel)
    if not os.path.isfile(p):
        return None
    with open(p, "rb") as f:
        return f.read().decode("latin-1")


THEME = """WardenOS = { theme = { bg = colors.black, panel = colors.gray, text = colors.white,
  dim = colors.lightGray, accent = colors.cyan, good = colors.green, bad = colors.red, warn = colors.yellow },
  version = "1.4.1" }"""

# strict bounds check: buffered apps draw into windows; the mock only counts off-screen writes on real screens,
# so every window write that lands outside the window is counted here (WINDOW_VIOLATIONS)
STRICT = r"""
WINDOW_VIOLATIONS, WINDOW_LOG = 0, {}
local create = window.create
window.create = function(parent, x, y, w, h, vis)
  local t = create(parent, x, y, w, h, vis)
  local write = t.write
  t.write = function(s)
    s = tostring(s)
    local cx, cy = t.getCursorPos()
    local tw, th = t.getSize()
    for i = 1, #s do
      local px = cx + i - 1
      if s:sub(i, i) ~= " " and (px < 1 or px > tw or cy < 1 or cy > th) then
        WINDOW_VIOLATIONS = WINDOW_VIOLATIONS + 1
        WINDOW_LOG[#WINDOW_LOG + 1] = cx .. "," .. cy .. " " .. s
        break
      end
    end
    return write(s)
  end
  t.blit = function(s) return t.write(s) end
  return t
end
"""

# fake peripherals of other mods; DETACHED[name] = true removes one
PERIPHS = r"""
DETACHED = {}
ENERGY = 500000
local P = {
  energyCell_0 = { types = { "thermal:energy_cell", "energy_storage" }, m = {
    getEnergy = function() ENERGY = ENERGY + 10000 return ENERGY end, getEnergyCapacity = function() return 1000000 end } },
  mekanism_cube_0 = { types = { "basicEnergyCube" }, m = {
    getEnergy = function() return 2500000000 end, getMaxEnergy = function() return 10000000000 end,
    getEnergyFilledPercentage = function() return 0.25 end } },
  tank_0 = { types = { "fluid_storage" }, m = {
    tanks = function() return { { name = "minecraft:water", amount = 12000, capacity = 16000 } } end } },
  chest_0 = { types = { "minecraft:chest", "inventory" }, m = {
    size = function() return 27 end,
    list = function() return { [1] = { name = "minecraft:cobblestone", count = 64 }, [2] = { name = "minecraft:cobblestone", count = 32 },
      [5] = { name = "minecraft:iron_ingot", count = 10 }, [7] = { name = "minecraft:diamond", count = 3 },
      [8] = { name = "minecraft:dirt", count = 1 } } end,
    getItemDetail = function() return nil end } },
  stress_0 = { types = { "create_stressometer" }, m = {
    getStress = function() return 512 end, getStressCapacity = function() return 1024 end } },
  speed_0 = { types = { "create_speedometer" }, m = { getSpeed = function() return 64 end } },
  meBridge_0 = { types = { "meBridge" }, m = {
    listItems = function() return { { name = "minecraft:stone", amount = 1000 }, { name = "minecraft:glass", amount = 500 } } end,
    getEnergyUsage = function() return 12.5 end, getStoredEnergy = function() return 1000 end,
    getMaxEnergyStorage = function() return 2000 end,
    getUsedItemStorage = function() return 4096 end, getTotalItemStorage = function() return 16384 end } },
  reactor_0 = { types = { "some_mod_reactor" }, m = {
    getTemperature = function() return 1234.5 end, getInfo = function(a) return { mode = "auto", rate = 5, arg = a } end } },
  redstone_integrator_0 = { types = { "redstone_integrator" }, m = {
    getInput = function(s) return s == "top" end, getAnalogInput = function(s) return s == "top" and 7 or 0 end } },
}
local base = { getNames = peripheral.getNames, getType = peripheral.getType, getMethods = peripheral.getMethods,
  call = peripheral.call }
local function live(n) return P[n] and not DETACHED[n] end
peripheral.getNames = function()
  local out = base.getNames()
  local extra = {}
  for n in pairs(P) do if live(n) then extra[#extra + 1] = n end end
  table.sort(extra)
  for _, n in ipairs(extra) do out[#out + 1] = n end
  return out
end
peripheral.getType = function(n)
  if P[n] then if live(n) then return table.unpack(P[n].types) end return nil end
  return base.getType(n)
end
peripheral.getMethods = function(n)
  if P[n] then
    if not live(n) then return nil end
    local out = {}
    for k in pairs(P[n].m) do out[#out + 1] = k end
    table.sort(out)
    return out
  end
  return base.getMethods(n)
end
peripheral.call = function(n, method, ...)
  if P[n] then
    if not live(n) then error("No peripheral attached") end
    local f = P[n].m[method]
    if not f then error("No such method " .. tostring(method)) end
    return f(...)
  end
  return base.call(n, method, ...)
end
peripheral.isPresent = function(n) return peripheral.getType(n) ~= nil end
"""


class Env:
    def __init__(self, events=(), files=None, CW=45, CH=17, modem=True):
        self.rt = lua.LuaRuntime(unpack_returned_tuples=True, encoding="latin-1")
        g = self.rt.globals()
        g.HOST_READ = lambda p: read(p)
        g.CW, g.CH, g.MW, g.MH = CW, CH, 0, 0
        g.MODEM = modem
        g.HOST_EVENT = self.host_event
        g.HOST_API = self.api
        g.SCRIPT_EVENTS = self.rt.table_from([self.lua(e) for e in events])
        g.SCRIPT_LINES = self.rt.table_from([])
        self.M = self.rt.execute(read("tests/mock_cc.lua"))
        self.problems, self.shots, self.responses, self.bodies = [], {}, [], []
        self.hosts = {"click": self.click, "row": self.click_row, "shot": self.shot, "tick": self.tick,
                      "edit": self.edit_button, "lua": self.run_lua}
        for d in ("/os", "/os/lib", "/os/apps"):
            self.M.FS[d] = True
        for p in ("os/lib/log.lua", "os/lib/world.lua", "os/lib/map.lua", "os/lib/claude.lua", "os/lib/json.lua",
                  "os/lib/bigfont.lua", "os/apps/monitoring.lua", "os/apps/dashboard.lua"):
            self.M.FS["/" + p] = read("src/" + p)
        for k, v in (files or {}).items():
            self.M.FS[k] = v

    def lua(self, v):
        if isinstance(v, dict):
            return self.rt.table_from({k: self.lua(x) for k, x in v.items()})
        if isinstance(v, (list, tuple)):
            return self.rt.table_from([self.lua(x) for x in v])
        return v

    def api(self, body, headers):
        self.bodies.append(json.loads(body))
        if not self.responses:
            return (400, json.dumps({"type": "error", "error": {"type": "x", "message": "no response"}}), None)
        return self.responses.pop(0)

    def host_event(self, name, *args):
        ev = self.hosts[name](*args)
        return None if ev is None else self.lua(ev)

    def screen(self):
        t = self.M.native
        return "\n".join(t.rows[y] for y in range(1, t.h + 1))

    def click(self, label, nth=1, min_row=1):
        t = self.M.native
        seen = 0
        for y in range(min_row, t.h + 1):
            i = t.rows[y].find(label)
            if i >= 0:
                seen += 1
                if seen == nth:
                    return ["mouse_click", 1, i + 1, y]
        self.problems.append("not on screen: %r\n%s" % (label, self.screen()))
        return None

    def click_row(self, label, row):
        i = self.M.native.rows[row].find(label)
        if i < 0:
            self.problems.append("not on row %d: %r\n%s" % (row, label, self.screen()))
            return None
        return ["mouse_click", 1, i + 1, row]

    def edit_button(self, label, which):
        """tap '<' '>' 'r' or 'x' on the title row of the card labelled `label` (edit mode)"""
        t = self.M.native
        for y in range(1, t.h + 1):
            i = t.rows[y].find(label)
            if i >= 0:
                j = t.rows[y].find("< > r x", i)
                if j >= 0:
                    return ["mouse_click", 1, j + 1 + "<>rx".index(which) * 2, y]
        self.problems.append("no edit buttons for %r\n%s" % (label, self.screen()))
        return None

    def shot(self, name):
        self.shots[name] = self.screen()
        return None

    def tick(self):
        return ["timer", self.M.lastTimer]

    def run_lua(self, code):
        self.rt.execute(code)
        return None

    def plain(self, v):
        if lua.lua_type(v) == "table":
            keys = list(v.keys())
            if keys and all(isinstance(k, int) for k in keys):
                return [self.plain(v[i]) for i in sorted(keys)]
            return {k: self.plain(x) for k, x in v.items()}
        return v

    def run_app(self, path, prelude=""):
        f = self.rt.eval("function(pre, path) local p = assert(load(pre, '=prelude', 't', _G)) p() "
                         "return pcall(function() dofile(path).main() end) end")
        ok, err = f(THEME + "\n" + STRICT + "\n" + PERIPHS + "\n" + prelude, path)
        g = self.rt.globals()
        return ok, err, int(g.WINDOW_VIOLATIONS or 0) + int(self.M.violations), list((g.WINDOW_LOG or {}).values())[:3]


# ---------------------------------------------------------------- 1. log.lua
UNIT = r"""
local R = {}
local function ok(c, m) if not c then R[#R + 1] = m end end
local log = dofile("/os/lib/log.lua")
ok(dofile("/os/lib/log.lua") == log and rawget(_G, "WardenLog") == log, "not one shared instance")
for i = 1, 200 do log.add("rednet", { n = i }) end
local l = log.list("rednet")
ok(#l == 150, "rednet ring holds " .. #l)
ok(l[1].n == 200 and l[150].n == 51, "rednet not newest first: " .. tostring(l[1].n) .. " " .. tostring(l[150].n))
ok(type(l[1].time) == "number" and type(l[1].clock) == "number", "no time stamps")
for i = 1, 100 do log.add("error", { source = "t", text = "e" .. i }) end
ok(#log.list("error") == 60 and log.list("error")[1].text == "e100", "error ring")
for i = 1, 50 do log.add("claude", { model = "m", ms = i }) end
ok(#log.list("claude") == 40 and log.total("claude") == 50, "claude ring")
for i = 1, 70 do log.add("info", "line " .. i) end
ok(#log.list("info") == 60 and log.list("info")[1].text == "line 70", "info ring / string entries")
log.add("info", string.rep("x", 5000))
ok(#log.list("info")[1].text <= 200, "long info line not cut")
for i = 1, 5 do log.add("event", "timer") end
log.add("event", "key") log.add("event", "key")
local n, rate = log.count("timer")
ok(n == 5 and rate == 5, "event count " .. n .. " rate " .. rate)
ok(log.count() == 7, "total events")
ok(log.list("event")[1].name == "timer" and log.list("event")[2].count == 2, "event list")
for i = 1, 200 do log.add("event", "ev" .. i) end
ok(#log.list("event") <= 65, "event names not bounded: " .. #log.list("event"))
ok(log.rate("error") == 100, "error rate " .. log.rate("error"))
log.clear("error")
ok(#log.list("error") == 0 and #log.list("rednet") == 150, "clear(kind)")
-- never throws
local fine = pcall(function()
  log.add(nil, nil) log.add("event", nil) log.add("weird", 42) log.list(nil) log.list("nope") log.count("nope")
  log.clear("nope") log.rednet({}) log.rednet({ "rednet_message", 1, setmetatable({}, { __pairs = function() error("x") end }) })
  local cyc = {} cyc.self = cyc
  log.rednet({ "rednet_message", 3, cyc, "p" })
end)
ok(fine, "log call threw")
-- summaries
ok(log.summary({ t = "cmd", cmd = "goto", seq = 4 }) == "cmd goto #4", "cmd summary " .. log.summary({ t = "cmd", cmd = "goto", seq = 4 }))
ok(log.summary({ t = "status", kind = "turtle", task = "mine", state = "run", fuel = 50 }) == "status mine/run fuel 50", "status summary")
ok(log.summary({ t = "map", obs = { 1, 2, 3 } }) == "map 3 obs", "map summary")
ok(log.summary("hello") == "hello", "string summary")
local big = { t = "map", obs = {} }
for i = 1, 5000 do big.obs[i] = { i, 64, i, "minecraft:stone" } end
log.rednet({ "rednet_message", 9, big, "wardenos" })
local e = log.list("rednet")[1]
ok(e.from == 9 and e.protocol == "wardenos" and e.t == "map" and e.size > 1000 and e.big, "size estimate of a big message")
log.clear()
ok(#log.list("rednet") == 0 and log.count() == 0, "clear()")
return table.concat(R, "; ")
"""
env = Env()
res = env.rt.execute(UNIT)
check(res == "", "log.lua: " + str(res))
print("log.lua: ok" if res == "" else "log.lua: FAILED")

# ---------------------------------------------------------------- 2. world.lua logs rednet + events
WORLD = r"""
local R = {}
local function ok(c, m) if not c then R[#R + 1] = m end end
local W = dofile("/os/lib/world.lua")
local log = dofile("/os/lib/log.lua")
W.event(table.pack("rednet_message", 12, { t = "status", kind = "turtle", task = "mine", state = "run", fuel = 50, owner = 3 }, "wardenos"))
W.event(table.pack("rednet_message", 12, { t = "ack", cmd = "dig", ok = true, seq = 2 }, "wardenos"))
W.event(table.pack("rednet_message", 40, "hello there", "chat"))
W.event(table.pack("rednet_message", 41, { t = "cmd", to = 12, cmd = "home", seq = 9 }, "wardenos"))
W.event(table.pack("timer", 1))
local l = log.list("rednet")
ok(#l == 4, "logged " .. #l .. " messages")
ok(l[4].from == 12 and l[4].drone and l[4].summary == "status mine/run fuel 50", "status entry")
ok(l[3].drone and l[3].summary:find("ack dig ok"), "ack from a known drone not marked")
ok(l[2].protocol == "chat" and not l[2].drone and l[2].summary == "hello there", "other protocol")
ok(l[1].to == 12 and l[1].summary == "cmd home #9", "to field")
ok(log.count("rednet_message") == 4 and log.count("timer") == 1, "events not counted")
ok(W.drones[12] and W.drones[12].fuel == 50, "drone cache broken")
return table.concat(R, "; ")
"""
env = Env()
res = env.rt.execute(WORLD)
check(res == "", "world.lua: " + str(res))
print("world.lua logging: ok" if res == "" else "world.lua logging: FAILED")

# ---------------------------------------------------------------- 3. claude.lua logs API calls
def reply(inp=10, out=5, cache=0, stop="end_turn"):
    return (200, json.dumps({"type": "message", "role": "assistant", "model": "claude-opus-5-5",
                             "content": [{"type": "text", "text": "hi"}], "stop_reason": stop,
                             "usage": {"input_tokens": inp, "output_tokens": out, "cache_read_input_tokens": cache}}), None)


def api_error(status, message):
    return (status, json.dumps({"type": "error", "error": {"type": "x", "message": message}}), None)


CLAUDE = r"""
local R = {}
local function ok(c, m) if not c then R[#R + 1] = m end end
local api = dofile("/os/lib/claude.lua")
local body = { model = "claude-opus-5-5", max_tokens = 100, messages = { { role = "user", content = "hi" } },
               output_config = { effort = "low" } }
local res, err = api.send("k", body)
ok(res and res.stop_reason == "end_turn", "request failed: " .. tostring(err))
local log = rawget(_G, "WardenLog")
ok(log ~= nil, "log not loaded by claude.lua")
local c = log and log.list("claude")[1] or {}
ok(c.model == "claude-opus-5-5" and c.effort == "low" and c.input == 10 and c.output == 5 and c.cacheRead == 300
   and c.stop == "end_turn" and c.retries == 0 and type(c.ms) == "number" and not c.error, "call entry wrong")
res, err = api.send("k", body)
ok(not res and err, "error not returned")
c = log.list("claude")[1]
ok(c.error and c.error:find("bad request") and #log.list("claude") == 2, "error call not logged: " .. tostring(c.error))
ok(log.list("error")[1] and log.list("error")[1].source == "claude", "error not in the error log")
res, err = api.send("k", body)
c = log.list("claude")[1]
ok(res and c.retries == 1 and c.output == 7, "retry not logged: " .. tostring(c.retries))
-- a broken logger never breaks a request
rawset(_G, "WardenLog", { add = function() error("boom") end, list = function() return {} end })
res, err = api.send("k", body)
ok(res ~= nil, "broken logger broke the request: " .. tostring(err))
return table.concat(R, "; ")
"""
env = Env()
env.responses = [reply(cache=300), api_error(400, "bad request"), api_error(529, "overloaded"), reply(out=7), reply()]
res = env.rt.execute(CLAUDE)
check(res == "", "claude.lua: " + str(res))
print("claude.lua logging: ok" if res == "" else "claude.lua logging: FAILED")

# ---------------------------------------------------------------- 4. System Monitor
SEED = r"""
local log = dofile("/os/lib/log.lua")
local map = dofile("/os/lib/map.lua")
map.add({ { 10, 64, 20, "minecraft:stone" }, { 11, 64, 20, "minecraft:dirt" } })
map.protect({ name = "base", x1 = 0, z1 = 0, x2 = 10, z2 = 10 })
local rev = map.protected().rev
WardenOS.drones = {
  [12] = { t = "status", kind = "turtle", label = "miner", owner = 7, task = "mine", state = "run", fuel = 50,
           fuelItems = 3, version = "1.4.0", protectRev = 0, safeDig = true, seen = os.clock() - 30,
           calibrated = true, abs = { x = 120, y = 64, z = -30, f = 1 }, by = { id = 7, who = "claude" } },
  [13] = { t = "status", kind = "turtle", label = "ok", owner = 7, task = "manual", state = "ready", fuel = 5000,
           version = WardenOS.version, protectRev = rev, safeDig = true, seen = os.clock(), calibrated = false },
}
log.rednet({ "rednet_message", 12, { t = "status", kind = "turtle", task = "mine", state = "run", fuel = 50 }, "wardenos" }, { drone = true })
log.rednet({ "rednet_message", 40, "hello chat", "chat" })
log.rednet({ "rednet_message", 13, { t = "map", obs = { 1, 2 } }, "wardenos" }, { drone = true })
for i = 1, 30 do log.add("info", "filler line " .. i) end
log.add("claude", { model = "claude-opus-5-5", effort = "low", ms = 1234, input = 1000, output = 50, cacheRead = 900, stop = "end_turn", retries = 0 })
log.add("claude", { model = "claude-sonnet-5-5", effort = "high", ms = 300, error = "HTTP 529: overloaded", retries = 2 })
log.add("error", { source = "claude", text = "HTTP 529: overloaded" })
log.add("info", "drone 12 went home")
for i = 1, 3 do log.add("event", "timer") end
WardenOS.claude = { busy = true, status = "thinking", drones = { [12] = true } }
rednet.open("back")
"""
TABS = [("Overview", "Sys"), ("Devices", "Dev"), ("Net", "Net"), ("Drones", "Drones"), ("Claude", "Claude"),
        ("Logs", "Logs"), ("Disk", "Disk")]
for (cw, ch) in [(45, 17), (45, 18), (52, 22), (51, 21)]:
    tag = "monitor %dx%d" % (cw, ch)
    names = [l if cw >= 52 else s for (l, s) in TABS]
    ev = [["host", "shot", "first"]]
    for n in names:
        ev += [["host", "row", " %s " % n, 1], ["host", "shot", n], ["mouse_scroll", 1, 10, 8], ["key", DOWN],
               ["mouse_scroll", -1, 10, 8], ["key", UP], ["host", "tick"]]
    nm = lambda short: names[[s for (_, s) in TABS].index(short)]
    ev += [["host", "row", " %s " % nm("Net"), 1], ["host", "click", " show all "], ["host", "shot", "net-wos"],
           ["host", "click", " show wardenos "], ["host", "shot", "net-drones"], ["host", "click", " pause "],
           ["host", "lua", 'dofile("/os/lib/log.lua").rednet({ "rednet_message", 99, { t = "status", kind = "turtle" }, "wardenos" }, { drone = true })'],
           ["host", "tick"], ["host", "shot", "net-paused"], ["host", "click", " resume "], ["host", "shot", "net-resumed"],
           ["host", "row", " %s " % nm("Drones"), 1], ["host", "click", "#12 miner"], ["host", "shot", "drone-detail"],
           ["host", "click", " < "],
           ["host", "row", " %s " % nm("Logs"), 1], ["host", "click", " events "], ["host", "shot", "events"],
           ["host", "click", " log "], ["host", "click", " clear "], ["host", "shot", "logs-cleared"]]
    env = Env(events=ev, CW=cw, CH=ch)
    ok, err, viol, vlog = env.run_app("/os/apps/monitoring.lua", SEED)
    sh = env.shots
    check(err == "SCRIPT_END", "%s: stopped early: %s" % (tag, err))
    check(viol == 0, "%s: %d chars outside the window %s" % (tag, viol, vlog))
    check(not env.problems, "%s: %s" % (tag, env.problems[:2]))
    row1 = sh.get("first", "").split("\n")[0]
    check(all((" %s " % n) in row1 for n in names), "%s: tab bar incomplete: %r" % (tag, row1))
    for n in names:
        check("panel error" not in sh.get(n, "") and "error:" not in sh.get(n, ""), "%s: tab %s failed:\n%s" % (tag, n, sh.get(n)))
    check("SYSTEM MONITOR" in sh.get(names[0], "") and "OK" in sh.get(names[0], ""), "%s: overview:\n%s" % (tag, sh.get(names[0])))
    check("left" in sh.get(nm("Dev"), "") and "create_stressometer" in sh.get(nm("Dev"), ""), "%s: devices:\n%s" % (tag, sh.get(nm("Dev"))))
    net = sh.get("Net", "")
    check("status mine/run fuel 50" in net and "hello chat" in net and "/min" in net and "back open" in net,
          "%s: net tab:\n%s" % (tag, net))
    check("hello chat" not in sh.get("net-wos", "") and "status mine/run" in sh.get("net-wos", ""), "%s: wardenos filter:\n%s" % (tag, sh.get("net-wos")))
    check("show drones" in sh.get("net-drones", "") and "map 2 obs" in sh.get("net-drones", ""), "%s: drones filter" % tag)
    check("#99" not in sh.get("net-paused", "") and "resume" in sh.get("net-paused", ""), "%s: pause:\n%s" % (tag, sh.get("net-paused")))
    check("#99" in sh.get("net-resumed", ""), "%s: resume:\n%s" % (tag, sh.get("net-resumed")))
    dr = sh.get("Drones", "")
    check("2 drones, 1 online, 1 need attention" in dr, "%s: drones summary:\n%s" % (tag, dr))
    check("f:50+3c!" in dr and "off 30s" in dr and "v1.4.0!" in dr and "prot 0!" in dr and "120 64 -30" in dr
          and "uncal." in dr and " AI" in dr, "%s: drone warnings:\n%s" % (tag, dr))
    check("#13 ok" in dr and "f:5000" in dr and "f:5000!" not in dr, "%s: healthy drone flagged:\n%s" % (tag, dr))
    det = sh.get("drone-detail", "")
    check("protectRev" in det and "fuelItems" in det and "seen 30s ago" in det, "%s: drone detail:\n%s" % (tag, det))
    cl = sh.get("Claude", "")
    check("2 calls" in cl and "busy - thinking" in cl and "opus-5-5" in cl and "ERR HTTP 529" in cl
          and "1.9k/50" in cl and "1234ms" in cl, "%s: claude tab:\n%s" % (tag, cl))
    lg = sh.get("Logs", "")
    check("claude: HTTP 529: overloaded" in lg and "filler line 30" in lg, "%s: logs tab:\n%s" % (tag, lg))
    check("timer" in sh.get("events", ""), "%s: events view:\n%s" % (tag, sh.get("events")))
    check("Nothing logged." in sh.get("logs-cleared", ""), "%s: clear:\n%s" % (tag, sh.get("logs-cleared")))
    dk = sh.get("Disk", "")
    check("free of" in dk and "World map" in dk and "2 / " in dk and "protected 1" in dk and "lib/" in dk,
          "%s: disk tab:\n%s" % (tag, dk))
print("system monitor: ok" if not [f for f in fail if f.startswith("monitor")] else "system monitor: FAILED")

# no log library, no drones, no map: still renders
env = Env(events=[["host", "row", " %s " % n, 1] for (_, n) in TABS] + [["host", "shot", "end"]], CW=45, CH=17)
for p in ("/os/lib/log.lua", "/os/lib/map.lua", "/os/lib/claude.lua"):
    env.M.FS[p] = None
ok, err, viol, vlog = env.run_app("/os/apps/monitoring.lua")
check(err == "SCRIPT_END" and viol == 0 and not env.problems and "panel error" not in env.shots.get("end", ""),
      "monitor bare: %s %d %s\n%s" % (err, viol, env.problems[:1], env.shots.get("end")))

# ---------------------------------------------------------------- 5. Dashboard
def add(source, kind=None, extra=()):
    ev = [["host", "click", " + add "], ["host", "click", source]]
    if kind:
        ev.append(["host", "click", kind, 1, 2])
    ev += list(extra)
    return ev


CW, CH = 45, 17
ev = [["host", "shot", "empty"]]
ev += add("energyCell_0", "* Energy") + [["host", "shot", "energy"], ["host", "tick"], ["host", "tick"], ["host", "tick"],
                                          ["host", "shot", "energy2"]]
ev += add("mekanism_cube_0", "* Energy") + [["host", "shot", "mek"]]
ev += add("tank_0", "* Fluid") + [["host", "shot", "fluid"]]
ev += add("chest_0", "* Inventory") + [["host", "shot", "chest"]]
ev += add("stress_0", "* Create") + [["host", "shot", "stress"]]
ev += add("speed_0", "* Create") + [["host", "shot", "speed"]]
ev += add("meBridge_0", "* ME / RS") + [["host", "shot", "me"]]
ev += add("redstone_integrator_0", "* Redstone", [["host", "click", "top", 1, 2]]) + [["host", "shot", "integrator"]]
ev += add("reactor_0", "Custom method", [["host", "shot", "methods"], ["host", "click", "getTemperature"], ["host", "shot", "args"],
                                         ["key", ENTER]]) + [["host", "shot", "custom"]]
ev += add("reactor_0", "Custom method", [["host", "click", "getInfo"]] + [["char", c] for c in "5, x"] + [["key", ENTER]]) + \
    [["host", "shot", "custom2"]]
ev += add("Redstone (this computer)", None, [["host", "click", "back", 1, 2]]) + [["host", "shot", "redstone"]]
ev += add("Drones") + [["host", "shot", "drones"]]
ev += add("World map") + [["host", "shot", "map"]]
ev += add("Computer") + [["host", "shot", "computer"]]
ev += add("Clock") + [["host", "shot", "clock"]]
# edit: rename the first card, move it right, remove the clock
ev += [["mouse_scroll", -1, 10, 8]] * 40 + [["host", "click", " edit "], ["host", "shot", "edit"],
       ["host", "edit", "energyCel", "r"], ["host", "shot", "rename"]] + [["key", BACKSPACE]] * 20 + \
      [["char", c] for c in "Main power"] + [["key", ENTER], ["host", "shot", "renamed"],
       ["host", "edit", "Main power", ">"], ["host", "shot", "moved"]]
ev += [["mouse_scroll", 1, 10, 8]] * 60 + [["host", "edit", "Clock", "x"], ["host", "shot", "removed"],
       ["host", "click", " done "], ["host", "shot", "final"]]
env = Env(events=ev, CW=CW, CH=CH)
env.M.redstone.back = 15
prelude = r"""
local W = WardenOS
W.drones = { [12] = { fuel = 50, task = "mine", state = "working", by = { id = 7, who = "claude" }, seen = os.clock() }, [13] = { fuel = 900, task = "manual", seen = os.clock() - 60 } }
local map = dofile("/os/lib/map.lua")
map.add({ { 10, 64, 20, "minecraft:stone" } })
map.protect({ name = "base", x1 = 0, z1 = 0, x2 = 10, z2 = 10 })
"""
ok, err, viol, vlog = env.run_app("/os/apps/dashboard.lua", prelude)
sh = env.shots
check(err == "SCRIPT_END", "dashboard: stopped early: %s" % err)
check(viol == 0, "dashboard: %d chars outside the window %s" % (viol, vlog))
check(not env.problems, "dashboard: %s" % env.problems[:2])
check("No widgets yet." in sh.get("empty", ""), "dashboard: empty state:\n" + sh.get("empty", ""))


def has(name, *parts):
    s = sh.get(name, "")
    check(all(p in s for p in parts), "dashboard %s: missing %s in\n%s" % (name, [p for p in parts if p not in s], s))


has("energy", "energyCell_0", "51%", "510k / 1.0M FE")
has("energy2", "54%", "540k / 1.0M FE", "^")
check(any(ord(c) >= 128 for c in sh.get("energy2", "")), "dashboard: no sparkline drawn")
has("mek", "mekanism_cube_0", "25%", "2.5G / 10.0G J")
has("fluid", "tank_0", "water", "75%", "12 B / 16 B")
has("chest", "chest_0", "19%", "110 items", "5/27", "cobblestone", "96", "iron ingot", "10", "diamond")
has("stress", "stress_0", "50%", "512 / 1.0k su")
has("speed", "speed_0", "64 RPM")
has("me", "meBridge_0", "25%", "1.5k items, 2 types", "4.1k / 16.4k bytes", "12.5 FE/t")
has("integrator", "redstone_integr", "top: 7 ON")
has("methods", "getInfo", "getTemperature")
has("args", "Arguments for getTemperature")
has("custom", "getTemperature()", "1.2k")
has("custom2", "getInfo(5, x)", "arg: 5", "mode: auto", "rate: 5")
has("redstone", "Redstone back", "back: 15 ON")
has("drones", "2 drones, 1 online", "1 busy, 1 offline", "1 low fuel, 1 AI")
has("map", "World map", "1 protected areas", "blocks")
has("computer", "#7", "day 1")
has("clock", "12:00")
has("edit", "< > r x")
has("rename", "Label for this widget", "> energyCell_0")
has("renamed", "Main power")
cfg = env.M.FS["/os/dashboard.cfg"]
t = env.plain(env.rt.eval("function(s) return textutils.unserialize(s) end")(cfg or "{}"))
ws = (t or {}).get("widgets", [])
kinds = [w.get("kind") for w in ws]
check(len(ws) == 14 and "clock" not in kinds, "dashboard: config after remove: %s" % kinds)
check(ws and ws[0].get("periph") == "mekanism_cube_0" and ws[1].get("label") == "Main power", "dashboard: move/rename not saved: %s" % ws[:2])
check(any(w.get("method") == "getInfo" and w.get("args") == "5, x" for w in ws), "dashboard: custom args not saved")
check(any(w.get("kind") == "redstone" and w.get("side") == "back" and not w.get("periph") for w in ws), "dashboard: redstone side")
check(sh.get("removed", "").count("Clock") == 1 and "removed Clock" in sh.get("removed", ""), "dashboard: remove:\n" + sh.get("removed", ""))
check("< > r x" not in sh.get("final", ""), "dashboard: edit mode not left")

# reload at the maximized size (51x24 desktop: window 45x23 -> content 45x22; 164x81 monitor: 158x79)
for (cw, ch) in [(45, 22), (158, 79), (26, 18)]:
    env2 = Env(events=[["host", "shot", "max"], ["host", "tick"], ["host", "shot", "max2"]], CW=cw, CH=ch,
               files={"/os/dashboard.cfg": cfg})
    env2.M.redstone.back = 15
    ok, err, viol, vlog = env2.run_app("/os/apps/dashboard.lua", prelude)
    s = env2.shots.get("max2", "")
    check(err == "SCRIPT_END" and viol == 0 and not env2.problems, "dashboard %dx%d: %s %d %s" % (cw, ch, err, viol, vlog))
    if cw >= 100:
        for label in ["Main power", "mekanism_cube_0", "tank_0", "chest_0", "stress_0", "meBridge_0", "getInfo",
                      "Redstone back", "Drones", "World map", "Computer"]:
            check(label in s, "dashboard maximized: %s missing\n%s" % (label, s))
        check("2.5G / 10.0G J" in s and "110 items" in s, "dashboard maximized: values\n" + s)

# detached peripheral: card shows it, nothing crashes; attaching again recovers
env3 = Env(events=[["host", "shot", "det"], ["host", "lua", "DETACHED.tank_0 = nil"], ["peripheral", "tank_0"],
                   ["host", "shot", "back"]], CW=158, CH=79, files={"/os/dashboard.cfg": cfg})
ok, err, viol, vlog = env3.run_app("/os/apps/dashboard.lua", prelude + "\nDETACHED.tank_0 = true DETACHED.chest_0 = true")
d = env3.shots.get("det", "")
check(d.count("peripheral missing") == 2 and "error" not in d, "dashboard: detached:\n" + d)
check(env3.shots.get("back", "").count("peripheral missing") == 1 and "water" in env3.shots.get("back", ""),
      "dashboard: reattach:\n" + env3.shots.get("back", ""))
check(err == "SCRIPT_END" and viol == 0, "dashboard detached: %s %d" % (err, viol))

# broken config file is ignored
env4 = Env(events=[["host", "shot", "s"]], files={"/os/dashboard.cfg": "{{{ not lua"})
ok, err, viol, vlog = env4.run_app("/os/apps/dashboard.lua")
check(err == "SCRIPT_END" and "No widgets yet." in env4.shots.get("s", ""), "dashboard: bad config: %s" % err)
print("dashboard: ok" if not [f for f in fail if f.startswith("dashboard")] else "dashboard: FAILED")

print()
if fail:
    print("%d problem(s)" % len(fail))
    sys.exit(1)
print("all dashboard checks passed")
