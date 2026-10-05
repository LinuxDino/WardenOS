#!/usr/bin/env python3
"""To-Do app:  python3 tests/test_todo.py  (needs: pip install lupa)"""
import os, sys
import lupa.lua52 as lua

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
fail = []

def read(rel):
    with open(os.path.join(ROOT, rel), "rb") as f:
        return f.read().decode("latin-1")

def check(cond, msg):
    if not cond:
        fail.append(msg)
        print("FAIL", msg)

THEME = """WardenOS = { theme = { bg = colors.black, panel = colors.gray, text = colors.white, dim = colors.lightGray,
  accent = colors.cyan, good = colors.green, bad = colors.red, warn = colors.yellow } }"""

def run(events, w=40, h=15, files=None):
    rt = lua.LuaRuntime(unpack_returned_tuples=True, encoding="latin-1")
    g = rt.globals()
    g.HOST_READ = lambda p: None
    g.CW, g.CH, g.MW, g.MH = w, h, 0, 0
    evs = []
    for e in events:
        evs.append(rt.table_from(e))
    g.SCRIPT_EVENTS = rt.table_from(evs)
    g.SCRIPT_LINES = rt.table_from([])
    M = rt.execute(read("tests/mock_cc.lua"))
    M.FS["/os"] = True
    M.FS["/os/apps"] = True
    M.FS["/os/apps/todo.lua"] = read("src/os/apps/todo.lua")
    for k, v in (files or {}).items():
        M.FS[k] = v
    rt.execute(THEME)
    ok, err = rt.eval("function() return pcall(function() dofile('/os/apps/todo.lua').main() end) end")()
    check(err == "SCRIPT_END", "app stopped early: %s" % err)
    check(M.violations == 0, "%dx%d: %d chars drawn off-screen" % (w, h, M.violations))
    t = M.native
    screen = "\n".join(t.rows[y] for y in range(1, t.h + 1))
    data = rt.eval("function(s) return textutils.unserialize(s or '') end")(M.FS["/os/todo.dat"])
    return M, screen, data

def typed(s):
    return [["char", c] for c in s] + [["key", 28]]

def tasks_of(data):
    if data is None:
        return []
    ts = data.tasks
    return [ts[i] for i in range(1, len(ts) + 1)]

# add two tasks; "!!" makes the second one urgent (sorted to the top)
M, screen, data = run(typed("buy coal") + typed("!! fix the base wall"))
ts = tasks_of(data)
check([t.text for t in ts] == ["buy coal", "fix the base wall"], "tasks not saved: %s" % [t.text for t in ts])
check(ts[1].prio == 2 and ts[0].prio == 0, "priority from '!!' not set")
check(screen.splitlines()[1].strip().startswith("[ ] !! fix the base wall"), "urgent task not first:\n" + screen)
check("2 open" in screen, "open count missing:\n" + screen)
saved = M.FS["/os/todo.dat"]

# tick off the first row (the urgent one): it leaves the "open" view, shows under "done" and "all"
M, screen, data = run([["mouse_click", 1, 2, 2]], files={"/os/todo.dat": saved})
ts = {t.text: t for t in tasks_of(data)}
check(ts["fix the base wall"].done is True and ts["buy coal"].done is False, "tick did not mark done")
check("fix the base wall" not in screen and "1 open" in screen, "done task still in the open view:\n" + screen)
saved = M.FS["/os/todo.dat"]

# filters: "done" shows it with [x]; "all" shows both, open first
w = 40
M, screen, data = run([["mouse_click", 1, w - 1, 1]], files={"/os/todo.dat": saved})     # "done" tab (rightmost)
check("[x] !! fix the base wall" in screen and "buy coal" not in screen, "done filter wrong:\n" + screen)
M, screen, data = run([["mouse_click", 1, w - 15, 1]], files={"/os/todo.dat": saved})    # "all" tab
lines = screen.splitlines()
check(lines[1].strip().startswith("[ ] buy coal") and lines[2].strip().startswith("[x]"), "all filter order wrong:\n" + screen)

# select a task: cycle priority, then delete it
M, screen, data = run([["mouse_click", 1, 10, 2], ["mouse_click", 1, 9, 14]], h=15, files={"/os/todo.dat": saved})
ts = {t.text: t for t in tasks_of(data)}
check(ts["buy coal"].prio == 1, "priority button did not cycle: %s" % ts["buy coal"].prio)
M, screen, data = run([["mouse_click", 1, 10, 2], ["mouse_click", 1, 24, 14]], h=15, files={"/os/todo.dat": M.FS["/os/todo.dat"]})
check("buy coal" not in [t.text for t in tasks_of(data)], "delete did not remove the task")

# clear done
M, screen, data = run([["mouse_click", 1, 3, 14]], h=15, files={"/os/todo.dat": saved})
check(all(not t.done for t in tasks_of(data)) and len(tasks_of(data)) == 1, "clear done failed")

# small and big windows, empty state, broken file
for (ww, hh) in [(20, 10), (26, 18), (46, 17)]:
    M, screen, data = run(typed("a very long task name that does not fit on one row at all"), w=ww, h=hh)
    check(len(tasks_of(data)) == 1, "%dx%d: add failed" % (ww, hh))
M, screen, data = run([], files={"/os/todo.dat": "{ broken"})
check("No tasks yet" in screen, "empty state / broken file:\n" + screen)

print()
if fail:
    print("%d problem(s)" % len(fail))
    sys.exit(1)
print("todo app: ok")
