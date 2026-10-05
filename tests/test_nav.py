#!/usr/bin/env python3
"""Drone navigation and built-in jobs, dry-run against tests/mock_cc.lua in a small simulated world.

Covers: path finding around obstacles and dead ends, blocks that are never dug (containers, protected areas),
fuel refusal before trips, dead reckoning after failed moves, replanning when a block appears, waiting for
another turtle, GPS re-sync after the drone was pushed or turned, the tunnel / quarry / unload jobs and the
task numbers (ack.job, status.jobId, lastTask.n).

Run: python3 tests/test_nav.py   (exit code 1 on failure; needs: pip install lupa)
"""
import os
import sys

import lupa.lua52 as lua

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
fail = []


def read(p):
    with open(os.path.join(ROOT, p), encoding="utf-8") as f:
        return f.read()


def check(cond, msg):
    if not cond:
        fail.append(msg)
        print("FAIL:", msg)


def lua_table(rt, d):
    if isinstance(d, dict):
        return rt.table_from({k: lua_table(rt, v) for k, v in d.items()})
    if isinstance(d, list):
        return rt.table_from([lua_table(rt, v) for v in d])
    return d


# The world: POS = the turtle's TRUE absolute position/facing (0 north -z, 1 east +x, 2 south +z, 3 west -x),
# WORLD["x,y,z"] = { name, tags, ttl } solid blocks (ttl: vanishes after that many inspections, like a turtle
# that drives off). Moves into blocks fail, dig removes them (DIG_ITEMS: the block goes into the inventory),
# drop* put the selected stack into CHEST (counted), gps.locate answers POS when GPS_ON.
# Hooks: PUSH_AT = n: after the n-th successful forward move the turtle is pushed one block east (PUSH_DX/DZ);
# SPIN_AT = n: after the n-th move it is turned right; FLAKY = n: every n-th forward fails ("Movement obstructed",
# a mob); APPEAR = { at = n, key = "x,y,z" }: after n moves a planks block appears there.
PRELUDE = r"""
local M = ...
local function copy(v)
  if type(v) ~= "table" then return v end
  local t = {}
  for k, x in pairs(v) do t[k] = copy(x) end
  return t
end
local send, bc = rednet.send, rednet.broadcast
rednet.send = function(id, msg, p) return send(id, copy(msg), p) end
rednet.broadcast = function(msg, p) return bc(copy(msg), p) end

POS = { x = 0, y = 64, z = 0, f = 0 }
WORLD, TRAIL, CHEST = {}, {}, 0
GPS_ON, FUEL, MOVES, FWD = false, 500, 0, 0
INV = { [1] = { name = "minecraft:coal", count = 12 } }
local DX, DZ = { [0] = 0, 1, 0, -1 }, { [0] = -1, 0, 1, 0 }
local function key(x, y, z) return x .. "," .. y .. "," .. z end
local function target(side)
  if side == "up" then return POS.x, POS.y + 1, POS.z end
  if side == "down" then return POS.x, POS.y - 1, POS.z end
  if side == "back" then return POS.x - DX[POS.f], POS.y, POS.z - DZ[POS.f] end
  return POS.x + DX[POS.f], POS.y, POS.z + DZ[POS.f]
end
local SIDE = { forward = "front", back = "back", up = "up", down = "down" }
for n, side in pairs(SIDE) do
  local orig = turtle[n]
  turtle[n] = function()
    local x, y, z = target(side)
    if WORLD[key(x, y, z)] then return false, "Movement obstructed" end
    if FUEL <= 0 then return false, "Out of fuel" end
    if n == "forward" and FLAKY then
      FWD = FWD + 1
      if FWD % FLAKY == 0 then return false, "Movement obstructed" end
    end
    local ok, e = orig()
    if ok then
      POS.x, POS.y, POS.z = x, y, z
      FUEL = FUEL - 1
      MOVES = MOVES + 1
      TRAIL[#TRAIL + 1] = key(x, y, z)
      if PUSH_AT and MOVES == PUSH_AT then POS.x, POS.z = POS.x + (PUSH_DX or 1), POS.z + (PUSH_DZ or 0) end
      if SPIN_AT and MOVES == SPIN_AT then POS.f = (POS.f + 1) % 4 end
      if APPEAR and MOVES == APPEAR.at then WORLD[APPEAR.key] = { name = "minecraft:oak_planks", tags = {} } end
    end
    return ok, e
  end
end
local tr, tl = turtle.turnRight, turtle.turnLeft
turtle.turnRight = function() local ok = tr() if ok then POS.f = (POS.f + 1) % 4 end return ok end
turtle.turnLeft = function() local ok = tl() if ok then POS.f = (POS.f + 3) % 4 end return ok end
local function addItem(name)
  for i = 1, 16 do
    local d = INV[i]
    if d and d.name == name and d.count < (STACK or 64) then d.count = d.count + 1 return end
  end
  for i = 1, 16 do
    if not INV[i] then INV[i] = { name = name, count = 1 } return end
  end
end
DUG = {}
for n, side in pairs({ dig = "front", digUp = "up", digDown = "down" }) do
  local orig = turtle[n]
  turtle[n] = function()
    orig()
    local k = key(target(side))
    local b = WORLD[k]
    if not b then return false, "Nothing to dig here" end
    if b.name == "minecraft:bedrock" then return false, "Unbreakable block detected" end
    WORLD[k] = nil
    DUG[#DUG + 1] = k
    if DIG_ITEMS then addItem(b.drop or b.name) end
    return true
  end
end
for n, side in pairs({ inspect = "front", inspectUp = "up", inspectDown = "down" }) do
  turtle[n] = function()
    local k = key(target(side))
    local b = WORLD[k]
    if not b then return false, "No block to inspect" end
    if b.ttl then
      b.ttl = b.ttl - 1
      if b.ttl <= 0 then WORLD[k] = nil end
    end
    return true, { name = b.name, state = {}, tags = b.tags or {} }
  end
end
for _, n in ipairs { "drop", "dropUp", "dropDown" } do
  turtle[n] = function()
    local s = turtle.getSelectedSlot()
    local d = INV[s]
    if not d then return false, "No items to drop" end
    CHEST = CHEST + d.count
    INV[s] = nil
    return true
  end
end
gps.locate = function() if GPS_ON then return POS.x + 1e-9, POS.y - 1e-9, POS.z end end
turtle.getFuelLevel = function() return FUEL end
turtle.getItemCount = function(n) return INV[n] and INV[n].count or 0 end
turtle.getItemDetail = function(n) local d = INV[n] return d and { name = d.name, count = d.count } end
turtle.refuel = function(n)
  local d = INV[turtle.getSelectedSlot()]
  if not d or not (d.name:find("coal", 1, true) or d.name:find("planks", 1, true)) then
    return false, "Items not combustible"
  end
  n = n or d.count
  if n == 0 then return true end
  n = math.min(n, d.count)
  FUEL = FUEL + (d.name:find("planks", 1, true) and 15 or 80) * n
  d.count = d.count - n
  if d.count == 0 then INV[turtle.getSelectedSlot()] = nil end
  return true
end
"""

