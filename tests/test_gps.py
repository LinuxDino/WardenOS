#!/usr/bin/env python3
"""Warden GPS:  python3 tests/test_gps.py  (needs: pip install lupa)

1. /os/lib/gpsx.lua: least-squares fix over every host, a host with wrong coordinates is found, coplanar / too few
   hosts give no fix, outliers are rejected, far-from-spawn positions stay exact, the constellation check + advice
2. /os/gps/core.lua + host.lua: answers a GPS PING with its coordinates (like `gps host`), announces itself on
   rednet "wardenos" and answers gps_who, status screen, missing modem / missing config
3. the GPS app at several window sizes: hosts, check (advice), locate, drones; nothing drawn off-screen
4. the installer: standard computer -> dedicated GPS host (auto-detected position), typed position, welcome screen G,
   `install gps` on a desktop -> background host, `install update` on a host keeps its position
5. the desktop's background host (/os/lib/world.lua) answers pings and caches announcements
"""
import os, re, sys
import lupa.lua52 as lua

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src")
fail = []
ENTER, LEFT, RIGHT, G = 28, 203, 205, 34


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

THEME = """WardenOS = { theme = { bg = colors.black, panel = colors.gray, text = colors.white, dim = colors.lightGray,
  accent = colors.cyan, good = colors.green, bad = colors.red, warn = colors.yellow } }"""

# a wireless modem on "back" (MODEM) that simulates GPS hosts: a PING is answered by every host in GPSSIM.hosts
# ({ x, y, z [, real = { x, y, z }] }: real = where it really is, x y z = what it claims), seen from GPSSIM.pos
SIM = """
GPSSIM = { pos = { 0, 0, 0 }, hosts = {}, tx = {}, opened = {} }
local realCall = peripheral.call
peripheral.call = function(n, m, ...)
  if n == "back" and MODEM then
    local a = { ... }
    if m == "isWireless" then return true end
    if m == "open" then GPSSIM.opened[a[1]] = true return end
    if m == "close" then GPSSIM.opened[a[1]] = nil return end
    if m == "isOpen" then return GPSSIM.opened[a[1]] == true end
    if m == "transmit" then
      GPSSIM.tx[#GPSSIM.tx + 1] = { ch = a[1], reply = a[2], msg = a[3] }
      if a[3] == "PING" and a[1] == 65534 then
        local p = GPSSIM.pos
        for _, h in ipairs(GPSSIM.hosts) do
          local r = h.real or h
          local d = math.sqrt((r[1] - p[1]) ^ 2 + (r[2] - p[2]) ^ 2 + (r[3] - p[3]) ^ 2)
          os.queueEvent("modem_message", "back", a[2], 65534, { h[1], h[2], h[3] }, d)
        end
        os.queueEvent("timer", MOCK.lastTimer)
      end
      return
    end
  end
  return realCall(n, m, ...)
end
"""


def env(events=(), lines=(), w=51, h=19, modem=True, files=None, colour=True, all_src=False, host_event=None):
    rt = lua.LuaRuntime(unpack_returned_tuples=True, encoding="latin-1")
    g = rt.globals()
    g.HOST_READ = lambda p: read(p)
    g.CW, g.CH, g.MW, g.MH = w, h, 0, 0
    g.MODEM = modem
    if host_event:
        g.HOST_EVENT = host_event
    g.SCRIPT_EVENTS = rt.table_from([rt.table_from(e) for e in events])
    g.SCRIPT_LINES = rt.table_from(list(lines))
    M = rt.execute(read("tests/mock_cc.lua"))
    g.MOCK = M
    rt.execute(SIM)
    if not colour:
        rt.execute("MOCK.native.isColor = function() return false end MOCK.native.isColour = MOCK.native.isColor")
    if all_src:
        for f in SRC_FILES:
            parts = f.split("/")
            for i in range(1, len(parts)):
                M.FS["/" + "/".join(parts[:i])] = True
            M.FS["/" + f] = read("src/" + f)
    for k, v in (files or {}).items():
        M.FS[k] = v
    return rt, M


def run(rt, src, name, *args):
    f = rt.eval("function(src, name, ...) local f, e = load(src, '=' .. name, 't', _G) "
                "if not f then return false, e end local ok, r = pcall(f, ...) return ok, r end")
    return f(src, name, *args)


