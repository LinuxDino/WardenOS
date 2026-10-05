#!/usr/bin/env python3
"""Terminal commands in src/os/bin (neofetch, btop):  python3 tests/test_bin.py  (needs: pip install lupa)"""
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

def env(CW, CH, events, prelude=""):
    rt = lua.LuaRuntime(unpack_returned_tuples=True)
    g = rt.globals()
    g.HOST_READ = lambda p: read(p)
    g.CW, g.CH, g.MW, g.MH = CW, CH, 0, 0
    g.MODEM = True
    g.SCRIPT_EVENTS = rt.table_from([rt.table_from(e) for e in events])
    g.SCRIPT_LINES = rt.table_from([])
    M = rt.execute(read("tests/mock_cc.lua"))
    g.MOCK = M
    for f in ("os/config.lua", "os/lib/log.lua", "os/lib/map.lua", "os/lib/cli.lua", "os/lib/sha256.lua",
              "os/lib/bigfont.lua"):
        src = read("src/" + f)
        if src is not None:
            M.FS["/" + f] = src
    for d in ("/os", "/os/lib", "/os/bin", "/os/man"):
        M.FS[d] = True
    for d in ("bin", "man"):                       # every terminal command and manual page
        for f in sorted(os.listdir(os.path.join(ROOT, "src/os", d))):
            M.FS["/os/%s/%s" % (d, f)] = read("src/os/%s/%s" % (d, f))
    rt.execute('rednet.open("back")')
    if prelude:
        rt.execute(prelude)
    return rt, M

def run(rt, path, *args):
    f = rt.eval("function(p, ...) local fn, e = loadfile and nil, nil "
                "local src = assert(fs.open(p, 'r')).readAll() "
                "fn, e = load(src, '=' .. p, 't', _G) if not fn then return false, e end "
                "local ok, r = pcall(fn, ...) return ok, r end")
    return f(path, *args)

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

# ---------------------------------------------------------------- the Linux-style commands
# a shell like CraftOS's (resolve, resolveProgram, aliases, run), CC settings, a few files to work on
SHELL_MOCK = r"""
CWD = "home"
shell.dir = function() return CWD end
shell.setDir = function(d) CWD = d end
shell.resolve = function(p)
  if p:sub(1, 1) == "/" or p:sub(1, 1) == "\\" then return fs.combine(p, "") end
  return fs.combine(CWD, p)
end
shell.path = function() return ".:/rom/programs:/os/bin" end
shell.aliases = function() return { ls = "list", cat = "/os/bin/cat.lua" } end
shell.resolveProgram = function(name)
  local a = shell.aliases()[name]
  if a then name = a end
  if name:find("/") then
    for _, p in ipairs({ name, name .. ".lua" }) do if fs.exists(p) and not fs.isDir(p) then return fs.combine(p, "") end end
    return nil
  end
  for _, dir in ipairs({ "/rom/programs", "/os/bin" }) do
    for _, p in ipairs({ dir .. "/" .. name, dir .. "/" .. name .. ".lua" }) do
      if fs.exists(p) and not fs.isDir(p) then return fs.combine(p, "") end
    end
  end
end
shell.run = function(...)
  local t = {}
  for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end
  RUNS = (RUNS or "") .. table.concat(t, " ") .. ";"
  return true
end
settings = { getNames = function() return { "shell.allow_disk_startup", "motd.enable" } end,
             get = function(k) if k == "motd.enable" then return false end return true end }
HOST_EVENT = function(kind, a, b)
  if kind == "timer" then return { "timer", MOCK.lastTimer } end
  if kind == "grow" then                                   -- tail -f: the file grows, then a tick
    MOCK.FS[a] = MOCK.FS[a] .. b
    return { "timer", MOCK.lastTimer }
  end
end
"""
NOTES = "apple pie\\nBanana split\\ncherry\\n\\nApple juice\\ndate 42\\n"
FILES = r"""
fs.makeDir("/home/sub/deep")
local function put(p, s) local f = fs.open(p, "w") f.write(s) f.close() end
put("/home/notes.txt", "%s")
put("/home/sub/a.lua", "print('apple')\nreturn 1\n")
put("/home/sub/deep/b.txt", string.rep("x", 2048))
put("/home/nums.txt", "10\n9\n100\n-3\n9\n")
put("/home/.hidden", "secret apple\n")
""" % NOTES
TICKS = [["host", "timer"]] * 4 + [["char", "q"]]
ART_STUB = r"""
MOCK.FS["/os/lib/art.lua"] = [[
local A = {}
function A.get(name, size)
  if name ~= "warden" then return nil end
  local w = size == "medium" and 14 or 8
  local rows = {}
  for i = 1, (size == "medium" and 10 or 6) do
    rows[i] = { ("WARDEN" .. i .. string.rep("#", w)):sub(1, w), string.rep("9", w), string.rep("f", w) }
  end
  return { w = w, h = #rows, rows = rows }
end
return A
]]
"""

