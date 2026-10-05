#!/usr/bin/env python3
"""App Store: catalog, install/remove/update, apt, the Store app and every package in store/.
   python3 tests/test_store.py   (needs: pip install lupa)

The mock's http.get serves the repository (HOST_READ), so the real store/index.lua and store/packages/* are used.
Scripted events ["host", ...] are built when they are delivered: ["host", "tap", "Games"] taps that text where it is
on screen right now, ["host", "timer"] fires the newest timer, ["host", "snap", "name"] saves the screen."""
import os, re, sys
import lupa.lua52 as lua

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
fail = []

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
    return cond

# the files the installer would have listed in /os/files.dat (the manifest + the store's own files)
_m = re.findall(r'"(os/[^"]+|startup\.lua)"', read("manifest.lua").split("drone =")[0])
OS_FILES = sorted(set(["/" + p for p in _m] + ["/os/lib/store.lua", "/os/apps/store.lua", "/os/bin/apt.lua"]))

PRELUDE = r"""
WardenOS = { theme = { bg = colors.black, panel = colors.gray, text = colors.white, dim = colors.lightGray,
  accent = colors.cyan, good = colors.green, bad = colors.red, warn = colors.yellow },
  repo = "LinuxDino/WardenOS", branch = "main", version = "1.6.1" }
keys.space, keys.delete, keys.home, keys["end"] = 57, 211, 199, 207
keys.leftCtrl, keys.rightCtrl, keys.s, keys.a, keys.w = 29, 157, 31, 30, 17
-- events the code queued (os_toast, os_apps_changed, os_launch)
QUEUED = {}
local q = os.queueEvent
os.queueEvent = function(...) QUEUED[#QUEUED + 1] = table.pack(...) return q(...) end
-- windows: drawing outside a window counts as off-screen too
local create = window.create
window.create = function(parent, x, y, w, h, vis)
  local t = create(parent, x, y, w, h, vis)
  local write = t.write
  t.write = function(s)
    s = tostring(s)
    local cx, cy = t.getCursorPos()
    local W, H = t.getSize()
    for i = 1, #s do
      local px = cx + i - 1
      if s:sub(i, i) ~= " " and (px < 1 or px > W or cy < 1 or cy > H) then
        MOCK.violations = MOCK.violations + 1
        MOCK.log[#MOCK.log + 1] = "OFFSCREEN window " .. px .. "," .. cy .. " " .. s
        break
      end
    end
    return write(s)
  end
  return t
end
"""

class Env:
    def __init__(self, w=51, h=19, events=(), lines=(), serve=None, offline=False, files=None, prelude=""):
        rt = lua.LuaRuntime(unpack_returned_tuples=True, encoding="latin-1")
        self.rt, self.serve, self.snaps, self.missing = rt, dict(serve or {}), {}, []
        g = rt.globals()
        g.HOST_READ = self.host_read
        g.HOST_EVENT = self.host_event
        g.CW, g.CH, g.MW, g.MH = w, h, 0, 0
        g.SCRIPT_EVENTS = rt.table_from([rt.table_from(e) for e in events])
        g.SCRIPT_LINES = rt.table_from(list(lines))
        self.M = rt.execute(read("tests/mock_cc.lua"))
        g.MOCK = self.M
        rt.execute(PRELUDE)
        if offline:
            rt.execute('http.get = function() return nil, "Could not connect" end')
        FS = self.M.FS
        for d in ("/os", "/os/apps", "/os/bin", "/os/lib"):
            FS[d] = True
        for f in ("os/lib/store.lua", "os/apps/store.lua", "os/bin/apt.lua", "os/config.lua", "os/lib/bigfont.lua",
                  "os/apps/settings.lua", "os/kernel.lua", "os/lib/art.lua"):
            FS["/" + f] = read("src/" + f)
        FS["/os/files.dat"] = 'return nil' if False else self.ser({"version": "1.6.1", "branch": "main", "files": OS_FILES})
        for k, v in (files or {}).items():
            FS[k] = v
        if prelude:
            rt.execute(prelude)

    def ser(self, d):
        return self.rt.eval("function(t) return textutils.serialize(t) end")(self.table(d))

    def table(self, d):
        if isinstance(d, dict):
            return self.rt.table_from({k: self.table(v) for k, v in d.items()})
        if isinstance(d, (list, tuple)):
            return self.rt.table_from([self.table(v) for v in d])
        return d

    def host_read(self, p):
        if p in self.serve:
            return self.serve[p]
        return read(p)

    def screen(self):
        t = self.M.native
        return "\n".join(t.rows[y] for y in range(1, t.h + 1))

    def host_event(self, kind, *a):
        if kind == "timer":
            return self.rt.table_from(["timer", self.M.lastTimer])
        if kind == "snap":
            self.snaps[a[0]] = self.screen()
            return None
        if kind == "tap":                       # tap the first of the texts that is on screen (last match row wins)
            t = self.M.native
            for text in a:
                for y in range(1, t.h + 1):
                    x = t.rows[y].find(text)
                    if x >= 0:
                        return self.rt.table_from(["mouse_click", 1, x + 1 + min(1, len(text) - 1), y])
            self.missing.append(a)
            return None
        if kind == "tapat":                     # tap a column of the row where a text is
            text, dx = a
            t = self.M.native
            for y in range(1, t.h + 1):
                x = t.rows[y].find(text)
                if x >= 0:
                    return self.rt.table_from(["mouse_click", 1, x + 1 + dx, y])
            self.missing.append(a)
            return None
        raise ValueError(kind)

    def lua(self, code, *args):
        """run Lua code (a chunk; ... = args) protected: ok, result"""
        f = self.rt.eval("function(code, ...) local fn, e = load(code, '=test', 't', _G) if not fn then return false, e end "
                         "return pcall(fn, ...) end")
        return f(code, *args)

    def run_file(self, path, *args):
        r = self.lua("local p = ... local src = assert(fs.open(p, 'r')).readAll() "
                        "local fn = assert(load(src, '=' .. p, 't', _G)) fn(select(2, ...)) return nil", path, *args)
        return r if isinstance(r, tuple) else (r, None)

    def queued(self, name):
        Q = self.rt.globals().QUEUED
        return [[Q[i][j] for j in range(2, Q[i].n + 1)] for i in range(1, len(Q) + 1) if Q[i][1] == name]

    def db(self):
        s = self.M.FS["/os/store/installed"]
        d = self.rt.eval("function(s) return textutils.unserialize(s or '{}') end")(s)
        return d

    def offscreen(self):
        return [l for l in self.M.log.values() if "OFFSCREEN" in str(l)][:3]

