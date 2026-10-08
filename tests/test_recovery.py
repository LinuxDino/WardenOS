#!/usr/bin/env python3
"""Recovery checks:  python3 tests/test_recovery.py  (needs: pip install lupa). Exit code 1 on failure.

/startup.lua on an installed computer (installed with install.lua against the mocked CC: Tweaked):
1. the kernel throws -> the Recovery screen (not a red line), /os/crash.txt with stage, error and traceback
2. a damaged / missing file needed to boot -> Recovery before the boot menu, names the file
3. Safe mode: the kernel runs again with WARDEN_SAFE, the real kernel shows the computer screen only
4. 3 failed starts in a row -> Recovery ("keeps failing"), a good start resets the counter
5. boot menu entry "Recovery" -> menu with "Start WardenOS"
6. Repair with /os/kernel.lua gone -> the installer update restores it, accounts kept
7. a monitor that throws (other mod / changed by an update) -> the desktop starts on the computer screen
8. Check files / Reset display settings / Show full error
"""
import os, sys
import lupa.lua52 as lua

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
fail = []
ENTER, DOWN, F12 = 28, 208, 88


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


def new_env(events, lines=(), fs=None, CW=51, CH=19, MW=0, MH=0, pre=""):
    rt = lua.LuaRuntime(unpack_returned_tuples=True)
    g = rt.globals()
    g.HOST_READ = lambda p: read(p)
    g.CW, g.CH, g.MW, g.MH = CW, CH, MW, MH
    g.SCRIPT_EVENTS = rt.table_from([rt.table_from(e) for e in events])
    g.SCRIPT_LINES = rt.table_from(list(lines))
    M = rt.execute(read("tests/mock_cc.lua"))
    for k, v in (fs or {}).items():
        M.FS[k] = v
    if pre:
        rt.execute(pre)
    return rt, M


def run(rt, src, name, *args):
    f = rt.eval("function(src, name, ...) local f, e = load(src, '=' .. name, 't', _G) "
                "if not f then return false, e end local ok, r = pcall(f, ...) return ok, r end")
    return f(src, name, *args)


def snap(M):
    return {k: v for k, v in M.FS.items()}


def text(M):
    t = M.native
    return "\n".join(t.rows[y] for y in range(1, t.h + 1))


def log(M):
    return "\n".join(M.log.values())


def boot(fs, events, **kw):
    rt, M = new_env(events, fs=fs, **kw)
    ok, err = run(rt, fs["/startup.lua"], "startup.lua")
    return rt, M, ok, err


# an installed computer
rt, M = new_env([["key", ENTER]] + [["key", DOWN]] * 80 + [["key", ENTER]] * 3,
                ["AGREE", "", "dino", "secret1", "secret1", "ERASE"])
ok, err = run(rt, read("install.lua"), "install.lua")
check(ok and M.rebooted, "install: %s" % err)
BASE = snap(M)
check(BASE.get("/os/recovery.lua") == read("src/os/recovery.lua"), "install: /os/recovery.lua not installed")
LOGIN = [["char", c] for c in "secret1"] + [["key", ENTER]]
AUTO = [["timer", i] for i in range(1, 12)]        # boot screen + menu time out -> WardenOS


# 1. kernel error -> Recovery screen + crash report; 7 = CraftOS
fs = dict(BASE)
fs["/os/kernel.lua"] = 'local function inner() local t = nil return t.x end\ninner()'
rt, M, ok, err = boot(fs, [["key", ENTER], ["char", "7"]])
scr = text(M)
f = snap(M)
check("WardenOS Recovery" in "".join(M.written.values()) and "could not start" in "".join(M.written.values()),
      "kernel error: no recovery screen:\n%s\n%s" % (scr, log(M)[-300:]))
crash = f.get("/os/crash.txt", "")
check("stage: kernel" in crash and "attempt to index" in crash and "traceback" in crash and "WardenOS: " in crash,
      "kernel error: crash report:\n%s" % crash)