def screen(M):
    t = M.native
    return "\n".join(t.rows[y] for y in range(1, t.h + 1))


def hosts_lua(hosts):
    out = []
    for hst in hosts:
        if len(hst) == 6:
            out.append("{ %d, %d, %d, real = { %d, %d, %d } }" % hst)
        else:
            out.append("{ %d, %d, %d }" % hst)
    return "{ " + ", ".join(out) + " }"


def sim(rt, pos, hosts):
    rt.execute("GPSSIM.pos = { %d, %d, %d } GPSSIM.hosts = %s" % (pos + (hosts_lua(hosts),)))


GOOD = [(100, 200, 100), (110, 200, 100), (100, 200, 110), (100, 210, 100), (108, 206, 108)]   # 5 hosts, 3D

# ---------------------------------------------------------------- 1. gpsx
rt, M = env()
X = rt.eval('function() return load(HOST_READ("src/os/lib/gpsx.lua"), "=gpsx", "t", _G)() end')()


def loc(X, *a):
    res = X.locate(*a)
    return res if isinstance(res, tuple) else (res, None)


def xyz(r):
    return repr(r and (r.x, r.y, r.z))

sim(rt, (37, 64, -250), GOOD)
r, why = loc(X)
check(r is not None and (r.x, r.y, r.z) == (37, 64, -250), "gpsx.locate: wrong fix %s" % xyz(r))
check(r is not None and r.quality == "exact" and r.agree == 3 and r.samples == 3 and r.hosts == 5,
      "gpsx.locate: %r" % (r and (r.quality, r.agree, r.samples, r.hosts),))
check(len(rt.eval("GPSSIM.tx")) == 3 and not rt.eval("GPSSIM.opened[65534]"), "gpsx.locate: 3 pings, channel closed again")

# far from spawn: still exact
far = [(x + 29000000, y, z - 29000000) for (x, y, z) in GOOD]
sim(rt, (29000123, 70, -28999877), far)
r, why = loc(X)
check(r is not None and (r.x, r.y, r.z) == (29000123, 70, -28999877) and r.quality == "exact",
      "gpsx.locate far away: %r %s" % (xyz(r), why))

# one host claims a wrong position: found and ignored
liar = list(GOOD)
liar[2] = (100, 200, 113, 100, 200, 110)          # claims z=113, really at z=110
sim(rt, (37, 64, -250), liar)
r, why = loc(X)
check(r is not None and (r.x, r.y, r.z) == (37, 64, -250), "gpsx: liar broke the fix %s" % xyz(r))
bad = r and r.bad
check(bad is not None and len(bad) == 1 and (bad[1].x, bad[1].y, bad[1].z) == (100, 200, 113),
      "gpsx: wrong host not reported: %r" % ((bad and [(b.x, b.y, b.z) for b in bad.values()]),))

# all hosts in one plane -> mirrored fixes, no answer; 3 hosts -> none; no hosts -> none
flat = [(100, 200, 100), (110, 200, 100), (100, 200, 110), (110, 200, 110)]
sim(rt, (37, 64, -250), flat)
r, why = loc(X)
check(r is None and "plane" in str(why), "gpsx: coplanar hosts gave %s / %s" % (r, why))
sim(rt, (105, 200, 104), flat)                    # ...unless you stand in that plane
r, why = loc(X)
check(r is not None and (r.x, r.y, r.z) == (105, 200, 104), "gpsx: in-plane fix failed")
sim(rt, (37, 64, -250), GOOD[:3])
r, why = loc(X)
check(r is None, "gpsx: 3 hosts gave a fix")
sim(rt, (37, 64, -250), [])
r, why = loc(X)
check(r is None and "no GPS hosts" in str(why), "gpsx: no hosts: %s" % why)

# consensus rejects outliers; vanilla sampling with one bad sample
c = X.consensus(rt.eval("{ {x=1,y=2,z=3}, {x=1,y=2,z=3}, {x=1.01,y=2,z=3}, {x=50,y=2,z=3} }"))
check(c.agree == 3 and abs(c.x - 1.0033) < 0.01 and c.spread > 40, "gpsx.consensus: %s %s" % (c.agree, c.x))
rt.execute("local q = { {10,64,10}, {300,1,1}, {10,64,10} } local i = 0 "
           "gps.locate = function() i = i + 1 local p = q[i] if p then return p[1], p[2], p[3] end end")