INDEX = read("store/index.lua")
catalog_env = Env()
ok, cat = catalog_env.lua("return dofile(...)", "/os/lib/store.lua")
PKGS = []
ok, n = catalog_env.lua("local s = dofile('/os/lib/store.lua') local l = s.catalog(true) return #l")
idx = catalog_env.rt.eval("function() return (dofile('/os/lib/store.lua').catalog()) end")()
for i in range(1, len(idx) + 1):
    p = idx[i]
    PKGS.append({"id": p.id, "kind": p.kind, "version": p.version, "size": p.size, "name": p.name,
                 "files": [(p.files[j]["from"], p.files[j].to) for j in range(1, len(p.files) + 1)],
                 "art": p.art is not None})

# ---------------------------------------------------------------- catalog
raw_count = len(re.findall(r'^\s+id = "', INDEX, re.M))
check(len(PKGS) == raw_count and raw_count >= 12, "catalog: %d of %d packages valid" % (len(PKGS), raw_count))
for p in PKGS:
    total = 0
    for frm, to in p["files"]:
        body = read(frm)
        check(body is not None, "%s: file %s missing in the repo" % (p["id"], frm))
        total += len(body or "")
    check(p["size"] == total, "%s: size %d in index.lua, files are %d bytes" % (p["id"], p["size"], total))
    check(p["art"], "%s: no valid art icon" % p["id"])
check(catalog_env.M.FS["/os/store/index"] == INDEX, "catalog: not cached in /os/store/index")

# offline: the saved catalog is used
e = Env(offline=True, files={"/os/store/index": INDEX, "/os/store": True})
ok, n, msg, off = e.lua("local l, m, o = dofile('/os/lib/store.lua').catalog(true) return #l, m, o")
check(ok and n == len(PKGS) and off is True and "offline" in str(msg), "offline with cache: %s %s %s" % (n, msg, off))
# offline, nothing saved: empty list + message, no crash
e = Env(offline=True)
ok, n, msg, off = e.lua("local l, m, o = dofile('/os/lib/store.lua').catalog(true) return #l, m, o")
check(ok and n == 0 and off is True and "can't load" in str(msg), "offline without cache: %s %s" % (n, msg))
# the saved catalog is used without a request when not refreshing
e = Env(files={"/os/store/index": INDEX, "/os/store": True})
ok, n = e.lua("return #dofile('/os/lib/store.lua').catalog()")
check(ok and n == len(PKGS) and not any("GET" in str(l) for l in e.M.log.values()), "catalog(false) made a request")
# a broken catalog from GitHub does not replace the saved one
e = Env(serve={"store/index.lua": "return { packages = "}, files={"/os/store/index": INDEX, "/os/store": True})
ok, n, msg = e.lua("local l, m = dofile('/os/lib/store.lua').catalog(true) return #l, m")
check(ok and n == len(PKGS) and e.M.FS["/os/store/index"] == INDEX, "broken remote catalog replaced the cache: %s" % msg)
print("catalog: %d packages" % len(PKGS))