check("CraftOS" in log(M), "kernel error: 7 did not drop to CraftOS: %s" % log(M)[-200:])
check(M.violations == 0, "kernel error: off-screen writes")
check("value it did not expect" in "".join(M.written.values()), "kernel error: no plain-language hint")

# 2. a damaged file needed to boot -> Recovery before the boot menu
fs = dict(BASE)
fs["/os/lib/login.lua"] = "local x = ("
rt, M, ok, err = boot(fs, [["char", "7"]])
w = "".join(M.written.values())
check("/os/lib/login.lua" in w and "damaged" in w, "damaged file: not named:\n%s" % text(M))
check("WardenOS booting" not in log(M), "damaged file: still tried to boot")
fs = dict(BASE)
del fs["/os/boot.lua"]
rt, M, ok, err = boot(fs, [["char", "7"]])
check("/os/boot.lua" in "".join(M.written.values()) and "missing" in "".join(M.written.values()),
      "missing file: not named:\n%s" % text(M))

# 3. Safe mode: the kernel runs again with WARDEN_SAFE
fs = dict(BASE)
fs["/os/kernel.lua"] = 'if not WARDEN_SAFE then error("monitor exploded") end print("SAFE OK")'
rt, M, ok, err = boot(fs, [["key", ENTER], ["char", "3"]])
check("SAFE OK" in log(M) and "safe mode" in log(M), "safe mode: kernel not started safely: %s" % log(M)[-300:])
check(rt.eval("WARDEN_SAFE") is None, "safe mode: flag left set")
check("monitor is not working" in "".join(M.written.values()), "safe mode: no monitor hint")
# the real kernel in safe mode: computer screen only even with a monitor attached
fs = dict(BASE)
fs["/os/settings.lua"] = '{ display = "monitor", scale = 0.5 }'
rt, M = new_env(LOGIN + [["timer", i] for i in range(1, 30)] + [["key", F12]], fs=fs, MW=164, MH=81,
                pre="WARDEN_SAFE = true")
ok, err = run(rt, "dofile('/os/kernel.lua')", "k")
check(ok and rt.eval("WardenOS.display") == "computer", "safe kernel: display %s (%s)" % (rt.eval("WardenOS.display"), err))
check(rt.eval("WardenOS.drones") is None, "safe kernel: background world service still loaded")
check("Safe mode" in "".join(M.written.values()), "safe kernel: no safe mode note")

# 4. 3 failed starts in a row -> Recovery; a good start resets the counter
fs = dict(BASE)
fs["/os/boot.state"] = "{ fails = 3 }"
rt, M, ok, err = boot(fs, [["key", ENTER], ["char", "8"]])
w = "".join(M.written.values())
check("keeps failing" in w and "failed to start 3 times" in w, "boot loop: no recovery:\n%s" % text(M))
check("WardenOS booting" not in log(M), "boot loop: booted anyway")
fs = dict(BASE)
fs["/os/boot.state"] = "{ fails = 2 }"
rt, M, ok, err = boot(fs, [["key", ENTER]] + LOGIN + [["key", F12]])
st = rt.eval("function(s) return textutils.unserialize(s) end")(snap(M).get("/os/boot.state"))
check(st is not None and st.fails == 0, "boot loop: counter not reset by a good start: %s" % snap(M).get("/os/boot.state"))
check("stopped" in log(M), "boot loop: good start did not run: %s" % log(M)[-200:])

# 5. boot menu "Recovery" -> menu, 1 = Start WardenOS
fs = dict(BASE)
rt, M, ok, err = boot(fs, [["char", "3"], ["char", "1"]] + LOGIN + [["key", F12]])
w = "".join(M.written.values())
check("Start WardenOS" in w and "Pick what to do" in w, "menu recovery: not shown:\n%s" % text(M))
check("stopped" in log(M), "menu recovery: Start WardenOS did not boot: %s" % log(M)[-200:])
check("/os/crash.txt" not in snap(M), "menu recovery: wrote a crash report without an error")
# D on Recovery never makes it the default
rt, M, ok, err = boot(dict(BASE), [["key", DOWN], ["key", DOWN], ["char", "d"], ["char", "2"]])
check("recovery" not in (snap(M).get("/os/boot.cfg") or ""), "menu recovery: became the default")

