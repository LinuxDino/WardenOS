#!/usr/bin/env python3
"""Look and feel checks:  python3 tests/test_ui.py  (needs: pip install lupa)

1. /os/lib/art.lua: every art name/size has equal-length blit rows with valid colors and draws inside any terminal
2. every app header has a valid 4x2 `art` icon
3. the desktop (dock icons, wallpaper, Warden + clock) at every test size without off-screen characters
4. os_apps_changed adds / removes an app from the dock and app view; a removed app's window keeps running
5. login with the on-screen keyboard (shift, digits, symbols page, backspace, show/hide, enter) on 57x24 and 30x12
   monitors, a wrong password is rejected
6. boot screen: skippable by a key (passed on to the boot menu) or a tap, short; the boot menu still works
7. toasts (os_toast) appear and disappear; the goodbye screen on shut down
"""
import os, re, sys
import lupa.lua52 as lua

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src")
fail = []
ENTER, DOWN, F12 = 28, 208, 88


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


SRC_FILES = sorted(os.path.relpath(os.path.join(d, f), SRC).replace(os.sep, "/")
                   for d, _, fs in os.walk(SRC) for f in fs)
APPS = [f[len("os/apps/"):-4] for f in SRC_FILES if f.startswith("os/apps/") and f.endswith(".lua")]


class Env:
    """The mock CC: Tweaked with every file of src/ installed and an account dino / <password>."""

    def __init__(self, events=(), CW=51, CH=19, MW=0, MH=0, password="secret1", settings=None, files=None):
        self.rt = lua.LuaRuntime(unpack_returned_tuples=True, encoding="latin-1")
        g = self.rt.globals()
        g.HOST_READ = lambda p: read(p)
        g.CW, g.CH, g.MW, g.MH = CW, CH, MW, MH
        g.HOST_EVENT = self.host_event
        self.hosts, self.shots, self.problems = {"shot": self.shot, "tap": self.tap, "timer": self.timer}, {}, []
        g.SCRIPT_EVENTS = self.rt.table_from([self.lua(e) for e in events])
        g.SCRIPT_LINES = self.rt.table_from([])
        self.M = self.rt.execute(read("tests/mock_cc.lua"))
        for f in SRC_FILES:
            parts = f.split("/")
            for i in range(1, len(parts)):
                self.M.FS["/" + "/".join(parts[:i])] = True
            self.M.FS["/" + f] = read("src/" + f)
        users = self.rt.eval("""function(pw)
            local sha = dofile("/os/lib/sha256.lua")
            return textutils.serialize({ version = 1, last = "dino",
              users = { { name = "dino", admin = true, salt = "00ff", hash = sha.hashPassword(pw, "00ff") } } })
          end""")(password)
        self.M.FS["/os/users.dat"] = users
        if settings:
            self.M.FS["/os/settings.lua"] = settings
        for k, v in (files or {}).items():
            self.M.FS[k] = v
        # record what is blitted on the real screens (bg strings): icons, wallpaper and art use blit
        self.rt.execute("BLITS = {} STARTS = {}")
        self.rt.eval("""function(M)
          local function wrap(t) if not t then return end local b = t.blit
            t.blit = function(s, f, bg) BLITS[#BLITS + 1] = bg return b(s, f, bg) end end
          wrap(M.native) wrap(M.mon)
          local st = os.startTimer
          os.startTimer = function(s) STARTS[#STARTS + 1] = s return st(s) end
        end""")(self.M)

    def lua(self, v):
        if isinstance(v, (list, tuple)):
            return self.rt.table_from([self.lua(x) for x in v])
        if isinstance(v, dict):
            return self.rt.table_from({k: self.lua(x) for k, x in v.items()})
        return v

    def host_event(self, name, *args):
        ev = self.hosts[name](*args)
        return None if ev is None else self.lua(ev)

    monitor = False                             # True: the desktop is on the monitor (taps = monitor_touch)

    def term(self):
        return self.M.mon if self.monitor else self.M.native

    def screen(self, t=None):
        t = t or self.term()
        return [t.rows[y] for y in range(1, t.h + 1)]

    def shot(self, tag):
        self.shots[tag] = "\n".join(self.screen())
        return None

    def timer(self):
        return ["timer", self.M.lastTimer]

    # tap an on-screen key (or any label with what="label") of the login keyboard
    def tap(self, key, what="key"):
        rows = self.screen()
        pos = None
        if what == "label":
            for y, r in enumerate(rows, 1):
                i = r.find(key)
                if i >= 0:
                    pos = (i + 1, y)
                    break
        else:
            pats = [r"1\s*2\s*3\s*4", r"q\s*w\s*e\s*r", r"a\s*s\s*d\s*f", r"z\s*x\s*c\s*v", r"-\s*_\s*\.\s*@",
                    r"\*\s*\+\s*=\s*\(", r"(123|abc)\s+space\s+enter"]
            for y, r in enumerate(rows, 1):
                if not any(re.search(p, r, re.I) for p in pats):
                    continue
                for m in re.finditer(r"\S+", r):     # keys are separate words on keyboard rows
                    if m.group(0) == key or (key.isalpha() and len(key) == 1 and m.group(0).lower() == key.lower()):
                        pos = (m.start() + 1, y)
                        break
                if pos:
                    break
        if not pos:
            self.problems.append("key %r not on screen:\n%s" % (key, "\n".join(rows)))
            return None
        if self.monitor:
            return ["monitor_touch", "right", pos[0], pos[1]]
        return ["mouse_click", 1, pos[0], pos[1]]

    def run(self, path="/startup.lua"):
        f = self.rt.eval("function(src, name) local f, e = load(src, '=' .. name, 't', _G) "
                         "if not f then return false, e end local ok, r = pcall(f) return ok, r end")
        return f(self.M.FS[path], path)

    def log(self):
        return "\n".join(self.M.log.values())

    def blits(self):
        b = self.rt.globals().BLITS
        return [b[i] for i in range(1, len(b) + 1)]

    def offscreen(self, tag):
        check(self.M.violations == 0, "%s: %d chars drawn off-screen %s" % (tag, self.M.violations,
              [l for l in self.M.log.values() if "OFFSCREEN" in l][:3]))
        check(not self.problems, "%s: %s" % (tag, self.problems))