STONE = ("minecraft:stone", ["minecraft:base_stone_overworld"])
PLANKS = ("minecraft:oak_planks", ["minecraft:planks"])
OBSIDIAN = ("minecraft:obsidian", [])
BEDROCK = ("minecraft:bedrock", [])
CHEST_B = ("minecraft:chest", [])
TURTLE_B = ("computercraft:turtle_normal", [])
MANY = [["timer", 100 + i] for i in range(80)]


def setup(pos=(0, 64, 0, 0), world=None, fuel=None, inv=None, gps=False, extra=""):
    out = ["POS = { x = %d, y = %d, z = %d, f = %d }" % pos, "GPS_ON = %s" % ("true" if gps else "false")]
    for (x, y, z), b in (world or {}).items():
        name, tags = b[0], b[1]
        ttl = b[2] if len(b) > 2 else None
        out.append('WORLD["%d,%d,%d"] = { name = "%s", tags = { %s }%s }'
                   % (x, y, z, name, ", ".join('["%s"] = true' % t for t in tags), ", ttl = %d" % ttl if ttl else ""))
    if fuel is not None:
        out.append("FUEL = %d" % fuel)
    if inv is not None:
        out.append("INV = { %s }" % ", ".join('[%d] = { name = "%s", count = %d }' % (k, n, c) for k, (n, c) in inv.items()))
    out.append(extra)
    return "\n".join(out)


