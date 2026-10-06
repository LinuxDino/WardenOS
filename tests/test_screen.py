#!/usr/bin/env python3
"""Warden Screen:  python3 tests/test_screen.py  (needs: pip install lupa)

1. the brain (/os/lib/screenserver.lua, via /os/lib/world.lua): answers screen_who and screen_req for every page
   (drones, map, me with and without a bridge, claude, gps) with sane data, rate-limits a screen, small messages
2. the client (/os/screen/client.lua) renders every page at several monitor sizes (and on the computer's own
   screen, and in black and white) without writing off-screen; brain offline / no modem states; touch cycles pages
3. the installer: standard computer -> dedicated screen (only the screen files downloaded, config + startup
   written), welcome screen S on an Advanced computer, re-run keeps the settings, desktop -> dedicated / cancel,
   and `install gps` / welcome G still make a GPS host
"""
import os, re, sys
import lupa.lua52 as lua

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src")
fail = []
ENTER, G, S = 28, 34, 31


def read(rel):
    p = os.path.join(ROOT, rel)
    if not os.path.isfile(p):
        return None
    with open(p, "rb") as f:
        return f.read().decode("latin-1")


def check(cond, msg):
    if not cond:
        fail.append(msg)
        print("FAIL", msg)


SRC_FILES = sorted(os.path.relpath(os.path.join(d, f), SRC).replace(os.sep, "/")
                   for d, _, fs in os.walk(SRC) for f in fs)

# fixtures on the brain
FIXTURES = """
WardenOS = WardenOS or {}
CLOCK = 100
os.clock = function() return CLOCK end
DRONES_FIX = {
  [12] = { label = "miner", fuel = 4500, fuelLimit = 20000, state = "working", task = "quarry", seen = 99,
           calibrated = true, abs = { x = 100, y = 64, z = -30 }, origin = { x = 96, y = 64, z = -28 },
           by = { who = "claude" }, progress = { phase = "mining", step = 45, total = 100 }, taskTime = 130 },
  [13] = { label = "digger", fuel = 120, state = "idle", seen = 98, pos = { 110, 70, -20 },
           lastTask = { name = "goto", ok = false, info = "blocked by bedrock", by = { who = "player" } } },
  [14] = { label = "old", fuel = "unlimited", state = "idle", seen = 10 },
}
if WardenOS.drones == nil then WardenOS.drones = DRONES_FIX end
WardenOS.claude = { busy = true, status = "Running drone_goto...", talks = {},
  drones = { [12] = { action = "quarry 90 60 -40 to 110 64 -20", at = 95, task = true } },
  recent = { { text = "drone_goto", at = 97 }, { text = "map_view", at = 90 } } }
WardenOS.gpsHosts = {
  [21] = { x = 100, y = 200, z = 100, served = 9, label = "gps1", seen = 99 },
  [22] = { x = 110, y = 200, z = 100, served = 4, seen = 99 },
  [23] = { x = 100, y = 200, z = 110, served = 2, seen = 99 },
  [24] = { x = 100, y = 210, z = 100, served = 0, seen = 99 },
}
"""