# ---------------------------------------------------------------- install / remove / update
LIB = "local S = dofile('/os/lib/store.lua') "
e = Env()
ok, r, m = e.lua(LIB + "return S.install('snake')")
FS = e.M.FS
check(ok and r is True and "Installed Snake" in str(m), "install snake: %s %s" % (r, m))
check(FS["/os/apps/snake.lua"] == read("store/packages/snake/snake.lua"), "install: /os/apps/snake.lua not written exactly")
check(FS["/os/bin/snake.lua"] == read("store/packages/snake/cmd.lua"), "install: /os/bin/snake.lua not written exactly")
db = e.db()
check(db and db.snake and db.snake.version == "1.0.0" and len(db.snake.files) == 2, "install: not recorded in /os/store/installed")
check(e.queued("os_apps_changed") != [], "install: os_apps_changed not queued")
check(["Installed Snake 1.0.0"] in e.queued("os_toast"), "install: os_toast not queued: %s" % e.queued("os_toast"))
ok, r, m = e.lua(LIB + "return S.install('snake')")
check(r is False and "already installed" in m, "install twice: %s" % m)
# a command: no os_apps_changed
e2 = Env()
ok, r, m = e2.lua(LIB + "return S.install('weather')")
check(r is True and e2.M.FS["/os/bin/weather.lua"] == read("store/packages/weather/weather.lua"), "install weather: %s" % m)
check(e2.queued("os_apps_changed") == [] and e2.queued("os_toast") != [], "command install: wrong events")
ok, r, m = e2.lua(LIB + "return S.install('nope')")
check(r is False and "Unknown package" in m and e2.queued("os_toast")[-1] == [m], "unknown package: %s" % m)

# a broken file: nothing at all is written
broken = Env(serve={"store/packages/snake/cmd.lua": "local x = = 1"})
before = dict(broken.M.FS.items())
ok, r, m = broken.lua(LIB + "return S.install('snake')")
after = {k: v for k, v in broken.M.FS.items() if not k.startswith("/os/store")}
check(r is False and "broken" in m, "syntax error not reported: %s" % m)
check(after == {k: v for k, v in before.items() if not k.startswith("/os/store")}, "broken package wrote files: %s"
      % sorted(set(after) - set(before)))
check("/os/apps/snake.lua" not in broken.M.FS and "/os/store/installed" not in broken.M.FS, "broken package installed")
check(broken.queued("os_toast") != [] and broken.queued("os_apps_changed") == [], "broken: events wrong")
# a download that fails halfway: nothing written
e3 = Env(serve={"store/packages/snake/cmd.lua": None})
e3.serve.pop("store/packages/snake/cmd.lua")
e3.host_read = lambda p: None if p == "store/packages/snake/cmd.lua" else read(p)
e3.rt.globals().HOST_READ = e3.host_read
ok, r, m = e3.lua(LIB + "return S.install('snake')")
check(r is False and "download failed" in m and "/os/apps/snake.lua" not in e3.M.FS, "failed download: %s" % m)

# packages that target OS files or other places are refused
def evil(files, extra=""):
    lst = ", ".join('{ from = "store/packages/x/a.lua", to = "%s" }' % t for t in files)
    return ('return { packages = { { id = "evil", name = "Evil", kind = "app", version = "1.0", files = { %s }%s } } }'
            % (lst, extra))
for targets, why in [(["/os/apps/settings.lua"], "WardenOS file"), (["/os/kernel.lua"], "wants to write"),
                     (["/startup.lua"], "wants to write"), (["/os/lib/evil.lua"], "wants to write"),
                     (["/os/data/other/x.lua"], "wants to write"), (["/os/apps/store.lua"], "WardenOS file"),
                     (["/os/bin/apt.lua"], "WardenOS file"), (["/os/bin/mine.lua"], "already exists"),
                     (["/os/apps/evil.lua", "/os/apps/evil.lua"], "twice")]:
    e = Env(serve={"store/index.lua": evil(targets), "store/packages/x/a.lua": "return {}"},
            files={"/os/bin/mine.lua": "print('my own script')"})
    ok, r, m = e.lua(LIB + "S.catalog(true) return S.install('evil')")
    check(r is False and why in str(m), "evil %s: %s" % (targets, m))
    check(e.M.FS["/os/apps/settings.lua"] == read("src/os/apps/settings.lua") and e.M.FS["/os/bin/mine.lua"] == "print('my own script')"
          and "/os/lib/evil.lua" not in e.M.FS and "/os/apps/evil.lua" not in e.M.FS, "evil %s: something was written" % targets)
# paths with .. never make it into the catalog
e = Env(serve={"store/index.lua": evil(["/os/apps/../kernel.lua"]), "store/packages/x/a.lua": "return {}"})
ok, n = e.lua(LIB + "return #S.catalog(true)")
check(n == 0, "a path with .. was accepted")
# too old WardenOS
e = Env(serve={"store/index.lua": evil(["/os/apps/evil.lua"], ', requires = "9.0"'), "store/packages/x/a.lua": "return {}"})
ok, r, m = e.lua(LIB + "S.catalog(true) return S.install('evil')")
check(r is False and "needs WardenOS 9.0" in m, "requires not checked: %s" % m)
# protected even without /os/files.dat (the manifest from GitHub)
e = Env(serve={"store/index.lua": evil(["/os/apps/todo.lua"]), "store/packages/x/a.lua": "return {}"})
e.M.FS["/os/files.dat"] = None
ok, r, m = e.lua(LIB + "S.catalog(true) return S.install('evil')")
check(r is False and "WardenOS file" in str(m), "manifest not used for protection: %s" % m)

# remove: exactly the files it installed + the empty dirs it created; data the app made stays
DEMO = ('return { packages = { { id = "demo", name = "Demo", kind = "app", version = "1.0", files = {'
        '{ from = "store/packages/demo/a.lua", to = "/os/apps/demo.lua" },'
        '{ from = "store/packages/demo/b.txt", to = "/os/data/demo/sub/readme.txt" } } } } }')
