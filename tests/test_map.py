#!/usr/bin/env python3
"""World map checks. Run from anywhere:  python3 tests/test_map.py   (needs: pip install lupa). Exit code 1 on failure.

1. /os/lib/map.lua unit by unit: add/get/surface/cell/view/find/info, chunk files written and read back, the cap,
   protected areas (rev goes up on every change)
2. the kernel (booted via /startup.lua like a real computer): stores incoming {t="map"} messages, pushes the
   protected areas to a drone of this computer that has an old copy (rate-limited, never to other owners' drones),
   writes the map when it stops
   zoom (1, 2, 4, 8, 16 blocks per character): aggregation priority, marks, scale text, 60x40 cap, speed
3. the Map app at 46x18 (window content 46x17): renders without drawing off-screen, drone marker, tap info,
   the protect-area flow (two corners + name) and deleting an area; zoom buttons/keys, center, tap and protect
   at zoom 4
4. the Drones app: Calibrate form sends `calibrate` with {x, y, z, facing}, Use GPS / Scan / Safe dig buttons
"""
import os, sys
import lupa.lua52 as lua

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENTER, F12, BACKSPACE = 28, 88, 14
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
  version = "1.3.1" }"""


class Env:
    def __init__(self, events=(), lines=(), files=None, CW=51, CH=19, modem=True, src=True):
        self.rt = lua.LuaRuntime(unpack_returned_tuples=True)
        g = self.rt.globals()
        g.HOST_READ = lambda p: read(p)
        g.CW, g.CH, g.MW, g.MH = CW, CH, 0, 0
        g.MODEM = modem
        g.HOST_EVENT = self.host_event
        g.SCRIPT_EVENTS = self.rt.table_from([self.lua(e) for e in events])
        g.SCRIPT_LINES = self.rt.table_from(list(lines))
        self.M = self.rt.execute(read("tests/mock_cc.lua"))
        self.problems = []
        self.hosts = {"click": self.click, "tap": self.tap, "shot": self.shot, "fsnap": self.fsnap}
        self.shots, self.fsnaps = {}, {}
        if src:
            for d in ("/os", "/os/lib", "/os/apps"):
                self.M.FS[d] = True
            for p in ("os/lib/map.lua", "os/lib/claude.lua", "os/lib/json.lua", "os/apps/map.lua", "os/apps/drones.lua",
                      "os/lib/templates.lua"):
                self.M.FS["/" + p] = read("src/" + p)
        for k, v in (files or {}).items():
            self.M.FS[k] = v

    def lua(self, v):
        if isinstance(v, dict):
            return self.rt.table_from({k: self.lua(x) for k, x in v.items()})
        if isinstance(v, (list, tuple)):
            return self.rt.table_from([self.lua(x) for x in v])
        return v

    def host_event(self, name, *args):
        ev = self.hosts[name](*args)
        return None if ev is None else self.lua(ev)

    def screen(self):
        t = self.M.native
        return "\n".join(t.rows[y] for y in range(1, t.h + 1))

    def click(self, label, nth=1):
        t = self.M.native
        seen = 0
        for y in range(1, t.h + 1):
            i = t.rows[y].find(label)
            if i >= 0:
                seen += 1
                if seen == nth:
                    return ["mouse_click", 1, i + 1, y]
        self.problems.append("not on screen: %r\n%s" % (label, self.screen()))
        return None

    def tap(self, x, y):
        return ["mouse_click", 1, x, y]

    def shot(self, name):
        self.shots[name] = self.screen()
        return None

    def fsnap(self, path):
        self.fsnaps[path] = self.M.FS[path]
        return None

    def fs(self):
        return {k: v for k, v in self.M.FS.items()}

    def plain(self, v):
        if lua.lua_type(v) == "table":
            keys = list(v.keys())
            if keys and all(isinstance(k, int) for k in keys):
                return [self.plain(v[i]) for i in sorted(keys)]
            return {k: self.plain(x) for k, x in v.items()}
        return v

    def sent(self):
        return [{"to": self.M.sent[i].to, "msg": self.plain(self.M.sent[i].msg)} for i in range(1, len(self.M.sent) + 1)]

    def log(self):
        return "\n".join(self.M.log.values())

    def run_app(self, path, prelude=""):
        f = self.rt.eval("function(pre, path) local p = assert(load(pre, '=prelude', 't', _G)) p() "
                         "return pcall(function() dofile(path).main() end) end")
        return f(THEME + "\n" + prelude, path)


# ---------------------------------------------------------------- 1. the map library
UNIT = r"""
local map = dofile("/os/lib/map.lua")
local R = {}
local function ok(c, m) if not c then R[#R + 1] = m end end
ok(dofile("/os/lib/map.lua") == map, "not one shared instance")
local s, d = map.add({ {10, 64, 20, "minecraft:stone"}, {10, 65, 20, "minecraft:grass_block"}, {10, 66, 20, "air"},
                       {11, 64, 20, "minecraft:oak_log"}, {-3, 70, -17, "minecraft:diamond_ore"},
                       { x = 12, y = 63, z = 20, name = "minecraft:oak_planks" }, {13, 60, 21, "minecraft:water"},
                       {14, 50, 20, "minecraft:cave_air"}, {1, 999, 1, "minecraft:stone"}, {1, 2, 3}, "junk" })
ok(s == 8 and d == 0, "add stored " .. tostring(s) .. " dropped " .. tostring(d))
ok(map.get(10, 64, 20) == "minecraft:stone", "get")
ok(map.get(14, 50, 20) == "air", "cave_air not stored as air")
ok(map.get(1, 999, 1) == nil, "out of range y stored")
ok(map.get(99, 64, 99) == nil, "unknown block")
local y, n = map.surface(10, 20)
ok(y == 65 and n == "minecraft:grass_block", "surface " .. tostring(y) .. " " .. tostring(n))
map.add({ {10, 65, 20, "air"} })                -- the top block was dug: surface drops to the next one
y, n = map.surface(10, 20)
ok(y == 64 and n == "minecraft:stone", "surface after dig " .. tostring(y))
ok(map.cell(14, 20) == ".", "air-only column is not '.'")
ok(map.cell(500, 500) == "?", "unknown cell")
ok(map.category("minecraft:stone") == "#" and map.category("minecraft:dirt") == ":" and
   map.category("minecraft:water") == "~" and map.category("minecraft:lava") == "^" and
   map.category("minecraft:oak_log") == "T" and map.category("minecraft:oak_leaves") == "T" and
   map.category("minecraft:iron_ore") == "o" and map.category("minecraft:deepslate_diamond_ore") == "o" and
   map.category("minecraft:oak_planks") == "=" and map.category("minecraft:glass") == "=" and
   map.category("minecraft:stone_bricks") == "=" and map.category("minecraft:white_wool") == "=" and
   map.category("minecraft:bedrock") == "#" and map.category("minecraft:grass_block") == ":" and
   map.category("minecraft:sand") == ":" and map.category("minecraft:sandstone") == "#" and
   map.category("create:gearbox") == "=" and map.category("air") == ".", "categories")

local rows, legend, area = map.view(8, 18, 15, 22)
ok(#rows == 5 and #rows[1] == 8, "view size " .. #rows .. "x" .. #(rows[1] or ""))
ok(rows[3]:sub(3, 3) == "#" and rows[3]:sub(4, 4) == "T" and rows[3]:sub(5, 5) == "=" and rows[3]:sub(7, 7) == ".",
   "view row " .. tostring(rows[3]))
ok(rows[4]:sub(6, 6) == "~", "water " .. tostring(rows[4]))
ok(legend:find("# stone", 1, true) and legend:find("P protected", 1, true), "legend " .. legend)
local lrows = map.view(8, 18, 15, 22, 64, { { x = 8, z = 18, ch = "D" } })
ok(lrows[1]:sub(1, 1) == "D" and lrows[3]:sub(3, 3) == "#" and lrows[3]:sub(5, 5) == "?", "layer view / marks " .. lrows[3])
local big = map.view(0, 0, 500, 500)
ok(#big == 40 and #big[1] == 60, "view not capped to 60x40")

local f = map.find("ore", { x = 0, y = 64, z = 0 })
ok(#f == 1 and f[1].x == -3 and f[1].name == "minecraft:diamond_ore", "find ore")
map.add({ {0, 64, 1, "minecraft:oak_log"}, {50, 64, 50, "minecraft:birch_log"} })
f = map.find("LOG", { x = 0, y = 64, z = 0 }, 2)
ok(#f == 2 and f[1].x == 0 and f[2].x == 11, "find nearest first / limit")
ok(#map.find("air") >= 1 and #map.find("stone") >= 1, "find air/stone")

local inf = map.info()
ok(inf.total == 10 and inf.bounds.x1 == -3 and inf.bounds.x2 == 50 and inf.bounds.z1 == -17
   and inf.counts["T"] == 3 and inf.counts["o"] == 1, "info " .. textutils.serialize({ inf.total, inf.counts }))

-- protected areas
local p = map.protected()
ok(p.rev == 0 and #p.boxes == 0, "protect starts empty")
local i = map.protect({ name = "house", x1 = 12, z1 = 25, x2 = 8, z2 = 19 })
p = map.protected()
ok(i == 1 and p.rev == 1 and p.boxes[1].x1 == 8 and p.boxes[1].x2 == 12 and p.boxes[1].y1 == -64
   and p.boxes[1].y2 == 320, "protect add")
ok(map.isProtected(10, 64, 20) and not map.isProtected(13, 64, 20), "isProtected")
map.protect({ name = "farm", x1 = 0, z1 = 0, x2 = 1, z2 = 1, y1 = 70, y2 = 60 })
ok(map.protected().rev == 2 and map.protected().boxes[2].y1 == 60 and not map.isProtected(0, 50, 0), "protect y range")
ok(map.view(8, 18, 15, 22)[3]:sub(3, 3) == "P", "protected overlay")
ok(select(2, map.protect({ name = "x" })) ~= nil, "bad area accepted")
ok(map.unprotect(2) and map.protected().rev == 3 and #map.protected().boxes == 1, "unprotect")
ok(not map.unprotect(9), "unprotect missing")

-- disk: chunk files + index + protect, then read back by a fresh instance
local wrote = map.flush()
ok(wrote >= 3, "flush wrote " .. wrote)
ok(fs.exists("/os/map/0_1") and fs.exists("/os/map/-1_-2") and fs.exists("/os/map/index") and fs.exists("/os/map/protect"),
   "files " .. table.concat(fs.list("/os/map"), " "))
ok(map.flush() == 0, "second flush wrote again")
WardenMap = nil
local m2 = dofile("/os/lib/map.lua")
ok(m2 ~= map, "fresh instance")
ok(m2.count() == 10 and m2.get(10, 64, 20) == "minecraft:stone" and m2.get(-3, 70, -17) == "minecraft:diamond_ore"
   and m2.get(12, 63, 20) == "minecraft:oak_planks" and m2.get(10, 65, 20) == "air", "read back")
local y2 = m2.surface(10, 20)
ok(y2 == 64, "surface after reload " .. tostring(y2))
ok(m2.protected().rev == 3 and m2.protected().boxes[1].name == "house", "protect read back")
-- index lost: rebuilt from the chunk files
fs.delete("/os/map/index")
WardenMap = nil
local m3 = dofile("/os/lib/map.lua")
ok(m3.count() == 10, "index rebuild " .. m3.count())

-- the cap: known blocks still update, new ones are dropped
m3.CAP = 11
local s2, d2 = m3.add({ {10, 64, 20, "minecraft:cobblestone"}, {100, 64, 100, "minecraft:stone"}, {101, 64, 100, "minecraft:stone"} })
ok(s2 == 2 and d2 == 1 and m3.get(10, 64, 20) == "minecraft:cobblestone" and m3.count() == 11, "cap " .. s2 .. " " .. d2)
ok(m3.info().full, "info.full")
return R
"""
env = Env()
res = env.rt.execute(UNIT)
for i in range(1, len(res) + 1):
    check(False, "map: " + res[i])
size = sum(len(v) for k, v in env.fs().items() if k.startswith("/os/map/") and isinstance(v, str))
check(size < 2000, "map: %d bytes on disk for 11 blocks" % size)

# bulk: 20000 blocks, bytes per block on disk
BULK = r"""
local map = dofile("/os/lib/map.lua")
local obs = {}
for x = 0, 99 do for z = 0, 199 do obs[#obs + 1] = { x, 60 + (x + z) % 5, z, (x * z) % 3 == 0 and "air" or "minecraft:stone" }
  if #obs == 500 then map.add(obs) obs = {} end end end
map.add(obs)
map.flush()
local rows = map.view(0, 0, 59, 39)
return map.count(), #rows
"""
env = Env()
n, rows = env.rt.execute(BULK)
size = sum(len(v) for k, v in env.fs().items() if k.startswith("/os/map/") and isinstance(v, str))
check(n == 20000 and rows == 40, "map bulk: %s blocks %s rows" % (n, rows))
check(size / 20000 < 3.3, "map bulk: %.2f bytes per block" % (size / 20000))
# zoom: aggregation priority, marks, scale text, the 60x40 character cap, zoom normalization, the grid cache
ZOOM = r"""
local map = dofile("/os/lib/map.lua")
local R = {}
local function ok(c, m) if not c then R[#R + 1] = m end end
local obs = {}
for x = 0, 7 do for z = 0, 7 do obs[#obs + 1] = { x, 64, z, "minecraft:stone" } end end
obs[#obs + 1] = { 5, 64, 5, "minecraft:oak_planks" }              -- building in cell (1,1) at zoom 4
obs[#obs + 1] = { 17, 64, 2, "minecraft:dirt" }                   -- one known column in an unknown cell
obs[#obs + 1] = { 24, 64, 0, "minecraft:water" } obs[#obs + 1] = { 25, 60, 1, "minecraft:iron_ore" }
obs[#obs + 1] = { 28, 64, 0, "air" } obs[#obs + 1] = { 29, 64, 1, "minecraft:poppy" }
obs[#obs + 1] = { 32, 64, 0, "air" }
map.add(obs)
ok(map.zoom(3) == 2 and map.zoom(5) == 4 and map.zoom(7) == 8 and map.zoom(100) == 16 and map.zoom(0) == 1
   and map.zoom(-4) == 1 and map.zoom("x") == 1 and map.zoom(nil) == 1 and map.zoom("16") == 16, "zoom normalize")
local rows, legend, area = map.view(0, 0, 7, 7, nil, nil, 4)
ok(#rows == 2 and rows[1] == "##" and rows[2] == "#=", "zoom 4 building beats stone " .. table.concat(rows, "/"))
ok(area.zoom == 4 and area.w == 2 and area.h == 2 and area.scale == "1 char = 4x4 blocks" and area.x2 == 7,
   "zoom 4 area " .. textutils.serialize(area))
ok(legend:find("1 char = 4x4 blocks", 1, true) and legend:find("# stone", 1, true), "zoom 4 legend " .. legend)
ok(area.ylo == 64 and area.yhi == 64, "surface y range")
rows = map.view(0, 0, 7, 7, nil, nil, 2)
ok(#rows == 4 and rows[3] == "##=#" and rows[1] == "####", "zoom 2 " .. table.concat(rows, "/"))
rows = map.view(0, 0, 100, 100, nil, nil, 16)
ok(#rows == 7 and #rows[1] == 7 and rows[1] == "=o.????" and rows[2] == "???????", "zoom 16 " .. table.concat(rows, "/"))
rows = map.view(16, 0, 35, 3, nil, nil, 4)
ok(rows[1] == ":?o,.", "known beats unknown / ore beats water / plants beat air " .. tostring(rows[1]))
rows = map.view(0, 0, 7, 7, 64, nil, 4)
ok(rows[1] == "##" and rows[2] == "#=", "layer zoom " .. table.concat(rows, "/"))
rows = map.view(0, 0, 7, 7, 65, nil, 4)
ok(rows[1] == "??" and rows[2] == "??", "layer zoom, nothing at y " .. table.concat(rows, "/"))
-- marks land in the cell that contains them; D/H beat blocks
rows = map.view(0, 0, 7, 7, nil, { { x = 6, z = 1, ch = "D" }, { x = 5, z = 6, ch = "H" }, { x = 99, z = 99 } }, 4)
ok(rows[1] == "#D" and rows[2] == "#H", "zoom marks " .. table.concat(rows, "/"))
-- the cap: 60 x 40 characters
rows, legend, area = map.view(0, 0, 5000, 5000, nil, nil, 16)
ok(#rows == 40 and #rows[1] == 60 and area.x2 == 959 and area.z2 == 639 and area.w == 60 and area.h == 40,
   "zoom 16 cap " .. #rows .. "x" .. #rows[1] .. " " .. area.x2)
rows, legend, area = map.view(0, 0, 5000, 5000, nil, nil, 5)
ok(area.zoom == 4 and #rows == 40 and #rows[1] == 60 and area.x2 == 239, "zoom 5 -> 4")
rows, legend, area = map.view(0, 0, 7, 7, nil, nil, "junk")
ok(area.zoom == 1 and #rows == 8 and area.scale == "1 char = 1 block" and not legend:find("char =", 1, true), "bad zoom -> 1")
-- the grid cache: same table while nothing changes, rebuilt after add() and protect()
local g1 = map.grid(0, 0, 7, 7, nil, 4)
ok(map.grid(0, 0, 7, 7, nil, 4) == g1, "grid not cached")
ok(g1.name[4] == "minecraft:oak_planks" and g1.by[4] == 64, "grid dominant block " .. tostring(g1.name[4]))
local rev = map.rev
map.add({ { 1, 64, 1, "minecraft:lava" } })
ok(map.rev > rev and map.grid(0, 0, 7, 7, nil, 4) ~= g1, "grid not rebuilt after add")
ok(map.view(0, 0, 7, 7, nil, nil, 4)[1] == "^#", "lava beats stone")
-- protected overlay wins over everything at zoom > 1 (also over a drone), only when the layer is inside its y range
map.protect({ name = "p", x1 = 1, z1 = 1, x2 = 1, z2 = 1 })
map.protect({ name = "high", x1 = 4, z1 = 4, x2 = 4, z2 = 4, y1 = 100, y2 = 120 })
rows = map.view(0, 0, 7, 7, nil, { { x = 2, z = 2, ch = "D" } }, 4)
ok(rows[1] == "P#" and rows[2] == "#P", "zoom protected overlay " .. table.concat(rows, "/"))
rows = map.view(0, 0, 7, 7, 64, nil, 4)
ok(rows[1] == "P#" and rows[2] == "#=", "zoom protected overlay, layer " .. table.concat(rows, "/"))
ok(map.view(0, 0, 7, 7, nil, { { x = 1, z = 1, ch = "D" } })[2]:sub(2, 2) == "D", "zoom 1: marks still on top")
return R
"""
env = Env()
res = env.rt.execute(ZOOM)
for i in range(1, len(res) + 1):
    check(False, "map zoom: " + res[i])

# speed: 400000 blocks over 800 x 500 columns, one 60 x 40 view at zoom 16 (960 x 640 blocks), surface and layer
PERF = r"""
local map = dofile("/os/lib/map.lua")
map.CAP = 1000000
local names = { "minecraft:stone", "minecraft:grass_block", "minecraft:oak_log", "minecraft:water", "minecraft:sand" }
local obs = {}
for x = 0, 799 do for z = 0, 499 do
  obs[#obs + 1] = { x, 60 + (x * 7 + z * 3) % 9, z, names[(x * z) % 5 + 1] }
  if #obs == 512 then map.add(obs) obs = {} end end end
map.add(obs)
local t0 = os.clock()
local rows = map.view(-80, -70, 2000, 2000, nil, nil, 16)
local t1 = os.clock()
local lrows = map.view(-80, -70, 2000, 2000, 64, nil, 16)
local t2 = os.clock()
map.view(-80, -70, 2000, 2000, 64, nil, 16)
local t3 = os.clock()
return map.count(), t1 - t0, t2 - t1, t3 - t2, #rows, #rows[1], rows[10]
"""
env = Env()
n, ts, tl, tc, nr, nc, r10 = env.rt.execute(PERF)
print("map zoom 16 view over %d blocks: surface %.3f s, layer %.3f s, cached %.4f s (plain Lua)" % (n, ts, tl, tc))
check(n == 400000 and nr == 40 and nc == 60 and "?" not in r10[6:55], "map perf: %s blocks %sx%s %r" % (n, nr, nc, r10))
check(ts < 0.5 and tl < 0.5, "map perf: zoom 16 view too slow: %.3f / %.3f s" % (ts, tl))
check(tc < 0.01, "map perf: cached view not cached: %.4f s" % tc)
print("map library: ok (%.2f bytes/block on disk)" % (size / 20000) if not fail else "map library: FAILED")
nfail = len(fail)

# ---------------------------------------------------------------- 2. the kernel hook
inst = Env(events=[["key", ENTER]] + [["key", 208]] * 80 + [["key", ENTER]] * 3,
           lines=["AGREE", "", "dino", "secret1", "secret1", "ERASE"], src=False)
f = inst.rt.eval("function(src) local f = load(src, '=install.lua', 't', _G) return pcall(f) end")
f(read("install.lua"))
DESK = inst.fs()
check("/os/lib/map.lua" in DESK and "/os/lib/world.lua" in DESK and "/os/apps/map.lua" in DESK, "install: map files missing")


def tstatus(owner, rev, label="miner", abs_=None):
    d = {"t": "status", "kind": "turtle", "version": "1.3.1", "label": label, "owner": owner, "fuel": 500,
         "fuelLimit": 20000, "fuelItems": 12, "task": "manual", "state": "ready", "log": [], "homeSet": True,
         "nav": {"x": 0, "y": 0, "z": 0, "f": 0}, "calibrated": abs_ is not None, "safeDig": True, "protectRev": rev}
    if abs_:
        d["abs"] = {"x": abs_[0], "y": abs_[1], "z": abs_[2], "f": 1}
        d["origin"] = {"x": abs_[0] - 2, "y": abs_[1], "z": abs_[2], "f": 0}
    return d


files = dict(DESK)
files["/os/map"] = True
files["/os/map/protect"] = '{rev = 2, boxes = {{name = "base", x1 = 0, y1 = -64, z1 = 0, x2 = 9, y2 = 320, z2 = 9}}}'
login = [["key", ENTER]] + [["char", ch] for ch in "secret1"] + [["key", ENTER]]
obs = [[5, 64, 5, "minecraft:stone"], [5, 65, 5, "air"], [40, 70, -40, "minecraft:oak_log"]]
env = Env(events=login + [
    ["rednet_message", 12, {"t": "map", "obs": obs}, "wardenos"],
    ["rednet_message", 12, tstatus(7, 0), "wardenos"],         # mine, old copy: push
    ["rednet_message", 12, tstatus(7, 0), "wardenos"],         # again right away: rate-limited
    ["rednet_message", 13, tstatus(99, 0), "wardenos"],        # someone else's drone: never
    ["rednet_message", 14, tstatus(7, 2), "wardenos"],         # mine, up to date: nothing
    ["rednet_message", 15, {"t": "status", "kind": "turtle", "owner": 7}, "wardenos"],   # old agent: no protectRev
    ["rednet_message", 30, {"t": "map", "obs": "junk"}, "wardenos"],
    ["key", F12]], files=files, src=False)
f = env.rt.eval("function(src) local f = load(src, '=startup.lua', 't', _G) local ok, r = pcall(f) return ok, r end")
ok, err = f(env.fs()["/startup.lua"])
log = env.log()
check(ok and "stopped" in log and "Kernel error" not in log, "kernel: %s %s" % (err, log[-300:]))
pushes = [m for m in env.sent() if m["msg"].get("t") == "cmd" and m["msg"].get("cmd") == "protect"]
check(len(pushes) == 1 and pushes[0]["to"] == 12, "kernel: protect pushes %s" % pushes)
if pushes:
    m = pushes[0]["msg"]
    check(m["to"] == 12 and m["seq"] >= 3000000 and m["arg"]["rev"] == 2 and len(m["arg"]["boxes"]) == 1
          and m["arg"]["boxes"][0]["x2"] == 9 and m["arg"]["boxes"][0]["name"] == "base", "kernel: protect message %s" % m)
fsk = env.fs()
idx = fsk.get("/os/map/index", "")
check("0_0" in idx and "2_-3" in idx, "kernel: map not written on exit: %s" % sorted(k for k in fsk if k.startswith("/os/map")))
check("minecraft:stone" in fsk.get("/os/map/0_0", "") and "minecraft:oak_log" in fsk.get("/os/map/2_-3", ""),
      "kernel: chunk contents")
check(env.M.violations == 0, "kernel: drew off-screen")
# the game/server stops without a clean exit (no F12, no shutdown): the periodic flush must already have saved
files = dict(DESK)
env = Env(events=login + [["rednet_message", 12, {"t": "map", "obs": obs}, "wardenos"], ["host", "fsnap", "/os/map/index"]]
          + [["timer", 900 + i] for i in range(8)], files=files, src=False)
env.rt.execute("CLK = 0 os.clock = function() CLK = CLK + 1 return CLK end")   # every look at the clock: +1 s
boot = env.rt.eval("function(src) local f = load(src, '=startup.lua', 't', _G) local ok, r = pcall(f) return ok, r end")
ok, err = boot(env.fs()["/startup.lua"])
fsk = env.fs()
check("minecraft:stone" in fsk.get("/os/map/0_0", "") and "0_0" in fsk.get("/os/map/index", ""),
      "map not saved before an unclean stop: %s" % sorted(k for k in fsk if k.startswith("/os/map")))
# ... and a fresh boot (new Lua state) reads it back
env2 = Env(files={k: v for k, v in fsk.items()}, src=True)
got = env2.rt.eval("function() local m = dofile('/os/lib/map.lua') return m.get(5, 64, 5), m.get(40, 70, -40) end")()
check(got == ("minecraft:stone", "minecraft:oak_log"), "map after restart: %s" % (got,))
print("kernel hook: ok" if len(fail) == nfail else "kernel hook: FAILED")
nfail = len(fail)

# ---------------------------------------------------------------- 3. the Map app (window content 46x17)
SEED = r"""
local map = dofile("/os/lib/map.lua")
local obs = {}
for x = 90, 110 do for z = 195, 205 do
  obs[#obs + 1] = { x, 64, z, (x == 100 and "minecraft:water") or (z == 195 and "minecraft:oak_planks") or "minecraft:grass_block" }
end end
map.add(obs)
WardenOS.drones = { [12] = { kind = "turtle", owner = 7, calibrated = true, abs = { x = 100, y = 65, z = 200, f = 1 },
                             origin = { x = 95, y = 64, z = 200, f = 0 }, seen = os.clock() } }
"""
# view centered on the drone at x=100, z=200: left = 100 - 23 = 77, top = 200 - 6 = 194; block (x, z) is at
# screen column x - 76, row z - 194 + 2
col = lambda x: x - 76
row = lambda z: z - 194 + 2
env = Env(CW=46, CH=17, events=[
    ["host", "shot", "first"],
    ["host", "tap", col(105), row(198)],
    ["host", "shot", "tapped"],
    ["host", "click", " Protect "],
    ["host", "tap", col(90), row(195)],
    ["host", "tap", col(96), row(199)],
    ["host", "shot", "name"],
] + [["char", ch] for ch in "my house"] + [["key", ENTER],
    ["host", "shot", "saved"], ["host", "fsnap", "/os/map/protect"],
    ["host", "click", " > "], ["host", "click", " v "], ["key", 203], ["key", 200], ["mouse_scroll", 1, 10, 5],
    ["host", "click", " Layer "], ["host", "click", " y+ "], ["host", "shot", "layer"], ["host", "click", " Surf "],
    ["host", "click", " Center "], ["host", "shot", "center"],
    ["host", "click", " Areas "], ["host", "shot", "areas"],
    ["host", "click", " delete "], ["host", "click", " sure? "], ["host", "shot", "deleted"],
    ["host", "click", " < "],
    ["host", "click", " Protect "], ["host", "click", " Cancel "],
    ["timer", 1], ["theme_changed"],
])
ok, err = env.run_app("/os/apps/map.lua", SEED)
sh = env.shots
check(not ok and err == "SCRIPT_END", "map app: did not run to the end: %s" % err)
check(env.M.violations == 0, "map app: %d chars off-screen %s" % (env.M.violations,
      [l for l in env.M.log.values() if "OFFSCREEN" in l][:3]))
check(not env.problems, "map app: %s" % env.problems)
first = sh.get("first", "").split("\n")
check(len(first) == 17 and all(len(r) == 46 for r in first), "map app: screen size")
check("Map" in first[0] and "surface" in first[0] and "100,200" in first[0], "map app: header %r" % first[0][:46])
check(first[row(200) - 1][col(100) - 1] == "D" and first[row(200) - 1][col(95) - 1] == "H",
      "map app: drone/home marker:\n" + sh.get("first", ""))
check(first[row(198) - 1][col(100) - 1] == "~" and first[row(198) - 1][col(105) - 1] == ":"
      and first[row(195) - 1][col(105) - 1] == "=", "map app: map cells:\n" + sh.get("first", ""))
check("105 64 198  minecraft:grass_block" in sh.get("tapped", ""), "map app: tap info:\n" + sh.get("tapped", ""))
check("Name (y1 y2 optional)" in sh.get("name", ""), "map app: no name prompt:\n" + sh.get("name", ""))
check("protected: my house" in sh.get("saved", ""), "map app: not saved:\n" + sh.get("saved", ""))
pr = env.fsnaps.get("/os/map/protect", "")
unser = lambda s: env.plain(env.rt.eval("function(s) return textutils.unserialize(s) end")(s or "nil"))
pb = (unser(pr) or {}).get("boxes") or [{}]
check(pb[0] == {"name": "my house", "x1": 90, "x2": 96, "z1": 195, "z2": 199, "y1": -64, "y2": 320},
      "map app: protect file %s" % pr)
check("y=65" in sh.get("layer", "").split("\n")[0], "map app: layer mode:\n" + sh.get("layer", ""))
check("centered on drone #12" in sh.get("center", ""), "map app: center:\n" + sh.get("center", ""))
check("my house" in sh.get("areas", "") and "x 90..96" in sh.get("areas", ""), "map app: areas:\n" + sh.get("areas", ""))
check("No protected areas" in sh.get("deleted", "") and (unser(env.fs().get("/os/map/protect")) or {}).get("rev") == 2,
      "map app: delete:\n" + sh.get("deleted", ""))

# zoom: buttons and keys change the scale, the center stays, tap info and the protect flow at zoom 4
# at zoom z: left = (floor(100 / z) - 23) * z, top = (floor(200 / z) - 6) * z; block (x, z) is in screen
# column floor((x - left) / z) + 1, row floor((z - top) / z) + 2
zcol = lambda x, z=4: (x - (100 // z - 23) * z) // z + 1
zrow = lambda bz, z=4: (bz - (200 // z - 6) * z) // z + 2
env = Env(CW=46, CH=17, events=[
    ["host", "click", " + "], ["host", "shot", "z1"],                     # already at 1: stays
    ["key", 209], ["host", "shot", "z2"],                                  # PageDown: zoom out
    ["char", "-"], ["host", "shot", "z4"],
    ["host", "tap", zcol(104), zrow(196)], ["host", "shot", "tap4"],
    ["host", "click", " Protect "],
    ["host", "tap", zcol(88), zrow(192)], ["host", "shot", "corner4"],
    ["host", "tap", zcol(96), zrow(200)],
] + [["char", ch] for ch in "zoomed"] + [["key", ENTER], ["host", "fsnap", "/os/map/protect"],
    ["host", "click", " + "], ["host", "shot", "in2"], ["char", "+"], ["host", "shot", "in1"],
    ["key", 209], ["key", 209], ["key", 209], ["key", 209], ["key", 209], ["host", "shot", "z16"],
    ["key", 205], ["host", "shot", "pan16"], ["host", "click", " Center "], ["host", "shot", "center16"],
    ["mouse_scroll", 1, 10, 5], ["host", "shot", "scroll16"],
    ["host", "click", " Layer "], ["host", "click", " + "], ["host", "shot", "layer16"],
    ["key", 201], ["host", "shot", "layer4"],
    ["host", "tap", 1, 2], ["host", "tap", 46, 14], ["timer", 1],
])
ok, err = env.run_app("/os/apps/map.lua", SEED)
sh = env.shots
check(err == "SCRIPT_END" and not env.problems, "map zoom app: %s %s" % (err, env.problems))
check(env.M.violations == 0, "map zoom app: %d chars off-screen %s" % (env.M.violations,
      [l for l in env.M.log.values() if "OFFSCREEN" in l][:3]))
hdr = lambda k: sh.get(k, "").split("\n")[0]
for k, zz in (("z1", 1), ("z2", 2), ("z4", 4), ("in2", 2), ("in1", 1), ("z16", 16)):
    check((" x%d " % zz) in hdr(k) and "100,200" in hdr(k), "map zoom app: %s header %r" % (k, hdr(k)))
z4 = sh.get("z4", "").split("\n")
check(len(z4) == 17 and z4[zrow(200) - 1][zcol(100) - 1] == "D" and z4[zrow(200) - 1][zcol(95) - 1] == "H",
      "map zoom app: zoom 4 markers / center:\n" + sh.get("z4", ""))
check(z4[zrow(196) - 1][zcol(100) - 1] == "~" and z4[zrow(196) - 1][zcol(104) - 1] == ":"
      and z4[zrow(192) - 1][zcol(104) - 1] == "=", "map zoom app: zoom 4 cells:\n" + sh.get("z4", ""))
check("x104..107 z196..199 y64 grass_block" in sh.get("tap4", ""), "map zoom app: tap info:\n" + sh.get("tap4", ""))
check("corner 1: 88..91 192..195" in sh.get("corner4", ""), "map zoom app: corner:\n" + sh.get("corner4", ""))
pb = (unser(env.fsnaps.get("/os/map/protect")) or {}).get("boxes") or [{}]
check(pb[0] == {"name": "zoomed", "x1": 88, "x2": 99, "z1": 192, "z2": 203, "y1": -64, "y2": 320},
      "map zoom app: protect box %s" % pb)
in1 = sh.get("in1", "").split("\n")
check(in1[row(200) - 1][col(100) - 1] == "D", "map zoom app: back at zoom 1:\n" + sh.get("in1", ""))
check("x16 276,200" in hdr("pan16"), "map zoom app: pan at zoom 16 %r" % hdr("pan16"))
c16 = sh.get("center16", "").split("\n")
check("centered on drone #12" in sh.get("center16", "") and c16[zrow(200, 16) - 1][zcol(100, 16) - 1] == "D",
      "map zoom app: center at zoom 16:\n" + sh.get("center16", ""))
check("100,264" in hdr("scroll16"), "map zoom app: scroll at zoom 16 %r" % hdr("scroll16"))
check(" x8 " in hdr("layer16") and "y=" in hdr("layer16") and " x4 " in hdr("layer4"), "map zoom app: layer + zoom %r %r"
      % (hdr("layer16"), hdr("layer4")))

# the view survives a restart: the last center, zoom and layer are saved in /os/map/view and come back
saved = env.fs().get("/os/map/view")
sv = unser(saved) or {}
check(sv.get("zoom") == 4 and sv.get("layer") is not None, "map view file %r" % saved)
env = Env(CW=46, CH=17, files={"/os/map": True, "/os/map/view": saved}, events=[["host", "shot", "again"]])
ok, err = env.run_app("/os/apps/map.lua", SEED)
again = env.shots.get("again", "").split("\n")[0]
check(err == "SCRIPT_END" and " x4 " in again and ("y=%d" % sv.get("layer", -999)) in again
      and ("%d,%d" % (sv.get("cx", 0), sv.get("cz", 0))) in again, "map view restored %r %r" % (err, again))

# empty map, no drones, no modem: still draws
env = Env(CW=46, CH=17, modem=False, events=[["host", "shot", "empty"], ["host", "tap", 20, 8], ["host", "click", " Center "],
                                              ["host", "click", " Areas "], ["host", "shot", "areas"]])
ok, err = env.run_app("/os/apps/map.lua")
check(err == "SCRIPT_END" and env.M.violations == 0 and not env.problems, "map app empty: %s %s" % (err, env.problems))
check("0 blocks known" in env.shots.get("empty", "") or "not seen yet" in env.screen(), "map app empty:\n" + env.shots.get("empty", ""))
print("map app: ok" if len(fail) == nfail else "map app: FAILED")
nfail = len(fail)

# ---------------------------------------------------------------- 4. Drones app: calibrate, GPS, scan, safe dig
st = tstatus(7, 2)
st["pos"] = [120, 64, -30]
st["calibrated"] = False
st2 = tstatus(7, 2, abs_=(120, 64, -30))
env = Env(CW=46, CH=17, events=[
    ["rednet_message", 12, st, "wardenos"],
    ["host", "click", "#12 miner"],
    ["host", "shot", "detail"],
    ["host", "click", " Calibrate "],
    ["host", "shot", "form"],
    ["key", BACKSPACE], ["char", "x"], ["key", ENTER], ["host", "shot", "bad"],
    ["key", BACKSPACE], ["char", "E"],
    ["host", "click", " Send "],
    ["host", "click", " Calibrate "], ["host", "click", " Use GPS "],
    ["host", "click", " Scan "],
    ["host", "click", " Safe dig: on "],
    ["rednet_message", 12, st2, "wardenos"],
    ["host", "shot", "calibrated"],
])
ok, err = env.run_app("/os/apps/drones.lua", 'rednet.open("back")')
check(err == "SCRIPT_END", "drones app: %s" % err)
check(env.M.violations == 0 and not env.problems, "drones app: %d off-screen, %s" % (env.M.violations, env.problems))
cmds = [m["msg"] for m in env.sent() if m["msg"].get("t") == "cmd"]
check([c["cmd"] for c in cmds] == ["calibrate", "calibrate", "scan", "safedig"], "drones app: commands %s" % cmds)
if len(cmds) == 4:
    check(cmds[0].get("arg") == {"x": 120, "y": 64, "z": -30, "facing": 1}, "drones app: calibrate arg %s" % cmds[0].get("arg"))
    check(cmds[1].get("arg") is None, "drones app: GPS calibrate has an arg %s" % cmds[1])
    check(cmds[3].get("arg") is False, "drones app: safedig arg %s" % cmds[3])
    check(all(c["to"] == 12 for c in cmds), "drones app: wrong drone")
check("coal: 12" in env.shots.get("detail", "") and "not calibrated" in env.shots.get("detail", "")
      and "safe dig on" in env.shots.get("detail", ""), "drones app: detail:\n" + env.shots.get("detail", ""))
check("> 120 64 -30" in env.shots.get("form", ""), "drones app: form not prefilled from GPS:\n" + env.shots.get("form", ""))
check("facing: N, E, S or W" in env.shots.get("bad", ""), "drones app: bad input not explained:\n" + env.shots.get("bad", ""))
check("120 64 -30 E" in env.shots.get("calibrated", ""), "drones app: abs position:\n" + env.shots.get("calibrated", ""))
print("drones app: ok" if len(fail) == nfail else "drones app: FAILED")
nfail = len(fail)

# ---------------------------------------------------------------- 5. Drones app: templates
TPL = r"""
local t = dofile("/os/lib/templates.lua")
assert(t.save({ name = "Cross 9x15", description = "builds a cross of cobblestone on the hill top", author = "claude",
                code = "local WIDTH = 9\nlocal HEIGHT = 15\nfor i = 1, HEIGHT do turtle.up() end\nreturn 'ok'" }))
assert(t.save({ name = "Dig 3", description = "digs 3 forward", author = "player", code = "for i = 1, 3 do turtle.dig() end" }))
assert(not t.save({ name = "bad", code = "for do" }))
assert(t.slug("My Cool/Thing!") == "my_cool_thing_")
"""
env = Env(CW=46, CH=17, events=[
    ["rednet_message", 12, tstatus(7, 2), "wardenos"],
    ["rednet_message", 13, tstatus(7, 2, label="helper"), "wardenos"],
    ["host", "click", " templates "], ["host", "shot", "list"],
    ["host", "click", "Cross 9x15"], ["host", "shot", "detail"],
    ["host", "click", " Run on #13 "],
    ["rednet_message", 13, {"t": "ack", "seq": 1, "cmd": "run", "ok": True, "info": "started"}, "wardenos"],
    ["host", "shot", "acked"],
    ["host", "click", " < "], ["host", "click", "Dig 3"], ["host", "click", " Delete "], ["host", "click", " Sure? delete "],
    ["host", "shot", "deleted"],
    ["host", "click", " < "], ["host", "click", "#12 miner"], ["host", "shot", "drone"],
    ["host", "click", " Templates "], ["host", "click", "Cross 9x15"], ["host", "shot", "pre"],
    ["host", "click", " Run on #12 "],
])
ok, err = env.run_app("/os/apps/drones.lua", 'rednet.open("back")\n' + TPL)
sh = env.shots
check(err == "SCRIPT_END", "templates: %s" % err)
check(env.M.violations == 0 and not env.problems, "templates: %d off-screen, %s" % (env.M.violations, env.problems))
check("Templates (2)" in sh.get("list", "") and "AI Cross 9x15" in sh.get("list", "") and "Dig 3" in sh.get("list", ""),
      "templates: list:\n" + sh.get("list", ""))
det = sh.get("detail", "")
check("by Claude" in det and "builds a cross" in det and "local WIDTH = 9" in det and " Run on #12 " in det
      and " Run on #13 " in det and " Delete " in det, "templates: detail:\n" + det)
check("run ok: started" in sh.get("acked", ""), "templates: ack:\n" + sh.get("acked", ""))
check("deleted Dig 3" in sh.get("deleted", "") and "/os/templates/dig_3.dat" not in env.fs(), "templates: delete:\n" + sh.get("deleted", ""))
check(" Templates " in sh.get("drone", ""), "templates: no button in the drone view:\n" + sh.get("drone", ""))
check(" Run on #12 " in sh.get("pre", "") and " Run on #13 " not in sh.get("pre", ""), "templates: not preselected:\n" + sh.get("pre", ""))
runs = [m for m in env.sent() if m["msg"].get("cmd") == "run"]
check([m["to"] for m in runs] == [13, 12] and runs[0]["msg"]["arg"]["name"] == "Cross 9x15"
      and "local WIDTH = 9" in runs[0]["msg"]["arg"]["code"], "templates: run messages %s" % runs)
print("drones templates: ok" if len(fail) == nfail else "drones templates: FAILED")
nfail = len(fail)

# pocket server: pocket_templates lists them (with code, so the pocket can send pocket_cmd "run")
files = dict(DESK)
files["/os/pockets"] = "{[20] = true}"
env = Env(files=files, src=False)
env.rt.execute('rednet.open("back")\n' + TPL)
S = env.rt.execute('return dofile("/os/lib/pocketserver.lua")')
S.event(env.lua(["rednet_message", 20, {"t": "pocket_templates"}, "wardenos", ]))
last = env.sent()[-1] if env.sent() else {}
tl = last.get("msg", {}).get("templates", []) if last.get("to") == 20 else []
check(last.get("msg", {}).get("t") == "pocket_templates" and [t["name"] for t in tl] == ["Cross 9x15", "Dig 3"]
      and "local WIDTH" in tl[0]["code"] and tl[0]["author"] == "claude", "pocket_templates: %s" % last)
print("pocket templates: ok" if len(fail) == nfail else "pocket templates: FAILED")

print()
if fail:
    print("%d problem(s)" % len(fail))
    sys.exit(1)
print("all map checks passed")