LOGIN = [["key", ENTER]] + [["char", c] for c in "secret1"] + [["key", ENTER]]

# ---------------------------------------------------------------- 1. art.lua
env = Env()
A = env.rt.eval('function() return dofile("/os/lib/art.lua") end')()
names = [A.names()[i] for i in range(1, len(A.names()) + 1)]
check(set(["warden", "logo", "sculk"]) <= set(names), "art.names(): %s" % names)
HEX = set("0123456789abcdef")
sizes_seen = {}
for n in names:
    sizes = [A.sizes(n)[i] for i in range(1, len(A.sizes(n)) + 1)]
    sizes_seen[n] = sizes
    for s in sizes:
        img = A.get(n, s)
        check(img is not None and img.w > 0 and img.h > 0 and len(img.rows) == img.h, "art.get(%s, %s): %s" % (n, s, img))
        if img is None:
            continue
        for i in range(1, img.h + 1):
            r = img.rows[i]
            t, fg, bg = r[1], r[2], r[3]
            check(len(t) == len(fg) == len(bg) == img.w, "art %s/%s row %d: lengths %d %d %d (w %d)" % (n, s, i, len(t), len(fg), len(bg), img.w))
            check(set(fg) <= HEX and set(bg) <= HEX, "art %s/%s row %d: bad colors %r %r" % (n, s, i, fg, bg))
        light = A.get(n, s, "0")
        check(all(set(light.rows[i][3]) <= HEX for i in range(1, light.h + 1)), "art %s/%s: bg param" % (n, s))
        # draw at every corner and partly outside a small terminal: never off-screen
        for (x, y) in [(1, 1), (-3, -2), (40, 10), (50, 1), (1, 18), (-30, 5), (60, 40), (45, 15)]:
            env.rt.eval("function(A, n, s, x, y) A.draw(term.native(), n, s, x, y) "
                        "A.blit(term.native(), A.get(n, s), x, y) end")(A, n, s, x, y)
        env.rt.eval("function(A, n) A.wallpaper(term.native(), -5, -3, 80, 40, 'f') end")(A, n)
check(set(sizes_seen.get("warden", [])) == {"small", "medium", "large"}, "warden sizes: %s" % sizes_seen.get("warden"))
ws = {s: (A.get("warden", s).w, A.get("warden", s).h) for s in ("small", "medium", "large")}
check(6 <= ws["small"][0] <= 10 and 4 <= ws["small"][1] <= 6 and 12 <= ws["medium"][0] <= 16 and 6 <= ws["medium"][1] <= 10
      and 18 <= ws["large"][0] <= 26 and 10 <= ws["large"][1] <= 14, "warden sizes: %s" % ws)