# a fake Advanced Peripherals ME bridge on "meBridge_0"
BRIDGE = """
local realNames, realType, realMethods, realCall = peripheral.getNames, peripheral.getType, peripheral.getMethods, peripheral.call
peripheral.getNames = function() local t = realNames() t[#t + 1] = "meBridge_0" return t end
peripheral.getType = function(n) if n == "meBridge_0" then return "meBridge" end return realType(n) end
peripheral.getMethods = function(n)
  if n == "meBridge_0" then return { "getItems", "getStoredEnergy", "getEnergyCapacity", "getEnergyUsage",
    "getUsedItemStorage", "getTotalItemStorage", "getCraftingCPUs", "isConnected", "craftItem" } end
  return realMethods(n)
end
peripheral.call = function(n, m, ...)
  if n == "meBridge_0" then
    if m == "getItems" then
      local t = {}
      for i = 1, 60 do t[i] = { name = "mod:item_" .. i, displayName = "Item " .. i, count = i * 100 } end
      t[61] = { name = "minecraft:cobblestone", displayName = "Cobblestone", count = 123456 }
      return t
    end
    if m == "getStoredEnergy" then return 1500000 end
    if m == "getEnergyCapacity" then return 2000000 end
    if m == "getEnergyUsage" then return 45 end
    if m == "getUsedItemStorage" then return 120000 end
    if m == "getTotalItemStorage" then return 400000 end
    if m == "isConnected" then return true end
    if m == "getCraftingCPUs" then
      return { { name = "cpu1", isBusy = true, storage = 1024,
                 craftingJob = { resource = { name = "minecraft:iron_ingot" }, amount = 64, progress = 20, totalItem = 64 } },
               { name = "cpu2", isBusy = false } }
    end
  end
  return realCall(n, m, ...)
end
"""


def env(events=(), lines=(), w=51, h=19, mw=0, mh=0, modem=True, files=None, colour=True, all_src=False,
        host_event=None, mon_colour=True):
    rt = lua.LuaRuntime(unpack_returned_tuples=True, encoding="latin-1")
    g = rt.globals()
    g.HOST_READ = lambda p: read(p)
    g.CW, g.CH, g.MW, g.MH = w, h, mw, mh
    g.MODEM = modem
    if host_event:
        g.HOST_EVENT = host_event
    g.SCRIPT_EVENTS = rt.table_from([rt.table_from(e) for e in events])
    g.SCRIPT_LINES = rt.table_from(list(lines))
    M = rt.execute(read("tests/mock_cc.lua"))
    g.MOCK = M
    rt.execute("keys.s = 31 keys.left = 203 keys.right = 205 "
               "local rc = peripheral.call peripheral.call = function(n, m, ...) "
               "if n == 'back' and MODEM and m == 'isWireless' then return true end return rc(n, m, ...) end")
    if not colour:
        rt.execute("MOCK.native.isColor = function() return false end MOCK.native.isColour = MOCK.native.isColor")
    if M.mon and not mon_colour:
        rt.execute("MOCK.mon.isColor = function() return false end MOCK.mon.isColour = MOCK.mon.isColor")
    if all_src:
        for f in SRC_FILES:
            parts = f.split("/")
            for i in range(1, len(parts)):
                M.FS["/" + "/".join(parts[:i])] = True
            M.FS["/" + f] = read("src/" + f)
    for k, v in (files or {}).items():
        M.FS[k] = v
    return rt, M


def run(rt, src, name, *args):
    f = rt.eval("function(src, name, ...) local f, e = load(src, '=' .. name, 't', _G) "
                "if not f then return false, e end local ok, r = pcall(f, ...) return ok, r end")
    return f(src, name, *args)


def screen(t):
    return "\n".join(t.rows[y] for y in range(1, t.h + 1))


def size(rt, v):
    return rt.eval("function(v) return (dofile('/os/lib/log.lua').size(v)) end")(v)


# ---------------------------------------------------------------- 1. brain
nfail = len(fail)
rt, M = env(all_src=True)
rt.execute("WardenOS = {}")
Wd = rt.eval("function() return dofile('/os/lib/world.lua') end")()
check(Wd.screenServer is not None and rt.eval("WardenOS.screens") is not None, "world: no screen server")
rt.execute("WardenOS.drones = false")      # the server must use world's own cache (the kernel shares it)
rt.execute(FIXTURES)
rt.execute(BRIDGE)
rt.globals().WORLD = Wd
rt.execute("for k, v in pairs(DRONES_FIX) do WORLD.drones[k] = v end "
           "for k, v in pairs(WardenOS.gpsHosts) do WORLD.gpsHosts[k] = v end")
