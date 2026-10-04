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

# end to end with CC: Tweaked's real shell. Its ROM files are CCPL-licensed, so they are not part of this repo:
# they are downloaded from the CC-Tweaked repository (branch mc-1.20.x) into tests/.cc-cache when the test runs.
CC_ROM = "https://raw.githubusercontent.com/cc-tweaked/CC-Tweaked/mc-1.20.x/projects/core/src/main/resources/data/computercraft/lua/rom/"
CC_FILES = {"programs/shell.lua": "shell.lua", "modules/main/cc/require.lua": "cc/require.lua",
            "modules/main/cc/expect.lua": "cc/expect.lua", "modules/main/cc/pretty.lua": "cc/pretty.lua",
            "modules/main/cc/internal/exception.lua": "cc/internal/exception.lua",
            "modules/main/cc/internal/error_printer.lua": "cc/internal/error_printer.lua"}
def cc_rom():
    import urllib.request
    cache = os.path.join(ROOT, "tests", ".cc-cache")
    for src, dst in CC_FILES.items():
        path = os.path.join(cache, dst)
        if not os.path.isfile(path):
            os.makedirs(os.path.dirname(path), exist_ok=True)
            try:
                with urllib.request.urlopen(CC_ROM + src, timeout=20) as r, open(path, "wb") as f:
                    f.write(r.read())
            except Exception as e:
                return None, "%s: %s" % (src, e)
    return {dst: read("tests/.cc-cache/" + dst) for dst in CC_FILES.values()}, None
CC, why = cc_rom()
if CC is None:
    print("real CC shell test skipped (could not download the CC: Tweaked ROM: %s)" % why)
# boot shell -> /startup.lua (path + aliases) -> a nested shell like the Terminal app -> type the commands
SHELL_ENV = r"""
settings = { get = function(k, d) return d end }
multishell = nil
os.run = function(env, path, ...)                 -- the real os.run: load the file with env and call it
  local f = fs.open(path, "r")
  if not f then printError("No such file " .. path) return false end
  local src = f.readAll() f.close()
  local fn, err = load(src, "@" .. path, "t", setmetatable(env, { __index = _G }))
  if not fn then printError(err) return false end
  local ok, e = pcall(fn, ...)
  if not ok then printError(e) RUN_ERRORS = (RUN_ERRORS or "") .. tostring(e) .. ";" end
  return ok
end
loadfile = function(path, mode, env)
  local f = fs.open(path, "r")
  if not f then return nil, "File not found" end
  local src = f.readAll() f.close()
  return load(src, "@" .. path, mode or "t", env or _G)
end
local realRead = read
read = function() return realRead() end
"""
for (w, h) in ([(46, 15), (26, 19)] if CC else []):
    lines = ["neofetch", "btop", "exit"]
    rt, M = env(w, h, [["timer", 1], ["char", "q"]], SHELL_ENV)
    rt.globals().SCRIPT_LINES = None
    M.FS["/rom"] = True
    M.FS["/rom/programs"] = True
    M.FS["/rom/programs/shell.lua"] = CC["shell.lua"]
    M.FS["/rom/programs/exit.lua"] = "shell.exit()"           # the ROM exit program
    for d in ("/rom/modules", "/rom/modules/main", "/rom/modules/main/cc"):
        M.FS[d] = True
    # Cobalt accepts "%%%." as a gsub replacement, PUC Lua 5.2 doesn't; "%%." means the same thing
    M.FS["/rom/modules/main/cc/require.lua"] = CC["cc/require.lua"].replace('"%%%."', '"%%."')
    M.FS["/rom/modules/main/cc/internal"] = True
    for m in ("expect", "pretty", "internal/exception", "internal/error_printer"):
        M.FS["/rom/modules/main/cc/%s.lua" % m] = CC["cc/%s.lua" % m]
    rt.execute("""require = nil package = nil
      local r = dofile("rom/modules/main/cc/require.lua")
      require, package = r.make(_G, "/")
      -- Cobalt accepts "%%%." as a gsub replacement, PUC Lua 5.2 doesn't: same search, written portably
      package.searchpath = function(name, path)
        local fname = name:gsub("%.", "/")
        for pattern in path:gmatch("[^;]+") do
          local p = pattern:gsub("%?", function() return fname end)
          if fs.exists(p) and not fs.isDir(p) then return p end
        end
        return nil, "no file for " .. name
      end""")
    boot = read("src/startup.lua").split("local ok, choice")[0]     # the part that runs before the boot menu
    rt.execute('SCRIPT_LINES_LIST = {"neofetch", "btop", "exit"}')
    rt.execute("""local i = 0
      read = function() i = i + 1 return SCRIPT_LINES_LIST[i] or "exit" end
      local top = { path = ".:/rom/programs", dir = "", aliases = {} }
      shell = {
        path = function() return top.path end, setPath = function(p) top.path = p end,
        dir = function() return top.dir end, aliases = function() return top.aliases end,
        setAlias = function(a, p) top.aliases[a] = p end, getCompletionInfo = function() return {} end,
        resolve = function(p) return p end,
      }""")
    rt.execute(boot)
    ok, err = rt.eval("""function()
      local env = setmetatable({ shell = shell, multishell = false }, { __index = _G })
      return pcall(os.run, env, "/rom/programs/shell.lua")
    end""")()
    out = "\n".join(M.written.values()) if hasattr(M.written, "values") else ""
    written = "".join(M.written.values())
    check(ok, "real shell %dx%d: %s" % (w, h, err))
    check("No such program" not in written, "real shell %dx%d: command not found:\n%s" % (w, h, screen(M)))
    check("OS: WardenOS" in written.replace("OS : ", "OS: ") or "WardenOS" in written, "real shell %dx%d: neofetch output missing" % (w, h))
    check("btop" in written, "real shell %dx%d: btop did not run" % (w, h))
    check(not rt.globals().RUN_ERRORS, "real shell %dx%d: program error %s" % (w, h, rt.globals().RUN_ERRORS))

print()
if fail:
    print("%d problem(s)" % len(fail))
    sys.exit(1)
print("terminal commands: ok")