def cmd_env(w, h, events=None, lines=None, pre="", art=False):
    rt, M = env(w, h, TICKS if events is None else events, SHELL_MOCK + FILES + (ART_STUB if art else "") + pre)
    if lines is not None:
        rt.globals().SCRIPT_LINES = rt.table_from(lines)
        rt.execute("local L = SCRIPT_LINES read = function() local l = table.remove(L, 1) "
                   "if not l then error('SCRIPT_END', 0) end return l end")
    return rt, M

def text_of(M):
    return "\n".join(M.native.rows[y].rstrip() for y in range(1, M.native.h + 1)).strip("\n")

def cmd(name, *args, w=51, h=70, events=None, lines=None, pre="", art=False):
    rt, M = cmd_env(w, h, events, lines, pre, art)
    ok, err = run(rt, "/os/bin/%s.lua" % name, *args)
    check(ok, "%s %s at %dx%d crashed: %s" % (name, " ".join(args), w, h, err))
    check(M.violations == 0, "%s %s at %dx%d: %d chars off-screen %s" % (name, " ".join(args), w, h, M.violations,
          [M.log[i] for i in range(1, len(M.log) + 1) if str(M.log[i]).startswith("OFFSCREEN")][:3]))
    return text_of(M), rt, M

# typical arguments for every command in src/os/bin (all of them must be listed here)
TYPICAL = {
    "cat": ["-n", "notes.txt"], "head": ["-n", "2", "notes.txt"], "tail": ["-3", "notes.txt"],
    "grep": ["-in", "apple", "notes.txt"], "wc": ["notes.txt", "nums.txt"], "touch": ["new.txt"],
    "tree": ["/home"], "du": ["-h", "/home"], "df": [], "free": [], "uname": ["-a"], "whoami": [],
    "hostname": [], "pwd": [], "uptime": [], "date": [], "cal": [], "which": ["cat", "nope"], "man": ["cat"],
    "env": [], "printenv": ["PATH"], "ps": ["-a"], "top": [], "htop": [], "ping": ["-c", "1", "12"],
    "ifconfig": [], "ip": ["a"], "nano": ["x.txt"], "vim": ["x.txt"], "vi": [":q"], "sudo": ["ls", "/"],
    "yes": ["hello"], "echo": ["{red}hot", "{blue}cold"], "rev": ["hello", "world"], "sort": ["-n", "nums.txt"],
    "seq": ["3"], "factor": ["360", "97"], "base64": ["hello"], "sha256sum": ["-s", "abc", "notes.txt"],
    "cowsay": ["moo", "moo", "this is a longer sentence for the bubble"], "fortune": [], "sl": [], "cmatrix": [],
    "lolcat": ["notes.txt"], "figlet": ["Hi 42!"], "banner": ["WOW"], "asciiquarium": [], "hollywood": [],
    "pacman": ["-Syu"], "less": ["notes.txt"], "more": ["notes.txt"], "neofetch": [], "btop": [],
}
bins = sorted(f[:-4] for f in os.listdir(os.path.join(ROOT, "src/os/bin"))
              if f.endswith(".lua") and f != "apt.lua")          # apt (App Store) is tested on its own