rt.execute("dofile('/os/lib/map.lua').add({ {100, 63, -30, 'minecraft:stone'}, {101, 63, -30, 'minecraft:iron_ore'}, "
           "{110, 69, -20, 'minecraft:water'} })")
srv = Wd.screenServer
ev = rt.eval("function(...) return table.pack(...) end")
rt.execute("rednet.open('back')")

Wd.event(ev("rednet_message", 40, rt.eval("{ t = 'screen_who' }"), "wardenos"))
sent = [M.sent[i] for i in range(1, len(M.sent) + 1)]
check(any(s.to == 40 and s.msg.t == "screen_here" and s.msg.id == 7 and s.msg.drones == 3 for s in sent),
      "brain: screen_who not answered")


def ask(page, w=50, h=20, extra=""):
    n = len(M.sent)
    rt.execute("CLOCK = CLOCK + 2")
    Wd.event(ev("rednet_message", 40, rt.eval("{ t = 'screen_req', page = '%s', w = %d, h = %d, seq = 3 %s }"
                                             % (page, w, h, extra)), "wardenos"))
    out = [M.sent[i] for i in range(n + 1, len(M.sent) + 1)]
    out = [s for s in out if s.to == 40]
    return out[0].msg if out else None


d = ask("drones")
check(d is not None and d.t == "screen_data" and d.page == "drones" and d.seq == 3 and d.brain.id == 7, "drones: no answer")
if d:
    ls = [d.drones[i] for i in range(1, len(d.drones) + 1)]
    check([e.id for e in ls] == [12, 13, 14], "drones: order %s" % [e.id for e in ls])
    e = ls[0]
    check(e.online and e.label == "miner" and e.task == "quarry" and e.by == "claude" and e.step == 45 and e.total == 100
          and [e.pos[i] for i in (1, 2, 3)] == [100, 64, -30] and e.fuel == 4500, "drones: miner %r" % dict(e))
    check(ls[1].last.ok is False and "bedrock" in ls[1].last.info and [ls[1].pos[i] for i in (1, 2, 3)] == [110, 70, -20],
          "drones: last task / gps pos")
    check(not ls[2].online and ls[2].fuel == "unlimited", "drones: offline drone")
    check(size(rt, d) < 4000, "drones: message too big")

# rate limit: an immediate second request is not answered
n = len(M.sent)
Wd.event(ev("rednet_message", 40, rt.eval("{ t = 'screen_req', page = 'drones', w = 50, h = 20 }"), "wardenos"))
check(len(M.sent) == n, "brain: no rate limit")
check(Wd.screens[40] is not None and Wd.screens[40].page == "drones", "brain: screen not listed")

d = ask("map", 40, 15)
check(d is not None and d.rows is not None and len(d.rows) == 15 and all(len(d.rows[i]) == 40 for i in range(1, 16)),
      "map: wrong size %r" % (d and d.rows and [len(d.rows[i]) for i in range(1, len(d.rows) + 1)]))
if d and d.rows:
    allrows = "".join(d.rows[i] for i in range(1, len(d.rows) + 1))
    check("D" in allrows and "H" in allrows, "map: no drone / home marker")
    lg = [d.legend[i][1] for i in range(1, len(d.legend) + 1)]
    check("D" in lg and d.area.scale, "map: legend %s" % lg)
    check(size(rt, d) < 6000, "map: message too big")
d = ask("map", 200, 100)
check(d is not None and len(d.rows) <= 40 and len(d.rows[1]) <= 60, "map: not capped")
d = ask("map", 30, 10, ", center = { x = 0, z = 0 }, zoom = 1")
check(d is not None and d.area.cx == 0 and d.area.zoom == 1, "map: center / zoom ignored")

d = ask("me")
check(d is not None and d.bridge is not None and d.bridge.name == "meBridge_0" and d.types == 61, "me: %r" % (d and dict(d)))
if d and d["items"]:
    check(d["items"][1].display == "Cobblestone" and d["items"][1].count == 123456 and len(d["items"]) <= 40, "me: top items")
    check(d.energy.stored == 1500000 and d.storage.total == 400000 and d.cpus[1].busy, "me: energy / storage / cpus")
    check(size(rt, d) < 6000, "me: message too big")