check(A.get("nope", "small") is None, "art.get(unknown) should be nil")
check(env.M.violations == 0, "art.draw: %d chars off-screen" % env.M.violations)
print("art: ok" if not fail else "art: FAILED")
nfail = len(fail)

# ---------------------------------------------------------------- 2. app icons
THEME_STUB = """WardenOS = { name = "WardenOS", version = "0", theme = { bg = colors.black, panel = colors.gray,
  text = colors.white, dim = colors.lightGray, accent = colors.cyan, good = colors.green, bad = colors.red,
  warn = colors.yellow }, claude = {}, drones = {} }"""
env.rt.execute(THEME_STUB)
for app in APPS:
    hdr = env.rt.eval('function(p) local ok, a = pcall(dofile, p) if ok then return a end return nil end')("/os/apps/%s.lua" % app)
    check(hdr is not None, "app %s: header did not load" % app)
    if hdr is None:
        continue
    a = hdr.art
    check(a is not None and len(a) == 2, "app %s: no 4x2 art" % app)
    if a is None:
        continue
    for i in (1, 2):
        r = a[i]
        ok = r is not None and all(isinstance(r[k], str) and len(r[k]) == 4 for k in (1, 2, 3)) \
            and set(r[2]) <= HEX and set(r[3]) <= HEX and all(32 <= ord(c) < 127 for c in r[1])
        check(ok, "app %s: art row %d invalid: %s" % (app, i, r and [r[1], r[2], r[3]]))
    check(A.validIcon(a), "app %s: art.validIcon is false" % app)
    check(isinstance(hdr.icon, str) and hdr.icon != "", "app %s: text icon fallback missing" % app)
print("app icons: ok" if len(fail) == nfail else "app icons: FAILED")
nfail = len(fail)

# ---------------------------------------------------------------- 3. desktop at every size
for (CW, CH, MW, MH) in [(51, 19, 0, 0), (51, 19, 57, 24), (51, 19, 164, 81), (51, 19, 29, 13), (26, 20, 0, 0)]:
    tag = "desktop %dx%d mon %dx%d" % (CW, CH, MW, MH)
    for theme in ("dark", "light", "sculk"):
        env = Env(LOGIN + [["host", "shot", "desk"], ["os_launch", "about"], ["host", "shot", "win"],
                           ["key", F12]], CW, CH, MW, MH, settings='{ theme = "%s" }' % theme)
        env.monitor = MW >= 30 and MH >= 12
        ok, err = env.run()
        check(ok and "stopped" in env.log() and "Kernel error" not in env.log(), "%s %s: %s %s" % (tag, theme, err, env.log()[-300:]))
        desk = env.shots.get("desk", "").split("\n")
        check(desk and "WARDENOS" in desk[0] and "12:30" in desk[0], "%s %s: top bar %r" % (tag, theme, desk[:1]))
        check(any(l[:6].strip() == "Apps" for l in desk), "%s %s: dock has no Apps label:\n%s" % (tag, theme, "\n".join(desk)))
        bl = env.blits()
        check(any("9911" in b for b in bl), "%s %s: dock icons not drawn with art" % (tag, theme))
        if theme == "dark":
            W = len(desk[0])
            check("art.wallpaper(" not in read("src/os/kernel.lua"), "%s: the desktop draws a background pattern again" % tag)
            check(any("933" in b for b in bl), "%s: no Warden art on the desktop" % tag)
        check("About" in env.shots.get("win", ""), "%s %s: About window missing" % (tag, theme))
        env.offscreen("%s %s" % (tag, theme))
print("desktop: ok" if len(fail) == nfail else "desktop: FAILED")
nfail = len(fail)

# ---------------------------------------------------------------- 4. os_apps_changed
WEATHER = 'return { name = "Rain", short = "Rain", icon = "~", order = 3, w = 30, h = 10, ' \
          'main = function() while true do os.pullEvent() end end }'


def add(env):
    env.M.FS["/os/apps/weather.lua"] = WEATHER
    return ["os_apps_changed"]


def remove(env):
    env.M.FS["/os/apps/weather.lua"] = None
    return ["os_apps_changed"]


