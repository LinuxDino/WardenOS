#!/usr/bin/env python3
"""Drone agent task runner + home navigation, dry-run against tests/mock_cc.lua.

Run: python3 tests/test_drone_tasks.py   (exit code 1 on failure)
"""
import os
import sys

import lupa.lua52 as lua

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
fail = []


def read(p):
    try:
        with open(os.path.join(ROOT, p), encoding="utf-8") as f:
            return f.read()
    except OSError:
        return None


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


# Lua code run after the mock: record deep copies of sent messages (status.log is a live table in the agent)
# and let the test block turtle.forward a number of times (_G.BLOCKS).
PRELUDE = """
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
BLOCKS = 0
local fwd = turtle.forward
turtle.forward = function()
  if BLOCKS > 0 then BLOCKS = BLOCKS - 1 return false, "Movement obstructed" end
  return fwd()
end

-- a tiny world: POS is the turtle's TRUE absolute position/facing (0 north -z, 1 east +x, 2 south +z, 3 west -x),
-- tracked here independently of the agent; WORLD["x,y,z"] = { name = ..., tags = { [tag] = true } } (solid blocks).
-- Moves into a solid block fail, dig removes it, inspect reads it, gps.locate (GPS_ON) returns POS.
POS = { x = 0, y = 0, z = 0, f = 0 }
WORLD = {}
GPS_ON = false
FUEL = 500
INV = { [1] = { name = "minecraft:coal", count = 12 }, [5] = { name = "minecraft:cobblestone", count = 64 } }
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
    local ok, e = orig()
    if ok then POS.x, POS.y, POS.z = x, y, z FUEL = FUEL - 1 end
    return ok, e
  end
end
local tr, tl = turtle.turnRight, turtle.turnLeft
turtle.turnRight = function() local ok = tr() if ok then POS.f = (POS.f + 1) % 4 end return ok end
turtle.turnLeft = function() local ok = tl() if ok then POS.f = (POS.f + 3) % 4 end return ok end
for n, side in pairs({ dig = "front", digUp = "up", digDown = "down" }) do
  local orig = turtle[n]
  turtle[n] = function()
    local ok, e = orig()
    if not WORLD_DIG then return ok, e end
    local k = key(target(side))
    if not WORLD[k] then return false, "Nothing to dig here" end
    WORLD[k] = nil
    return true
  end
end
INSPECTS = 0
for n, side in pairs({ inspect = "front", inspectUp = "up", inspectDown = "down" }) do
  turtle[n] = function()
    INSPECTS = INSPECTS + 1
    local b = WORLD[key(target(side))]
    if not b then return false, "No block to inspect" end
    return true, { name = b.name, state = {}, tags = b.tags or {} }
  end
end
gps.locate = function() if GPS_ON then return POS.x + 1e-9, POS.y - 1e-9, POS.z end end
turtle.getFuelLevel = function() return FUEL end
turtle.getItemCount = function(n) return INV[n] and INV[n].count or 0 end
turtle.getItemDetail = function(n) local d = INV[n] return d and { name = d.name, count = d.count } end
REFUELS = 0
turtle.refuel = function(n)
  local s = turtle.getSelectedSlot()
  local d = INV[s]
  if not d or not (d.name:find("coal", 1, true) or d.name:find("log", 1, true)) then
    return false, "Items not combustible"
  end
  n = n or d.count
  if n == 0 then return true end
  n = math.min(n, d.count)
  REFUELS = REFUELS + n
  FUEL = FUEL + 80 * n
  d.count = d.count - n
  if d.count == 0 then INV[s] = nil end
  return true
end
"""


def turtle_env(events, fs=None, pre=None):
    rt = lua.LuaRuntime(unpack_returned_tuples=True)
    g = rt.globals()
    g.HOST_READ = lambda p: read(p)
    g.CW, g.CH, g.MW, g.MH = 39, 13, 0, 0
    g.TURTLE, g.MODEM = True, True
    g.SCRIPT_EVENTS = rt.table_from([rt.table_from([lua_table(rt, x) for x in e]) for e in events])
    g.SCRIPT_LINES = rt.table_from([])
    M = rt.execute(read("tests/mock_cc.lua"))
    rt.execute(PRELUDE, M)
    if pre:
        rt.execute(pre)
    for k, v in (fs or {}).items():
        M.FS[k] = v
    return rt, M


def run_agent(events, fs=None, pre=None):
    rt, M = turtle_env(events, fs, pre)
    f = rt.eval("function(src) local f, e = load(src, '=agent.lua', 't', _G) "
                "if not f then return false, e end local ok, r = pcall(f) return ok, r end")
    ok, err = f(read("src/os/drone/agent.lua"))
    return rt, M, err


def cmd(frm, c, seq, arg=None):
    m = {"t": "cmd", "to": 7, "seq": seq, "cmd": c}
    if arg is not None:
        m["arg"] = arg
    return ["rednet_message", frm, m, "wardenos"]