d = ask("claude")
check(d is not None and d.busy and "drone_goto" in d.status and d.drones[1].id == 12 and d.drones[1].running
      and d.recent[1].text == "drone_goto", "claude: %r" % (d and dict(d)))
d = ask("gps")
check(d is not None and d.n == 4 and d.online == 4 and d.grade in ("excellent", "good", "fair", "poor") and d.advice[1],
      "gps: %r" % (d and dict(d)))
d = ask("nope")
check(d is not None and d.error, "unknown page: no error")

# no bridge: says so
rt2, M2 = env(all_src=True)
rt2.execute("WardenOS = {}")
rt2.execute(FIXTURES)
S2 = rt2.eval("function() return dofile('/os/lib/screenserver.lua').new({}) end")()
d = S2.build("me", 40, 15)
check(d.error and "bridge" in d.error.lower(), "me without bridge: %r" % dict(d))
d = S2.build("map", 40, 15)
check(d.error, "map without map: no error")
d = S2.build("drones", 40, 15)
check(len(d.drones) == 3, "server without world: drones from WardenOS.drones")
print("brain: ok" if len(fail) == nfail else "brain: FAILED")

# ---------------------------------------------------------------- 2. client
nfail = len(fail)
# the brain (#5) answers screen requests in the same Lua state through the real server
BRAIN = """
SRV = dofile('/os/lib/screenserver.lua').new({ map = dofile('/os/lib/map.lua'), log = dofile('/os/lib/log.lua') })
BRAIN_ON = true
local realSend, realBc = rednet.send, rednet.broadcast
rednet.send = function(id, msg, proto)
  local r = realSend(id, msg, proto)
  if r and BRAIN_ON and id == 5 and type(msg) == "table" and msg.t == "screen_req" then
    local d = SRV.build(msg.page, msg.w, msg.h, msg)
    local o = {}
    for k, v in pairs(d) do o[k] = v end
    o.t, o.page, o.seq, o.brain = "screen_data", msg.page, msg.seq, { id = 5, label = "brain" }
    os.queueEvent("rednet_message", 5, o, "wardenos")
  end
  return r
end
rednet.broadcast = function(msg, proto)
  realBc(msg, proto)
  if BRAIN_ON and type(msg) == "table" and msg.t == "screen_who" then
    os.queueEvent("rednet_message", 5, { t = "screen_here", id = 5, label = "brain", version = "1.9.0", drones = 3 }, "wardenos")
    if MOCK.lastTimer then os.queueEvent("timer", MOCK.lastTimer) end
  end
end
"""


def client_env(page, mw, mh, w=51, h=19, brain="5", monitor=None, mon_colour=True, modem=True, events=None,
               host_event=None):
    cfgs = '{ page = "%s", brain = %s, interval = 2%s }' % (page, brain, (', monitor = "%s"' % monitor) if monitor else "")
    rt, M = env(events or [["host", "shot"]], w=w, h=h, mw=mw, mh=mh, all_src=True, mon_colour=mon_colour,
                modem=modem, files={"/os/screen/screen.cfg": cfgs}, host_event=host_event)
    rt.execute("WardenOS = {}")
    rt.execute(FIXTURES)
    rt.execute(BRIDGE)
    rt.execute("dofile('/os/lib/map.lua').add({ {100, 63, -30, 'minecraft:stone'}, {101, 63, -30, 'minecraft:iron_ore'} })")
    rt.execute(BRAIN)
    return rt, M


PAGES = {"drones": ["miner", "quarry", "digger", "FAILED"], "map": ["D"], "me": ["Cobblestone", "Energy"],
         "claude": ["BUSY", "drone_goto", "#12"], "gps": ["Constellation", "#21"]}