check(sorted(TYPICAL) == bins, "TYPICAL does not cover src/os/bin: %s" % sorted(set(bins) ^ set(TYPICAL)))
man_dir = os.path.join(ROOT, "src/os/man")
for b in bins:
    check(os.path.isfile(os.path.join(man_dir, b + ".txt")), "no manual page /os/man/%s.txt" % b)
for f in os.listdir(man_dir):
    page = read("src/os/man/" + f)
    check(all(ord(c) < 128 for c in page), "man/%s: not ASCII" % f)
    check("NAME" in page and "SYNOPSIS" in page and "DESCRIPTION" in page, "man/%s: missing a section" % f)

for (w, h) in [(51, 19), (26, 20), (39, 13)]:
    for name in bins:
        lines = ["hunter2"] if name == "sudo" else None
        for args in (TYPICAL.get(name, []), ["--help"]):
            cmd(name, *args, w=w, h=h, lines=lines)

# output checks (a tall screen, so nothing scrolls away)
out, _, _ = cmd("cat", "-n", "notes.txt")
check("     1  apple pie" in out and "     6  date 42" in out and "\n     4\n" in out, "cat -n:\n" + out)
out, _, _ = cmd("cat", "nope.txt")
check("cat: nope.txt: No such file or directory" in out, "cat missing file:\n" + out)
out, _, _ = cmd("head", "-n", "2", "notes.txt")
check(out == "apple pie\nBanana split", "head -n 2:\n" + out)
out, _, _ = cmd("head", "-1", "notes.txt")
check(out == "apple pie", "head -1:\n" + out)
out, _, _ = cmd("tail", "-n", "2", "notes.txt")
check(out == "Apple juice\ndate 42", "tail -n 2:\n" + out)
out, _, _ = cmd("grep", "-i", "apple", "notes.txt")
check(out == "apple pie\nApple juice", "grep -i:\n" + out)
out, _, _ = cmd("grep", "-n", "an", "notes.txt")
check(out == "2:Banana split", "grep -n:\n" + out)
out, _, _ = cmd("grep", "-v", "a", "notes.txt")
check(out == "cherry\n\nApple juice", "grep -v:\n" + repr(out))
out, _, _ = cmd("grep", "-r", "apple", "/home")
check("/home/notes.txt:apple pie" in out and "/home/sub/a.lua:print('apple')" in out
      and ".hidden:secret apple" in out, "grep -r:\n" + out)
out, _, _ = cmd("grep", "-c", "%d+", "notes.txt")
check(out == "1", "grep -c pattern:\n" + out)
out, _, _ = cmd("grep", "-F", "%d", "notes.txt")
check(out == "", "grep -F is plain:\n" + out)
out, _, _ = cmd("grep", "(", "notes.txt")
check("grep: bad pattern" in out, "grep bad pattern:\n" + out)
out, _, _ = cmd("wc", "notes.txt")
check(out.split() == ["6", "9", "51", "notes.txt"], "wc:\n" + out)
out, _, _ = cmd("wc", "-l", "notes.txt", "nums.txt")
check(out == " 6 notes.txt\n 5 nums.txt\n11 total", "wc -l:\n" + out)
_, _, M = cmd("touch", "new.txt", "notes.txt")
check(M.FS["/home/new.txt"] == "" and M.FS["/home/notes.txt"] == NOTES.replace("\\n", "\n"), "touch")
out, _, _ = cmd("tree", "/home")
check(out.split("\n") == ["/home", "|-- sub", "|   |-- deep", "|   |   `-- b.txt", "|   `-- a.lua",
                          "|-- notes.txt", "`-- nums.txt", "", "2 directories, 4 files"], "tree:\n" + out)
out, _, _ = cmd("tree", "-L", "1", "-a", "/home")
check("|-- .hidden" in out and "deep" not in out and "1 directory, 3 files" in out, "tree -L 1 -a:\n" + out)
out, _, _ = cmd("du", "-h", "/home")
check([l.split() for l in out.split("\n")] == [["2.0K", "/home/sub/deep"], ["2.0K", "/home/sub"], ["2.1K", "/home"]],
      "du -h:\n" + out)