def run_agent(events, pre=""):
    rt = lua.LuaRuntime(unpack_returned_tuples=True)
    g = rt.globals()
    g.HOST_READ = lambda p: read(p)
    g.CW, g.CH, g.MW, g.MH = 39, 13, 0, 0
    g.TURTLE, g.MODEM = True, True
    g.SCRIPT_EVENTS = rt.table_from([rt.table_from([lua_table(rt, x) for x in e]) for e in events])
    g.SCRIPT_LINES = rt.table_from([])
    M = rt.execute(read("tests/mock_cc.lua"))
    rt.execute(PRELUDE, M)
    rt.execute(pre)
    f = rt.eval("function(src) local f, e = load(src, '=agent.lua', 't', _G) "
                "if not f then return false, e end local ok, r = pcall(f) return ok, r end")
    ok, err = f(read("src/os/drone/agent.lua"))
    return rt, M, err


def cmd(c, seq, arg=None):
    m = {"t": "cmd", "to": 7, "seq": seq, "cmd": c}
    if arg is not None:
        m["arg"] = arg
    return ["rednet_message", 5, m, "wardenos"]


def ping():
    return ["rednet_message", 5, {"t": "ping"}, "wardenos"]


def calib(x, y, z, f="north", seq=2):
    return cmd("calibrate", seq, {"x": x, "y": y, "z": z, "facing": f})


def msgs(M):
    return [M.sent[i] for i in range(1, len(M.sent) + 1)]


def acks(M):
    return {e.msg.seq: (e.msg.ok, e.msg.info) for e in msgs(M) if e.msg.t == "ack"}


def ack_msgs(M):
    return {e.msg.seq: e.msg for e in msgs(M) if e.msg.t == "ack"}


def pinged(M):
    return [e.msg for e in msgs(M) if e.to == 5 and e.msg.t == "status"]


def statuses(M):
    return [e.msg for e in msgs(M) if e.msg.t == "status"]


def last(M):
    p = pinged(M)
    return p[-1].lastTask if p else None


def true_pos(rt):
    p = rt.globals().POS
    return (p.x, p.y, p.z, p.f)


def absof(st):
    return (st.abs.x, st.abs.y, st.abs.z, st.abs.f) if st.abs else None


def trail(rt):
    t = rt.globals().TRAIL
    return [tuple(int(v) for v in t[i].split(",")) for i in range(1, len(t) + 1)]


def intact(rt, cells):
    W = rt.globals().WORLD
    return all(W["%d,%d,%d" % c] is not None for c in cells)


def log_lines(M):
    seen = []
    for st in statuses(M):
        if st.log:
            for i in range(1, len(st.log) + 1):
                if st.log[i] not in seen:
                    seen.append(st.log[i])
    return seen


def lt_text(lt):
    return dict(lt) if lt else None


def go(arg, world=None, start=(0, 64, 0, 0), fuel=None, inv=None, gps=False, extra="", more=None, cmds=()):
    """claim, calibrate at start, optional extra commands, goto arg, timers, ping"""
    ev = [cmd("claim", 1), calib(*start[:3], f=start[3])] + list(cmds) + [cmd("goto", 3, arg)]
    ev += (more if more is not None else MANY) + [ping()]
    return run_agent(ev, setup(start, world, fuel, inv, gps, extra))