DEMO_SERVE = {"store/index.lua": DEMO, "store/packages/demo/a.lua": "return { name = 'Demo', main = function() end }",
              "store/packages/demo/b.txt": "hello"}
e = Env(serve=DEMO_SERVE)
ok, r, m = e.lua(LIB + "S.catalog(true) return S.install('demo')")
check(r is True and e.M.FS["/os/data/demo/sub/readme.txt"] == "hello", "demo install: %s" % m)
ok, r, m = e.lua(LIB + "return S.remove('demo')")
check(r is True and "/os/apps/demo.lua" not in e.M.FS and "/os/data/demo/sub/readme.txt" not in e.M.FS, "remove: files left")
check("/os/data/demo" not in e.M.FS and "/os/data" not in e.M.FS, "remove: empty dirs it created were kept: %s"
      % [k for k in e.M.FS.keys() if k.startswith("/os/data")])
check(e.M.FS["/os/apps/settings.lua"] and e.M.FS["/os/apps"] is True and e.M.FS["/os/bin"] is True, "remove: deleted too much")
check(e.queued("os_apps_changed") != [] and ["Removed Demo"] in e.queued("os_toast"), "remove: events missing")
e = Env(serve=DEMO_SERVE)
e.lua(LIB + "S.catalog(true) S.install('demo')")
e.M.FS["/os/data/demo/best"] = "42"                      # written by the app itself
ok, r, m = e.lua(LIB + "return S.remove('demo')")
check(e.M.FS["/os/data/demo/best"] == "42" and "/os/data/demo/sub" not in e.M.FS, "remove: user data lost or sub dir kept")
e.lua(LIB + "S.install('demo')")
ok, r, m = e.lua(LIB + "return S.remove('demo', { purge = true })")
check("/os/data/demo" not in e.M.FS, "purge: data kept")
ok, r, m = e.lua(LIB + "return S.remove('demo')")
check(r is False and "not installed" in m, "remove twice: %s" % m)
# an OS update took over a path the package had: remove leaves the OS file alone
e = Env(serve=DEMO_SERVE)
e.lua(LIB + "S.catalog(true) S.install('demo')")
e.M.FS["/os/files.dat"] = e.ser({"files": OS_FILES + ["/os/apps/demo.lua"]})
e.M.FS["/os/apps/demo.lua"] = "-- now part of WardenOS"
ok, r, m = e.lua(LIB + "return S.remove('demo')")
check(r is True and e.M.FS["/os/apps/demo.lua"] == "-- now part of WardenOS", "remove deleted a file that is now an OS file")

# upgrades + update (a file that the new version drops is deleted)
e = Env()
e.lua(LIB + "S.install('snake') S.install('2048')")
newer = INDEX.replace('id = "snake", name = "Snake", kind = "app", category = "game", version = "1.0.0"',
                      'id = "snake", name = "Snake", kind = "app", category = "game", version = "1.1.0"')
newer = newer.replace('        { from = "store/packages/snake/cmd.lua", to = "/os/bin/snake.lua" },\n', '', 1)
check(newer != INDEX, "test setup: could not bump snake")
e.serve["store/index.lua"] = newer
ok, ups = e.lua(LIB + "S.catalog(true) local u = S.upgrades() return textutils.serialize(u)")
check('"snake"' in ups and '"1.1.0"' in ups and '"2048"' not in ups, "upgrades(): %s" % ups)
ok, st = e.lua(LIB + "S.catalog() return S.status('snake') .. ',' .. S.status('2048') .. ',' .. tostring(S.status('mines'))")
check(st == "update,installed,nil", "status(): %s" % st)
ok, r, m = e.lua(LIB + "return S.update('snake')")
check(r is True and "Updated Snake to 1.1.0" in m and e.db().snake.version == "1.1.0", "update: %s" % m)
check("/os/bin/snake.lua" not in e.M.FS and "/os/apps/snake.lua" in e.M.FS, "update: dropped file not removed")
ok, r, m = e.lua(LIB + "return S.update('snake')")
check(r is True and "up to date" in m, "update when current: %s" % m)
ok, ups = e.lua(LIB + "return #S.upgrades()")
check(ups == 0, "upgrades after update: %s" % ups)
print("install/remove/update: ok" if not fail else "install/remove/update: problems")

# ---------------------------------------------------------------- apt
def apt(*args, env=None, w=100, h=200, **kw):
    e = env or Env(w=w, h=h, **kw)
    ok, err = e.run_file("/os/bin/apt.lua", *args)
    check(ok, "apt %s: crashed: %s" % (" ".join(args), err))
    check(e.M.violations == 0, "apt %s: drew off-screen %s" % (" ".join(args), e.offscreen()))
    out = e.screen()
    e.M.native.clear()
    e.M.native.setCursorPos(1, 1)
    return e, out

e, out = apt("update")
check("Hit:1 https://raw.githubusercontent.com/LinuxDino/WardenOS main InRelease" in out and "Reading package lists... Done" in out
      and "All packages are up to date." in out, "apt update:\n" + out)