out, _, _ = cmd("du", "-s", "/home")
check(out.split() == ["3", "/home"], "du -s (KB):\n" + out)
out, _, _ = cmd("df")
check("hdd" in out and "976.6K" in out and "97.7K" in out and "10%" in out and "[" in out, "df:\n" + out)
out, _, _ = cmd("df", w=26)
check("hdd /" in out and "97.7K of 976.6K used" in out and "read-only" in out, "df narrow:\n" + out)
out, _, _ = cmd("free")
check("Lua:" in out and "Disk:" in out and "977" in out and "RAM: n/a" in out, "free:\n" + out)
out, _, _ = cmd("uname", "-a", w=80, pre='_HOST = "ComputerCraft 1.109.2 (Minecraft 1.20.1)"')
check(out == "WardenOS 1.6.1 CC: Tweaked 1.109.2 (Minecraft 1.20.1) Advanced Computer".replace(
    "1.6.1", re.search(r'version\s*=\s*"([^"]+)"', read("src/os/config.lua")).group(1)), "uname -a:\n" + out)
out, _, _ = cmd("uname")
check(out == "WardenOS", "uname: " + out)
out, _, _ = cmd("whoami", pre=DRONES)
check(out == "dino", "whoami (desktop): " + out)
out, _, _ = cmd("whoami", pre="os.setComputerLabel('base')")
check(out == "base", "whoami (label): " + out)
out, rt, M = cmd("hostname", "mybox")
check(M.label == "mybox", "hostname sets the label")
out, _, _ = cmd("hostname")
check(out == "computer-7", "hostname: " + out)
out, _, _ = cmd("pwd")
check(out == "/home", "pwd: " + out)
out, _, _ = cmd("uptime", pre='dofile("/os/lib/log.lua").add("event", "timer")')
check(out.startswith(tuple("0123456789")) and " up 0h 00m, 0 users, load: 1 ev/min" in out, "uptime:\n" + out)
out, _, _ = cmd("date", "+%Y")
check(out.isdigit() and len(out) == 4, "date +%Y: " + out)
out, _, _ = cmd("date", "-m")
check(out == "Minecraft day 1, 12:00", "date -m: " + out)
out, _, _ = cmd("cal", "2", "2024")
check(out.split("\n") == ["   February 2024", "Su Mo Tu We Th Fr Sa", "             1  2  3",
                          " 4  5  6  7  8  9 10", "11 12 13 14 15 16 17", "18 19 20 21 22 23 24",
                          "25 26 27 28 29"], "cal 2 2024:\n" + out)
out, _, _ = cmd("cal", "-m", "9", "2025")
check(out.split("\n")[2] == " 1  2  3  4  5  6  7", "cal -m 9 2025:\n" + out)
out, _, _ = cmd("which", "cat", "fortune", "nope")
check(out.split("\n")[:2] == ["/os/bin/cat.lua", "/os/bin/fortune.lua"] and "which: no nope in" in out, "which:\n" + out)
out, _, _ = cmd("man", "grep")
check(out.startswith("NAME") and "SYNOPSIS" in out and "grep" in out, "man grep:\n" + out)
out, rt, _ = cmd("man", "hello", pre='fs.makeDir("/rom/programs") MOCK.FS["/rom/programs/hello.lua"] = "print(1)"')
check(rt.globals().RUNS == "hello --help;", "man without a page runs --help: %r" % rt.globals().RUNS)
out, _, _ = cmd("man", "nothing")
check("No manual entry for nothing" in out, "man nothing:\n" + out)
out, _, _ = cmd("man", "-k", "rainbow")
check("lolcat" in out, "man -k:\n" + out)
out, _, M = cmd("man", "man", w=26, h=8, events=[["key", 208], ["char", " "], ["char", "q"]])
check("q:quit" in "".join(M.written.values()) or " q" in "".join(M.written.values()), "man pager status line")
out, _, _ = cmd("env")
check("PATH=.:/rom/programs:/os/bin" in out and "PWD=/home" in out and "motd.enable=false" in out, "env:\n" + out)
out, _, _ = cmd("printenv", "PWD")
check(out == "/home", "printenv PWD: " + out)
out, _, _ = cmd("ps", "-a", pre=DRONES + "\nWardenOS.apps = { 'files', 'terminal' }")
check("bios" in out and "kernel" in out and "[files]" in out and "shell" in out, "ps:\n" + out)
for name in ("top", "htop"):
    out, rt, _ = cmd(name)
    check(rt.globals().RUNS == "/os/bin/btop.lua;", "%s runs btop: %r" % (name, rt.globals().RUNS))