r, why = loc(X, rt.eval("{ vanilla = true, samples = 3 }"))
check(r is not None and (r.x, r.y, r.z) == (10, 64, 10) and r.agree == 2 and r.quality == "good",
      "gpsx vanilla consensus: %r" % ((r and (r.x, r.y, r.z, r.agree, r.quality)),))

# no modem
rt2, M2 = env(modem=False)
X2 = rt2.eval('function() return load(HOST_READ("src/os/lib/gpsx.lua"), "=gpsx", "t", _G)() end')()
r, why = loc(X2)
check(r is None and "modem" in str(why), "gpsx without modem: %s" % why)


def analyze(hosts):
    return X.analyze(rt.eval("{ %s }" % ", ".join("{ x = %d, y = %d, z = %d }" % h for h in hosts)))


def advice(a):
    return " ".join(a.advice[i] for i in range(1, len(a.advice) + 1))


a = analyze([])
check(a.n == 0 and a.grade == "none" and "installer" in advice(a), "analyze(none): %s" % advice(a))
a = analyze(GOOD[:3])
check("4th host higher or lower" in advice(a) and a.score < 40, "analyze(3): %s" % advice(a))
a = analyze(flat)
check(a.coplanar and "flat plane" in advice(a) and a.grade == "poor", "analyze(flat): %s %s" % (a.grade, advice(a)))
a = analyze([(0, 70, 0), (5, 70, 0), (10, 70, 0), (15, 70, 0)])
check(a.collinear and "line" in advice(a), "analyze(line): %s" % advice(a))
a = analyze(GOOD)
check(not a.coplanar and a.grade in ("excellent", "good") and a.score >= 85 and "Looks great" in advice(a),
      "analyze(good): %s %s %s" % (a.grade, a.score, advice(a)))
a = analyze(GOOD[:4])
check("5th host" in advice(a), "analyze(4): no spare advice: %s" % advice(a))
a = analyze([(0, 20, 0), (10, 20, 0), (0, 20, 10), (0, 30, 0)])
check("y=20" in advice(a), "analyze(low): no height advice: %s" % advice(a))
a = analyze([(0, 200, 0), (0, 200, 0), (10, 200, 0), (0, 200, 10), (0, 210, 0)])
check("same position" in advice(a), "analyze(dup): %s" % advice(a))
check(M.violations == 0, "gpsx: drew off-screen")
print("gpsx: ok" if not fail else "gpsx: FAILED")

# ---------------------------------------------------------------- 2. host
nfail = len(fail)
HOSTFILES = {"/os": True, "/os/gps": True, "/os/config.lua": read("src/os/config.lua"),
             "/os/gps/core.lua": read("src/os/gps/core.lua"), "/os/gps/host.lua": read("src/os/gps/host.lua"),
             "/os/gps/host.cfg": '{ x = 120, y = 200, z = -45, mode = "dedicated" }'}
for (w, h, colour) in [(51, 19, True), (26, 20, False), (39, 13, True)]:
    tag = "host %dx%d" % (w, h)
    rt, M = env([["modem_message", "back", 65534, 65534, "PING", 12.5],
                 ["modem_message", "back", 65534, 65534, "PING", None],      # wired: ignored, like gps host
                 ["modem_message", "back", 5, 65534, "HELLO", 3],
                 ["rednet_message", 30, "WHO", "wardenos"],
                 ["timer", 1]], w=w, h=h, files=HOSTFILES, colour=colour)
    # the rednet message must be a Lua table: patch the queued event
    rt.execute('SCRIPT_EVENTS[4][3] = { t = "gps_who" }')
    ok, err = run(rt, read("src/os/gps/host.lua"), "host.lua")
    tx = rt.eval("GPSSIM.tx")
    replies = [tx[i] for i in range(1, len(tx) + 1)]
    check(err == "SCRIPT_END", "%s: stopped early: %s" % (tag, err))
    check(len(replies) == 1 and replies[0].ch == 65534 and replies[0].reply == 65534
          and [replies[0].msg[i] for i in (1, 2, 3)] == [120, 200, -45],
          "%s: PING not answered like gps host: %s" % (tag, [(r.ch, r.reply, r.msg) for r in replies]))
    check(rt.eval("GPSSIM.opened[65534]") is True, "%s: GPS channel not open" % tag)
    sent = [M.sent[i] for i in range(1, len(M.sent) + 1)]
    check(any(s.to == "all" and s.msg.t == "gps_host" and s.msg.x == 120 and s.msg.z == -45 and s.proto == "wardenos"
              for s in sent), "%s: no announcement" % tag)
    check(any(s.to == 30 and s.msg.t == "gps_host" and s.msg.served == 1 for s in sent), "%s: gps_who not answered" % tag)
    sc = screen(M)
    check("Warden GPS host" in sc and "120 200 -45" in sc and "1 request" in sc, "%s: status screen:\n%s" % (tag, sc))
    check(M.violations == 0, "%s: %d chars off-screen" % (tag, M.violations))