e, out = apt("install", "snake", env=e)
check("The following NEW packages will be installed:" in out and "  snake" in out
      and "0 upgraded, 1 newly installed, 0 to remove and 0 not upgraded." in out and "Setting up snake (1.0.0) ..." in out,
      "apt install:\n" + out)
check(e.M.FS["/os/apps/snake.lua"] == read("store/packages/snake/snake.lua"), "apt install: file not written")
e, out = apt("install", "snake", env=e)
check("snake is already the newest version (1.0.0)." in out, "apt install again:\n" + out)
e, out = apt("sudo", "install", "timer", "calc", env=e)
check("2 newly installed" in out and "run it with: timer" in out and "/os/bin/calc.lua" in e.M.FS, "apt sudo install:\n" + out)
e, out = apt("install", "nope", "mines", env=e)
check("E: Unable to locate package nope" in out and "/os/apps/mines.lua" not in e.M.FS, "apt install unknown:\n" + out)
e, out = apt("list", env=e)
check("Listing... Done" in out and "snake/stable 1.0.0 app [installed]" in out and "mines/stable 1.0.0 app" in out, "apt list:\n" + out)
e, out = apt("list", "--installed", env=e)
check("snake/stable" in out and "mines/stable" not in out, "apt list --installed:\n" + out)
e, out = apt("search", "mine", env=e)
check("Full Text Search... Done" in out and "mines/stable 1.0.0 app" in out and "snake/stable" not in out, "apt search:\n" + out)
e, out = apt("show", "snake", env=e)
check("Package: snake" in out and "Version: 1.0.0" in out and "/os/apps/snake.lua" in out and "Description:" in out, "apt show:\n" + out)
e, out = apt("show", "nope", env=e)
check("Unable to locate package nope" in out, "apt show unknown:\n" + out)
e.serve["store/index.lua"] = newer
e, out = apt("update", env=e)
check("1 package can be upgraded. Run 'apt list --upgradable' to see it." in out, "apt update with an upgrade:\n" + out)
e, out = apt("list", "--upgradable", env=e)
check("snake/stable 1.1.0 app [upgradable from: 1.0.0]" in out and "timer" not in out, "apt list --upgradable:\n" + out)
e, out = apt("upgrade", env=e)
check("The following packages will be upgraded:" in out and "1 upgraded, 0 newly installed, 0 to remove and 0 not upgraded." in out
      and "Setting up snake (1.1.0) ..." in out and e.db().snake.version == "1.1.0", "apt upgrade:\n" + out)
e, out = apt("upgrade", env=e)
check("0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded." in out, "apt upgrade (nothing):\n" + out)
e, out = apt("remove", "snake", env=e)
check("The following packages will be REMOVED:" in out and "Removing snake (1.1.0) ..." in out
      and "0 upgraded, 0 newly installed, 1 to remove" in out and "/os/apps/snake.lua" not in e.M.FS, "apt remove:\n" + out)
e, out = apt("remove", "mines", env=e)
check("Package 'mines' is not installed, so not removed" in out, "apt remove not installed:\n" + out)
e, out = apt("remove", "nope", env=e)
check("E: Unable to locate package nope" in out, "apt remove unknown:\n" + out)
e, out = apt("moo")
check("(oo)" in out and "Have you mooed today?" in out, "apt moo:\n" + out)
e, out = apt("moo", "moo", "moo")
check("Warden" in out, "apt moo moo moo:\n" + out)
e, out = apt("frobnicate")
check("E: Invalid operation frobnicate" in out, "apt unknown command:\n" + out)
e, out = apt()
check("Super Cow Powers" in out and "install" in out, "apt help:\n" + out)
e, out = apt("update", offline=True)
check("Failed to fetch" in out and "E:" in out, "apt update offline:\n" + out)
for args in [("help",), ("moo",), ("list",), ("show", "notes"), ("search", "a"), ("install", "notes")]:
    apt(*args, w=26, h=20)                     # narrow terminal: nothing off-screen (checked in apt())
print("apt: ok" if not [f for f in fail if f.startswith("apt")] else "apt: problems")

# ---------------------------------------------------------------- the Store app
def store_app(events, w=45, h=17, **kw):
    e = Env(w=w, h=h, events=events, **kw)
    ok, err = e.lua("dofile('/os/apps/store.lua').main()")
    check(err == "SCRIPT_END", "store %dx%d: stopped early: %s" % (w, h, err))
    check(e.M.violations == 0, "store %dx%d: drew off-screen %s" % (w, h, e.offscreen()))
    check(not e.missing, "store %dx%d: not on screen: %s" % (w, h, e.missing))
    return e