for (CW, CH, MW, MH) in [(51, 19, 57, 24), (51, 19, 0, 0)]:
    tag = "apps_changed %dx%d" % (MW or CW, MH or CH)
    env = Env(LOGIN + [["host", "view"], ["host", "shot", "before"], ["host", "view"],
                       ["host", "add"], ["host", "view"], ["host", "shot", "added"], ["host", "view"],
                       ["os_launch", "weather"], ["host", "remove"], ["host", "shot", "running"],
                       ["host", "view"], ["host", "shot", "removed"], ["key", F12]], CW, CH, MW, MH)
    env.monitor = MW > 0
    env.hosts["add"] = lambda env=env: add(env)
    env.hosts["remove"] = lambda env=env: remove(env)
    env.hosts["view"] = lambda env=env: (["monitor_touch", "right", 3, 2] if env.monitor else ["mouse_click", 1, 3, 2])
    ok, err = env.run()
    check(ok and "stopped" in env.log() and "Kernel error" not in env.log(), "%s: %s %s" % (tag, err, env.log()[-300:]))
    check("Rain" not in env.shots.get("before", "") and "Apps" in env.shots.get("before", ""), "%s: before:\n%s" % (tag, env.shots.get("before")))
    check("Rain" in env.shots.get("added", ""), "%s: new app not in the app view:\n%s" % (tag, env.shots.get("added")))
    check("Rain" in env.shots.get("running", ""), "%s: window of the removed app closed:\n%s" % (tag, env.shots.get("running")))
    view = "\n".join(l[6:] for l in env.shots.get("removed", "").split("\n")[1:])   # the app view, not the dock
    check("Rain" not in view, "%s: removed app still in the app view:\n%s" % (tag, env.shots.get("removed")))
    env.offscreen(tag)
print("os_apps_changed: ok" if len(fail) == nfail else "os_apps_changed: FAILED")
nfail = len(fail)

# ---------------------------------------------------------------- 5. login with the on-screen keyboard
PW = "Ab1-z@"
for (MW, MH) in [(57, 24), (30, 12)]:
    tag = "keyboard %dx%d" % (MW, MH)
    keys_ = [["host", "tap", k] for k in ["^", "a", "b", "1", "-", "z", "x", "<-", "123", "@", "abc"]]
    env = Env([["key", ENTER], ["host", "shot", "login"]] + keys_ +
              [["host", "tap", "show", "label"], ["host", "shot", "shown"], ["host", "tap", "enter"],
               ["host", "shot", "desk"], ["key", F12]], 51, 19, MW, MH, password=PW)
    env.monitor = True
    ok, err = env.run()
    check(ok and "stopped" in env.log() and "Kernel error" not in env.log(), "%s: login failed: %s %s %s" % (tag, err, env.log()[-300:], env.problems))
    check("enter" in env.shots.get("login", "") and "space" in env.shots.get("login", ""), "%s: no keyboard:\n%s" % (tag, env.shots.get("login")))
    check(PW in env.shots.get("shown", ""), "%s: show did not reveal the password:\n%s" % (tag, env.shots.get("shown")))
    check("WARDENOS" in env.shots.get("desk", ""), "%s: desktop not shown after login" % tag)
    env.offscreen(tag)
    # hidden password shows stars; a wrong password is rejected, then the right one works
    env = Env([["key", ENTER], ["host", "tap", "x"], ["host", "tap", "y"], ["host", "shot", "stars"], ["host", "tap", "enter"],
               ["host", "shot", "wrong"]] + [["timer", i] for i in range(1, 12)] +
              [["host", "shot", "again"]] + [["char", c] for c in PW] + [["key", ENTER], ["key", F12]], 51, 19, MW, MH, password=PW)
    env.monitor = True
    ok, err = env.run()
    check("**" in env.shots.get("stars", "") and "xy" not in env.shots.get("stars", ""), "%s: password not masked:\n%s" % (tag, env.shots.get("stars")))
    check("wrong username or password" in env.shots.get("wrong", ""), "%s: wrong password not rejected:\n%s" % (tag, env.shots.get("wrong")))
    check("WARDENOS" not in env.shots.get("again", ""), "%s: logged in with a wrong password" % tag)
    check(ok and "stopped" in env.log() and "Kernel error" not in env.log(), "%s: right password after a wrong one: %s" % (tag, env.log()[-300:]))
    env.offscreen(tag + " wrong")