rt, M = env([["timer", 1]], modem=False, files=HOSTFILES)
ok, err = run(rt, read("src/os/gps/host.lua"), "host.lua")
check("NONE" in screen(M) and "wireless or ender modem" in screen(M), "host without modem: no clear message:\n" + screen(M))
files = dict(HOSTFILES)
del files["/os/gps/host.cfg"]
rt, M = env([], files=files)
ok, err = run(rt, read("src/os/gps/host.lua"), "host.lua")
check(ok and any("installer" in l for l in M.log.values()), "host without config: %s %s" % (err, list(M.log.values())))
# the startup restarts the host and stops on Ctrl+T
files = dict(HOSTFILES)
rt, M = env([["terminate"]], files=files)
ok, err = run(rt, read("src/os/gps/startup.lua"), "startup.lua")
check(ok and any("stopped" in l for l in M.log.values()), "gps startup: terminate not handled: %s %s" % (err, list(M.log.values())))
print("gps host: ok" if len(fail) == nfail else "gps host: FAILED")

# ---------------------------------------------------------------- 3. app
nfail = len(fail)
FLAT_HOSTS = """{ [21] = { t = "gps_host", x = 100, y = 200, z = 100, served = 9, label = "gps1", modems = 1, seen = os.clock() },
  [22] = { t = "gps_host", x = 110, y = 200, z = 100, served = 4, modems = 1, seen = os.clock() },
  [23] = { t = "gps_host", x = 100, y = 200, z = 110, served = 2, modems = 0, seen = os.clock() },
  [24] = { t = "gps_host", x = 110, y = 200, z = 110, served = 0, modems = 1, seen = os.clock() - 999 } }"""
DRONES = """{ [12] = { label = "miner", pos = { 1, 2, 3 }, calibrated = true }, [13] = { label = "digger", calibrated = false } }"""
for (w, h) in [(46, 17), (51, 19), (26, 12), (30, 10)]:
    tag = "app %dx%d" % (w, h)
    shots = {}

    def host_event(name, *args):
        shots[len(shots)] = screen(Mx)
        return None
    # hosts -> scan (a plain gps host answers) -> check -> locate (Enter) -> drones -> back to hosts
    ev = [["host", "shot"], ["key", ENTER], ["host", "shot"], ["key", RIGHT], ["host", "shot"],
          ["key", RIGHT], ["key", ENTER], ["host", "shot"], ["key", RIGHT], ["host", "shot"],
          ["key", RIGHT], ["mouse_scroll", 1, 5, 5], ["mouse_click", 1, 3, h]]
    rt, Mx = env(ev, w=w, h=h, files={"/os": True, "/os/lib": True, "/os/lib/gpsx.lua": read("src/os/lib/gpsx.lua"),
                                       "/os/apps": True, "/os/apps/gps.lua": read("src/os/apps/gps.lua")},
                 host_event=host_event)
    rt.execute(THEME)
    rt.execute("WardenOS.gpsHosts = %s WardenOS.drones = %s" % (FLAT_HOSTS, DRONES))
    sim(rt, (105, 150, 104), [(100, 200, 100), (110, 200, 100), (100, 200, 110), (100, 210, 100), (300, 90, 300)])
    ok, err = rt.eval("function() return pcall(function() dofile('/os/apps/gps.lua').main() end) end")()
    check(err == "SCRIPT_END", "%s: stopped early: %s" % (tag, err))
    check(Mx.violations == 0, "%s: %d chars off-screen" % (tag, Mx.violations))
    s = [shots.get(i, "") for i in range(5)]
    flat_ = lambda t: re.sub(r"\s+", " ", re.sub(r"\n\s*-?\s*", " ", t))
    check("#21" in s[0] and "100 200 100" in s[0], "%s hosts tab:\n%s" % (tag, s[0]))
    if w >= 40:
        check("no modem!" in s[0] and "off" in s[0], "%s hosts tab states:\n%s" % (tag, s[0]))
        check("no modem!" not in s[1], "%s scan: a host that answered still shows no modem:\n%s" % (tag, s[1]))
        check("plain gps host" in s[1] or "300 90 300" in s[1], "%s scan: plain host not listed:\n%s" % (tag, s[1]))
        check("answered" in s[1], "%s scan: no result message:\n%s" % (tag, s[1]))
        check("Constellation" in s[2], "%s check tab:\n%s" % (tag, s[2]))
        check("105 150 104" in s[3] and "exact" in s[3], "%s locate tab:\n%s" % (tag, s[3]))
        check("#12" in s[4] and "GPS 1 2 3" in s[4] and "no GPS fix" in s[4], "%s drones tab:\n%s" % (tag, s[4]))
    else:
        check("105 150 104" in s[3], "%s locate tab:\n%s" % (tag, s[3]))