for (w, h) in [(45, 17), (45, 18), (158, 79), (76, 39), (20, 17), (30, 12)]:
    tag = "%dx%d" % (w, h)
    tabs = ["Games", "Tools"] if w >= 45 else []
    ev = [["host", "snap", "start"]]
    if w >= 45:
        ev += [["host", "tap", " Games "], ["host", "snap", "games"], ["host", "tap", " Tools "], ["host", "snap", "tools"],
               ["host", "tap", " Cmds ", " Commands "], ["host", "snap", "cmds"]]
    else:
        ev += [["key", 205], ["host", "snap", "games"], ["key", 205], ["host", "snap", "tools"], ["key", 205], ["host", "snap", "cmds"]]
    ev += [["char", "p"], ["char", "a"], ["char", "i"], ["host", "snap", "search"],
           ["key", 14], ["key", 14], ["key", 14], ["key", 203], ["key", 203], ["key", 203], ["host", "snap", "back"]]
    # Featured -> Snake detail -> Install -> back -> Installed tab
    ev += [["host", "tap", "Snake "], ["host", "snap", "detail"]] + [["mouse_scroll", 1, 3, 12]] * 30 + [
           ["host", "snap", "detail2"], ["host", "tap", " Install "], ["host", "snap", "installed"],
           ["host", "tap", " < "], ["host", "snap", "list2"]]
    if w >= 45:
        ev += [["host", "tap", " Mine ", " Installed "], ["host", "snap", "mine"]]
    ev += [["mouse_scroll", 1, 3, 5], ["mouse_scroll", -1, 3, 5]]
    e = store_app(ev, w, h)
    s = e.snaps
    check("Snake" in s.get("start", "") and "Warden" in s.get("start", "") and "Minesweeper" not in s.get("start", "x"),
          tag + " featured tab wrong:\n" + s.get("start", ""))
    check("Minesweeper" in s.get("games", "") and "Notes" not in s.get("games", "x"), tag + " games tab wrong:\n" + s.get("games", ""))
    check("Calculator" in s.get("tools", "") and "Snake" not in s.get("tools", "x"), tag + " tools tab wrong:\n" + s.get("tools", ""))
    check("weather" in s.get("cmds", "") and "Snake" not in s.get("cmds", "x"), tag + " commands tab wrong:\n" + s.get("cmds", ""))
    check("Paint" in s.get("search", "") and "Snake" not in s.get("search", "x") and "pai" in s.get("search", ""),
          tag + " search wrong:\n" + s.get("search", ""))
    check(" Install " in s.get("detail", "") and ("/os/apps/snake.lua" if w >= 30 else "/os/apps/snake.l") in s.get("detail2", "") and
          ("7.4 KB" in s.get("detail", "") or w < 30), tag + " detail wrong:\n" + s.get("detail", "") + s.get("detail2", ""))
    check(" Remove " in s.get("installed", "") and " Open " in s.get("installed", "") and "Installed Snake" in s.get("installed", ""),
          tag + " after install:\n" + s.get("installed", ""))
    check(e.M.FS["/os/apps/snake.lua"] == read("store/packages/snake/snake.lua"), tag + " store install: file not written")
    check(e.queued("os_apps_changed") != [] and e.queued("os_toast") != [], tag + " store install: events not queued")
    if w >= 25:
        check(" Open " in s.get("list2", ""), tag + " no Open badge after install:\n" + s.get("list2", ""))
    if w >= 45:
        check("Snake" in s.get("mine", "") and "Paint" not in s.get("mine", "x"), tag + " installed tab:\n" + s.get("mine", ""))
    if w >= 76:
        rows = [r for r in s.get("start", "").splitlines() if r.count(" Get ") >= 2]
        check(rows, tag + " maximized: no grid with several columns:\n" + s.get("start", ""))

# updates: badge, Updates tab, Update all, then Remove (asks first) and Open
inst = Env()
inst.lua(LIB + "S.install('snake') S.install('blocks')")
pre = {k: v for k, v in inst.M.FS.items() if k.startswith("/os/store") or k.startswith("/os/apps/snake") or
       k.startswith("/os/bin/snake") or "blocks" in k}
newer2 = newer.replace('id = "blocks", name = "Blocks", kind = "app", category = "game", version = "1.0.0"',
                       'id = "blocks", name = "Blocks", kind = "app", category = "game", version = "1.2.0"')
for (w, h) in [(45, 17), (158, 79)]:
    tag = "%dx%d" % (w, h)
    ev = [["host", "snap", "start"], ["host", "tap", " Updates "], ["host", "snap", "updates"],
          ["host", "tap", " Update all "], ["host", "snap", "updated"],
          ["host", "tap", " Mine ", " Installed "], ["host", "tap", "Blocks "], ["host", "snap", "detail"],
          ["host", "tap", " Remove "], ["host", "snap", "confirm"], ["host", "tap", " Remove? "], ["host", "snap", "removed"],
          ["host", "tap", " < "], ["host", "tap", " Open "]]
    e = store_app(ev, w, h, serve={"store/index.lua": newer2}, files=pre)
    s = e.snaps
    check("update 1.0.0 -> 1.1.0" in s.get("start", "") or "update 1.0.0 -> 1.2.0" in s.get("start", ""),
          tag + " no update line in the list:\n" + s.get("start", ""))
    check(" Update " in s.get("updates", "") and "Update all (2)" in s.get("updates", ""), tag + " updates tab:\n" + s.get("updates", ""))
    check("Updated 2 packages" in s.get("updated", "") and "No updates" in s.get("updated", ""), tag + " update all:\n" + s.get("updated", ""))
    db = e.db()
    check(db.snake.version == "1.1.0" and db.blocks is None, tag + " update all / remove: versions not updated")
    check("Remove again" in s.get("confirm", "") and " Remove? " in s.get("confirm", ""), tag + " remove did not ask:\n" + s.get("confirm", ""))
    check("/os/apps/blocks.lua" not in e.M.FS and "Removed Blocks" in s.get("removed", ""), tag + " remove from detail failed:\n"
          + s.get("removed", ""))
    check(["snake"] in e.queued("os_launch"), tag + " Open did not launch the app: %s" % e.queued("os_launch"))