# ---------------------------------------------------------------- path finding
# a dead end: the drone sits inside a U of obsidian open to the south; the target is north of it
u = {}
for y in range(63, 66):
    for x in range(-2, 3):
        u[(x, y, -2)] = OBSIDIAN
    for z in range(-2, 1):
        u[(-2, y, z)] = OBSIDIAN
        u[(2, y, z)] = OBSIDIAN
for x in range(-2, 3):
    for z in range(-2, 1):
        u[(x, 66, z)] = OBSIDIAN                  # a roof
        u[(x, 62, z)] = OBSIDIAN                  # and a floor
rt, M, err = go({"x": 0, "y": 64, "z": -5}, u)
lt = last(M)
check(err == "SCRIPT_END", "u-trap: agent died %s" % err)
check(lt and lt.ok is True and lt.info == "arrived 0 64 -5" and true_pos(rt)[:3] == (0, 64, -5),
      "u-trap: %s at %s" % (lt_text(lt), true_pos(rt)))
check(intact(rt, u) and not rt.globals().DUG[1], "u-trap: dug through obsidian")
st = pinged(M)[-1]
check(absof(st)[:3] == true_pos(rt)[:3], "u-trap: thinks it is at %s, is at %s" % (absof(st), true_pos(rt)))

# ---------------------------------------------------------------- never dug: containers, even with safe dig off
chest_wall = {(x, y, -2): CHEST_B for x in range(-1, 2) for y in range(63, 66)}
rt, M, err = go({"x": 0, "y": 64, "z": -4}, chest_wall, cmds=[cmd("safedig", 9, False)])
lt = last(M)
check(acks(M).get(9) == (True, "safe dig off"), "chest: safedig %s" % (acks(M).get(9),))
check(lt and lt.ok is True and true_pos(rt)[:3] == (0, 64, -4) and intact(rt, chest_wall),
      "chest: %s at %s, chests %s" % (lt_text(lt), true_pos(rt), intact(rt, chest_wall)))
code = 'face("north") return turtle.dig()'
rt, M, err = run_agent([cmd("claim", 1), calib(0, 64, 0), cmd("safedig", 9, False),
                        cmd("run", 3, {"name": "d", "code": code}), ["timer", 1], ping()],
                       setup(world={(0, 64, -1): CHEST_B}))
lt = last(M)
check(lt and lt.info == "false, protected: minecraft:chest (never dug)" and intact(rt, [(0, 64, -1)]),
      "chest dig: %s" % lt_text(lt))
# the target itself is a chest the drone saw: a clear reason
rt, M, err = go({"x": 0, "y": 64, "z": -1}, {(0, 64, -1): CHEST_B}, cmds=[cmd("scan", 8)])
lt = last(M)
check(lt and lt.ok is False and lt.info.startswith("no path to 0 64 -1: the target is minecraft:chest (protected")
      and "never dug" in lt.info, "chest target: %s" % lt_text(lt))
# bedrock under the target column: no digging bedrock, clear reason
rt, M, err = go({"x": 0, "y": 63, "z": 0}, {(0, 63, 0): BEDROCK}, cmds=[cmd("scan", 8)])
lt = last(M)
check(lt and lt.ok is False and "minecraft:bedrock" in lt.info and intact(rt, [(0, 63, 0)]),
      "bedrock target: %s" % lt_text(lt))

# ---------------------------------------------------------------- protected area: never dug, gone around
pwall = {(x, y, -3): STONE for x in range(-2, 3) for y in range(63, 66)}
box = {"rev": 1, "boxes": [{"name": "Base", "x1": -2, "y1": 63, "z1": -3, "x2": 2, "y2": 65, "z2": -3}]}
rt, M, err = go({"x": 0, "y": 64, "z": -6}, pwall, cmds=[cmd("protect", 8, box)])
lt = last(M)
check(lt and lt.ok is True and true_pos(rt)[:3] == (0, 64, -6) and intact(rt, pwall)
      and not any(c in pwall for c in trail(rt)), "protected: %s at %s" % (lt_text(lt), true_pos(rt)))