SIZES = [(164, 81), (57, 24), (39, 19), (15, 10)]
for page, words in PAGES.items():
    for (mw, mh) in SIZES:
        tag = "client %s %dx%d" % (page, mw, mh)
        shot = {}

        def he(*a):
            shot["mon"] = screen(Mx.mon)
            shot["pc"] = screen(Mx.native)
            shot["scale"] = Mx.mon.scale
            return None
        rt, Mx = client_env(page, mw, mh, host_event=he)
        ok, err = run(rt, read("src/os/screen/client.lua"), "client.lua")
        check(err == "SCRIPT_END", "%s: stopped early: %s" % (tag, err))
        check(Mx.violations == 0, "%s: %d chars off-screen %s" % (tag, Mx.violations,
              [l for l in Mx.log.values() if l.startswith("OFFSCREEN")][:3]))
        sc = shot.get("mon", "")
        title = {"drones": "Drones", "map": "Map", "me": "Storage", "claude": "Claude", "gps": "GPS"}[page]
        check(title in sc.split("\n")[0] and "#5" in sc.split("\n")[0], "%s: header:\n%s" % (tag, sc))
        if mw >= 39:
            for wd in words:
                check(wd in sc, "%s: %r missing:\n%s" % (tag, wd, sc))
        check("Warden Screen" in shot.get("pc", "") and "right" in shot.get("pc", ""), "%s: computer status" % tag)
        if (mw, mh) == (164, 81) and page != "map":
            check(shot.get("scale", 0.5) > 0.5, "%s: text scale not raised (%s)" % (tag, shot.get("scale")))

# computer screen only (no monitor), black and white monitor, standard computer
for page in PAGES:
    shot = {}

    def he(*a):
        shot["pc"] = screen(Mx.native)
        return None
    rt, Mx = client_env(page, 0, 0, w=51, h=19, host_event=he)
    ok, err = run(rt, read("src/os/screen/client.lua"), "client.lua")
    check(err == "SCRIPT_END" and Mx.violations == 0, "client %s on the computer: %s %d" % (page, err, Mx.violations))
    check(PAGES[page][0] in shot.get("pc", ""), "client %s on the computer:\n%s" % (page, shot.get("pc")))
    rt, Mx = client_env(page, 57, 24, mon_colour=False)
    ok, err = run(rt, read("src/os/screen/client.lua"), "client.lua")
    check(err == "SCRIPT_END" and Mx.violations == 0, "client %s black and white: %s" % (page, err))

# auto brain: found by screen_who
shot = {}


def he(*a):
    shot["mon"] = screen(Mx.mon)
    return None
rt, Mx = client_env("drones", 57, 24, brain="nil", events=[["timer", 1], ["host", "shot"]], host_event=he)
ok, err = run(rt, read("src/os/screen/client.lua"), "client.lua")
check("miner" in shot.get("mon", "") and "#5" in shot.get("mon", ""), "client auto brain:\n%s" % shot.get("mon"))

# offline brain: waiting, then OFFLINE after a while; touch cycles the page (saved)
shot = []


def he(what, *a):
    if what == "shot":
        shot.append(screen(Mx.mon))
        return None
    rt.execute("CLOCK = CLOCK + 20")
    return rt.table_from(["timer", Mx.lastTimer])
rt, Mx = client_env("drones", 57, 24, events=[["host", "shot"], ["host", "tick"], ["host", "shot"],
                                               ["monitor_touch", "right", 3, 3], ["host", "shot"]], host_event=he)
rt.execute("BRAIN_ON = false")
ok, err = run(rt, read("src/os/screen/client.lua"), "client.lua")
check(len(shot) == 3, "client offline: %s" % err)
if len(shot) == 3:
    check("Waiting for brain #5" in shot[0], "client offline: no waiting state:\n" + shot[0])
    check("OFFLINE" in shot[1] and "offline" in shot[1], "client offline: no offline state:\n" + shot[1])
    check("Map" in shot[2].split("\n")[0], "client touch: page not changed:\n" + shot[2])