def ping(frm):
    return ["rednet_message", frm, {"t": "ping"}, "wardenos"]


def msgs(M):
    return [M.sent[i] for i in range(1, len(M.sent) + 1)]


def acks(M):
    return {e.msg.seq: (e.msg.ok, e.msg.info) for e in msgs(M) if e.msg.t == "ack"}


def statuses(M):
    return [e.msg for e in msgs(M) if e.msg.t == "status" and e.to == "all"]


def logs(st):
    return [st.log[i] for i in range(1, len(st.log) + 1)] if st.log else []


def all_log_lines(M):
    seen = []
    for st in statuses(M):
        for line in logs(st):
            if line not in seen:
                seen.append(line)
    return seen


def actions(M):
    return list(M.turtle.values())


def nav(st):
    return (st.nav.x, st.nav.y, st.nav.z, st.nav.f)


# --- 1. a task runs: turtle actions, print -> log, return value -> lastTask
code1 = 'turtle.forward() print("moved") turtle.dig() return 42'
rt, M, err = run_agent([["timer", 1], cmd(5, "claim", 1), cmd(5, "run", 2, {"name": "dig1", "code": code1}),
                        ["timer", 2], ["timer", 3]])
check(err == "SCRIPT_END", "task: agent stopped early: %s" % err)
a = acks(M)
check(a.get(2) == (True, "started"), "task: run ack %s" % (a.get(2),))
check(actions(M) == ["forward", "dig"], "task: turtle did %s" % actions(M))
lines = all_log_lines(M)
check(any(l.endswith(" moved") for l in lines), "task: 'moved' not in log %s" % lines)
check(any(l.endswith("task dig1 done") for l in lines), "task: no done note %s" % lines)
st = statuses(M)[-1]
check(st.state == "ready" and st.task == "manual", "task: final state %s/%s" % (st.state, st.task))
check(st.lastTask and st.lastTask.name == "dig1" and st.lastTask.ok is True and st.lastTask.info == "42",
      "task: lastTask %s" % (dict(st.lastTask) if st.lastTask else None))
check(any(s.task == "dig1" and s.state == "working" for s in statuses(M)), "task: no 'working' broadcast")

# --- 2. syntax error, runtime error, non-owner
rt, M, err = run_agent([cmd(5, "claim", 1), cmd(5, "run", 2, {"name": "bad", "code": "turtle.forward("}),
                        cmd(5, "run", 3, {"name": "boom", "code": 'error("boom")'}),
                        ["timer", 1], ping(5), cmd(9, "run", 4, {"name": "x", "code": "return 1"}),
                        ["timer", 2]])
check(err == "SCRIPT_END", "errors: agent stopped early: %s" % err)
a = acks(M)
check(a.get(2, (None, ""))[0] is False and a[2][1].startswith("syntax error"), "errors: syntax ack %s" % (a.get(2),))
check(a.get(3) == (True, "started"), "errors: boom ack %s" % (a.get(3),))
check(a.get(4, (None,))[0] is False, "errors: non-owner run accepted %s" % (a.get(4),))
lt = statuses(M)[-1].lastTask
check(lt and lt.name == "boom" and lt.ok is False and "boom" in lt.info, "errors: lastTask %s" % (dict(lt) if lt else None))
check(any(l.find("task boom failed") >= 0 for l in all_log_lines(M)), "errors: no failed note")
check(any(e.to == 5 and e.msg.t == "status" for e in msgs(M)), "errors: ping not answered after a crash")
check(all(len(l) <= 66 for l in all_log_lines(M)), "errors: log line too long %s" % [l for l in all_log_lines(M) if len(l) > 66])

# --- 3. long task: busy refusal, stop cancels
code3 = 'for i = 1, 5 do sleep(1) report("step " .. i) end'
rt, M, err = run_agent([cmd(5, "claim", 1), cmd(5, "run", 2, {"name": "slow", "code": code3}),
                        ["timer", 1], ["timer", 2], cmd(5, "forward", 3),
                        cmd(5, "run", 4, {"name": "two", "code": "return 1"}), cmd(5, "locate", 5),
                        cmd(5, "stop", 6), ["timer", 3], ["timer", 4], ["timer", 5], ["timer", 6]])
check(err == "SCRIPT_END", "busy: agent stopped early: %s" % err)
a = acks(M)
check(a.get(3, (None, ""))[0] is False and a[3][1] == "busy: slow", "busy: forward ack %s" % (a.get(3),))
check(a.get(4, (None, ""))[0] is False and a[4][1] == "busy: slow", "busy: second run ack %s" % (a.get(4),))
check(5 in a, "busy: locate not answered")
check(a.get(6, (None,))[0] is True, "busy: stop ack %s" % (a.get(6),))
check(actions(M) == [], "busy: turtle moved %s" % actions(M))
st = statuses(M)[-1]
check(st.state == "ready" and st.task == "manual", "busy: final state %s/%s" % (st.state, st.task))
check(st.lastTask and st.lastTask.ok is False and st.lastTask.info == "stopped", "busy: lastTask not 'stopped'")
steps = [l for l in all_log_lines(M) if " step " in l]
check(1 <= len(steps) < 5, "busy: step lines %s" % steps)
check(any(l.endswith("task slow stopped") for l in all_log_lines(M)), "busy: no stopped note")