# ---------------------------------------------------------------- fuel
# not enough fuel and no coal: refused at once with the numbers, no move
rt, M, err = go({"x": 0, "y": 64, "z": -300}, fuel=100, inv={})
a = acks(M).get(3)
check(a and a[0] is False and a[1].startswith("not enough fuel: needs about") and "has 100" in a[1]
      and "bring" in a[1] and "coal" in a[1], "fuel refuse: %s" % (a,))
check(not trail(rt) and true_pos(rt)[:3] == (0, 64, 0), "fuel refuse: moved %s" % trail(rt)[:5])
# enough coal in the inventory: burns what it needs (real fuel only, the planks stay) and goes
rt, M, err = go({"x": 0, "y": 64, "z": -60}, fuel=50, inv={1: ("minecraft:oak_planks", 64), 2: ("minecraft:coal", 10)},
                more=MANY * 2)
a, lt = acks(M).get(3), last(M)
INV = rt.globals().INV
check(a == (True, "started") and lt and lt.ok is True and true_pos(rt)[:3] == (0, 64, -60),
      "fuel burn: %s %s at %s" % (a, lt_text(lt), true_pos(rt)))
check(INV[1] is not None and INV[1].count == 64 and (INV[2] is None or INV[2].count < 10),
      "fuel burn: planks burnt / coal not used")
# home: not enough fuel to get back
rt, M, err = run_agent([cmd("claim", 1), calib(0, 64, 0), cmd("goto", 3, {"x": 0, "y": 64, "z": -30})] + MANY
                       + [cmd("run", 4, {"name": "drain", "code": "_G.FUEL = 10 return 1"}), ["timer", 1],
                          cmd("home", 5), ["timer", 2], ping()], setup(inv={}))
lt = last(M)
check(lt and lt.name == "home" and lt.ok is False and lt.info.startswith("not enough fuel to get home: needs about 35, has 10"),
      "home fuel: %s" % lt_text(lt))
# refuel to a target: burns only what is needed
rt, M, err = run_agent([cmd("claim", 1), cmd("refuel", 2, 300), cmd("refuel", 3, 5000), ping()],
                       setup(fuel=100, inv={1: ("minecraft:coal", 30)}))
a = acks(M)
check(a.get(2) == (True, "fuel 340 (+240)"), "refuel to: %s" % (a.get(2),))
check(a.get(3, (None, ""))[0] is False and "out of fuel items before 5000" in a[3][1], "refuel to: %s" % (a.get(3),))

# ---------------------------------------------------------------- dead reckoning stays right after failed moves
# every 3rd forward fails (a mob steps in the way): no position drift
rt, M, err = go({"x": 5, "y": 66, "z": -20}, extra="FLAKY = 3", more=MANY * 2)
lt = last(M)
st = pinged(M)[-1]
check(lt and lt.ok is True and true_pos(rt)[:3] == (5, 66, -20) and absof(st)[:3] == (5, 66, -20),
      "flaky: %s, thinks %s, is %s" % (lt_text(lt), absof(st), true_pos(rt)))
# manual moves into blocks fail; the position does not change
rt, M, err = run_agent([cmd("claim", 1), calib(0, 64, 0), cmd("forward", 3), cmd("up", 4), cmd("down", 5), ping()],
                       setup(world={(0, 64, -1): STONE, (0, 65, 0): STONE, (0, 63, 0): STONE}))
a, st = acks(M), pinged(M)[-1]
check(a.get(3)[0] is False and a.get(4)[0] is False and a.get(5)[0] is False and absof(st) == (0, 64, 0, 0),
      "blocked moves: %s at %s" % (a, absof(st)))

