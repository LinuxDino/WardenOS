#!/usr/bin/env python3
"""Terminal commands in src/os/bin (neofetch, btop):  python3 tests/test_bin.py  (needs: pip install lupa)"""
import os, sys
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

def env(CW, CH, events, prelude=""):
    rt = lua.LuaRuntime(unpack_returned_tuples=True)
    g = rt.globals()
    g.HOST_READ = lambda p: read(p)
    g.CW, g.CH, g.MW, g.MH = CW, CH, 0, 0
    g.MODEM = True
    g.SCRIPT_EVENTS = rt.table_from([rt.table_from(e) for e in events])
    g.SCRIPT_LINES = rt.table_from([])
    M = rt.execute(read("tests/mock_cc.lua"))
    for f in ("os/config.lua", "os/lib/log.lua", "os/lib/map.lua", "os/bin/neofetch.lua", "os/bin/btop.lua"):
        src = read("src/" + f)
        if src is not None:
            M.FS["/" + f] = src
    for d in ("/os", "/os/lib", "/os/bin"):
        M.FS[d] = True
    rt.execute('rednet.open("back")')
    if prelude:
        rt.execute(prelude)
    return rt, M

def run(rt, path):
    f = rt.eval("function(p) local fn, e = loadfile and nil, nil "
                "local src = assert(fs.open(p, 'r')).readAll() "
                "fn, e = load(src, '=' .. p, 't', _G) if not fn then return false, e end "
                "local ok, r = pcall(fn) return ok, r end")
    return f(path)

def screen(M):
    t = M.native
    return "\n".join(t.rows[y] for y in range(1, t.h + 1))

DRONES = '''WardenOS = { version = "1.5.0", user = "dino", theme = {}, drones = {
  [12] = { label = "miner", task = "goto 1 2 3", state = "working", fuel = 150, fuelLimit = 20000, seen = os.clock(),
           by = { id = 7, who = "claude" }, progress = { phase = "moving", step = 5, total = 20 } },
  [14] = { label = "farmer", task = "manual", state = "ready", fuel = 9000, fuelLimit = 20000, seen = -100 },
} }'''

for (w, h) in [(51, 19), (46, 17), (39, 13), (26, 20)]:
    tag = "%dx%d" % (w, h)
    # neofetch, with and without the desktop's WardenOS global
    for pre, name in [("", "plain"), (DRONES, "desktop")]:
        rt, M = env(w, h, [], pre)
        ok, err = run(rt, "/os/bin/neofetch.lua")
        text = screen(M)
        check(ok, "neofetch %s %s: %s" % (tag, name, err))
        check("OS: WardenOS" in text.replace("OS : ", "OS: "), "neofetch %s %s: no OS line\n%s" % (tag, name, text))
        check(M.violations == 0, "neofetch %s %s: %d chars off-screen" % (tag, name, M.violations))
        if name == "desktop":
            check("1 online" in text or w < 40, "neofetch %s: drones line missing\n%s" % (tag, text))
    # btop: three seconds of updates, a rednet status from a drone, then q
    ev = [["timer", 1], ["rednet_message", 20, "STATUS", "wardenos"], ["timer", 2], ["timer", 3], ["char", "q"]]
    fix = """for i = 1, #SCRIPT_EVENTS do
      local e = SCRIPT_EVENTS[i]
      if e[3] == "STATUS" then e[3] = { t = "status", kind = "turtle", label = "x", task = "manual" } end
    end"""
    for pre, name in [("", "plain"), (DRONES, "desktop")]:
        rt, M = env(w, h, ev, pre + "\n" + fix)
        ok, err = run(rt, "/os/bin/btop.lua")
        check(ok, "btop %s %s: %s" % (tag, name, err))
        check(M.violations == 0, "btop %s %s: %d chars off-screen" % (tag, name, M.violations))
        written = "".join(M.written.values())
        check("btop" in written, "btop %s %s: header not drawn" % (tag, name))
        if name == "desktop" and h >= 17:
            check("AI" in written and "#12" in written, "btop %s: Claude drone not shown" % tag)
        if name == "plain" and h >= 17:
            check("#20" in written, "btop %s: drone heard over rednet not shown" % tag)

# startup puts /os/bin on the shell path (and only once)
rt, M = env(51, 19, [])
rt.execute('''local p = ".:/rom/programs"
  shell.path = function() return p end
  shell.setPath = function(v) p = v end
  local function boot()
    local src = HOST_READ("src/startup.lua")
    src = src:gsub("local ok, choice.*", "")
    assert(load(src, "=startup", "t", _G))()
  end
  boot() boot()
  RESULT = p''')
check(rt.globals().RESULT == ".:/rom/programs:/os/bin", "startup path: %r" % rt.globals().RESULT)

print()
if fail:
    print("%d problem(s)" % len(fail))
    sys.exit(1)
print("terminal commands: ok")