# --- 4. home: sethome, manual moves, task moves, home, restart keeps nav
rt, M, err = run_agent([cmd(5, "claim", 1), cmd(5, "home", 2),
                        cmd(5, "sethome", 3), cmd(5, "forward", 4), cmd(5, "forward", 5), cmd(5, "turnRight", 6),
                        cmd(5, "forward", 7), cmd(5, "up", 8), ping(5),
                        cmd(5, "run", 9, {"name": "walk", "code": "turtle.forward()"}), ["timer", 1], ping(5)])
check(err == "SCRIPT_END", "home: agent stopped early: %s" % err)
a = acks(M)
check(a.get(2) == (False, "no home set"), "home: home without sethome %s" % (a.get(2),))
check(a.get(3, (None,))[0] is True, "home: sethome ack %s" % (a.get(3),))
pings = [e.msg for e in msgs(M) if e.to == 5 and e.msg.t == "status"]
check(len(pings) == 2 and nav(pings[0]) == (1, 1, -2, 1) and pings[0].homeSet is True,
      "home: nav after manual moves %s" % [nav(p) for p in pings])
check(len(pings) == 2 and nav(pings[1]) == (2, 1, -2, 1), "home: nav after task move %s" % [nav(p) for p in pings])
check(any(l.endswith("home set") for l in all_log_lines(M)), "home: no 'home set' note")
fs1 = {k: v for k, v in M.FS.items()}
check("/os/drone/nav" in fs1, "home: nav not saved")

# restart with the same disk: nav survives, then go home (with an obstacle: dig, then a detour up)
before = len(actions(M))
rt, M, err = run_agent([["timer", 1], ping(5), cmd(5, "home", 1), ["timer", 2], ["timer", 3]], fs1)
check(err == "SCRIPT_END", "home2: agent stopped early: %s" % err)
pings = [e.msg for e in msgs(M) if e.to == 5 and e.msg.t == "status"]
check(pings and nav(pings[0]) == (2, 1, -2, 1) and pings[0].homeSet is True,
      "home2: nav lost on restart %s" % [nav(p) for p in pings])
a = acks(M)
check(a.get(1) == (True, "started"), "home2: home ack %s" % (a.get(1),))
st = statuses(M)[-1]
check(nav(st) == (0, 0, 0, 0), "home2: did not get home %s, did %s" % (nav(st), actions(M)))
check(st.lastTask and st.lastTask.name == "home" and st.lastTask.ok is True, "home2: lastTask %s"
      % (dict(st.lastTask) if st.lastTask else None))
check(any(s.task == "home" and s.state == "working" for s in statuses(M)), "home2: no 'working' broadcast")
check(any(l.endswith("arrived home") for l in all_log_lines(M)), "home2: no 'arrived home' note")

# replay recorded actions from the saved position: must end at 0,0,0 facing 0
DX, DZ = [0, 1, 0, -1], [-1, 0, 1, 0]
x, y, z, f = 2, 1, -2, 1
for act in actions(M):
    if act == "forward": x, z = x + DX[f], z + DZ[f]
    elif act == "back": x, z = x - DX[f], z - DZ[f]
    elif act == "up": y += 1
    elif act == "down": y -= 1
    elif act == "turnRight": f = (f + 1) % 4
    elif act == "turnLeft": f = (f + 3) % 4
check((x, y, z, f) == (0, 0, 0, 0), "home2: actions %s end at %s" % (actions(M), (x, y, z, f)))

# blocked path: forward fails twice -> dig, then detour up, still arrives
rt, M, err = run_agent([cmd(5, "run", 1, {"name": "block", "code": "_G.BLOCKS = 2"}), ["timer", 1],
                        cmd(5, "home", 2), ["timer", 2], ["timer", 3]], fs1)
st = statuses(M)[-1]
acts = actions(M)
check(nav(st) == (0, 0, 0, 0) and "dig" in acts and acts.count("up") >= 1,
      "blocked: nav %s actions %s" % (nav(st), acts))
check(st.lastTask and st.lastTask.name == "home" and st.lastTask.ok is True, "blocked: lastTask failed")

# never gets through: error "blocked at ..."
rt, M, err = run_agent([cmd(5, "run", 1, {"name": "block", "code": "_G.BLOCKS = 1000"}), ["timer", 1],
                        cmd(5, "home", 2), ["timer", 2], ["timer", 3], ping(5)], fs1)
st = statuses(M)[-1]
check(st.lastTask and st.lastTask.name == "home" and st.lastTask.ok is False
      and st.lastTask.info.startswith("blocked at"), "stuck: lastTask %s" % (dict(st.lastTask) if st.lastTask else None))