# ---------------------------------------------------------------- replanning: a block appears on the way
rt, M, err = go({"x": 0, "y": 64, "z": -10}, extra='APPEAR = { at = 3, key = "0,64,-5" }')
lt = last(M)
check(lt and lt.ok is True and true_pos(rt)[:3] == (0, 64, -10) and intact(rt, [(0, 64, -5)]),
      "appear: %s at %s" % (lt_text(lt), true_pos(rt)))
check(any(s.progress and s.progress.replans and s.progress.replans >= 1 for s in statuses(M))
      or len(trail(rt)) > 10, "appear: no replan")
# another turtle sits in the target cell and drives off after a while: waits, then arrives
rt, M, err = go({"x": 0, "y": 64, "z": -3}, {(0, 64, -3): TURTLE_B + (4,)})
lt = last(M)
check(lt and lt.ok is True and true_pos(rt)[:3] == (0, 64, -3), "turtle waits: %s at %s" % (lt_text(lt), true_pos(rt)))
check("dig" not in list(M.turtle.values()), "turtle waits: dug the other turtle")
# walled in by obsidian (with safe dig): fails with the reason, does not loop
cage = {(x, y, z): OBSIDIAN for x in range(-1, 2) for y in range(63, 66) for z in range(-1, 2) if (x, y, z) != (0, 64, 0)}
rt, M, err = go({"x": 0, "y": 64, "z": -5}, cage)
lt = last(M)
check(err == "SCRIPT_END" and lt and lt.ok is False and lt.info.startswith("no path to 0 64 -5")
      and "obsidian" in lt.info, "cage: %s" % lt_text(lt))
check(intact(rt, cage), "cage: dug obsidian")

# ---------------------------------------------------------------- GPS re-sync
rt, M, err = run_agent([cmd("claim", 1), cmd("calibrate", 2), cmd("goto", 3, {"x": 10, "y": 70, "z": -30})] + MANY * 2
                       + [ping()], setup((10, 70, 20, 0), gps=True, extra="PUSH_AT = 5"))
lt, st = last(M), pinged(M)[-1]
check(acks(M).get(2) == (True, "calibrated 10 70 20 north"), "gps: calibrate %s" % (acks(M).get(2),))
check(lt and lt.ok is True and true_pos(rt)[:3] == (10, 70, -30) and absof(st)[:3] == (10, 70, -30),
      "gps push: %s thinks %s is %s" % (lt_text(lt), absof(st), true_pos(rt)))
check(any("GPS: position corrected" in l for l in log_lines(M)), "gps push: no note %s" % log_lines(M))
# turned by something on the way: facing found again
rt, M, err = run_agent([cmd("claim", 1), cmd("calibrate", 2), cmd("goto", 3, {"x": 10, "y": 70, "z": -30})] + MANY * 2
                       + [ping()], setup((10, 70, 20, 0), gps=True, extra="SPIN_AT = 4"))
lt, st = last(M), pinged(M)[-1]
check(lt and lt.ok is True and true_pos(rt)[:3] == (10, 70, -30) and absof(st) == true_pos(rt),
      "gps spin: %s thinks %s is %s" % (lt_text(lt), absof(st), true_pos(rt)))
# without GPS a push is not noticed (shows the test world really pushes)
rt, M, err = go({"x": 0, "y": 64, "z": -10}, extra="PUSH_AT = 3")
check(true_pos(rt)[:3] == (1, 64, -10), "no gps push: at %s" % (true_pos(rt),))

# ---------------------------------------------------------------- task numbers
rt, M, err = run_agent([cmd("claim", 1), calib(0, 64, 0), cmd("goto", 3, {"x": 0, "y": 64, "z": -2}), ping()] + MANY
                       + [cmd("goto", 4, {"x": 0, "y": 64, "z": 0}), ping()] + MANY + [ping()], setup())
