#!/usr/bin/env python3
"""MineView checks (sampler, storage, app). Run from anywhere:  python3 tests/test_mineview.py
(needs: pip install lupa). Exit code 1 on failure.

1. sampler through /os/lib/world.lua (the kernel's hook): auto mode uses only the ME bridge when there is one;
   inventory mode sums every chest (one stub chest yields for task_complete like a real main-thread call:
   other events keep flowing while the sampling coroutine waits, a wrong task id doesn't wake it);
   turtles/computers skipped; a detached and a failing chest never create fake production/consumption;
   candles of every timeframe (OHLC + produced/consumed) against an independent reference, hourly roll-up over
   30 h, raw window pruned to 24 h; failed sources logged; a source that never answers is abandoned
2. persistence: appended and compacted files reload to the same items/candles (read-only instance)
3. item cap (largest + pinned, no churn), limit setting, disk low (nothing written, status + UI say so),
   history budget, clear
4. app: watchlist / chart / flow / crosshair / timeframes / pan / filter / pin / settings / pick list / clear /
   empty state / read-only, nothing drawn outside the window at 45x17, 45x18, 51x19, 79x36, 158x79
5. storage size estimate (bytes per item per day)
"""
import math, os, re, sys
import lupa.lua52 as lua

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENTER, BACKSPACE, LEFT, RIGHT, UP, DOWN = 28, 14, 203, 205, 200, 208
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
  version = "1.5.2" }"""

# strict bounds check for buffered windows + a record of the colours blitted by the last full-size buffer
STRICT = r"""
WINDOW_VIOLATIONS, WINDOW_LOG, BLITS = 0, {}, {}
local create = window.create
window.create = function(parent, x, y, w, h, vis)
  local t = create(parent, x, y, w, h, vis)
  BLITS = {}
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
    if cx < 1 or cx + #s - 1 > tw or cy < 1 or cy > th then
      if s:match("^ +$") then WINDOW_VIOLATIONS = WINDOW_VIOLATIONS + 1 WINDOW_LOG[#WINDOW_LOG + 1] = "blank " .. cx .. "," .. cy end
    end
    return write(s)
  end
  t.blit = function(s, f, b)
    local cx, cy = t.getCursorPos()
    if #s ~= #f or #s ~= #b then WINDOW_VIOLATIONS = WINDOW_VIOLATIONS + 1 WINDOW_LOG[#WINDOW_LOG + 1] = "blit lengths" end
    BLITS[#BLITS + 1] = { x = cx, y = cy, s = s, f = f, b = b }
    return t.write(s)
  end
  return t
end
"""

# stub peripherals: chest_0 (instant), chest_1 (yields for task_complete like a main-thread call), meBridge_0,
# a turtle and a computer (never counted). SCHED[STEP] = { c0 = {name=count}, c1 = {..} | "detached" | "error",
# me = {name=count} } drives the contents.
PERIPHS = r"""
DETACHED, SCHED, STEP, TASKS, PENDING, YIELDS = {}, {}, 1, 0, nil, 0
HANG = false
local function slots(c)
  local out, i = {}, 0
  local names = {}
  for n in pairs(c or {}) do names[#names + 1] = n end
  table.sort(names)
  for _, n in ipairs(names) do
    local left = c[n]
    while left > 0 do                             -- split into stacks of 64 (summed again by the sampler)
      i = i + 1
      out[i * 2] = { name = n, count = math.min(64, left), nbt = (i % 3 == 0) and "abc" or nil }
      left = left - 64
    end
  end
  return out
end
local P = {
  chest_0 = { types = { "minecraft:chest", "inventory" }, m = {
    size = function() return 54 end, list = function() return slots(SCHED[STEP].c0) end,
    getItemDetail = function() return nil end } },
  chest_1 = { types = { "minecraft:barrel", "inventory" }, m = {
    size = function() return 27 end,
    list = function()
      TASKS = TASKS + 1
      local id = TASKS
      PENDING = id
      while true do                               -- like CC: a main-thread task, finished by task_complete
        local ev = table.pack(os.pullEvent("task_complete"))
        YIELDS = YIELDS + 1
        if ev[2] == id then break end
      end
      PENDING = nil
      if HANG then while true do os.pullEvent("never") end end
      local c = SCHED[STEP].c1
      if c == "error" then error("barrel is busy") end
      return slots(c)
    end } },
  meBridge_0 = { types = { "meBridge" }, m = {
    listItems = function()
      local out = {}
      for n, a in pairs(SCHED[STEP].me or {}) do
        out[#out + 1] = { name = n, amount = a, displayName = "[" .. n:gsub("^.-:", ""):gsub("_", " ") .. "]",
                          isCraftable = false }
      end
      return out
    end,
    getEnergyUsage = function() return 5 end } },
  turtle_0 = { types = { "turtle" }, m = { list = function() error("turtle must not be read") end } },
  computer_3 = { types = { "computer" }, m = { list = function() error("computer must not be read") end } },
}
local function live(n)
  if not P[n] or DETACHED[n] then return false end
  if n == "chest_1" and SCHED[STEP] and SCHED[STEP].c1 == "detached" then return false end
  if n == "meBridge_0" and NO_BRIDGE then return false end
  return true
end
peripheral.getNames = function()
  local out = {}
  for n in pairs(P) do if live(n) then out[#out + 1] = n end end
  table.sort(out)
  return out
end
peripheral.getType = function(n) if live(n) then return table.unpack(P[n].types) end return nil end
peripheral.getMethods = function(n)
  if not live(n) then return nil end
  local out = {}
  for k in pairs(P[n].m) do out[#out + 1] = k end
  table.sort(out)
  return out
end
peripheral.call = function(n, method, ...)
  if not live(n) then error("No peripheral attached") end
  local f = P[n].m[method]
  if not f then error("No such method " .. tostring(method)) end
  return f(...)
end
peripheral.isPresent = function(n) return live(n) end

-- the "kernel": world.lua gets every event; the sampler's timer fires, the yielding chest gets other events
-- first (key, a foreign task_complete) and then its own task_complete
CLOCK = 1699999200
os.epoch = function() return CLOCK * 1000 end
WORLD = dofile("/os/lib/world.lua")
MV = WardenOS.mineview
WORLD.event(table.pack("start"))
WAITED = 0                                        -- times the sampler was still waiting after another event
function RUN(from, to)
  for i = from, to do
    STEP = i
    CLOCK = CLOCK + (SCHED[i].dt or 60)
    WORLD.event(table.pack("timer", MV._timer()))
    local guard = 0
    while PENDING and guard < 5 do
      guard = guard + 1
      local p = PENDING
      WORLD.event(table.pack("key", 28))
      WORLD.event(table.pack("task_complete", p + 1000, true))
      if PENDING == p and MV.status().busy then WAITED = WAITED + 1 end
      WORLD.event(table.pack("task_complete", p, true))
    end
  end
end
"""


class Env:
    def __init__(self, events=(), files=None, CW=45, CH=17):
        self.rt = lua.LuaRuntime(unpack_returned_tuples=True, encoding="latin-1")
        g = self.rt.globals()
        g.HOST_READ = lambda p: read(p)
        g.CW, g.CH, g.MW, g.MH = CW, CH, 0, 0
        g.HOST_EVENT = self.host_event
        g.SCRIPT_EVENTS = self.rt.table_from([self.lua(e) for e in events])
        g.SCRIPT_LINES = self.rt.table_from([])
        self.M = self.rt.execute(read("tests/mock_cc.lua"))
        self.problems, self.shots, self.blits = [], {}, {}
        self.hosts = {"click": self.click, "shot": self.shot, "tick": self.tick, "lua": self.run_lua, "at": self.at}
        for d in ("/os", "/os/lib", "/os/apps"):
            self.M.FS[d] = True
        for p in ("os/lib/log.lua", "os/lib/world.lua", "os/lib/mineview.lua", "os/apps/mineview.lua"):
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

    def click(self, label, nth=1, min_row=1):
        t = self.M.native
        seen = 0
        for y in range(min_row, t.h + 1):
            start = 0
            while True:
                i = t.rows[y].find(label, start)
                if i < 0:
                    break
                seen += 1
                if seen == nth:
                    return ["mouse_click", 1, i + 1 + (len(label) - len(label.lstrip())), y]
                start = i + 1
        self.problems.append("not on screen: %r\n%s" % (label, self.screen()))
        return None

    def at(self, dx, y):
        """click dx columns from the right edge (negative) or the left (positive) on row y (negative = from bottom)"""
        t = self.M.native
        x = t.w + dx + 1 if dx < 0 else dx
        yy = t.h + y + 1 if y < 0 else y
        return ["mouse_click", 1, x, yy]

    def shot(self, name):
        self.shots[name] = self.screen()
        b = self.rt.globals().BLITS
        self.blits[name] = [(b[i].x, b[i].y, b[i].s, b[i].f, b[i].b) for i in range(1, len(b) + 1)] if b else []
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

    def prelude(self, sched, extra=""):
        g = self.rt.globals()
        self.rt.execute(THEME + "\n" + STRICT + "\n" + PERIPHS)
        g.SCHED = self.lua(sched)
        if extra:
            self.rt.execute(extra)

    def run_app(self, path="/os/apps/mineview.lua"):
        f = self.rt.eval("function(path) return pcall(function() dofile(path).main() end) end")
        ok, err = f(path)
        g = self.rt.globals()
        return ok, err, int(g.WINDOW_VIOLATIONS or 0) + int(self.M.violations), list((g.WINDOW_LOG or {}).values())[:3]


# ---------------------------------------------------------------- schedule + independent reference
def schedule():
    """phase A: 90 one-minute steps (some 59/61 s), phase B: 180 ten-minute steps (30 h), phase C: 20 minutes"""
    s = []
    for k in range(1, 291):
        if k <= 90:
            dt = 60 + (1 if k % 7 == 0 else 0) - (1 if k % 11 == 0 else 0)
        elif k <= 270:
            dt = 600
        else:
            dt = 60
        c0 = {"minecraft:cobblestone": 100 + 10 * k, "minecraft:coal": max(0, 640 - 2 * k)}
        c1 = {"minecraft:cobblestone": 50, "minecraft:coal": 300 + int(50 * math.sin(k / 7.0)), "minecraft:iron_ingot": 7}
        if k >= 30:
            c1["minecraft:diamond"] = 1 + (k - 30) // 10
        if k in (40, 41):
            c1 = "detached"
        if k == 55:
            c1 = "error"
        me = {"minecraft:stone": 1000 + k, "minecraft:glass": 500, "ae2:certus_quartz_crystal": 33}
        s.append({"dt": dt, "c0": c0, "c1": c1, "me": me})
    return s


T0 = 1699999200
SCHED = schedule()
ITEMS = ["minecraft:cobblestone", "minecraft:coal", "minecraft:iron_ingot", "minecraft:diamond"]


def samples(upto):
    """[(t, {item: count}, okset)] of steps 1..upto in inventory mode"""
    out, t = [], T0
    for k in range(1, upto + 1):
        st = SCHED[k - 1]
        t += st["dt"]
        counts, ok = {}, {"chest_0"}
        for n, c in st["c0"].items():
            counts[n] = counts.get(n, 0) + c
        if isinstance(st["c1"], dict):
            ok.add("chest_1")
            for n, c in st["c1"].items():
                counts[n] = counts.get(n, 0) + c
        out.append((t, counts, frozenset(ok)))
    return out


def values(smp, item):
    """per sample: count or None before the item was first seen (afterwards missing = 0)"""
    seen, out = False, []
    for (t, counts, ok) in smp:
        if item in counts:
            seen = True
        out.append(counts.get(item, 0) if seen else None)
    return out


def ref_candles(smp, item, P, start=0):
    vals = values(smp, item)
    out, cur, prev, prev_ok = [], None, None, None
    for i in range(start, len(smp)):
        t, _, ok = smp[i]
        v = vals[i]
        if v is not None:
            b = t // P * P
            if cur is None or cur["t"] != b:
                o = prev if prev is not None else v
                cur = {"t": b, "o": o, "h": o, "l": o, "c": o, "prod": 0, "cons": 0}
                out.append(cur)
            cur["h"], cur["l"], cur["c"] = max(cur["h"], v), min(cur["l"], v), v
            if prev is not None and prev_ok == ok:
                d = v - prev
                if d > 0:
                    cur["prod"] += d
                else:
                    cur["cons"] -= d
        prev, prev_ok = v, ok
    return out


def ref_tf(smp, item, tf):
    P = {"1m": 60, "5m": 300, "15m": 900, "1h": 3600, "4h": 14400, "1d": 86400}[tf]
    if P >= 3600:
        return ref_candles(smp, item, P)
    cut = smp[-1][0] - 86400                      # raw window: last 24 h + the sample before
    start = 0
    for i, (t, _, _) in enumerate(smp):
        if t <= cut:
            start = i
    return ref_candles(smp, item, P, start)


def got_candles(env, mv, item, tf):
    return [{k: c[k] for k in ("t", "o", "h", "l", "c", "prod", "cons")} for c in env.plain(mv.candles(item, tf)) or []]


def compare_all(env, mv, upto, tag):
    smp = samples(upto)
    bad = []
    for item in ITEMS:
        for tf in ("1m", "5m", "15m", "1h", "4h", "1d"):
            want, got = ref_tf(smp, item, tf), got_candles(env, mv, item, tf)
            if want != got:
                diff = next((i for i in range(min(len(want), len(got))) if want[i] != got[i]), min(len(want), len(got)))
                bad.append("%s %s: %d vs %d candles, first diff #%d want %s got %s" % (
                    item, tf, len(want), len(got), diff, want[diff] if diff < len(want) else None,
                    got[diff] if diff < len(got) else None))
    check(not bad, "%s: candles differ from the reference:\n  %s" % (tag, "\n  ".join(bad[:6])))
    return not bad


# ---------------------------------------------------------------- 1. sampler: auto mode -> bridge only
env = Env()
env.prelude(SCHED)
g = env.rt.globals()
g.RUN(1, 2)
mv = g.MV
st = env.plain(mv.status())
items = {e["name"]: e for e in env.plain(mv["items"]())}
check(st.get("using") == "bridges" and st.get("okCount") == 1, "auto mode: not bridge-only: %s" % st)
check(set(items) == {"minecraft:stone", "minecraft:glass", "ae2:certus_quartz_crystal"},
      "auto mode: counted %s" % sorted(items))
check(items.get("minecraft:stone", {}).get("current") == 1002, "bridge amount: %s" % items.get("minecraft:stone"))
check(items.get("ae2:certus_quartz_crystal", {}).get("display") == "certus quartz crystal",
      "bridge displayName not used/cleaned: %s" % items.get("ae2:certus_quartz_crystal"))
check(int(g.YIELDS) == 0, "auto mode read the chests")
# no bridge any more -> auto falls back to the inventories
env.rt.execute("NO_BRIDGE = true")
g.RUN(3, 3)
st = env.plain(mv.status())
check(st.get("using") == "inventories" and st.get("okCount") == 2, "auto without bridge: %s" % st)
items = {e["name"]: e for e in env.plain(mv["items"]())}
check(items.get("minecraft:cobblestone", {}).get("current") == 100 + 30 + 50, "inventory sum: %s" % items.get("minecraft:cobblestone"))
check("minecraft:stone" in items, "old bridge item dropped although under the limit")
print("auto source mode: ok" if not fail else "auto source mode: FAILED")

# ---------------------------------------------------------------- 1b. inventory mode, yields, candles, roll-up
nf = len(fail)
env = Env(files={"/os/mineview": True, "/os/mineview/config": '{ mode = "inventories", interval = 60 }'})
env.prelude(SCHED)
g = env.rt.globals()
mv = g.MV
check(env.plain(mv.config()).get("mode") == "inventories", "config file not read")
# the yielding chest: the sample stays open while other events arrive
STEP1 = r"""
STEP = 1
CLOCK = CLOCK + 60
WORLD.event(table.pack("timer", MV._timer()))
local R = {}
R.pending = PENDING ~= nil
R.busy = MV.status().busy
R.samples0 = MV.status().samples
WORLD.event(table.pack("key", 28))
WORLD.event(table.pack("rednet_message", 5, { t = "status" }, "wardenos"))
WORLD.event(table.pack("timer", 99999))
WORLD.event(table.pack("task_complete", PENDING + 77, true))
R.still = MV.status().busy and PENDING ~= nil and MV.status().samples == 0
R.yields = YIELDS
WORLD.event(table.pack("task_complete", PENDING, true))
R.done = not MV.status().busy and MV.status().samples == 1
return R
"""
r = env.plain(env.rt.execute(STEP1))
check(r.get("pending") and r.get("busy") and r.get("samples0") == 0, "yielding source: sample not waiting: %s" % r)
check(r.get("still") and r.get("yields") == 1, "yielding source: woken by another event: %s" % r)
check(r.get("done"), "yielding source: task_complete did not finish the sample: %s" % r)
g.RUN(2, 90)
check(int(g.WAITED) >= 80, "the sampler did not wait across events (%s)" % g.WAITED)
st = env.plain(mv.status())
check(st.get("samples") == 90 and st.get("items") == 4, "after 90 samples: %s" % st)
check(not st.get("failed"), "failed sources still listed: %s" % st.get("failed"))
logs = env.plain(env.rt.execute("return dofile('/os/lib/log.lua').list('error')")) or []
check(any("chest_1" in (e.get("text") or "") and "barrel is busy" in (e.get("text") or "") for e in logs),
      "failing source not logged: %s" % logs[:3])
check(not any("turtle" in (e.get("text") or "") or "computer" in (e.get("text") or "") for e in logs),
      "turtle/computer read: %s" % logs[:3])
# missing-source protection: steps 40, 41 (detached) and 55 (error) never count as production/consumption
c1m = {c["t"]: c for c in got_candles(env, mv, "minecraft:cobblestone", "1m")}
smp = samples(90)
for k in (40, 42, 55, 56):
    t = smp[k - 1][0]
    cd = c1m.get(t // 60 * 60, {})
    check(cd.get("prod") == 0 and cd.get("cons") == 0, "step %d: fake flow from a missing source: %s" % (k, cd))
cd = c1m.get(smp[40][0] // 60 * 60, {})       # 40 -> 41: both without chest_1, a reliable delta
check(cd.get("prod") == 10 and cd.get("cons") == 0, "step 41 (same sources as 40): %s" % cd)
cd = c1m.get(smp[38][0] // 60 * 60, {})
check(cd.get("prod") == 10 and cd.get("cons") == 0 and cd.get("c") - cd.get("o") == 10, "normal step flow: %s" % cd)
cd = c1m.get(smp[39][0] // 60 * 60, {})
check(cd.get("c") == 100 + 400 and cd.get("l") == 500, "detached step: counts not as read: %s" % cd)
items = {e["name"]: e for e in env.plain(mv["items"]())}
cob = items.get("minecraft:cobblestone", {})
check(cob.get("current") == 100 + 900 + 50 and 590 <= cob.get("prodH", 0) <= 610 and cob.get("consH") == 0
      and cob.get("rate") == cob.get("prodH"),
      "cobblestone rates: %s" % cob)
check(cob.get("ch1h") == 600 - 0 and abs(cob.get("pct1h") - 600 / 450 * 100) < 0.01, "1h change: %s" % cob)
coal = items.get("minecraft:coal", {})
check(coal.get("consH", 0) > 100 and coal.get("rate", 0) < 0, "coal consumption: %s" % coal)
dia = items.get("minecraft:diamond", {})
check(dia.get("current") == 7 and dia.get("display") == "Diamond", "late item: %s" % dia)
compare_all(env, mv, 90, "after 1.5 h")
# long run: 30 h in 10 minute steps, then minutes again
g.RUN(91, 290)
st = env.plain(mv.status())
check(st.get("samples") <= 24 * 6 + 20 + 2, "raw window not pruned to 24 h: %d samples" % st.get("samples"))
check(st.get("hours") >= 31, "hourly roll-up: %s hours" % st.get("hours"))
compare_all(env, mv, 290, "after 31.8 h")
h1 = got_candles(env, mv, "minecraft:cobblestone", "1h")
check(len(h1) >= 32 and h1[0]["t"] == T0, "1h candles not back to the start: %d, first %s" % (len(h1), h1[:1]))
d1 = got_candles(env, mv, "minecraft:cobblestone", "1d")
check(len(d1) == 3 and d1[0]["t"] % 86400 == 0, "1d candles (3 UTC days): %s" % d1)
# flat item (iron): hourly candles omitted on disk but rebuilt flat
iron = got_candles(env, mv, "minecraft:iron_ingot", "1h")
check(all(c["o"] == c["c"] == c["h"] == c["l"] for c in iron[2:] if c["l"] == 7), "flat iron candles")
# files
env.rt.execute("MV.flush(true)")
raw = env.M.FS["/os/mineview/raw.log"] or ""
hourly = env.M.FS["/os/mineview/hourly.log"] or ""
check(raw.startswith("T ") and "\nN " in raw and "\nG " in raw, "raw.log format: %r" % raw[:80])
check(hourly.startswith("N ") or hourly.startswith("B "), "hourly.log format: %r" % hourly[:80])
check(all(ord(c) < 128 for c in raw + hourly), "history files not ASCII")
print("sampler (yields, flows, candles, roll-up): ok" if len(fail) == nf else "sampler: FAILED")

# ---------------------------------------------------------------- 2. persistence: reload == live
nf = len(fail)
RELOAD = r"""
local M2 = dofile("/os/lib/mineview.lua").new({ readonly = true })
return M2
"""


def same_as_reload(env, mv, upto, tag):
    m2 = env.rt.execute(RELOAD)
    a, b = env.plain(mv["items"]()), env.plain(m2["items"]())
    check(a == b, "%s: items differ after reload\n%s\n%s" % (tag, a[:2], b[:2]))
    for item in ITEMS:
        for tf in ("1m", "5m", "15m", "1h", "4h", "1d"):
            x, y = got_candles(env, mv, item, tf), got_candles(env, m2, item, tf)
            check(x == y, "%s: %s %s differ after reload (%d vs %d)" % (tag, item, tf, len(x), len(y)))
    s2 = env.plain(m2.status())
    check(s2.get("readonly") and not s2.get("recording"), "%s: read-only status %s" % (tag, s2))
    return m2


same_as_reload(env, mv, 290, "compacted")
# appended lines (no rewrite): 12 more minutes, the periodic flush appends
before = env.M.FS["/os/mineview/raw.log"]
SCHED2 = SCHED + [dict(SCHED[-1], dt=60) for _ in range(12)]
g.SCHED = env.lua(SCHED2)
SCHED[:] = SCHED2
g.RUN(291, 302)
env.rt.execute("MV.flush(true)")
after = env.M.FS["/os/mineview/raw.log"]
check(after.startswith(before) and len(after) > len(before), "raw.log not appended (%d -> %d)" % (len(before), len(after)))
same_as_reload(env, mv, 302, "appended")
compare_all(env, mv, 302, "after append")
m2 = env.rt.execute(RELOAD)
check(m2.sampleNow() is False or m2.sampleNow() == (False, "recording runs on the desktop"), "read-only instance samples")
print("persistence: ok" if len(fail) == nf else "persistence: FAILED")
DATA_FILES = {k: env.M.FS[k] for k in ("/os/mineview", "/os/mineview/config", "/os/mineview/raw.log", "/os/mineview/hourly.log")}

# ---------------------------------------------------------------- 3. item cap, pinned, limit, disk, budget, clear
nf = len(fail)
big = []
for k in range(1, 8):
    me = {"mod:item_%03d" % i: i * 10 for i in range(1, 261)}
    if k >= 3:
        me["mod:item_060"] = 615                   # a bit more than the smallest tracked (610): no churn
    if k >= 4:
        me["mod:item_060"] = 100000                # far more: replaces the smallest
    big.append({"dt": 60, "c0": {}, "c1": {}, "me": me})
env = Env()
env.prelude(big)
g = env.rt.globals()
mv = g.MV
g.RUN(1, 1)
names = {e["name"] for e in env.plain(mv["items"]())}
check(len(names) == 200 and "mod:item_061" in names and "mod:item_060" not in names and "mod:item_260" in names,
      "cap: %d items, 60 in: %s, 61 in: %s" % (len(names), "mod:item_060" in names, "mod:item_061" in names))
mv.pin("mod:item_001", True)
g.RUN(2, 2)
lst = env.plain(mv["items"]())
check(len(lst) == 200 and lst[0]["name"] == "mod:item_001" and lst[0]["pinned"], "pinned not first/tracked: %s" % lst[:1])
check("mod:item_061" not in {e["name"] for e in lst}, "pin did not take the smallest slot")
g.RUN(3, 3)
check("mod:item_060" not in {e["name"] for e in env.plain(mv["items"]())}, "tracked set churns on a small difference")
g.RUN(4, 4)
names = {e["name"] for e in env.plain(mv["items"]())}
check("mod:item_060" in names and "mod:item_062" not in names and len(names) == 200, "big newcomer not tracked")
mv.setConfig(env.lua({"limit": 50}))
g.RUN(5, 5)
lst = env.plain(mv["items"]())
check(len(lst) == 50 and lst[0]["name"] == "mod:item_001" and lst[1]["name"] == "mod:item_060", "limit 50: %d %s" % (len(lst), lst[:2]))
cfg = env.plain(mv.config())
check(cfg.get("limit") == 50 and cfg.get("pinned", {}).get("mod:item_001"), "config: %s" % cfg)
saved = env.M.FS["/os/mineview/config"] or ""
check("limit" in saved and "mod:item_001" in saved, "config not saved: %r" % saved)
cfg = env.plain(mv.setConfig(env.lua({"interval": 5, "mode": "nonsense", "limit": 9999, "maxKB": 1})))
check(cfg["interval"] == 20 and cfg["mode"] == "auto" and cfg["limit"] == 200 and cfg["maxKB"] == 64, "config not clamped: %s" % cfg)
mv.setConfig(env.lua({"interval": 60, "limit": 50, "maxKB": 256}))
# disk low: nothing written, status says so; space back: everything written
env.rt.execute("MV.flush(true)")
raw0 = env.M.FS["/os/mineview/raw.log"]
env.rt.execute("REAL_FREE = fs.getFreeSpace fs.getFreeSpace = function() return 150 * 1024 end")
g.RUN(6, 6)
env.rt.execute("MV.flush(true)")
st = env.plain(mv.status())
check(st.get("disk") == "low" and env.M.FS["/os/mineview/raw.log"] == raw0, "disk low: %s, file changed: %s" % (st.get("disk"), env.M.FS["/os/mineview/raw.log"] != raw0))
check(st.get("samples") == 6, "disk low stopped recording in memory")
LOWDISK_FILES = {k: env.M.FS[k] for k in ("/os", "/os/mineview", "/os/mineview/config", "/os/mineview/raw.log", "/os/mineview/hourly.log")}
env.rt.execute("fs.getFreeSpace = REAL_FREE")
g.RUN(7, 7)
env.rt.execute("MV.flush(true)")
check(env.plain(mv.status()).get("disk") == "ok", "disk state not back to ok")
m2 = env.rt.execute(RELOAD)
check(env.plain(m2.status()).get("samples") == 7, "after the disk was free again: %s" % env.plain(m2.status()).get("samples"))
# budget: a tiny budget trims the oldest data, files stay under it
mv.setConfig(env.lua({"maxKB": 64, "limit": 200}))
big2 = big + [{"dt": 60, "c0": {}, "c1": {}, "me": {"mod:item_%03d" % i: i * 10 + k * (i % 7) for i in range(1, 261)}}
              for k in range(1, 200)]
g.SCHED = env.lua(big2)
g.RUN(8, 205)
env.rt.execute("MV.flush(true)")
size = len(env.M.FS["/os/mineview/raw.log"] or "") + len(env.M.FS["/os/mineview/hourly.log"] or "")
check(size <= 64 * 1024, "history over budget: %d bytes" % size)
check(env.plain(mv.status()).get("samples") < 205, "budget did not trim raw samples")
# clear
mv.clear()
st = env.plain(mv.status())
check(st.get("samples") == 0 and st.get("items") == 0 and not env.M.FS["/os/mineview/raw.log"], "clear: %s" % st)
check(env.M.FS["/os/mineview/config"], "clear removed the config")
# a source that never answers is abandoned
env.rt.execute("""SCHED[300] = { dt = 60, c0 = {}, c1 = { ["minecraft:dirt"] = 1 }, me = {} }
NO_BRIDGE = true HANG = true
STEP = 300 CLOCK = CLOCK + 60
WORLD.event(table.pack("timer", MV._timer()))
WORLD.event(table.pack("task_complete", PENDING, true))
CLOCK = CLOCK + 200
WORLD.event(table.pack("key", 28))""")
st = env.plain(mv.status())
check(not st.get("busy") and "too long" in str(st.get("error")), "hanging source not abandoned: %s" % st)
print("cap / pin / limit / disk / budget / clear: ok" if len(fail) == nf else "cap / pin / disk: FAILED")

# ---------------------------------------------------------------- 4. app
nf = len(fail)
APP_PRE = r"""
RUN(1, 90)
"""
CFG_INV = '{ mode = "inventories", interval = 60 }'


def app_events():
    ev = [["host", "shot", "chart"]]
    for tf in ("1m", "15m", "1h", "4h", "1d", "5m"):
        ev += [["host", "click", " %s " % tf], ["host", "shot", "tf-" + tf]]
    ev += [["host", "at", -7, 6], ["host", "shot", "cross"], ["host", "at", -7, 2], ["host", "shot", "uncross"],
           ["host", "click", " 1m "], ["mouse_scroll", -1, 30, 6], ["mouse_scroll", -1, 30, 6], ["host", "shot", "pan"],
           ["host", "click", " now "], ["host", "shot", "now"],
           ["key", LEFT], ["key", RIGHT], ["key", DOWN], ["host", "shot", "coal"], ["key", UP]]
    ev += [["char", c] for c in "coal"] + [["host", "shot", "filter"]] + [["key", BACKSPACE]] * 4
    ev += [["host", "at", 1, 6], ["host", "shot", "pinned"], ["mouse_scroll", 1, 3, 8], ["mouse_scroll", -1, 3, 8],
           ["host", "click", " set "], ["host", "shot", "settings"],
           ["host", "click", " + ", 1], ["host", "shot", "interval"],
           ["host", "click", " inventories "], ["host", "click", " bridges "], ["host", "click", " all "],
           ["host", "shot", "selected"], ["host", "click", "chest_0"], ["host", "shot", "picked"],
           ["mouse_scroll", 1, 10, 8], ["mouse_scroll", 1, 10, 8], ["host", "shot", "scrolled"],
           ["mouse_scroll", -1, 10, 8], ["mouse_scroll", -1, 10, 8], ["mouse_scroll", -1, 10, 8],
           ["host", "click", " Clear history "], ["host", "shot", "sure"], ["host", "click", " Sure? tap again "],
           ["host", "shot", "cleared"], ["host", "click", " < "], ["host", "shot", "empty"], ["host", "tick"]]
    return ev


def colours_in_chart(blits, name, c):
    return c in "".join(b[4] for b in blits.get(name, []))   # "d" green (good), "e" red (bad) cells blitted


for (cw, ch) in [(45, 17), (45, 18), (51, 19), (79, 36), (158, 79)]:
    tag = "app %dx%d" % (cw, ch)
    env = Env(events=app_events(), CW=cw, CH=ch, files={"/os/mineview": True, "/os/mineview/config": CFG_INV})
    env.prelude(SCHED, APP_PRE)
    ok, err, viol, vlog = env.run_app()
    sh = env.shots
    check(err == "SCRIPT_END", "%s: stopped early: %s" % (tag, err))
    check(viol == 0, "%s: %d chars outside the window %s" % (tag, viol, vlog))
    check(not env.problems, "%s: %s" % (tag, env.problems[:2]))
    c = sh.get("chart", "")
    rows = c.split("\n")
    check("Cobblestone" in rows[1] and "1.1k" in rows[1] and re.search(r"\+(59\d|60\d)/h -0/h net \+(59\d|60\d)/h", rows[1]),
          "%s: header:\n%s" % (tag, c))
    for label in (" 1m ", " 5m ", " 15m ", " 1h ", " 4h ", " 1d ", " now ", " set "):
        check(label in rows[0], "%s: toolbar misses %r: %r" % (tag, label, rows[0]))
    check("Coal" in c and "Diamond" in c and "Iron Ingot"[: 10] in c.replace("\n", " ") or "Iron" in c, "%s: watchlist:\n%s" % (tag, c))
    check(re.search(r"\d\d[:.]\d\d", rows[-1]) is not None, "%s: no time labels: %r" % (tag, rows[-1]))
    check(any(re.search(r"\+\d+ *$", r) for r in rows[-8:-2]) and re.search(r"-\d+ *$", rows[-2]),
          "%s: flow scale labels missing:\n%s" % (tag, c))
    check(colours_in_chart(env.blits, "chart", "d"), "%s: no green candles blitted" % tag)
    check(colours_in_chart(env.blits, "coal", "e") and "Coal" in sh.get("coal", "").split("\n")[1],
          "%s: coal (down arrow key) without red candles:\n%s" % (tag, sh.get("coal")))
    check("%" in c and "^" in c, "%s: watchlist change column:\n%s" % (tag, c))
    for tf in ("1m", "15m", "1h", "4h", "1d", "5m"):
        s = sh.get("tf-" + tf, "")
        check("error" not in s and "Cobblestone" in s, "%s: timeframe %s:\n%s" % (tag, tf, s))
    check("no candles yet" not in sh.get("tf-1h", ""), "%s: 1h chart empty" % tag)
    cr = sh.get("cross", "").split("\n")[1] if sh.get("cross") else ""
    check(re.search(r"O\S+ H\S+ L\S+ C\S+ \+\S+ -\S+", cr) is not None, "%s: crosshair info: %r" % (tag, cr))
    check("Cobblestone" in sh.get("uncross", "").split("\n")[1], "%s: crosshair not cleared" % tag)
    if cw < 100:                                  # 90 one-minute candles: only a narrower chart can pan
        check("<" in sh.get("pan", "") and sh.get("pan") != sh.get("now"), "%s: pan:\n%s" % (tag, sh.get("pan")))
    f = sh.get("filter", "")
    check("/coal" in f and "Cobblestone" not in f.split("\n")[3] and "Diamond" not in f, "%s: filter:\n%s" % (tag, f))
    check("*" in "".join(r[:1] for r in sh.get("pinned", "").split("\n")[3:]), "%s: star not set:\n%s" % (tag, sh.get("pinned")))
    s = sh.get("settings", "")
    check("Sample every" in s and "60s" in s and "Sources" in s and "inventories" in s and "Track up to" in s
          and "200 items" in s, "%s: settings:\n%s" % (tag, s))
    check("90s" in sh.get("interval", ""), "%s: interval +:\n%s" % (tag, sh.get("interval")))
    sel = sh.get("selected", "")
    check(" selected " in sel and "[ ] chest_0" in sel and "chest_1" in sel and "meBridge_0" in sel
          and "turtle_0" not in sel, "%s: pick list:\n%s" % (tag, sel))
    check("[x] chest_0" in sh.get("picked", ""), "%s: pick:\n%s" % (tag, sh.get("picked")))
    full = "\n".join(sh.get(k, "") for k in ("settings", "scrolled", "picked", "selected"))
    check("90 samples" in full or "samples" in full, "%s: status lines:\n%s" % (tag, sh.get("settings")))
    check("Sure? tap again" in sh.get("sure", ""), "%s: clear confirm" % tag)
    check("history cleared" in sh.get("cleared", "") or "0 items" in sh.get("cleared", ""), "%s: clear:\n%s" % (tag, sh.get("cleared")))
    e = sh.get("empty", "")
    check("No data yet" in e and "after 2" in e and "ME Bridge" in e.replace("\n", " "), "%s: empty state:\n%s" % (tag, e))
    cfg = env.plain(env.rt.globals().MV.config())
    check(cfg.get("mode") == "selected" and cfg.get("selected") == ["chest_0"] and cfg.get("interval") == 90,
          "%s: settings not applied: %s" % (tag, cfg))
print("app at 5 sizes: ok" if len(fail) == nf else "app: FAILED")

# read-only (no desktop instance): stored history, says where recording happens
nf = len(fail)
ro_ev = [["host", "shot", "ro"], ["host", "click", " 1h "], ["host", "shot", "ro1h"], ["host", "click", " set "],
         ["host", "shot", "roset"]]
env = Env(events=ro_ev, CW=45, CH=17, files=DATA_FILES)
env.rt.execute(THEME + "\n" + STRICT)
ok, err, viol, vlog = env.run_app()
sh = env.shots
check(err == "SCRIPT_END" and viol == 0 and not env.problems, "read-only app: %s %d %s %s" % (err, viol, vlog, env.problems[:1]))
check("Cobblestone" in sh.get("ro", "") and "read-only" in sh.get("ro", ""), "read-only chart:\n%s" % sh.get("ro"))
check("no candles yet" not in sh.get("ro1h", ""), "read-only 1h:\n%s" % sh.get("ro1h"))
check("recording runs on the desktop" in sh.get("roset", "").replace("\n", " "), "read-only settings:\n%s" % sh.get("roset"))
# disk low banner
env = Env(events=[["host", "shot", "low"]], CW=45, CH=17, files=LOWDISK_FILES)
env.prelude(big, "fs.getFreeSpace = function() return 1000 end RUN(1, 2) MV.flush(true)")
ok, err, viol, vlog = env.run_app()
check("DISK LOW" in env.shots.get("low", ""), "disk low not shown:\n%s" % env.shots.get("low"))
# first start: empty state, no samples yet
env = Env(events=[["host", "shot", "first"]], CW=45, CH=17)
env.prelude(SCHED)
ok, err, viol, vlog = env.run_app()
s = env.shots.get("first", "")
check(err == "SCRIPT_END" and viol == 0 and "No data yet" in s and "Found 2 inventories, 1 bridges" in s,
      "empty state:\n%s" % s)
# one sample only: still the empty state (first data after 2 samples)
env = Env(events=[["host", "shot", "one"]], CW=45, CH=17)
env.prelude(SCHED, "RUN(1, 1)")
ok, err, viol, vlog = env.run_app()
check("Samples: 1" in env.shots.get("one", ""), "one sample:\n%s" % env.shots.get("one"))
print("read-only / disk low / empty: ok" if len(fail) == nf else "read-only / empty: FAILED")

# ---------------------------------------------------------------- 5. storage size estimate
# 24 h at 60 s: 10 items that change every sample, 40 static ones (bridge mode)
day = []
for k in range(1, 1441 + 60):
    me = {"mod:busy_%02d" % i: 10000 + k * (i + 1) + (k % 5) * 3 for i in range(10)}
    me.update({"mod:still_%02d" % i: 500 + i for i in range(40)})
    day.append({"dt": 60, "c0": {}, "c1": {}, "me": me})
env = Env()
env.prelude(day)
g = env.rt.globals()
g.RUN(1, len(day))
env.rt.execute("MV.flush(true)")
raw = len(env.M.FS["/os/mineview/raw.log"] or "")
hourly = len(env.M.FS["/os/mineview/hourly.log"] or "")
st = env.plain(g.MV.status())
check(raw + hourly < 256 * 1024 and st.get("samples") <= 1442, "day run: raw %d hourly %d samples %s" % (raw, hourly, st.get("samples")))
hours = st.get("hours") or 1
print("storage, 24 h at 60 s, 10 changing + 40 static items: raw.log %d B, hourly.log %d B (%d hours)" % (raw, hourly, hours))
print("  ~%d B per changing item per day in raw.log (rolling 24 h), ~%d B per changing item per day in hourly.log"
      % ((raw - 1441 * 4) / 10, hourly / hours * 24 / 10))

print()
if fail:
    print("%d problem(s)" % len(fail))
    sys.exit(1)
print("all mineview checks passed")