check(any(e.to == 5 and e.msg.t == "status" for e in msgs(M)), "stuck: agent dead after failed home")

# stop cancels home (home is a normal task); a non-owner cannot sethome
rt, M, err = run_agent([cmd(5, "run", 1, {"name": "block", "code": "_G.BLOCKS = 0"}), ["timer", 1],
                        cmd(9, "sethome", 2), cmd(5, "home", 3), cmd(5, "sethome", 4), ["timer", 2]], fs1)
a = acks(M)
check(a.get(2, (None,))[0] is False, "home3: non-owner sethome accepted")
check(a.get(4, (None, ""))[0] is False or statuses(M)[-1].lastTask.name == "home",
      "home3: sethome during home %s" % (a.get(4),))

# ================================================================ absolute coordinates, map, safe dig, fuel, helpers
STONE = ("minecraft:stone", ["minecraft:base_stone_overworld", "minecraft:mineable/pickaxe"])
DIRT = ("minecraft:dirt", ["minecraft:dirt", "minecraft:mineable/shovel"])
PLANKS = ("minecraft:oak_planks", ["minecraft:planks", "minecraft:mineable/axe"])
FACING = {0: "north", 1: "east", 2: "south", 3: "west"}


def setup(pos=(0, 0, 0, 0), world=None, fuel=None, inv=None, gps=False, extra=""):
    """Lua run before the agent: true position, world blocks {(x,y,z): (name, [tags])}, fuel, inventory."""
    out = ["POS = { x = %d, y = %d, z = %d, f = %d }" % pos, "WORLD_DIG = true", "GPS_ON = %s" % ("true" if gps else "false")]
    for (x, y, z), (name, tags) in (world or {}).items():
        out.append('WORLD["%d,%d,%d"] = { name = "%s", tags = { %s } }'
                   % (x, y, z, name, ", ".join('["%s"] = true' % t for t in tags)))
    if fuel is not None:
        out.append("FUEL = %d" % fuel)
    if inv is not None:
        out.append("INV = { %s }" % ", ".join('[%d] = { name = "%s", count = %d }' % (k, n, c) for k, (n, c) in inv.items()))
    out.append(extra)
    return "\n".join(out)


def true_pos(rt):
    p = rt.globals().POS
    return (p.x, p.y, p.z, p.f)


def absof(st):
    return (st.abs.x, st.abs.y, st.abs.z, st.abs.f) if st.abs else None


def originof(st):
    return (st.origin.x, st.origin.y, st.origin.z, st.origin.f) if st.origin else None


def pinged(M):
    return [e.msg for e in msgs(M) if e.to == 5 and e.msg.t == "status"]


def map_obs(M):
    out = {}
    for e in msgs(M):
        if e.msg.t == "map":
            check(e.to == "all" and e.proto == "wardenos", "map: not a wardenos broadcast")
            obs = e.msg.obs
            check(1 <= len(obs) <= 200, "map: %d obs in one message" % len(obs))
            for i in range(1, len(obs) + 1):
                o = obs[i]
                out[(o[1], o[2], o[3])] = o[4]
    return out


def world_ok(obs, world, tag):
    bad = {k: v for k, v in obs.items() if v != (world[k][0] if k in world else "air")}
    check(not bad, "%s: map obs disagree with the world %s" % (tag, bad))


# --- calibrate by hand, for every facing: absolute position stays right through moves and turns
WALK = ["forward", "turnRight", "forward", "forward", "up", "turnLeft", "turnLeft", "back", "down", "down", "turnRight"]
for F in range(4):
    start = (100, 64, -50, F)
    ev = [cmd(5, "claim", 1), cmd(5, "calibrate", 2, {"x": 100, "y": 64, "z": -50,
                                                       "facing": FACING[F].upper() if F % 2 else F})]
    ev += [cmd(5, w, 10 + i) for i, w in enumerate(WALK)] + [ping(5)]
    rt, M, err = run_agent(ev, pre=setup(start))
    a = acks(M)
    check(a.get(2) == (True, "calibrated 100 64 -50 %s" % FACING[F]), "calib%d: ack %s" % (F, a.get(2),))
    st = pinged(M)[-1]
    check(st.calibrated is True and st.homeSet is True, "calib%d: calibrated/homeSet %s %s" % (F, st.calibrated, st.homeSet))
    check(originof(st) == start, "calib%d: origin %s" % (F, originof(st)))
    check(absof(st) == true_pos(rt), "calib%d: abs %s, really at %s" % (F, absof(st), true_pos(rt)))