am, p = ack_msgs(M), pinged(M)
check(am[3].job == 1 and am[4].job == 2 and am.get(2).job is None, "job ids: %s %s" % (am[3].job, am[4].job))
check(any(s.jobId == 1 for s in statuses(M)) and p[-1].jobId is None and p[-1].lastTask.n == 2 and p[0].lastTask.n == 1,
      "job ids: status %s / %s" % (p[0].jobId, p[-1].lastTask.n))

# ---------------------------------------------------------------- tunnel
solid = {(x, y, z): STONE for x in range(-3, 4) for y in range(62, 68) for z in range(-12, 1) if (x, y, z) != (0, 64, 0)}
solid[(0, 65, -3)] = CHEST_B
rt, M, err = run_agent([cmd("claim", 1), calib(0, 64, 0), cmd("tunnel", 3, {"length": 6, "height": 2})] + MANY * 2 + [ping()],
                       setup(world=solid))
lt = last(M)
W = rt.globals().WORLD
cells = [(0, y, z) for y in (64, 65) for z in range(-6, 0)]
dug = [c for c in cells if W["%d,%d,%d" % c] is None]
check(acks(M).get(3) == (True, "started"), "tunnel: ack %s" % (acks(M).get(3),))
check(lt and lt.name == "tunnel 6" and lt.ok is True and lt.info.startswith("tunnel 6 x 1 x 2 done: dug 11 blocks")
      and "skipped 1" in lt.info and "chest" in lt.info, "tunnel: %s" % lt_text(lt))
check(len(dug) == 11 and W["0,65,-3"] is not None, "tunnel: dug %s" % dug)
check(W["0,64,-7"] is not None and W["1,64,-3"] is not None and W["0,63,-3"] is not None, "tunnel: dug outside")
check(true_pos(rt) == (0, 64, 0, 0) and absof(pinged(M)[-1]) == (0, 64, 0, 0), "tunnel: did not come back %s" % (true_pos(rt),))
# tunnel east, 3 high and 2 wide (to the right: south), not coming back
solid = {(x, y, z): STONE for x in range(-3, 9) for y in range(62, 69) for z in range(-3, 4) if (x, y, z) != (0, 64, 0)}
rt, M, err = run_agent([cmd("claim", 1), calib(0, 64, 0),
                        cmd("tunnel", 3, {"length": 4, "height": 3, "width": 2, "dir": "east", "back": False})]
                       + MANY * 2 + [ping()], setup(world=solid))
lt = last(M)
W = rt.globals().WORLD
cells = [(x, y, z) for x in range(1, 5) for y in range(64, 67) for z in (0, 1)]
check(lt and lt.ok is True and all(W["%d,%d,%d" % c] is None for c in cells) and lt.info.startswith("tunnel 4 x 2 x 3 done: dug 24"),
      "tunnel east: %s, left %s" % (lt_text(lt), [c for c in cells if W["%d,%d,%d" % c] is not None]))
check(W["5,64,0"] is not None and W["1,67,0"] is not None and W["1,64,2"] is not None and W["1,63,0"] is not None,
      "tunnel east: dug outside")
# bad args / fuel refusal
rt, M, err = run_agent([cmd("claim", 1), calib(0, 64, 0), cmd("tunnel", 3, {"length": 0}), cmd("tunnel", 4, {"length": 5, "width": 20}),
                        cmd("tunnel", 5, {"length": 400})], setup(fuel=100, inv={}))
a = acks(M)
check(a.get(3) == (False, "bad length (1-512)") and a.get(4) == (False, "bad width (1-8)")
      and a.get(5)[0] is False and a[5][1].startswith("not enough fuel"), "tunnel args: %s" % a)