check('"map"' in (Mx.FS["/os/screen/screen.cfg"] or ""), "client touch: page not saved")
check(Mx.violations == 0, "client offline: off-screen")
# stale data stays with an offline note
shot = []
rt, Mx = client_env("drones", 57, 24, events=[["host", "tick"], ["host", "shot"]], host_event=he)
rt.execute("local rs = rednet.send rednet.send = function(...) local r = rs(...) BRAIN_ON = false return r end")
ok, err = run(rt, read("src/os/screen/client.lua"), "client.lua")
check(shot and "Brain offline - showing data" in shot[0] and "miner" in shot[0], "client stale data:\n%s" % (shot and shot[0]))
# no modem
shot = []
rt, Mx = client_env("drones", 57, 24, modem=False, events=[["host", "shot"]], host_event=he)
ok, err = run(rt, read("src/os/screen/client.lua"), "client.lua")
check(shot and "No modem" in shot[0], "client no modem:\n%s" % (shot and shot[0]))
# not set up / startup stops on Ctrl+T
rt, Mx = env([], all_src=True)
ok, err = run(rt, read("src/os/screen/client.lua"), "client.lua")
check(ok and any("install screen" in l for l in Mx.log.values()), "client without config")
rt, Mx = client_env("drones", 57, 24, events=[["terminate"]])
ok, err = run(rt, read("src/os/screen/startup.lua"), "startup.lua")
check(ok and any("stopped" in l for l in Mx.log.values()), "screen startup: terminate not handled: %s" % err)
print("client: ok" if len(fail) == nfail else "client: FAILED")

# ---------------------------------------------------------------- 3. installer
nfail = len(fail)
manifest = lua.LuaRuntime().execute(read("manifest.lua"))
listed = [manifest.files[i] for i in range(1, len(manifest.files) + 1)]
scrl = [manifest.screen[i] for i in range(1, len(manifest.screen) + 1)]
check(all(f in listed for f in scrl), "manifest screen list has files that are not in files")
check(set(scrl) == {"os/config.lua", "os/screen/core.lua", "os/screen/client.lua", "os/screen/startup.lua"},
      "manifest screen list: %s" % scrl)
WHO = """
local realBc = rednet.broadcast
rednet.broadcast = function(msg, proto)
  realBc(msg, proto)
  if type(msg) == "table" and msg.t == "screen_who" then
    os.queueEvent("rednet_message", 5, { t = "screen_here", id = 5, label = "brain", version = "1.9.0", drones = 2 }, "wardenos")
    os.queueEvent("rednet_message", 9, { t = "screen_here", id = 9, label = "other", version = "1.9.0" }, "wardenos")
    os.queueEvent("timer", MOCK.lastTimer)
  end
end
"""


def fsnap(M):
    return {k: v for k, v in M.FS.items()}


def cfg_of(rt, f):
    return rt.eval("function(s) return textutils.unserialize(s or '') end")(f.get("/os/screen/screen.cfg"))


# a) standard computer + monitor: `install screen` -> page 3, biggest monitor, brain from the list
rt, M = env([], ["3", "", "", "y"], colour=False, mw=57, mh=24, files={"/notes.txt": "keep", "/startup.lua": "print('old')"})
rt.execute(WHO)
ok, err = run(rt, read("install.lua"), "install.lua", "screen")
f = fsnap(M)
c = cfg_of(rt, f)
gets = [l for l in M.log.values() if l.startswith("GET ")]
check(M.rebooted, "installer standard: did not finish: %s %s" % (err, list(M.log.values())[-6:]))
check(c is not None and c.page == "me" and c.monitor == "right" and c.brain == 5, "installer standard: cfg %r" % (c and dict(c)))
check(f.get("/startup.lua") == read("src/os/screen/startup.lua") and f.get("/startup.old.lua") == "print('old')",
      "installer standard: startup not written / old one not kept")