out, _, _ = cmd("ifconfig")
check("back: <UP,BROADCAST,RUNNING>" in out and "rednet open" in out and "id #7" in out, "ifconfig:\n" + out)
out, _, _ = cmd("ip")
check("2: back: <BROADCAST,UP>" in out and "inet #7" in out, "ip:\n" + out)
out, rt, _ = cmd("nano", "x.txt")
check(rt.globals().RUNS == "edit x.txt;", "nano: %r" % rt.globals().RUNS)
out, rt, _ = cmd("vim", "x.txt")
check(rt.globals().RUNS == "edit x.txt;" and out, "vim: %r" % rt.globals().RUNS)
out, rt, _ = cmd("vi", ":q")
check("E37" in out and not rt.globals().RUNS, "vi :q:\n" + out)
# sudo: the lecture + password the first time, then just the command
rt, M = cmd_env(51, 40, lines=["hunter2"])
ok, err = run(rt, "/os/bin/sudo.lua", "ls", "/")
ok2, err2 = run(rt, "/os/bin/sudo.lua", "edit", "x")
out = text_of(M)
check(ok and ok2, "sudo crashed: %s %s" % (err, err2))
check("usual lecture" in out and "[sudo] password for computer-7:" in out and out.count("usual lecture") == 1,
      "sudo lecture:\n" + out)
check(rt.globals().RUNS == "ls /;edit x;", "sudo runs the command: %r" % rt.globals().RUNS)
out, rt, _ = cmd("sudo", "make", "me", "a", "sandwich")
check(out == "Okay." and not rt.globals().RUNS, "sudo sandwich: " + out)
out, _, M = cmd("yes", "hi", h=10)
check(out.split("\n") == ["hi"] * 9 and M.lastTimer >= 4, "yes:\n" + out)
out, _, M = cmd("yes", h=10, events=[["host", "timer"], ["terminate"]])
check(out.split("\n")[0] == "y", "yes stops on Ctrl+T")
out, _, _ = cmd("echo", "-n", "{red}a", "{reset}b")
check(out == "a b", "echo: " + out)
out, _, _ = cmd("echo", "-e", "a\\nb")
check(out == "a\nb", "echo -e: " + out)
out, _, _ = cmd("rev", "hello", "world")
check(out == "dlrow olleh", "rev text: " + out)
out, _, _ = cmd("rev", "nums.txt")
check(out.split("\n")[:3] == ["01", "9", "001"], "rev file:\n" + out)
out, _, _ = cmd("sort", "notes.txt")
check(out.split("\n") == ["Apple juice", "Banana split", "apple pie", "cherry", "date 42"], "sort:\n" + out)
out, _, _ = cmd("sort", "-n", "-r", "-u", "nums.txt")
check(out.split("\n") == ["100", "10", "9", "-3"], "sort -nru:\n" + out)
out, _, _ = cmd("seq", "3")
check(out == "1\n2\n3", "seq 3: " + out)
out, _, _ = cmd("seq", "10", "-3", "0")
check(out == "10\n7\n4\n1", "seq 10 -3 0: " + out)
out, _, _ = cmd("seq", "-s", ",", "-w", "8", "10")
check(out == "08,09,10", "seq -s -w: " + out)
out, _, _ = cmd("seq", "-2", "0")
check(out == "-2\n-1\n0", "seq negative: " + out)
out, _, _ = cmd("factor", "360", "97", "1", "600851475143")
check(out == "360: 2 2 2 3 3 5\n97: 97\n1:\n600851475143: 71 839 1471 6857", "factor:\n" + out)
for text in ("hello", "Man", "Ma", "M", "any carnal pleasure."):
    out, _, _ = cmd("base64", "-w", "0", text)
    import base64 as b64
    check(out == b64.b64encode(text.encode()).decode(), "base64 %s: %s" % (text, out))
    back, _, _ = cmd("base64", "-d", out)
    check(back == text, "base64 -d %s: %s" % (out, back))
