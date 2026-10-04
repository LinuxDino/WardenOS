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
"""


def turtle_env(events, fs=None):
    rt = lua.LuaRuntime(unpack_returned_tuples=True)
    g = rt.globals()
    g.HOST_READ = lambda p: read(p)
    g.CW, g.CH, g.MW, g.MH = 39, 13, 0, 0
    g.TURTLE, g.MODEM = True, True
    g.SCRIPT_EVENTS = rt.table_from([rt.table_from([lua_table(rt, x) for x in e]) for e in events])
    g.SCRIPT_LINES = rt.table_from([])
    M = rt.execute(read("tests/mock_cc.lua"))
    rt.execute(PRELUDE, M)
    for k, v in (fs or {}).items():
        M.FS[k] = v
    return rt, M


def run_agent(events, fs=None):
    rt, M = turtle_env(events, fs)
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

print("drone tasks: ok" if not fail else "drone tasks: FAILED (%d)" % len(fail))
sys.exit(1 if fail else 0)