# check tab advice on a flat constellation, without a scan
for (w, h) in [(46, 17), (51, 19)]:
    tag = "app check %dx%d" % (w, h)
    rt, Mx = env([["key", RIGHT]], w=w, h=h, modem=False,
                 files={"/os": True, "/os/lib": True, "/os/lib/gpsx.lua": read("src/os/lib/gpsx.lua"),
                        "/os/apps": True, "/os/apps/gps.lua": read("src/os/apps/gps.lua")})
    rt.execute(THEME)
    rt.execute("WardenOS.gpsHosts = %s" % FLAT_HOSTS)
    ok, err = rt.eval("function() return pcall(function() dofile('/os/apps/gps.lua').main() end) end")()
    sc = screen(Mx)
    text = re.sub(r"\s+", " ", sc)
    check("POOR" in sc and "3 hosts" in sc, "%s: grade:\n%s" % (tag, sc))
    check("add 1 more" in text and "Host #24 has not been heard" in text and "no wireless modem" in text,
          "%s: advice:\n%s" % (tag, sc))
    check(Mx.violations == 0, "%s: off-screen" % tag)
rt, Mx = env([], w=46, h=17, modem=False,
             files={"/os": True, "/os/lib": True, "/os/lib/gpsx.lua": read("src/os/lib/gpsx.lua"),
                    "/os/apps": True, "/os/apps/gps.lua": read("src/os/apps/gps.lua")})
rt.execute(THEME)
ok, err = rt.eval("function() return pcall(function() dofile('/os/apps/gps.lua').main() end) end")()
text = re.sub(r"\s+", " ", screen(Mx))
check("No GPS hosts heard yet" in text and "no wireless or ender modem" in text, "app empty state:\n" + screen(Mx))
hdr = rt.eval("function() return dofile('/os/apps/gps.lua') end")()
check(hdr.name == "GPS" and hdr.w <= 51 and hdr.h <= 19, "app header")
print("gps app: ok" if len(fail) == nfail else "gps app: FAILED")

# ---------------------------------------------------------------- 4. installer
nfail = len(fail)
manifest = lua.LuaRuntime().execute(read("manifest.lua"))
listed = [manifest.files[i] for i in range(1, len(manifest.files) + 1)]
gpsl = [manifest.gps[i] for i in range(1, len(manifest.gps) + 1)]
check(all(f in listed for f in gpsl), "manifest gps list has files that are not in files")
check("os/gps/host.lua" in gpsl and "os/gps/core.lua" in gpsl and "os/gps/startup.lua" in gpsl, "manifest gps list incomplete")


def fsnap(M):
    return {k: v for k, v in M.FS.items()}


def cfg_of(rt, fs_):
    return rt.eval("function(s) return textutils.unserialize(s or '') end")(fs_.get("/os/gps/host.cfg"))


