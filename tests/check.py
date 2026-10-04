#!/usr/bin/env python3
"""WardenOS checks. Run from anywhere:  python3 tests/check.py   (needs: pip install lupa)

1. manifest.lua lists exactly the files in src/, versions match, files are ASCII
2. every Lua file compiles
3. full dry run against a mocked CC: Tweaked at several screen sizes:
   install.lua (download + clean install) -> startup/boot menu -> login -> open every app -> exit,
   then `install update` (keeps accounts, removes stale files)
"""
import os, re, sys
import lupa.lua52 as lua

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src")
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

# ---------------------------------------------------------------- static checks
rt = lua.LuaRuntime(unpack_returned_tuples=True)
manifest = rt.execute(read("manifest.lua"))
listed = [manifest.files[i] for i in range(1, len(manifest.files) + 1)]
on_disk = sorted(os.path.relpath(os.path.join(d, f), SRC).replace(os.sep, "/")
                 for d, _, fs in os.walk(SRC) for f in fs)
check(sorted(listed) == on_disk, "manifest.lua does not match src/: missing %s, extra %s"
      % (sorted(set(on_disk) - set(listed)), sorted(set(listed) - set(on_disk))))
check(len(set(listed)) == len(listed), "duplicate entries in manifest.lua")
cfg_ver = re.search(r'version\s*=\s*"([^"]+)"', read("src/os/config.lua")).group(1)
check(cfg_ver == manifest.version, "version mismatch: config.lua %s, manifest.lua %s" % (cfg_ver, manifest.version))

lua_files = ["install.lua", "manifest.lua"] + ["src/" + f for f in on_disk if f.endswith(".lua")]
compile_ = rt.eval("function(src, name) local f, e = load(src, name, 't', {}) return f ~= nil, e end")
for f in lua_files:
    src = read(f)
    check(all(ord(c) < 128 for c in src), f + " contains non-ASCII characters")
    ok, err = compile_(src, "=" + f)
    check(ok, "syntax error: %s" % err)
    check(not re.search(r"(?i)bxdn|tweakos", src), f + " still mentions the old name")
print("static checks: %d files" % len(lua_files))

# ---------------------------------------------------------------- dry runs
def new_env(CW, CH, MW, MH, events, lines, fs=None):
    rt = lua.LuaRuntime(unpack_returned_tuples=True)
    g = rt.globals()
    g.HOST_READ = lambda p: read(p)
    g.CW, g.CH, g.MW, g.MH = CW, CH, MW, MH
    g.SCRIPT_EVENTS = rt.table_from([rt.table_from(e) for e in events])
    g.SCRIPT_LINES = rt.table_from(lines)
    M = rt.execute(read("tests/mock_cc.lua"))
    if fs:
        for k, v in fs.items():
            M.FS[k] = v
    return rt, M

def run(rt, src, name, *args):
    f = rt.eval("function(src, name, ...) local f, e = load(src, '=' .. name, 't', _G) "
                "if not f then return false, e end local ok, r = pcall(f, ...) return ok, r end")
    return f(src, name, *args)

def snapshot_fs(M):
    return {k: v for k, v in M.FS.items()}

def screen_text(M):
    out = []
    for i in range(1, len(M.terms) + 1):
        t = M.terms[i]
        out.extend(t.rows[y] for y in range(1, t.h + 1))
    return "\n".join(out)

ENTER, DOWN, F12, U = 28, 208, 88, 22