# offline with nothing cached: a friendly message
e = store_app([["host", "snap", "x"]], offline=True)
check("Can't reach GitHub" in e.snaps.get("x", ""), "store offline message:\n" + e.snaps.get("x", ""))
print("store app: ok" if not [f for f in fail if " store" in f or f.startswith("store")] else "store app: problems")

# ---------------------------------------------------------------- every package
compile_ = catalog_env.rt.eval("function(src, name) local f, e = load(src, name, 't', {}) return f ~= nil, e end")
for p in PKGS:
    for frm, to in p["files"]:
        src = read(frm)
        ok, err = compile_(src, "=" + frm)
        check(ok, "%s: does not compile: %s" % (frm, err))
        check(all(ord(ch) < 128 for ch in src), frm + " has non-ASCII characters")
        lines = src.count("\n")
        check(lines < 420, "%s: %d lines (keep packages small)" % (frm, lines))

T = ["host", "timer"]
def click(x, y): return ["mouse_click", 1, x, y]
def chars(s): return [["char", ch] for ch in s]
UP, DOWN, LEFT, RIGHT, ENTER, BACK, TAB = 200, 208, 203, 205, 28, 14, 15
SCRIPTS = {
    "snake": [T, T, ["key", UP], T, ["char", "a"], T, click(3, 3), T, ["char", "p"], ["char", "p"], T] + [T] * 40 +
             [["key", ENTER], click(5, 5), T],
    "2048": [["key", LEFT], ["key", UP], ["key", RIGHT], ["key", DOWN], ["char", "w"], click(3, 5), click(2, 99), ["char", "n"]],
    "mines": [click(10, 8), ["char", "f"], click(3, 3), ["char", "f"], ["key", UP], ["key", ENTER], T, click(1, 1),
              ["char", "l"], click(10, 8), ["char", "l"], ["char", "l"]],
    "blocks": [T, ["key", LEFT], ["key", RIGHT], ["key", UP], ["key", DOWN], ["char", " "], T, ["char", "p"], ["char", "p"]] +
              [["char", " "]] * 30 + [T, click(5, 5)],
    "wardenrun": [T] * 30 + [["char", " "]] + [T] * 60 + [["key", ENTER], T, ["char", "p"], ["char", "p"], click(4, 4)],
    "calculator": chars("2+3*4") + [["key", ENTER], ["host", "snap", "calc"], ["host", "tap", " 7 "], ["host", "tap", " = "],
                  ["host", "snap", "seven"], ["key", BACK], click(1, 99)] + chars("sqrt(2") + [["key", ENTER]] +
                  [["key", BACK]] * 6 + chars("1/0") + [["key", ENTER], ["host", "snap", "err"]] + [["key", BACK]] * 3,
    "stopwatch": [["char", " "], T, ["char", "l"], T, ["char", " "], ["char", "t"], ["char", "+"], ["char", " "], T, T,
                  ["char", " "], ["char", "r"], ["host", "tap", " Stopwatch "], ["host", "tap", " Timer "],
                  ["host", "tap", " +10s "], click(3, 3)],
    "notes": [["char", "n"]] + chars("Shopping list") + [["key", ENTER]] + chars("- coal") + [["key", BACK], ["key", LEFT],
              ["key", UP], ["key", DOWN], ["key", ENTER], T, ["key", TAB], ["host", "snap", "notes"], ["key", UP], ["key", ENTER],
              ["key", TAB], ["host", "tap", " + new "], ["key", TAB], ["key", 211], ["key", 211]],
    "paint": [click(5, 5), click(6, 5), ["char", "f"], click(10, 10), ["char", "e"], click(5, 5), ["char", "p"],
              ["key", RIGHT], ["key", DOWN], ["mouse_scroll", 1, 4, 4], ["char", "s"], ["host", "snap", "paint"],
              ["char", "n"], ["char", "o"]],
}
QUIT = {"notes": [["key", TAB], ["char", "q"]]}
for p in PKGS:
    if p["kind"] != "app":
        continue
    pid = p["id"]
    app_file = [f for f in p["files"] if f[1].startswith("/os/apps/")][0]
    hdr = read(app_file[0])
    m = re.search(r"w = (\d+), h = (\d+)", hdr)
    aw, ah = int(m.group(1)), int(m.group(2))
    for (w, h, mode) in [(min(aw, 45), ah - 1, "window"), (20, 10, "small"), (158, 79, "maximized"), (51, 19, "terminal")]:
        tag = "%s %dx%d %s" % (pid, w, h, mode)
        ev = SCRIPTS.get(pid, []) + [["term_resize"]] + QUIT.get(pid, [["char", "q"]])
        e = Env(w=w, h=h, events=ev)
        for frm, to in p["files"]:
            e.M.FS[to] = read(frm)
        if mode == "terminal":
            cmd = [to for frm, to in p["files"] if to.startswith("/os/bin/")]
            if not cmd:
                continue
            ok, err = e.run_file(cmd[0])
        else:
            ok, err = e.lua("local app = dofile(...) assert(type(app.name) == 'string' and type(app.art) == 'table') app.main() return nil",
                            app_file[1])
        check(ok, "%s: did not quit cleanly on q: %s" % (tag, err))
        check(e.M.violations == 0, "%s: drew off-screen %s" % (tag, e.offscreen()))
        check(not e.missing or mode != "window", "%s: not on screen: %s" % (tag, e.missing))
        if mode == "window":
            s = e.snaps
            if pid == "calculator":
                check("= 14" in s.get("calc", "") and "= 7" in s.get("seven", "") and "division by zero" in s.get("err", ""),
                      "calculator results wrong:\n%s\n%s\n%s" % (s.get("calc"), s.get("seven"), s.get("err")))
            if pid == "notes":
                saved = [v for k, v in e.M.FS.items() if k.startswith("/os/data/notes/") and isinstance(v, str)]
                check(any(v.startswith("Shopping list") for v in saved), "notes: note not saved: %s" % saved)
                check("Shopping list" in s.get("notes", ""), "notes: list does not show the title:\n" + s.get("notes", ""))
            if pid == "paint":
                pics = [v for k, v in e.M.FS.items() if k.startswith("/os/data/paint/") and k.endswith(".nfp")]
                check(pics and re.match(r"^[0-9a-f \n]+$", pics[0]) and "e" in pics[0], "paint: picture not saved as .nfp: %s" % pics)
            if pid in ("snake", "2048", "blocks", "wardenrun"):
                pass
    print("package %-10s ok" % pid if not [f for f in fail if f.startswith(pid + " ") or f.startswith(pid + ":")]
          else "package %-10s FAILED" % pid)