# a) standard computer, other hosts exist: position detected
rt, M = env([], ["y", "y", "y"], colour=False, files={"/notes.txt": "keep", "/startup.lua": "print('old')"})
sim(rt, (120, 200, -45), GOOD)
ok, err = run(rt, read("install.lua"), "install.lua")
f = fsnap(M)
c = cfg_of(rt, f)
gets = [l for l in M.log.values() if l.startswith("GET ")]
check(M.rebooted, "installer standard: did not finish: %s %s" % (err, list(M.log.values())[-6:]))
check(c is not None and (c.x, c.y, c.z, c.mode) == (120, 200, -45, "dedicated"), "installer standard: cfg %r" % ((c and (c.x, c.y, c.z, c.mode)),))
check(f.get("/startup.lua") == read("src/os/gps/startup.lua") and f.get("/startup.old.lua") == "print('old')",
      "installer standard: startup not written / old one not kept")
check(f.get("/os/gps/host.lua") == read("src/os/gps/host.lua") and "/os/kernel.lua" not in f and f.get("/notes.txt") == "keep",
      "installer standard: wrong files %s" % sorted(f))
check(len(gets) == 1 + len(gpsl), "installer standard: downloaded %d files, not just the GPS host" % len(gets))
check(M.label == "gps-7", "installer standard: label %s" % M.label)
check(M.violations == 0, "installer standard: off-screen")
std = f

# b) typed position, no modem (warned)
rt, M = env([], ["oops", "5 90 -7", "y"], colour=False, modem=False)
ok, err = run(rt, read("install.lua"), "install.lua")
f = fsnap(M)
c = cfg_of(rt, f)
check(M.rebooted and c is not None and (c.x, c.y, c.z) == (5, 90, -7), "installer typed: %s %r" % (err, c and (c.x, c.y, c.z)))
check(any("No wireless or ender modem" in l for l in M.log.values()), "installer typed: no modem warning")
check(any("Three whole numbers" in l for l in M.log.values()), "installer typed: bad input not rejected")

# c) old `gps host` startup: position offered from it
rt, M = env([], ["y", "y"], colour=False, modem=False,
            files={"/startup.lua": 'shell.run("gps", "host", 11, 222, -33)'})
ok, err = run(rt, read("install.lua"), "install.lua")
c = cfg_of(rt, fsnap(M))
check(M.rebooted and c is not None and (c.x, c.y, c.z) == (11, 222, -33), "installer old gps startup: %s" % err)

# d) install update on a dedicated host: keeps the position, no questions
rt, M = env([], [], colour=False, files=dict(std, **{"/os/gps/host.lua": "-- old"}))
ok, err = run(rt, read("install.lua"), "install.lua", "update")
f = fsnap(M)
c = cfg_of(rt, f)
check(M.rebooted and c is not None and (c.x, c.y, c.z) == (120, 200, -45) and f.get("/os/gps/host.lua") == read("src/os/gps/host.lua"),
      "installer update on host: %s %s" % (err, list(M.log.values())[-4:]))
# ...and `install` on an Advanced computer that is a dedicated host: GPS flow, keep (Enter = yes)
rt, M = env([], [""], files=dict(std))
ok, err = run(rt, read("install.lua"), "install.lua")
c = cfg_of(rt, fsnap(M))
check(M.rebooted and c is not None and c.x == 120 and "/os/kernel.lua" not in fsnap(M), "installer re-run on host: %s" % err)

# e) welcome screen G on a fresh Advanced computer -> dedicated host
for (w, h) in [(51, 19), (26, 20)]:
    rt, M = env([["key", G]], ["n", "1 100 2", "y"], w=w, h=h)
    sim(rt, (0, 0, 0), [])
    ok, err = run(rt, read("install.lua"), "install.lua")
    f = fsnap(M)
    c = cfg_of(rt, f)
    check(M.rebooted and c is not None and (c.x, c.y, c.z, c.mode) == (1, 100, 2, "dedicated")
          and f.get("/startup.lua") == read("src/os/gps/startup.lua") and "/os/kernel.lua" not in f,
          "installer welcome G %dx%d: %s %s" % (w, h, err, list(M.log.values())[-5:]))
    check(M.violations == 0, "installer welcome G %dx%d: off-screen" % (w, h))