# calibrate after moving away from home: origin = where home really is
rt, M, err = run_agent([cmd(5, "claim", 1), cmd(5, "sethome", 2), cmd(5, "forward", 3), cmd(5, "turnLeft", 4),
                        cmd(5, "forward", 5), cmd(5, "up", 6), ping(5),
                        cmd(5, "calibrate", 7, {"x": 11, "y": 71, "z": 4, "facing": "north"}), ping(5),
                        cmd(5, "forward", 8), ping(5), cmd(5, "calibrate", 9, {"x": 1, "y": 2, "z": 3, "facing": "up"}),
                        cmd(5, "calibrate", 10, {"x": "a", "y": 2, "z": 3, "facing": 0})],
                       pre=setup((10, 70, 5, 1)))
p = pinged(M)
a = acks(M)
check(p[0].calibrated is False and p[0].abs is None and p[0].origin is None, "calib-away: calibrated before calibrate")
check(a.get(7, (None,))[0] is True and originof(p[1]) == (10, 70, 5, 1), "calib-away: origin %s" % (originof(p[1]),))
check(nav(p[1]) == nav(p[0]), "calib-away: nav changed %s" % (nav(p[1]),))
check(absof(p[2]) == true_pos(rt) == (11, 71, 3, 0), "calib-away: abs %s, really %s" % (absof(p[2]), true_pos(rt)))
check(a.get(9) == (False, "bad facing") and a.get(10) == (False, "bad position"), "calib-away: bad args %s %s"
      % (a.get(9), a.get(10)))
fs_cal = {k: v for k, v in M.FS.items()}
rt, M, err = run_agent([ping(5)], fs_cal, pre=setup((11, 71, 3, 0)))
check(originof(pinged(M)[0]) == (10, 70, 5, 1) and absof(pinged(M)[0]) == (11, 71, 3, 0),
      "calib-restart: calibration lost %s" % (originof(pinged(M)[0]),))

# --- GPS calibration: steps forward and back to find its facing
rt, M, err = run_agent([cmd(5, "claim", 1), cmd(5, "calibrate", 2), ping(5)], pre=setup((10, 70, 20, 3), gps=True))
a, st = acks(M), pinged(M)[-1]
check(a.get(2) == (True, "calibrated 10 70 20 west"), "gps: ack %s" % (a.get(2),))
check(actions(M) == ["forward", "back"] and true_pos(rt) == (10, 70, 20, 3), "gps: did %s" % actions(M))
check(originof(st) == (10, 70, 20, 3) and absof(st) == (10, 70, 20, 3), "gps: origin %s" % (originof(st),))
# forward blocked: back first
rt, M, err = run_agent([cmd(5, "claim", 1), cmd(5, "calibrate", 2), ping(5)],
                       pre=setup((10, 70, 20, 2), {(10, 70, 21): STONE}, gps=True))
check(acks(M).get(2) == (True, "calibrated 10 70 20 south") and actions(M) == ["back", "forward"],
      "gps-back: ack %s did %s" % (acks(M).get(2), actions(M)))
# boxed in / no GPS
rt, M, err = run_agent([cmd(5, "claim", 1), cmd(5, "calibrate", 2)],
                       pre=setup((10, 70, 20, 2), {(10, 70, 21): STONE, (10, 70, 19): STONE}, gps=True))
check(acks(M).get(2) == (False, "can't move to find facing"), "gps-stuck: ack %s" % (acks(M).get(2),))
rt, M, err = run_agent([cmd(5, "claim", 1), cmd(5, "calibrate", 2), ping(5)], pre=setup((10, 70, 20, 2)))
check(acks(M).get(2) == (False, "no GPS") and pinged(M)[-1].calibrated is False and actions(M) == [],
      "gps-none: ack %s" % (acks(M).get(2),))

# --- sethome keeps calibration
rt, M, err = run_agent([cmd(5, "claim", 1), cmd(5, "calibrate", 2, {"x": 0, "y": 64, "z": 0, "facing": "east"}),
                        cmd(5, "forward", 3), cmd(5, "turnRight", 4), cmd(5, "forward", 5), cmd(5, "sethome", 6),
                        ping(5), cmd(5, "forward", 7), cmd(5, "turnLeft", 8), cmd(5, "up", 9), ping(5)],
                       pre=setup((0, 64, 0, 1)))
p = pinged(M)
check(nav(p[0]) == (0, 0, 0, 0) and originof(p[0]) == (1, 64, 1, 2), "sethome: new origin %s" % (originof(p[0]),))
check(absof(p[1]) == true_pos(rt) == (1, 65, 2, 1), "sethome: abs %s, really %s" % (absof(p[1]), true_pos(rt)))

# --- map: moves report their neighbours (blocks and air) with absolute coordinates, every 2 s
world = {(5, 64, -1): STONE, (5, 65, -1): DIRT, (4, 63, -1): ("minecraft:grass_block", ["minecraft:dirt"]),
         (4, 63, -2): STONE, (6, 64, -2): PLANKS}
rt, M, err = run_agent([cmd(5, "claim", 1), cmd(5, "forward", 2), ["timer", 1],
                        cmd(5, "calibrate", 3, {"x": 4, "y": 64, "z": 0, "facing": "north"}),
                        cmd(5, "forward", 4), cmd(5, "turnRight", 5), ["timer", 2], ["timer", 3]],
                       pre=setup((4, 64, 1, 0), world))