# commands
def cmd_env(pid, args, events=(), lines=(), w=51, h=40, prelude=""):
    e = Env(w=w, h=h, events=events, lines=lines, prelude=prelude)
    p = [q for q in PKGS if q["id"] == pid][0]
    for frm, to in p["files"]:
        e.M.FS[to] = read(frm)
    ok, err = e.run_file(p["files"][0][1], *args)
    tag = "%s %s %dx%d" % (pid, " ".join(args), w, h)
    check(ok or err == "SCRIPT_END", "%s: crashed: %s" % (tag, err))
    check(e.M.violations == 0, "%s: drew off-screen %s" % (tag, e.offscreen()))
    return e, e.screen(), ok, err

for w in (51, 26):
    e, out, ok, err = cmd_env("weather", [], w=w)
    check("Day" in out and "12:30" in out and "Moon" in out, "weather output:\n" + out)
    e, out, ok, err = cmd_env("weather", ["-s"], w=w)
    check("Day 1 12:30" in out, "weather -s:\n" + out)
DETECTOR = """
local names, types = peripheral.getNames, peripheral.getType
peripheral.getNames = function() local t = names() t[#t + 1] = "top" return t end
peripheral.getType = function(n) if n == "top" then return "environmentDetector" end return types(n) end
local wrap = peripheral.wrap
peripheral.wrap = function(n) if n == "top" then return { isRaining = function() return true end,
  isThunder = function() return false end, getBiome = function() return "minecraft:dark_forest" end } end return wrap(n) end
"""
e, out, ok, err = cmd_env("weather", [], prelude=DETECTOR)
check("rain" in out and "dark forest" in out, "weather with a detector:\n" + out)
e, out, ok, err = cmd_env("calc", ["2+3*4"])
check("14" in out, "calc 2+3*4:\n" + out)
e, out, ok, err = cmd_env("calc", ["2^10", "-", "(1+1)*sqrt(16)"])
check("1016" in out, "calc with spaces:\n" + out)
e, out, ok, err = cmd_env("calc", ["1/0"])
check("division by zero" in out, "calc 1/0:\n" + out)
e, out, ok, err = cmd_env("calc", ["os.shutdown()"])
check("error" in out and not e.M.rebooted, "calc ran code:\n" + out)
e, out, ok, err = cmd_env("calc", [], lines=["1+1", "ans*10", ""])
check("20" in out and ok, "calc interactive:\n" + out)
e, out, ok, err = cmd_env("timer", [])
check("usage: timer" in out, "timer usage:\n" + out)
e, out, ok, err = cmd_env("timer", ["5m", "tea"], events=[T, T, ["char", "q"]])
check("tea - 05:00" in out and "cancelled" in out and ok, "timer cancel:\n" + out)
CLOCK = "local t = 0 os.epoch = function() t = t + 700 return t end"
for w in (51, 20):
    e, out, ok, err = cmd_env("timer", ["3"], events=[T] * 10, w=w, prelude=CLOCK)
    check("time's up" in out and ok, "timer done (%d):\n%s" % (w, out))
    check(["timer: time's up!"] in e.queued("os_toast"), "timer: no toast")
print("commands: ok" if not [f for f in fail if f.split()[0] in ("weather", "calc", "timer")] else "commands: problems")

print()
if fail:
    print("%d problem(s)" % len(fail))
    sys.exit(1)
print("store: ok")