# f) `install gps` on a computer with the WardenOS desktop -> background host, desktop kept
CLEAN = [["key", ENTER]] + [["key", 208]] * 80 + [["key", ENTER]] * 3
rt, M = env(CLEAN, ["AGREE", "", "dino", "secret1", "secret1", "ERASE"], modem=False)
run(rt, read("install.lua"), "install.lua")
pc = fsnap(M)
rt, M = env([], ["b", "40 180 40", "y"], files=dict(pc), modem=False)
ok, err = run(rt, read("install.lua"), "install.lua", "gps")
f = fsnap(M)
c = cfg_of(rt, f)
check(M.rebooted and c is not None and c.mode == "desktop" and (c.x, c.y, c.z) == (40, 180, 40),
      "installer gps on desktop: %s %s" % (err, list(M.log.values())[-5:]))
check(f.get("/startup.lua") == pc["/startup.lua"] and f.get("/os/users.dat") == pc["/os/users.dat"]
      and f.get("/os/kernel.lua") == pc["/os/kernel.lua"] and f.get("/os/config.lua") == pc["/os/config.lua"],
      "installer gps on desktop: the desktop was changed")
desk = f
# the desktop's update keeps the background host config
rt, M = env([["key", ENTER], ["key", ENTER]], [], files=dict(desk))
ok, err = run(rt, read("install.lua"), "install.lua", "update")
check(M.rebooted and fsnap(M).get("/os/gps/host.cfg") == desk["/os/gps/host.cfg"], "desktop update lost the GPS config: %s" % err)
# dedicated on a desktop: desktop removed, own files kept
rt, M = env([], ["d", "n", "40 180 40", "y"], files=dict(pc, **{"/home.txt": "mine"}))
ok, err = run(rt, read("install.lua"), "install.lua", "gps")
f = fsnap(M)
check(M.rebooted and f.get("/home.txt") == "mine" and "/os/kernel.lua" not in f and "/os/users.dat" not in f
      and f.get("/startup.lua") == read("src/os/gps/startup.lua") and "/os/gps/core.lua" in f
      and "/os/apps" not in f,
      "installer gps dedicated on desktop: %s %s" % (err, sorted(k for k in f if k.startswith("/os"))))
# cancel changes nothing
rt, M = env([], ["q"], files=dict(pc))
ok, err = run(rt, read("install.lua"), "install.lua", "gps")
check(fsnap(M) == pc and not M.rebooted, "installer gps cancel changed files")
print("installer gps: ok" if len(fail) == nfail else "installer gps: FAILED")

# ---------------------------------------------------------------- 5. background host on the desktop
nfail = len(fail)
rt, M = env([], all_src=True, files={"/os/gps/host.cfg": '{ x = 40, y = 180, z = 40, mode = "desktop" }'})
rt.execute("WardenOS = {}")
Wd = rt.eval("function() return dofile('/os/lib/world.lua') end")()
check(Wd.gpsHost is not None and rt.eval("WardenOS.gpsHost") is not None, "world: background host not started")
ev = rt.eval("function(...) return table.pack(...) end")
Wd.event(ev("modem_message", "back", 65534, 65534, "PING", 7.5))
tx = rt.eval("GPSSIM.tx")
check(len(tx) == 1 and [tx[1].msg[i] for i in (1, 2, 3)] == [40, 180, 40], "world: background host did not answer")
Wd.event(ev("rednet_message", 21, rt.eval('{ t = "gps_host", x = 1, y = 2, z = 3, served = 5 }'), "wardenos"))
check(Wd.gpsHosts[21] is not None and Wd.gpsHosts[21].served == 5 and rt.eval("WardenOS.gpsHosts[21]") is not None,
      "world: announcement not cached")
rt, M = env([], all_src=True, files={"/os/gps/host.cfg": '{ x = 40, y = 180, z = 40, mode = "dedicated" }'})
rt.execute("WardenOS = {}")
Wd = rt.eval("function() return dofile('/os/lib/world.lua') end")()
check(Wd.gpsHost is None, "world: a dedicated config must not start a background host")
print("background host: ok" if len(fail) == nfail else "background host: FAILED")

print()
if fail:
    print("%d problem(s)" % len(fail))
    sys.exit(1)
print("all gps checks passed")