obs = map_obs(M)
world_ok(obs, world, "map")
check(obs.get((5, 64, -1)) == "minecraft:stone" and obs.get((4, 63, -1)) == "minecraft:grass_block"
      and obs.get((4, 65, -1)) == "air" and obs.get((4, 64, -2)) == "air", "map: missing obs %s" % obs)
check((4, 64, -1) not in obs or obs[(4, 64, -1)] == "air", "map: own spot not air")
check(len([e for e in msgs(M) if e.msg.t == "map"]) >= 1, "map: nothing broadcast")
first_map = [i for i, e in enumerate(msgs(M)) if e.msg.t == "map"]
first_ack3 = [i for i, e in enumerate(msgs(M)) if e.msg.t == "ack" and e.msg.seq == 3]
check(first_map and first_ack3 and first_map[0] > first_ack3[0], "map: sent before calibrating")

# not calibrated: no inspecting, no map
rt, M, err = run_agent([cmd(5, "claim", 1), cmd(5, "forward", 2), cmd(5, "turnLeft", 3), ["timer", 1], ["timer", 2]],
                       pre=setup((0, 0, 0, 0), world))
check(not map_obs(M) and rt.globals().INSPECTS == 0, "map-uncal: inspected/sent without calibration")

# --- scan: looks all around, sends at once
world = {(0, 64, -1): STONE, (1, 64, 0): DIRT, (0, 63, 0): STONE, (-1, 64, 0): PLANKS}
rt, M, err = run_agent([cmd(5, "claim", 1), cmd(5, "scan", 2),
                        cmd(5, "calibrate", 3, {"x": 0, "y": 64, "z": 0, "facing": 0}), cmd(5, "scan", 4), ping(5)],
                       pre=setup((0, 64, 0, 0), world))
a = acks(M)
check(a.get(2) == (False, "not calibrated"), "scan: uncalibrated %s" % (a.get(2),))
check(a.get(4) == (True, "6 blocks"), "scan: ack %s" % (a.get(4),))
obs = map_obs(M)
world_ok(obs, world, "scan")
check(set(obs) >= {(0, 64, -1), (1, 64, 0), (0, 64, 1), (-1, 64, 0), (0, 65, 0), (0, 63, 0)}, "scan: obs %s" % obs)
check(actions(M) == ["turnRight"] * 4 and true_pos(rt)[3] == 0 and pinged(M)[-1].nav.f == 0, "scan: did %s" % actions(M))

# --- safe dig: natural blocks only; protected areas; task code too
world = {(0, 64, -1): PLANKS, (0, 65, 0): DIRT, (0, 63, 0): ("minecraft:deepslate_iron_ore", [])}
rt, M, err = run_agent([cmd(5, "claim", 1), ping(5), cmd(5, "dig", 2), cmd(5, "digUp", 3), cmd(5, "digDown", 4),
                        cmd(5, "run", 5, {"name": "chop", "code": "return turtle.dig()"}), ["timer", 1],
                        cmd(5, "safedig", 6, False), cmd(5, "dig", 7), cmd(5, "safedig", 8, "no"), ping(5)],
                       pre=setup((0, 64, 0, 0), world))
a, p = acks(M), pinged(M)
check(p[0].safeDig is True and p[0].protectRev == 0, "safedig: default status %s %s" % (p[0].safeDig, p[0].protectRev))
check(a.get(2) == (False, "protected: minecraft:oak_planks (safe dig)"), "safedig: planks %s" % (a.get(2),))
check(a.get(3, (None,))[0] is True and a.get(4, (None,))[0] is True, "safedig: dirt/ore %s %s" % (a.get(3), a.get(4)))
lt = [s.lastTask for s in statuses(M) if s.lastTask and s.lastTask.name == "chop"]
check(lt and lt[-1].info == "false, protected: minecraft:oak_planks (safe dig)", "safedig: task dig %s"
      % (lt[-1].info if lt else None))
check(a.get(7, (None,))[0] is True and a.get(8, (None,))[0] is False and p[-1].safeDig is False,
      "safedig off: %s %s" % (a.get(7), a.get(8)))
check(actions(M) == ["digUp", "digDown", "dig"], "safedig: dug %s" % actions(M))
check("safeDig" in M.FS["/os/drone/config"], "safedig: not saved")

# tags: stone (base_stone_overworld), "_ores" tags, c:ores
world = {(0, 64, -1): STONE, (0, 65, 0): ("mod:odd_rock", ["c:zinc_ores"]), (0, 63, 0): ("mod:thing", ["c:ores"])}
rt, M, err = run_agent([cmd(5, "claim", 1), cmd(5, "dig", 2), cmd(5, "digUp", 3), cmd(5, "digDown", 4),
                        cmd(5, "dig", 5)], pre=setup((0, 64, 0, 0), world))