check(f.get("/os/screen/client.lua") == read("src/os/screen/client.lua") and "/os/kernel.lua" not in f
      and "/os/screen/startup.lua" not in f and f.get("/notes.txt") == "keep", "installer standard: files %s" % sorted(f))
check(len(gets) == 1 + len(scrl), "installer standard: downloaded %d files, not just the screen" % len(gets))
check(M.label == "screen-7", "installer standard: label %s" % M.label)
check(any("brain" in l and "#5" in l for l in M.log.values()), "installer standard: brain list not shown")
check(M.violations == 0, "installer standard: off-screen")
std = f

# b) no modem, no monitor: typed brain ID, computer screen
rt, M = env([], ["x", "1", "#12", "y"], colour=False, modem=False)
ok, err = run(rt, read("install.lua"), "install.lua", "screen")
c = cfg_of(rt, fsnap(M))
check(M.rebooted and c is not None and c.page == "drones" and c.brain == 12 and c.monitor is None,
      "installer typed: %s %r" % (err, c and dict(c)))
check(any("No modem" in l for l in M.log.values()) and any("No monitor" in l for l in M.log.values()),
      "installer typed: no warnings")
# second brain from the list / auto brain
rt, M = env([], ["2", "0", "2", "y"], colour=False, mw=57, mh=24)
rt.execute(WHO)
ok, err = run(rt, read("install.lua"), "install.lua", "screen")
c = cfg_of(rt, fsnap(M))
check(M.rebooted and c is not None and c.page == "map" and c.monitor == "term" and c.brain == 9,
      "installer list choice: %s %r" % (err, c and dict(c)))
rt, M = env([], ["", "", "y"], colour=False)          # modem, nobody answers -> Enter = automatic
rt.execute("local b = rednet.broadcast rednet.broadcast = function(m, p) b(m, p) os.queueEvent('timer', MOCK.lastTimer) end")
ok, err = run(rt, read("install.lua"), "install.lua", "screen")
c = cfg_of(rt, fsnap(M))
check(M.rebooted and c is not None and c.brain is None, "installer auto brain: %s" % err)

# c) re-run on a screen: `install` keeps the settings (Enter), `install update` asks nothing
rt, M = env([], [""], colour=False, files=dict(std, **{"/os/screen/client.lua": "-- old"}))
ok, err = run(rt, read("install.lua"), "install.lua")
f = fsnap(M)
c = cfg_of(rt, f)
check(M.rebooted and c is not None and c.page == "me" and c.brain == 5 and f.get("/os/screen/client.lua") == read("src/os/screen/client.lua")
      and "/os/gps/host.lua" not in f, "installer re-run on a screen: %s %s" % (err, list(M.log.values())[-4:]))
rt, M = env([], [], files=dict(std))
ok, err = run(rt, read("install.lua"), "install.lua", "update")
c = cfg_of(rt, fsnap(M))
check(M.rebooted and c is not None and c.page == "me" and "/os/kernel.lua" not in fsnap(M), "installer update on a screen: %s" % err)

# d) welcome screen S on a fresh Advanced computer -> dedicated screen
for (w, h) in [(51, 19), (26, 20)]:
    rt, M = env([["key", S]], ["5", "", "", "y"], w=w, h=h, mw=57, mh=24)
    rt.execute(WHO)
    ok, err = run(rt, read("install.lua"), "install.lua")
    f = fsnap(M)
    c = cfg_of(rt, f)
    check(M.rebooted and c is not None and c.page == "gps" and c.brain == 5 and f.get("/startup.lua") == read("src/os/screen/startup.lua")
          and "/os/kernel.lua" not in f and "/os/apps" not in f, "installer welcome S %dx%d: %s %s" % (w, h, err, list(M.log.values())[-5:]))
    check(M.violations == 0, "installer welcome S %dx%d: off-screen" % (w, h))
    # the welcome screen footer fits
    rt, M = env([["key", 16]], [], w=w, h=h)
    run(rt, read("install.lua"), "install.lua")
    check(M.violations == 0, "welcome %dx%d: off-screen" % (w, h))