# a username typed on the keyboard (focus on the name field), 26x20 computer (smallest keyboard)
env = Env([["key", ENTER], ["host", "tap", "dino", "label"], ["host", "tap", "<-"], ["host", "tap", "<-"], ["host", "tap", "<-"],
           ["host", "tap", "<-"], ["host", "tap", "d"], ["host", "tap", "i"], ["host", "tap", "n"], ["host", "tap", "o"],
           ["host", "tap", "enter"]] + [["host", "tap", c] for c in "secret1"] + [["host", "tap", "enter"], ["key", F12]], 26, 20)
ok, err = env.run()
check(ok and "stopped" in env.log() and "Kernel error" not in env.log(), "keyboard 26x20: %s %s %s" % (err, env.log()[-300:], env.problems))
env.offscreen("keyboard 26x20")
print("login keyboard: ok" if len(fail) == nfail else "login keyboard: FAILED")
nfail = len(fail)

# ---------------------------------------------------------------- 6. boot screen + boot menu
def boot(events, **kw):
    env = Env(events, **kw)
    ok, err = env.run()
    return env, ok, err


env, ok, err = boot([["key", DOWN], ["key", ENTER]])              # a key skips the splash and reaches the menu
check("CraftOS" in env.log() and "WardenOS booting" not in env.log(), "boot: DOWN+ENTER did not pick CraftOS: %s" % env.log()[-200:])
env.offscreen("boot keys")
env, ok, err = boot([["mouse_click", 1, 1, 1], ["char", "2"]])    # a tap only skips
check("CraftOS" in env.log(), "boot: tap + '2' did not pick CraftOS: %s" % env.log()[-200:])
# no input: the splash animates (timers), then the menu counts down and boots the default
env, ok, err = boot([["timer", i] for i in range(1, 30)])
starts = env.rt.globals().STARTS
st = [starts[i] for i in range(1, len(starts) + 1)]
splash = [s for s in st if s < 1]
check("WardenOS booting" in env.log(), "boot: auto boot did not start WardenOS: %s" % env.log()[-200:])
check(0 < sum(splash) <= 1.0 + 1e-9, "boot: splash takes %.2f s (timers %s)" % (sum(splash), st[:12]))
check(any("WardenOS " in w for w in env.M.written.values()), "boot: splash without name/version")
env.offscreen("boot timers")
for (CW, CH, MW, MH) in [(51, 19, 0, 0), (51, 19, 57, 24), (51, 19, 29, 13), (26, 20, 0, 0)]:
    env, ok, err = boot([["timer", 1], ["timer", 2], ["host", "shot", "splash"], ["key", DOWN], ["host", "shot", "menu"],
                         ["key", ENTER]], CW=CW, CH=CH, MW=MW, MH=MH)
    check("CraftOS" in env.log(), "boot %dx%d: DOWN + ENTER after the splash: %s" % (CW, CH, env.log()[-200:]))
    check("WardenOS" in env.shots.get("menu", "") and "CraftOS" in env.shots.get("menu", ""), "boot menu %dx%d:\n%s" % (CW, CH, env.shots.get("menu")))
    env.offscreen("boot %dx%d mon %dx%d" % (CW, CH, MW, MH))
print("boot: ok" if len(fail) == nfail else "boot: FAILED")
nfail = len(fail)

# ---------------------------------------------------------------- 7. toast + goodbye
for (CW, CH) in [(51, 19), (26, 20)]:
    env = Env(LOGIN + [["os_toast", "Installed Weather"], ["host", "shot", "toast"], ["host", "timer"], ["host", "shot", "gone"],
                       ["mouse_click", 1, 2, 1], ["host", "tap", "Shut down", "label"]], CW, CH)
    ok, err = env.run()
    want = "Installed Weather"[:min(40, CW) - 4]
    check(want in env.shots.get("toast", ""), "toast %d: not shown:\n%s" % (CW, env.shots.get("toast")))
    check(want not in env.shots.get("gone", ""), "toast %d: still shown after its timer:\n%s" % (CW, env.shots.get("gone")))
    check(env.M.rebooted and any("Shutting down" in w for w in env.M.written.values()), "goodbye %d: %s %s" % (CW, err, env.log()[-200:]))
    env.offscreen("toast %d" % CW)
print("toast + goodbye: ok" if len(fail) == nfail else "toast + goodbye: FAILED")

print()
if fail:
    print("%d problem(s)" % len(fail))
    sys.exit(1)
print("all ui checks passed")