a = acks(M)
check(all(a.get(i, (None,))[0] is True for i in (2, 3, 4)), "tags: %s" % a)
check(a.get(5, (None,))[0] is False and "protected" not in str(a.get(5)), "tags: dig into air %s" % (a.get(5),))

# protected box: even stone is refused (needs calibration); persisted, status protectRev
world = {(10, 64, 9): STONE, (10, 65, 10): STONE}
box = {"rev": 7, "boxes": [{"name": "Town hall", "x1": 12, "y1": 70, "z1": 9, "x2": 8, "y2": 64, "z2": 0}]}
rt, M, err = run_agent([cmd(5, "claim", 1), cmd(5, "protect", 2, box), cmd(5, "dig", 3),
                        cmd(5, "calibrate", 4, {"x": 10, "y": 64, "z": 10, "facing": "north"}),
                        cmd(5, "digUp", 5), cmd(5, "protect", 6, {"rev": 8, "boxes": [{"x1": 1}]}), ping(5),
                        cmd(5, "run", 7, {"name": "sneak", "code": "return turtle.dig()"}), ["timer", 1]],
                       pre=setup((10, 64, 10, 0), world))
a = acks(M)
check(a.get(2) == (True, "1 areas"), "protect: ack %s" % (a.get(2),))
check(a.get(3, (None,))[0] is True, "protect: uncalibrated dig of stone refused %s" % (a.get(3),))
check(a.get(5, (None,))[0] is True, "protect: digUp outside box refused %s" % (a.get(5),))
check(a.get(6, (None,))[0] is False, "protect: bad box accepted")
check(pinged(M)[-1].protectRev == 7, "protect: protectRev %s" % pinged(M)[-1].protectRev)
fs_p = {k: v for k, v in M.FS.items()}
check("Town hall" in fs_p["/os/drone/config"], "protect: not saved")
rt, M, err = run_agent([cmd(5, "dig", 1), ping(5)], fs_p, pre=setup((10, 64, 10, 0), {(10, 64, 9): STONE}))
check(acks(M).get(1) == (False, "protected: Town hall"), "protect: stone in box %s" % (acks(M).get(1),))
check(actions(M) == [] and pinged(M)[-1].protectRev == 7, "protect: dug %s" % actions(M))

# home trip: a refused dig counts as blocked -> detour up
# (planks appear between the drone and home after it backed off, placed by a task: tasks run Lua on the "turtle")
rt, M, err = run_agent([cmd(5, "claim", 1), cmd(5, "sethome", 2), cmd(5, "back", 3), cmd(5, "back", 4),
                        cmd(5, "run", 5, {"name": "wall", "code": 'WORLD["0,64,1"] = { name = "minecraft:oak_planks", tags = {} }'}),
                        ["timer", 1], cmd(5, "home", 6), ["timer", 2], ["timer", 3]], pre=setup((0, 64, 0, 0)))
st = statuses(M)[-1]
check(st.lastTask and st.lastTask.name == "home" and st.lastTask.ok is True and nav(st) == (0, 0, 0, 0),
      "home-wall: %s" % (dict(st.lastTask) if st.lastTask else None))
check("dig" not in actions(M) and "up" in actions(M) and rt.globals().WORLD["0,64,1"] is not None,
      "home-wall: did %s" % actions(M))

# --- auto refuel before moves, fuelItems in the status
rt, M, err = run_agent([cmd(5, "claim", 1), cmd(5, "select", 2, 5), ping(5), cmd(5, "forward", 3), ping(5)],
                       pre=setup(fuel=150, inv={1: ("minecraft:coal", 12), 2: ("minecraft:oak_log", 3),
                                                5: ("minecraft:cobblestone", 64)}))
p = pinged(M)
check(p[0].fuelItems == 15 and p[1].fuelItems == 4, "refuel: fuelItems %s %s" % (p[0].fuelItems, p[1].fuelItems))
check(p[1].fuel == 1029 and p[1].selected == 5, "refuel: fuel %s selected %s" % (p[1].fuel, p[1].selected))
check(rt.globals().REFUELS == 11 and actions(M) == ["forward"], "refuel: burned %s" % rt.globals().REFUELS)
# enough fuel: nothing burned
rt, M, err = run_agent([cmd(5, "claim", 1), cmd(5, "forward", 3)], pre=setup(fuel=200))
check(rt.globals().REFUELS == 0, "refuel: burned with fuel 200")

# --- fuel guard: a task stops with low fuel and the drone goes home
rt, M, err = run_agent([cmd(5, "claim", 1), cmd(5, "sethome", 2),
                        cmd(5, "run", 3, {"name": "far", "code": "for i = 1, 300 do turtle.forward() end return 'gone'"}),
                        ["timer", 1], ["timer", 2], ping(5)],
                       pre=setup(fuel=230, inv={5: ("minecraft:cobblestone", 64)}))