# e) desktop: `install screen` -> D replaces the desktop, Q cancels
CLEAN = [["key", ENTER]] + [["key", 208]] * 80 + [["key", ENTER]] * 3
rt, M = env(CLEAN, ["AGREE", "", "dino", "secret1", "secret1", "ERASE"], modem=False)
run(rt, read("install.lua"), "install.lua")
pc = fsnap(M)
check("/os/kernel.lua" in pc and "/os/lib/screenserver.lua" in pc, "desktop install: no screen server")
rt, M = env([], ["d", "2", "#5", "y"], files=dict(pc, **{"/home.txt": "mine"}), modem=False)
ok, err = run(rt, read("install.lua"), "install.lua", "screen")
f = fsnap(M)
check(M.rebooted and f.get("/home.txt") == "mine" and "/os/kernel.lua" not in f and "/os/users.dat" not in f
      and f.get("/startup.lua") == read("src/os/screen/startup.lua") and "/os/apps" not in f and "/os/lib" not in f
      and cfg_of(rt, f).page == "map", "installer screen on desktop: %s %s" % (err, sorted(k for k in f if k.startswith("/os"))))
rt, M = env([], ["q"], files=dict(pc))
ok, err = run(rt, read("install.lua"), "install.lua", "screen")
check(fsnap(M) == pc and not M.rebooted, "installer screen cancel changed files")
# `install desktop` on a screen is the desktop setup again (not the screen flow)
rt, M = env([["key", 16]], [], files=dict(std))
ok, err = run(rt, read("install.lua"), "install.lua", "desktop")
check(any("WardenOS installer" in l for l in M.log.values()) and not M.rebooted, "install desktop on a screen")

# f) GPS still works: `install gps` on a screen -> dedicated GPS host (screen removed); welcome G
rt, M = env([], ["1 100 2", "y"], colour=False, modem=False, files=dict(std))
ok, err = run(rt, read("install.lua"), "install.lua", "gps")
f = fsnap(M)
check(M.rebooted and "/os/gps/host.cfg" in f and f.get("/startup.lua") == read("src/os/gps/startup.lua")
      and "/os/screen/screen.cfg" not in f, "install gps on a screen: %s %s" % (err, list(M.log.values())[-4:]))
rt, M = env([["key", G]], ["n", "1 100 2", "y"], w=51, h=19)
ok, err = run(rt, read("install.lua"), "install.lua")
f = fsnap(M)
check(M.rebooted and "/os/gps/host.cfg" in f and f.get("/startup.lua") == read("src/os/gps/startup.lua"),
      "welcome G: %s %s" % (err, list(M.log.values())[-4:]))
# a dedicated screen made from a GPS host: no GPS host left
gpsf = f
rt, M = env([], ["1", "", "", "y"], colour=False, files=dict(gpsf))
rt.execute(WHO)
ok, err = run(rt, read("install.lua"), "install.lua", "screen")
f = fsnap(M)
check(M.rebooted and "/os/gps/host.cfg" not in f and f.get("/startup.lua") == read("src/os/screen/startup.lua"),
      "install screen on a GPS host: %s" % err)
rt, M = env([], [""], colour=False, files=dict(f))
ok, err = run(rt, read("install.lua"), "install.lua")
check(M.rebooted and cfg_of(rt, fsnap(M)) is not None and "/os/gps/host.cfg" not in fsnap(M), "re-run after GPS -> screen")
print("installer screen: ok" if len(fail) == nfail else "installer screen: FAILED")

print()
if fail:
    print("%d problem(s)" % len(fail))
    sys.exit(1)
print("all screen checks passed")