# ---------------------------------------------------------------- quarry: protected cells stay, unload trips
ground = {(x, y, z): STONE for x in range(-6, 7) for y in range(56, 64) for z in range(-6, 7)}
ground[(0, 64, 1)] = CHEST_B                      # the chest in front of home (the drone faces south at home)
box = {"rev": 1, "boxes": [{"name": "Pillar", "x1": 3, "y1": 0, "z1": -3, "x2": 3, "y2": 100, "z2": -3}]}
q = {"x1": 2, "y1": 59, "z1": -4, "x2": 4, "y2": 63, "z2": -2}
rt, M, err = run_agent([cmd("claim", 1), calib(0, 64, 0, f="south"), cmd("protect", 8, box), cmd("quarry", 3, q)]
                       + MANY * 6 + [ping()],
                       setup((0, 64, 0, 2), ground, inv={1: ("minecraft:coal", 20)},
                             extra="DIG_ITEMS = true STACK = 8 " + " ".join(
                                 'INV[%d] = { name = "minecraft:item_%d", count = 64 }' % (i, i) for i in range(2, 15))))
lt = last(M)
W = rt.globals().WORLD
qcells = [(x, y, z) for x in range(2, 5) for y in range(59, 64) for z in range(-4, -1)]
left = [c for c in qcells if W["%d,%d,%d" % c] is not None]
check(acks(M).get(3) == (True, "started") and lt and lt.name == "quarry 3x5x3" and lt.ok is True,
      "quarry: %s %s" % (acks(M).get(3), lt_text(lt)))
check(sorted(left) == [(3, y, -3) for y in range(59, 64)], "quarry: left %s" % left)
check(lt and "dug 40 blocks" in lt.info and "skipped" in lt.info and "unload trips" in lt.info, "quarry info: %s" % lt_text(lt))
check(rt.globals().CHEST > 0 and W["0,64,1"] is not None, "quarry: nothing unloaded (%s)" % rt.globals().CHEST)
check(true_pos(rt) == (0, 64, 0, 2), "quarry: did not come back %s" % (true_pos(rt),))
check(W["2,58,-3"] is not None and W["1,63,-3"] is not None and W["5,60,-3"] is not None, "quarry: dug outside the box")
check(rt.globals().INV[1] is not None, "quarry: unloaded the fuel too")
# quarry: bad box / not calibrated / too big
rt, M, err = run_agent([cmd("claim", 1), cmd("quarry", 3, q), calib(0, 64, 0), cmd("quarry", 4, {"x1": 1}),
                        cmd("quarry", 5, {"x1": 0, "y1": 0, "z1": 0, "x2": 99, "y2": 5, "z2": 5})], setup())
a = acks(M)
check(a.get(3) == (False, "not calibrated") and a.get(4) == (False, "bad box") and a.get(5, (None, ""))[1].startswith("box too big"),
      "quarry args: %s" % a)

# ---------------------------------------------------------------- unload job
rt, M, err = run_agent([cmd("claim", 1), calib(0, 64, 0), cmd("goto", 3, {"x": 3, "y": 64, "z": -3})] + MANY
                       + [cmd("unload", 4)] + MANY + [ping()],
                       setup(world={(0, 63, 0): CHEST_B}, inv={1: ("minecraft:coal", 5), 2: ("minecraft:iron_ore", 30),
                                                              3: ("minecraft:coal", 7)}))
lt = last(M)
check(lt and lt.name == "unload" and lt.ok is True and lt.info == "unloaded 37 items into minecraft:chest (down)"
      and true_pos(rt) == (0, 64, 0, 0), "unload: %s at %s" % (lt_text(lt), true_pos(rt)))
check(rt.globals().INV[1] is not None and rt.globals().INV[2] is None, "unload: kept the wrong items")
rt, M, err = run_agent([cmd("claim", 1), calib(0, 64, 0), cmd("unload", 4), ["timer", 1], ping()], setup())
lt = last(M)
check(lt and lt.ok is False and lt.info.startswith("no chest at home"), "unload no chest: %s" % lt_text(lt))

print("navigation: ok" if not fail else "navigation: FAILED (%d)" % len(fail))
sys.exit(1 if fail else 0)