out, _, _ = cmd("base64", "notes.txt", w=26)
check("".join(out.split("\n")) == b64.b64encode(NOTES.replace("\\n", "\n").encode()).decode(), "base64 file:\n" + out)
out, _, _ = cmd("sha256sum", "-s", "abc", w=80)
check(out.startswith("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"), "sha256sum abc: " + out)
out, _, _ = cmd("sha256sum", "notes.txt", w=26)
import hashlib
check(hashlib.sha256(NOTES.replace("\\n", "\n").encode()).hexdigest()[:26] in out, "sha256sum file:\n" + out)
out, _, _ = cmd("cowsay", "moo")
check(out.split("\n")[:3] == [" _____", "< moo >", " -----"] and "(oo)" in out, "cowsay:\n" + out)
out, _, _ = cmd("cowsay", "-f", "tux", "hi", w=26)
check("|o_o |" in out, "cowsay -f tux:\n" + out)
out, _, _ = cmd("cowsay", "-f", "warden", "Shhh")
check("< Shhh >" in out and "\\\\.--.//" in out, "cowsay -f warden (ASCII):\n" + out)
out, _, _ = cmd("cowsay", "-f", "warden", "Shhh", art=True)
check("< Shhh >" in out and "WARDEN1" in out and ".--." not in out, "cowsay -f warden (art.lua):\n" + out)
for w in (26, 39):
    cmd("cowsay", "-f", "warden", "a long text that has to wrap in the bubble", w=w, h=13, art=True)
    cmd("cowsay", "a long text that has to wrap in the bubble", w=w, h=13)
out, _, _ = cmd("fortune")
check(len(out) > 10, "fortune: " + out)
out, _, _ = cmd("fortune", "-c")
check(out.startswith(" _") and "(oo)" in out, "fortune -c:\n" + out)
out, _, _ = cmd("lolcat", "hello")
check(out == "hello", "lolcat text: " + out)
out, _, _ = cmd("figlet", "-t", "AM")
check(out.split("\n")[:5] == [" #  #   #", "# # ## ##", "### # # #", "# # #   #", "# # #   #"], "figlet:\n" + out)
out, _, _ = cmd("banner", "W")
check(out.split("\n")[:5] == ["# #", "# #", "# #", "###", "# #"], "banner uses bigfont's W:\n" + out)
out, _, _ = cmd("figlet", "-t", "hello world", w=26)
check(len(out.split("\n")) >= 11, "figlet wraps on narrow screens:\n" + out)
out, _, _ = cmd("pacman", "-S", "neofetch", w=80)
check("unless you are Arch" in out and "btw" in out, "pacman:\n" + out)
out, _, _ = cmd("less", "notes.txt")
check(out.startswith("apple pie"), "less on a short file prints it:\n" + out)
# full-screen and looping commands stop on q and on Ctrl+T
for name, args in [("sl", []), ("cmatrix", []), ("hollywood", []), ("asciiquarium", []), ("yes", []),
                   ("tail", ["-f", "notes.txt"]), ("less", ["/os/lib/cli.lua"]), ("man", ["grep"])]:
    for stop in (["char", "q"], ["terminate"]):
        for (w, h) in [(51, 19), (26, 20), (39, 13)]:
            cmd(name, *args, w=w, h=h, events=[["host", "timer"]] * 6 + [stop])
_, _, M = cmd("sl", events=[["host", "timer"]] * 200)          # runs to the end on its own
check(M.lastTimer < 200, "sl ends by itself")
# tail -f prints what is appended
out, _, _ = cmd("tail", "-f", "-n", "1", "notes.txt",
                events=[["host", "timer"], ["host", "grow", "/home/notes.txt", "new line\npart"], ["host", "timer"],
                        ["host", "grow", "/home/notes.txt", "ial\n"], ["char", "q"]])