lts = [(s.lastTask.name, s.lastTask.ok, s.lastTask.info) for s in statuses(M) if s.lastTask]
check(("far", False, "low fuel: returning home") in lts, "fuelguard: lastTask %s" % sorted(set(lts)))
st = pinged(M)[-1]
check(st.lastTask and st.lastTask.name == "home" and st.lastTask.ok is True and nav(st) == (0, 0, 0, 0),
      "fuelguard: not home %s %s" % (nav(st), dict(st.lastTask) if st.lastTask else None))
check(actions(M).count("forward") == 106 + 106, "fuelguard: moves %d" % actions(M).count("forward"))
check(any(l.endswith("low fuel: returning home") for l in all_log_lines(M)), "fuelguard: no note")

# --- helpers: moveTo (around a wall it may not dig, through stone it may), face, whereAmI
world = {(7, 62, -3): PLANKS, (8, 63, -5): STONE}
code = ('moveTo(8, 62, -7) face("north") local w = whereAmI() '
        'return w.x, w.y, w.z, w.f, w.rel.x, w.rel.y, w.rel.z, w.rel.f, w.calibrated')
rt, M, err = run_agent([cmd(5, "claim", 1), cmd(5, "calibrate", 2, {"x": 5, "y": 60, "z": -3, "facing": "south"}),
                        cmd(5, "run", 3, {"name": "go", "code": code}), ["timer", 1], ping(5)],
                       pre=setup((5, 60, -3, 2), world))
st = pinged(M)[-1]
check(true_pos(rt) == (8, 62, -7, 0), "moveTo: really at %s, did %s" % (true_pos(rt), actions(M)))
check(st.lastTask and st.lastTask.ok and st.lastTask.info == "8, 62, -7, 0, -3, 2, 4, 2, true",
      "moveTo: lastTask %s" % (dict(st.lastTask) if st.lastTask else None))
W = rt.globals().WORLD
check(W["7,62,-3"] is not None and W["8,63,-5"] is None, "moveTo: dug the wrong blocks")
check(actions(M).count("dig") == 1, "moveTo: digs %s" % actions(M))
# not calibrated / stuck
rt, M, err = run_agent([cmd(5, "claim", 1), cmd(5, "run", 3, {"name": "go", "code": "moveTo(1, 2, 3)"}), ["timer", 1], ping(5)],
                       pre=setup())
lt = pinged(M)[-1].lastTask
check(lt and lt.ok is False and lt.info.endswith("not calibrated"), "moveTo: uncalibrated %s" % (dict(lt) if lt else None))
rt, M, err = run_agent([cmd(5, "claim", 1), cmd(5, "calibrate", 2, {"x": 0, "y": 0, "z": 0, "facing": 0}),
                        cmd(5, "run", 3, {"name": "go", "code": "moveTo(0, 0, -5)"}), ["timer", 1], ping(5)],
                       pre=setup((0, 0, 0, 0), {(0, y, -1): PLANKS for y in range(0, 40)}))
lt = pinged(M)[-1].lastTask
check(lt and lt.ok is False and lt.info == "blocked at 0 20 0", "moveTo: stuck %s" % (dict(lt) if lt else None))

# face by name, uncalibrated = relative to home; findItem / selectItem; inspectAll
code = ('face("west") local a = whereAmI().f face(1) local b = whereAmI().f turtle.select(5) '
        'local i = inspectAll() '
        'return a, b, findItem("cobble"), findItem("diamond"), selectItem("coal"), turtle.getSelectedSlot(), '
        'selectItem("zzz"), i.front, i.up, i.down, whereAmI().calibrated')
rt, M, err = run_agent([cmd(5, "claim", 1), cmd(5, "run", 3, {"name": "h", "code": code}), ["timer", 1], ping(5)],
                       pre=setup((0, 64, 0, 0), {(-1, 64, 0): STONE}))
lt = pinged(M)[-1].lastTask
check(lt and lt.info == "3, 1, 5, nil, true, 1, false, air, air, air, false", "helpers: %s" % (lt.info if lt else None))
check(actions(M) == ["turnLeft", "turnRight", "turnRight"], "helpers: turns %s" % actions(M))
code = 'face("north") local i = inspectAll() return whereAmI().rel.f, i.front'
rt, M, err = run_agent([cmd(5, "claim", 1), cmd(5, "calibrate", 2, {"x": 0, "y": 64, "z": 0, "facing": "south"}),
                        cmd(5, "run", 3, {"name": "h", "code": code}), ["timer", 1], ["timer", 2], ping(5)],
                       pre=setup((0, 64, 0, 2), {(0, 64, -1): STONE}))
lt = pinged(M)[-1].lastTask
check(lt and lt.info == "2, minecraft:stone" and true_pos(rt)[3] == 0, "helpers-abs: %s" % (lt.info if lt else None))
check(map_obs(M).get((0, 64, -1)) == "minecraft:stone", "helpers-abs: inspectAll not mapped")

print("drone tasks: ok" if not fail else "drone tasks: FAILED (%d)" % len(fail))
sys.exit(1 if fail else 0)