for (CW, CH, MW, MH) in [(51, 19, 0, 0), (51, 19, 57, 24), (51, 19, 29, 13), (51, 19, 164, 81), (26, 20, 0, 0)]:
    tag = "%dx%d mon %dx%d" % (CW, CH, MW, MH)

    # --- clean install
    rt, M = new_env(CW, CH, MW, MH,
                    [["key", ENTER]] + [["key", DOWN]] * 80 + [["key", ENTER]] * 3,
                    ["AGREE", "", "dino", "secret1", "secret1", "ERASE"],
                    {"/old.txt": "junk", "/programs": True, "/programs/x.lua": "print(1)"})
    ok, err = run(rt, read("install.lua"), "install.lua")
    check(ok and M.rebooted, "%s install: did not finish (%s) log=%s" % (tag, err, list(M.log.values())[-4:]))
    check(M.violations == 0, "%s install: %d chars drawn off-screen" % (tag, M.violations))
    fs = snapshot_fs(M)
    for f in listed:
        check(fs.get("/" + f) == read("src/" + f), "%s install: /%s not written correctly" % (tag, f))
    check("/old.txt" not in fs and "/programs" not in fs, tag + " install: old files not erased")
    check("/os/users.dat" in fs and "/os/files.dat" in fs, tag + " install: users.dat/files.dat missing")
    check(M.label == "warden-7", tag + " install: computer label not set")
    check("secret1" not in fs["/os/users.dat"], tag + " install: plain password stored")

    # --- boot -> login -> open every app -> F12
    W, H = (CW, CH)
    if MW and MW // 1 >= 30 and MH >= 12:
        W, H = None, None   # monitor size decided by fit logic, find it from the kernel run below
    n_apps = len([f for f in listed if f.startswith("os/apps/")])
    ev = [["key", ENTER]] + [["char", c] for c in "secret1"] + [["key", ENTER]]
    # dock: entries start at row 2, step 3 or 2 -> click both candidates' rows is wrong, so compute per size
    def dock_clicks(H):
        step = 3 if n_apps * 3 <= H - 2 else 2
        clicks = []
        for i in range(n_apps):
            y = 2 + i * step
            if y + 1 < H:
                clicks.append(["mouse_click", 1, 3, y])
        return clicks
    # the kernel draws on the computer screen when mirroring, so its size bounds the desktop
    rt2, M2 = new_env(CW, CH, MW, MH, [], [], fs)
    probe = rt2.eval("""function()
      local mon = peripheral.find('monitor')
      local tw, th = term.getSize()
      if mon then
        for _, s in ipairs({0.5,1,1.5,2,2.5,3,3.5,4,4.5,5}) do
          mon.setTextScale(s) local a, b = mon.getSize()
          if a <= tw and b <= th and a >= 30 and b >= 12 then return a, b end
        end
        mon.setTextScale(0.5) local a, b = mon.getSize()
        a, b = math.min(a, tw), math.min(b, th)
        if a >= 30 and b >= 12 then return a, b end
      end
      return tw, th end""")
    W, H = probe()
    clicks = dock_clicks(H)
    check(len(clicks) == n_apps, "%s kernel: only %d of %d apps fit in the dock" % (tag, len(clicks), n_apps))
    # open each app, also tap into it, scroll it, then hit the WardenOS menu and close it
    ev += [c for click in clicks for c in (click, ["mouse_click", 1, 20, 8], ["mouse_scroll", 1, 20, 8])]
    ev += [["timer", 1], ["mouse_click", 1, 2, 1], ["mouse_click", 1, 40, H], ["key", F12]]
    rt3, M3 = new_env(CW, CH, MW, MH, ev, [], fs)
    ok, err = run(rt3, fs["/startup.lua"], "startup.lua")
    text = screen_text(M3)
    log = "\n".join(M3.log.values())
    check(ok, "%s boot: %s" % (tag, err))
    check("Kernel error" not in log and "Boot menu error" not in log, "%s boot: kernel crashed: %s" % (tag, log[-400:]))
    check("stopped" in log, "%s boot: kernel did not reach a clean exit (log: %s)" % (tag, log[-300:]))
    check("crashed" not in text, "%s boot: an app crashed:\n%s" % (tag, text))
    check(M3.violations == 0, "%s boot: %d chars drawn off-screen" % (tag, M3.violations))
    for name in ["shell.lua", "lua.lua", "edit.lua"]:
        check(("[/rom/programs/%s]" % name) in log, "%s boot: %s app did not start" % (tag, name))

    # --- wrong password is rejected, the right one still works afterwards
    ev = [["key", ENTER]] + [["char", c] for c in "nope"] + [["key", ENTER]]
    ev += [["timer", i] for i in range(1, 40)]
    ev += [["char", c] for c in "secret1"] + [["key", ENTER], ["key", F12]]
    rt4, M4 = new_env(CW, CH, MW, MH, ev, [], fs)
    ok, err = run(rt4, fs["/startup.lua"], "startup.lua")
    log = "\n".join(M4.log.values())
    check(any("wrong username or password" in w for w in M4.written.values()), tag + " login: wrong password not rejected")
    check("stopped" in log and "Kernel error" not in log, tag + " login: correct password after a wrong one failed: " + log[-200:])

    # --- update: keeps accounts, removes stale files listed by the old version
    fs_old = dict(fs)
    fs_old["/os/apps/old.lua"] = "return nil"
    fs_old["/os/files.dat"] = fs["/os/files.dat"].replace('"/startup.lua"', '"/startup.lua", "/os/apps/old.lua"')
    fs_old["/os/kernel.lua"] = "-- old kernel"
    fs_old["/home.txt"] = "my notes"
    rt5, M5 = new_env(CW, CH, MW, MH, [["key", ENTER], ["key", ENTER]], [], fs_old)
    ok, err = run(rt5, read("install.lua"), "install.lua", "update")
    fs2 = snapshot_fs(M5)
    check(M5.rebooted, "%s update: did not finish (%s)" % (tag, err))
    check(fs2.get("/os/users.dat") == fs["/os/users.dat"], tag + " update: users.dat changed")
    check(fs2.get("/home.txt") == "my notes", tag + " update: user file lost")
    check("/os/apps/old.lua" not in fs2, tag + " update: stale file not removed")
    check(fs2.get("/os/kernel.lua") == read("src/os/kernel.lua"), tag + " update: kernel not updated")
    check(M5.violations == 0, "%s update: %d chars drawn off-screen" % (tag, M5.violations))
    print("dry run %-24s ok" % tag if not [f for f in fail if f.startswith(tag)] else "dry run %-24s FAILED" % tag)

# --- download failure must not touch anything
read_real = read
def read(p):
    return None if p == "src/os/kernel.lua" else read_real(p)
rt6, M6 = new_env(51, 19, 0, 0, [["key", ENTER]], [], {"/keep.txt": "x"})
ok, err = run(rt6, read_real("install.lua"), "install.lua")
check(snapshot_fs(M6).get("/keep.txt") == "x" and "/os" not in snapshot_fs(M6), "failed download changed files")
check(any("Nothing was changed" in l for l in M6.log.values()), "failed download: no message")
read = read_real
print("download failure: handled")

print()
if fail:
    print("%d problem(s)" % len(fail))
    sys.exit(1)
print("all checks passed")