check(out == "date 42\nnew line\npartial", "tail -f:\n" + out)
# ping: a status reply over rednet, then a timeout
PING_EV = """for i = 1, #SCRIPT_EVENTS do
  local e = SCRIPT_EVENTS[i]
  if e[3] == "STATUS" then e[3] = { t = "status", kind = "turtle", label = "miner" } end
end"""
out, rt, M = cmd("ping", "-c", "2", "12", events=[["rednet_message", 12, "STATUS", "wardenos"], ["host", "timer"],
                                                ["host", "timer"]], pre=PING_EV)
sent = [M.sent[i] for i in range(1, len(M.sent) + 1)]
check(len(sent) == 2 and sent[0].to == 12 and sent[0].proto == "wardenos" and sent[0].msg.t == "ping", "ping sends")
check("bytes from #12 (miner): seq=1 turtle time=0 ms" in out and "Request timeout for seq 2" in out
      and "2 sent, 1 received, 50% loss" in out, "ping:\n" + out)
out, rt, M = cmd("ping", "-c", "1", "miner", events=[["rednet_message", 12, "STATUS", "wardenos"],
                                                   ["rednet_message", 12, "STATUS", "wardenos"]], pre=PING_EV)
check("PING miner (#12)" in out and "1 received" in out, "ping by label:\n" + out)
out, _, _ = cmd("ping", "miner", events=[["rednet_message", 12, "STATUS", "wardenos"], ["char", "q"]],
                pre=PING_EV + "\n" + DRONES)
check("PING miner (#12)" in out and "1 sent, 1 received" in out, "ping (desktop drones, q):\n" + out)
# the look & feel engineer's real art.lua, when it is there
if read("src/os/lib/art.lua"):
    REAL_ART = 'MOCK.FS["/os/lib/art.lua"] = HOST_READ("src/os/lib/art.lua")'
    for (w, h) in [(51, 19), (46, 17), (39, 13), (26, 20)]:
        out, _, M = cmd("neofetch", w=w, h=h, pre=REAL_ART)
        check("OS: WardenOS" in out, "neofetch with art.lua %dx%d:\n%s" % (w, h, out))
        out, _, M = cmd("cowsay", "-f", "warden", "Shhh", w=w, h=h, pre=REAL_ART)
        check("< Shhh >" in out and ".--." not in out, "cowsay -f warden with art.lua %dx%d:\n%s" % (w, h, out))
# neofetch with the colored Warden from art.lua
for (w, h) in [(51, 19), (46, 17), (39, 13), (26, 20)]:
    out, _, M = cmd("neofetch", w=w, h=h, art=True)
    check(("WARDEN1" in out) == (w >= 40) and "OS: WardenOS" in out, "neofetch art %dx%d:\n%s" % (w, h, out))

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
    M.FS["/rom/programs/cd.lua"] = ("local d = shell.resolve(... or '') "    # a stand-in for the ROM cd program
                                    "if fs.isDir(d) then shell.setDir(d) else print('Not a directory') end")
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
    rt.execute('SCRIPT_LINES_LIST = {"neofetch", "btop", "cowsay moo", "cd /os", "pwd", "cat -n config.lua", '
               '"grep -n version config.lua", "which cat", "echo {green}all good", "exit"}')
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
    log = "\n".join(str(M.log[i]) for i in range(1, len(M.log) + 1))
    check("< moo >" in written and "(oo)" in written, "real shell %dx%d: cowsay missing" % (w, h))
    check("     1  -- WardenOS config" in written.replace("\n", ""), "real shell %dx%d: cat -n missing" % (w, h))
    check("/os" in written and "version" in written and "/os/bin/cat.lua" in written,
          "real shell %dx%d: pwd/grep/which output missing:\n%s" % (w, h, screen(M)))
    check("all good" in written and "No such" not in written, "real shell %dx%d: echo missing" % (w, h))

print()
if fail:
    print("%d problem(s)" % len(fail))
    sys.exit(1)
print("terminal commands: ok")