# 6. Repair with the kernel gone: the installer update puts it back, accounts kept
fs = dict(BASE)
del fs["/os/kernel.lua"]
rt, M, ok, err = boot(fs, [["char", "2"]])
f = snap(M)
check(M.rebooted and f.get("/os/kernel.lua") == read("src/os/kernel.lua") and f.get("/os/users.dat") == BASE["/os/users.dat"],
      "repair: kernel not restored (%s): %s" % (err, log(M)[-600:]))

# 7. a monitor that throws: desktop on the computer screen, a note instead of a crash
fs = dict(BASE)
rt, M = new_env([["key", ENTER]] + LOGIN + [["timer", i] for i in range(1, 30)] + [["key", F12]], fs=fs, MW=164, MH=81,
                pre="local m = peripheral.wrap('right') m.setTextScale = function() error('Monitor is not attached') end")
ok, err = run(rt, fs["/startup.lua"], "startup.lua")
check("stopped" in log(M) and "WardenOS Recovery" not in "".join(M.written.values()), "bad monitor: crashed: %s %s" % (err, log(M)[-300:]))
check(rt.eval("WardenOS.display") == "computer", "bad monitor: display %s" % rt.eval("WardenOS.display"))
check("does not work" in "".join(M.written.values()), "bad monitor: no note")

# 8. Check files, Reset display settings, Show full error
fs = dict(BASE)
fs["/os/kernel.lua"] = 'error("boom")'
fs["/os/apps/todo.lua"] = "return {"
fs["/os/settings.lua"] = '{ display = "monitor" }'
fs["/os/boot.cfg"] = '{ default = "wardenos", timeout = 5 }'
rt, M, ok, err = boot(fs, [["key", ENTER], ["char", "4"], ["key", ENTER], ["char", "5"], ["key", ENTER],
                           ["char", "6"], ["key", ENTER], ["char", "7"]])
w = "".join(M.written.values())
f = snap(M)
check("/os/apps/todo.lua" in w and "damaged" in w, "check files: damaged app not found:\n%s" % text(M))
check("/os/settings.lua" not in f and f.get("/os/settings.bak") == '{ display = "monitor" }' and "/os/boot.cfg" not in f
      and f.get("/os/users.dat") == BASE["/os/users.dat"], "reset display: %s" % sorted(k for k in f if k.startswith("/os/s")))
check("Error report" in w and "boom" in w, "show full error: not shown")
check("CraftOS" in log(M) and M.violations == 0, "menu actions: %s" % log(M)[-200:])

# small screen (pocket size) still fits
fs = dict(BASE)
fs["/os/kernel.lua"] = 'error("a very long error message ' + "x" * 200 + '")'
rt, M, ok, err = boot(fs, [["key", ENTER], ["char", "7"]], CW=26, CH=20)
check(M.violations == 0 and "Recovery" in "".join(M.written.values()), "26x20: %d off-screen" % M.violations)

# the startup still works when recovery.lua itself is broken: plain message + repair command
fs = dict(BASE)
fs["/os/recovery.lua"] = "return {"
fs["/os/kernel.lua"] = 'error("boom")'
rt, M, ok, err = boot(fs, [["key", ENTER]])
check("Kernel error: " in log(M) and "pastebin run CeQfPV78 update" in log(M), "no recovery.lua: %s" % log(M)[-300:])

print("recovery: ok" if not fail else "recovery: FAILED")
if fail:
    print("\n%d problem(s)" % len(fail))
    sys.exit(1)
print("all recovery checks passed")
