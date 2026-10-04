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

    # --- boot -> login -> open every app from the app view -> Settings -> F12, in every display mode
    app_ids = [f[len("os/apps/"):-4] for f in listed if f.startswith("os/apps/")]
    app_order = {i: int(re.search(r"order = (\d+)", read("src/os/apps/%s.lua" % i)).group(1)) for i in app_ids}
    app_ids.sort(key=lambda i: (app_order[i], i))
    login_ev = [["key", ENTER]] + [["char", c] for c in "secret1"] + [["key", ENTER]]

    def layout(display, scale):
        if MW and display != "computer":
            for sc in (scale, 0.5):
                a, b = int(MW // (sc * 2)), int(MH // (sc * 2))
                if display == "mirror":
                    a, b = min(a, CW), min(b, CH)
                if a >= 30 and b >= 12:
                    return a, b, "mirror" if display == "mirror" else "monitor"
        return CW, CH, "computer"

    def tiles(W, H):
        cols = max(1, (W - 8) // 12)
        th = 3 if cols * ((H - 2) // 4) >= len(app_ids) else 1
        out = []
        for i, a in enumerate(app_ids):
            c, r = i % cols, i // cols
            y = 4 + r * (th + 1)
            if y + th - 1 <= H:
                out.append((a, 8 + c * 12, y))
        return out

    for display, scale in [("auto", 0.5), ("mirror", 0.5), ("monitor", 1), ("computer", 0.5)]:
        mtag = "%s [%s %sx]" % (tag, display, scale)
        W, H, mode = layout(display, scale)
        tap = (lambda x, y: ["monitor_touch", "right", x, y]) if mode == "monitor" else (lambda x, y: ["mouse_click", 1, x, y])
        fsd = dict(fs)
        fsd["/os/settings.lua"] = '{ display = "%s", scale = %s }' % (display, scale)
        ts = tiles(W, H)
        check(len(ts) == len(app_ids), "%s: app view shows %d of %d apps" % (mtag, len(ts), len(app_ids)))
        ev = list(login_ev)
        for (_, x, y) in ts:                     # dock "Apps" -> tap the tile -> tap + scroll inside
            ev += [tap(3, 2), tap(x + 1, y), tap(20, 8), ["mouse_scroll", 1, 20, 8]]
        ev += [["timer", 1], tap(2, 1), tap(40, H)]          # open + close the WARDENOS menu
        sw, sh = min(44, W - 6), min(17, H - 1)
        settings_flow = display == "auto" and sw >= 36 and sh >= 14
        if settings_flow:
            n = len(app_ids)                    # windows already open -> where the new one lands
            sx = max(7, min(8 + (n % 5) * 3, W - sw + 1))
            sy = max(2, min(3 + (n % 5) * 2, H - sh + 1))
            row = lambda r: sy + r              # content row r is screen row sy + r
            ev += [["os_launch", "settings"],
                   tap(sx + 1, row(10)),                        # System: Check for updates
                   tap(sx + 9, row(1)), tap(sx + 2, row(6)),    # Display: Mirror
                   tap(sx + 18, row(1)), tap(sx + 2, row(5)),   # Theme: Light
                   tap(sx + 25, row(1)), tap(sx + 2, row(4)),   # Dock: toggle first app
                   tap(sx + 31, row(1)), tap(sx + 2, row(5))]   # Boot: CraftOS
        ev += [["key", F12]]
        rt3, M3 = new_env(CW, CH, MW, MH, ev, [], fsd)
        ok, err = run(rt3, fsd["/startup.lua"], "startup.lua")
        text = screen_text(M3)
        log = "\n".join(M3.log.values())
        check(ok, "%s boot: %s" % (mtag, err))
        check("Kernel error" not in log and "Boot menu error" not in log, "%s boot: kernel crashed: %s" % (mtag, log[-400:]))
        check("stopped" in log, "%s boot: kernel did not reach a clean exit (log: %s)" % (mtag, log[-300:]))
        check("crashed" not in text, "%s boot: an app crashed:\n%s" % (mtag, text))
        check(M3.violations == 0, "%s boot: %d chars drawn off-screen %s" % (mtag, M3.violations,
              [l for l in M3.log.values() if "OFFSCREEN" in l][:3]))
        for name in ["shell.lua", "lua.lua", "edit.lua"]:
            check(("[/rom/programs/%s]" % name) in log, "%s boot: %s app did not start" % (mtag, name))
        if settings_flow:
            fs3 = snapshot_fs(M3)
            written = "".join(M3.written.values()) + text
            st = rt3.eval("function(s) return textutils.unserialize(s) end")(fs3.get("/os/settings.lua", "{}"))
            bt = rt3.eval("function(s) return textutils.unserialize(s) end")(fs3.get("/os/boot.cfg", "{}"))
            check("Up to date (%s)" % manifest.version in text, mtag + " settings: update check did not report up to date")
            check(st and st.display == "mirror", mtag + " settings: display mode not saved")
            check(st and st.theme == "light", mtag + " settings: theme not saved")
            check(st and len(st.dock) == 3, mtag + " settings: dock pin not toggled")
            check(bt and bt.default == "craftos", mtag + " settings: boot default not saved")

    # --- Settings "Update now": kernel exits, installer updates without asking, reboots
    rt7, M7 = new_env(CW, CH, MW, MH, login_ev + [["os_update"]], [], dict(fs))
    ok, err = run(rt7, fs["/startup.lua"], "startup.lua")
    users7 = snapshot_fs(M7).get("/os/users.dat", "")
    check(M7.rebooted and '"dino"' in users7 and '"hash"' in users7 and "Downloaded" in "\n".join(M7.log.values()),
          "%s update from settings failed: %s" % (tag, "\n".join(M7.log.values())[-1500:]))

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
