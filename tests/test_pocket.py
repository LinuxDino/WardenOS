#!/usr/bin/env python3
"""WardenOS Pocket checks (installer, pocket UI, pocket server). Run from anywhere:  python3 tests/test_pocket.py
(needs: pip install lupa). Exit code 1 on failure.

Everything runs inside the CC: Tweaked mock (tests/mock_cc.lua). A second computer is simulated by feeding
rednet_message events and reading what this one sent (M.sent). Scripted events ["host", name, ...] are built
by HOST_EVENT when they are delivered (tap a label that is on screen right now, answer the seq just sent, ...).
"""
import json, os, sys
import lupa.lua52 as lua

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENTER, F12 = 28, 88
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


manifest_rt = lua.LuaRuntime(unpack_returned_tuples=True)
MANIFEST = manifest_rt.execute(read("manifest.lua"))
POCKET = [MANIFEST.pocket[i] for i in range(1, len(MANIFEST.pocket) + 1)]
FILES = [MANIFEST.files[i] for i in range(1, len(MANIFEST.files) + 1)]


def api_text(t):
    body = {"id": "msg_1", "type": "message", "role": "assistant", "model": "claude-opus-5-5",
            "content": [{"type": "text", "text": t}], "stop_reason": "end_turn", "stop_sequence": None,
            "usage": {"input_tokens": 10, "output_tokens": 5}}
    return (200, json.dumps(body), None)


def api_tool(id_, name, inp):
    body = {"id": "msg_2", "type": "message", "role": "assistant", "model": "claude-opus-5-5",
            "content": [{"type": "text", "text": "Let me check."},
                        {"type": "tool_use", "id": id_, "name": name, "input": inp}],
            "stop_reason": "tool_use", "stop_sequence": None, "usage": {"input_tokens": 10, "output_tokens": 5}}
    return (200, json.dumps(body), None)


class Env:
    def __init__(self, events=(), lines=(), files=None, CW=26, CH=20, pocket=True, modem=True, responses=()):
        self.rt = lua.LuaRuntime(unpack_returned_tuples=True)
        g = self.rt.globals()
        self.responses = list(responses)
        self.bodies, self.problems = [], []
        g.HOST_READ = lambda p: read(p)
        g.CW, g.CH, g.MW, g.MH = CW, CH, 0, 0
        g.MODEM = modem
        if pocket:
            g.pocket = self.rt.eval("{}")
        g.HOST_API = self.api
        g.HOST_EVENT = self.host_event
        g.SCRIPT_EVENTS = self.rt.table_from([self.lua(e) for e in events])
        g.SCRIPT_LINES = self.rt.table_from(list(lines))
        self.M = self.rt.execute(read("tests/mock_cc.lua"))
        for k, v in (files or {}).items():
            self.M.FS[k] = v
        self.hosts = {"click": self.click, "timer": self.timer, "reply": self.reply}

    def lua(self, v):
        if isinstance(v, dict):
            return self.rt.table_from({k: self.lua(x) for k, x in v.items()})
        if isinstance(v, (list, tuple)):
            return self.rt.table_from([self.lua(x) for x in v])
        return v

    def api(self, body, headers):
        try:
            self.bodies.append(json.loads(body))
        except Exception as e:
            self.problems.append("request body is not JSON: %s" % e)
            self.bodies.append(None)
        if not self.responses:
            self.problems.append("unexpected API request")
            return (400, json.dumps({"type": "error", "error": {"message": "no more responses"}}), None)
        return self.responses.pop(0)

    def host_event(self, name, *args):
        ev = self.hosts[name](*args)
        return None if ev is None else self.lua(ev)

    # tap the first place where label is on screen
    def click(self, label, dx=1):
        t = self.M.native
        for y in range(1, t.h + 1):
            i = t.rows[y].find(label)
            if i >= 0:
                return ["mouse_click", 1, i + 1 + dx, y]
        self.problems.append("not on screen: %r\n%s" % (label, self.screen()))
        return None

    def timer(self):
        return ["timer", self.M.lastTimer]

    # answer the last message of type `kind` this computer sent: fn(msg) -> reply table
    def reply(self, frm, kind, what):
        for m in reversed(self.sent()):
            if m["msg"].get("t") == kind:
                return ["rednet_message", frm, REPLIES[what](m["msg"]), "wardenos"]
        self.problems.append("nothing of type %s was sent" % kind)
        return None

    def run_file(self, path, *args):
        f = self.rt.eval("function(src, name, ...) local f, e = load(src, '=' .. name, 't', _G) "
                         "if not f then return false, e end local ok, r = pcall(f, ...) return ok, r end")
        src = self.M.FS[path] if path.startswith("/") else read(path)
        return f(src, path, *args)

    def screen(self):
        t = self.M.native
        return "\n".join(t.rows[y] for y in range(1, t.h + 1))

    def fs(self):
        return {k: v for k, v in self.M.FS.items()}

    def log(self):
        return "\n".join(self.M.log.values())

    def plain(self, v):
        if lua.lua_type(v) == "table":
            keys = list(v.keys())
            if keys and all(isinstance(k, int) for k in keys):
                return [self.plain(v[i]) for i in sorted(keys)]
            return {k: self.plain(x) for k, x in v.items()}
        return v

    def sent(self):
        return [{"to": self.M.sent[i].to, "msg": self.plain(self.M.sent[i].msg) if lua.lua_type(self.M.sent[i].msg) == "table"
                 else self.M.sent[i].msg} for i in range(1, len(self.M.sent) + 1)]

    def unser(self, s):
        return self.plain(self.rt.eval("function(s) return textutils.unserialize(s) end")(s))


REPLIES = {
    "ack_ok": lambda m: {"t": "pocket_ack", "seq": m["seq"], "cmd": m["cmd"], "ok": True, "info": "started"},
    "drone_ack": lambda m: {"t": "ack", "seq": m["seq"], "cmd": m["cmd"], "ok": True, "info": "started"},
}


def status(owner, label="miner"):
    return {"t": "status", "kind": "turtle", "version": "1.3.0", "label": label, "owner": owner,
            "fuel": 500, "fuelLimit": 20000, "task": "manual", "state": "ready", "slots": 2, "selected": 1,
            "items": [], "log": ["12:00 home set", "12:01 agent started"], "homeSet": True,
            "nav": {"x": 1, "y": 0, "z": -2, "f": 0}}


def violations(env, tag):
    check(env.M.violations == 0, "%s: %d chars drawn off-screen %s" % (tag, env.M.violations,
          [l for l in env.M.log.values() if "OFFSCREEN" in l][:3]))
    check(not env.problems, "%s: %s" % (tag, env.problems))


# ---------------------------------------------------------------- 1. installer on a pocket
for script in ("install.lua", "pastebin.lua"):
    env = Env(lines=["y"], files={"/notes.txt": "keep", "/startup.lua": "print('mine')"})
    ok, err = env.run_file(script)
    fs = env.fs()
    files = sorted(k for k, v in fs.items() if isinstance(v, str))
    want = sorted(["/notes.txt", "/startup.lua", "/startup.old.lua"] +
                  ["/" + p for p in POCKET if p != "os/pocket/startup.lua"])
    check(env.M.rebooted, "pocket install via %s: no reboot (%s) %s" % (script, err, env.log()[-300:]))
    check(files == want, "pocket install via %s: files %s, want %s" % (script, files, want))
    check(fs.get("/startup.lua") == read("src/os/pocket/startup.lua"), "pocket install: /startup.lua is not the pocket one")
    check(fs.get("/startup.old.lua") == "print('mine')", "pocket install: old startup not kept")
    check(all(fs.get("/" + p) == read("src/" + p) for p in POCKET if p != "os/pocket/startup.lua"),
          "pocket install: a file was not written correctly")
    check(env.M.label == "pocket-7", "pocket install: label %s" % env.M.label)
    violations(env, "pocket install " + script)
POCKET_FS = env.fs()

# a desktop install (as a computer), then the same files on a pocket: desktop removed, player files kept
desk = Env(events=[["key", ENTER]] + [["key", 208]] * 80 + [["key", ENTER]] * 3,
           lines=["AGREE", "", "dino", "secret1", "secret1", "ERASE"], CW=51, CH=19, pocket=False)
desk.run_file("install.lua")
DESK_FS = desk.fs()
check("/os/kernel.lua" in DESK_FS and "/os/lib/pocketserver.lua" in DESK_FS, "desktop install: pocket server missing")
files = dict(DESK_FS)
files.update({"/notes.txt": "keep", "/os/claude": True, "/os/claude/key": "sk-test"})
env = Env(lines=["y"], files=files)
ok, err = env.run_file("pastebin.lua")
fs = env.fs()
check(env.M.rebooted and fs.get("/startup.lua") == read("src/os/pocket/startup.lua") and fs.get("/notes.txt") == "keep"
      and fs.get("/os/claude/key") == "sk-test" and "/os/kernel.lua" not in fs and "/os/users.dat" not in fs
      and "/os/apps" not in fs and "/os/drone" not in fs and "/startup.old.lua" not in fs
      and "/os/pocket/startup.lua" not in fs and fs.get("/os/pocket/main.lua") == read("src/os/pocket/main.lua"),
      "pocket with desktop: not converted: %s %s" % (err, sorted(fs)))

# install update on a pocket: no questions, keeps the pocket config and Claude files
files = dict(POCKET_FS)
files.update({"/os/pocket/config": '{ mode = "local" }', "/os/claude": True, "/os/claude/key": "sk-test",
              "/os/pocket/main.lua": "-- old"})
env = Env(files=files)
ok, err = env.run_file("install.lua", "update", "-y")
fs = env.fs()
check(env.M.rebooted and fs.get("/os/pocket/config") == '{ mode = "local" }' and fs.get("/os/claude/key") == "sk-test"
      and fs.get("/os/pocket/main.lua") == read("src/os/pocket/main.lua") and fs.get("/startup.old.lua") == "print('mine')",
      "pocket update failed: %s %s" % (err, env.log()[-300:]))
print("pocket install: ok" if not fail else "pocket install: FAILED")
nfail = len(fail)


def pocket_env(events, conf=None, files=None, responses=()):
    fs = dict(POCKET_FS)
    if conf:
        fs["/os/pocket/config"] = conf
    fs.update(files or {})
    return Env(events=events + [["key", F12]], files=fs, responses=responses)


def start(env):
    ok, err = env.run_file("/startup.lua")
    check(ok, "pocket crashed: %s" % err)
    check("WardenOS Pocket error" not in env.log(), "pocket error: %s" % env.log()[-400:])
    check("stopped" in env.log(), "pocket: no clean exit: %s" % env.log()[-300:])


def conf_of(env):
    return env.unser(env.fs().get("/os/pocket/config", "nil")) or {}


def sent_of(env, kind):
    return [m for m in env.sent() if m["msg"].get("t") == kind]


# ---------------------------------------------------------------- 2. first start: the mode question
shots = {}
env = pocket_env([["host", "shot", "first"], ["host", "click", "Run on this pocket only"], ["host", "shot", "home"]])
env.hosts["shot"] = lambda name: (shots.__setitem__(name, env.screen()), None)[1]
start(env)
first, home = shots.get("first", ""), shots.get("home", "")
check("Connect to a WardenOS" in first and "Run on this pocket only" in first and "recommended" in first,
      "setup: question not shown:\n" + first)
check(conf_of(env).get("mode") == "local", "setup: local choice not saved: %s" % conf_of(env))
for label in ("WardenOS Pocket", "Drones", "Claude", "Terminal", "Settings", "local", "Local mode"):
    check(label in home, "home: %r missing:\n%s" % (label, home))
violations(env, "setup local")

shots = {}
env = pocket_env([["host", "click", "Connect to a WardenOS"], ["host", "shot", "servers"]])
env.hosts["shot"] = lambda name: (shots.__setitem__(name, env.screen()), None)[1]
start(env)
check(conf_of(env).get("mode") == "server", "setup: connect choice not saved: %s" % conf_of(env))
check("Pick server" in shots.get("servers", ""), "setup: connect does not open the server list:\n" + shots.get("servers", ""))
check(any(m["to"] == "all" and m["msg"].get("t") == "ping" for m in env.sent()), "setup: no discovery ping")
violations(env, "setup connect")
print("first start: ok" if len(fail) == nfail else "first start: FAILED")
nfail = len(fail)

# ---------------------------------------------------------------- 3. connected mode: pair, drones, commands
SRV = 3
drones_reply = {"t": "pocket_drones", "server": SRV, "drones": [
    {"id": 12, "label": "miner", "owner": SRV, "task": "manual", "state": "ready", "fuel": 500, "fuelLimit": 20000,
     "online": True, "homeSet": True, "nav": {"x": 1, "y": 0, "z": -2, "f": 0},
     "log": ["12:00 home set", "12:01 agent started"], "lastTask": {"name": "dig", "ok": True, "info": "42"}},
    {"id": 14, "label": "other", "owner": 99, "task": "manual", "state": "ready", "fuel": 80, "online": False, "log": []},
]}
shots = {}
env = pocket_env([
    ["host", "click", "Connect to a WardenOS"],
    ["rednet_message", SRV, {"t": "status", "kind": "computer", "label": "base", "user": "dino", "version": "1.3.0"}, "wardenos"],
    ["rednet_message", 12, status(None), "wardenos"],
    ["host", "click", "#3 base"],
    ["host", "shot", "waiting"],
    ["rednet_message", SRV, {"t": "pocket_paired", "ok": True}, "wardenos"],
    ["host", "shot", "home"],
    ["host", "click", "Drones"],
    ["rednet_message", SRV, drones_reply, "wardenos"],
    ["host", "shot", "list"],
    ["host", "click", "#12 miner"],
    ["host", "shot", "detail"],
    ["host", "click", "Go home"],
    ["host", "reply", SRV, "pocket_cmd", "ack_ok"],
    ["host", "shot", "acked"],
    ["host", "click", "Fwd"],
    ["host", "click", " < "],
    ["host", "click", "All home"],
])
env.hosts["shot"] = lambda name: (shots.__setitem__(name, env.screen()), None)[1]
start(env)
pairs_ = sent_of(env, "pocket_pair")
check(pairs_ and pairs_[0]["to"] == SRV, "connect: pair request not sent to #3: %s" % env.sent())
check("Waiting for approval on" in shots.get("waiting", "") and "#3" in shots.get("waiting", ""),
      "connect: no waiting screen:\n" + shots.get("waiting", ""))
c = conf_of(env)
check(c.get("mode") == "server" and c.get("server") == SRV and c.get("serverLabel") == "base", "connect: config %s" % c)
check("#3" in shots.get("home", "").split("\n")[0] and "Paired" in shots.get("home", ""), "connect: home after pairing:\n" + shots.get("home", ""))
check(any(m["to"] == SRV and m["msg"].get("t") == "pocket_drones" for m in env.sent()), "connect: drones not requested")
lst = shots.get("list", "")
check("#12 miner" in lst and "fuel 500/20000" in lst and "#14 other" in lst and "owned by #99" in lst,
      "connect: drone list:\n" + lst)
det = shots.get("detail", "")
check("1 0 -2" in det and "Go home" in det and "Set home" in det and "Stop" in det and "Fwd" in det
      and "home set" in det and "server" in det, "connect: drone detail:\n" + det)
cmds = sent_of(env, "pocket_cmd")
check(len(cmds) >= 1 and cmds[0]["to"] == SRV and cmds[0]["msg"]["cmd"] == "home" and cmds[0]["msg"]["drone"] == 12
      and isinstance(cmds[0]["msg"].get("seq"), int), "connect: Go home not sent as pocket_cmd: %s" % cmds)
check("#12 home ok" in shots.get("acked", ""), "connect: ack not shown:\n" + shots.get("acked", ""))
check([m["msg"]["cmd"] for m in cmds] == ["home", "forward", "home"], "connect: commands %s" % [m["msg"] for m in cmds])
check(not any(m["msg"].get("t") == "cmd" for m in env.sent()), "connect: pocket talked to a drone directly")
violations(env, "connected")

# denied pairing, then cancel
shots = {}
env = pocket_env([
    ["host", "click", "Connect to a WardenOS"],
    ["rednet_message", SRV, {"t": "status", "kind": "computer", "label": "base"}, "wardenos"],
    ["host", "click", "#3 base"],
    ["rednet_message", SRV, {"t": "pocket_paired", "ok": False, "info": "denied"}, "wardenos"],
    ["host", "shot", "denied"],
    ["host", "click", "Try again"],
    ["host", "click", "Cancel"],
])
env.hosts["shot"] = lambda name: (shots.__setitem__(name, env.screen()), None)[1]
start(env)
check("said no" in shots.get("denied", ""), "deny: not shown:\n" + shots.get("denied", ""))
check(len(sent_of(env, "pocket_pair")) == 2 and sent_of(env, "pocket_unpair"), "deny: retry/cancel not sent")
check(conf_of(env).get("server") is None, "deny: server saved anyway")
violations(env, "pair denied")
print("connected mode: ok" if len(fail) == nfail else "connected mode: FAILED")
nfail = len(fail)

# ---------------------------------------------------------------- 4. local mode: drones directly
shots = {}
env = pocket_env([
    ["host", "click", "Drones"],
    ["rednet_message", 12, status(7), "wardenos"],
    ["rednet_message", 13, status(None, "free"), "wardenos"],
    ["host", "shot", "list"],
    ["host", "click", "#12 miner"],
    ["host", "click", "Go home"],
    ["host", "reply", 12, "cmd", "drone_ack"],
    ["host", "shot", "acked"],
    ["host", "click", "Give to Claude"],
    ["host", "click", " < "],
    ["host", "click", "#13 free"],
    ["host", "click", "Claim"],
], conf='{ mode = "local" }')
env.hosts["shot"] = lambda name: (shots.__setitem__(name, env.screen()), None)[1]
start(env)
cmds = [m for m in env.sent() if m["msg"].get("t") == "cmd"]
check(any(m["to"] == 12 and m["msg"]["cmd"] == "home" and m["msg"]["to"] == 12 for m in cmds),
      "local: Go home not sent to the drone: %s" % cmds)
check(any(m["to"] == 13 and m["msg"]["cmd"] == "claim" for m in cmds), "local: claim not sent: %s" % cmds)
check("#12 home ok" in shots.get("acked", ""), "local: ack not shown:\n" + shots.get("acked", ""))
check("free: tap to claim" in shots.get("list", ""), "local: list:\n" + shots.get("list", ""))
check("12" in env.fs().get("/os/claude/drones", ""), "local: Give to Claude not saved")
check(not sent_of(env, "pocket_cmd"), "local: went through a server")
violations(env, "local drones")
print("local mode: ok" if len(fail) == nfail else "local mode: FAILED")
nfail = len(fail)

# ---------------------------------------------------------------- 5. Claude on the pocket (local) and remote
def typed(text):
    return [["char", ch] for ch in text] + [["key", ENTER]]

shots = {}
env = pocket_env([["host", "click", "Claude"], ["host", "shot", "key"]] + typed("sk-ant-pocket")
                 + typed("hello") + [["host", "shot", "chat"]],
                 conf='{ mode = "local" }', responses=[api_text("Hi from the pocket")])
env.hosts["shot"] = lambda name: (shots.__setitem__(name, env.screen()), None)[1]
start(env)
check("Anthropic API" in shots.get("key", ""), "local claude: no key screen:\n" + shots.get("key", ""))
check(env.fs().get("/os/claude/key") == "sk-ant-pocket", "local claude: key not saved")
check("Hi from the pocket" in shots.get("chat", "") and "> hello" in shots.get("chat", ""),
      "local claude: reply not shown:\n" + shots.get("chat", ""))
b = env.bodies[0] if env.bodies else {}
check(b and set(b) == {"model", "max_tokens", "system", "tools", "messages", "output_config", "fallbacks", "cache_control"}
      and b["model"] == "claude-opus-5-5" and b["max_tokens"] == 16000 and b["fallbacks"] == "default"
      and b["messages"] == [{"role": "user", "content": "hello"}] and "tool_choice" not in b and "thinking" not in b,
      "local claude: request body %s" % b)
violations(env, "local claude")

remote_state = {"t": "pocket_claude", "busy": True, "status": "Waiting for your OK",
                "log": [{"kind": "user", "text": "dig"}, {"kind": "claude", "text": "On it."}],
                "approval": {"name": "drone_command", "text": "drone #12: dig"}}
shots = {}
env = pocket_env([["host", "click", "Claude"],
                  ["rednet_message", SRV, remote_state, "wardenos"],
                  ["host", "shot", "card"],
                  ["host", "click", "Allow"],
                  ["rednet_message", SRV, {"t": "pocket_claude", "busy": False, "status": "",
                                           "log": [{"kind": "claude", "text": "Done digging."}]}, "wardenos"],
                  ["host", "click", "new"]] + typed("thanks"),
                 conf='{ mode = "server", server = 3 }')
env.hosts["shot"] = lambda name: (shots.__setitem__(name, env.screen()), None)[1]
start(env)
ops = [m["msg"] for m in sent_of(env, "pocket_claude")]
check(ops and ops[0].get("op") == "poll", "remote claude: no poll on open: %s" % ops)
check("Allow" in shots.get("card", "") and "drone #12: dig" in shots.get("card", ""), "remote claude: card:\n" + shots.get("card", ""))
check({"t": "pocket_claude", "op": "decision", "choice": "allow"} in ops, "remote claude: decision not sent: %s" % ops)
check({"t": "pocket_claude", "op": "new"} in ops, "remote claude: new not sent: %s" % ops)
check({"t": "pocket_claude", "op": "send", "text": "thanks"} in ops, "remote claude: message not sent: %s" % ops)
check(all(m["to"] == SRV for m in sent_of(env, "pocket_claude")), "remote claude: sent to the wrong computer")
check(not env.bodies, "remote claude: the pocket called the API itself")
violations(env, "remote claude")
print("pocket claude: ok" if len(fail) == nfail else "pocket claude: FAILED")
nfail = len(fail)

# ---------------------------------------------------------------- 6. terminal, settings, update
env = pocket_env([["host", "click", "Terminal"], ["char", "x"], ["terminate"],
                  ["host", "click", "Settings"], ["host", "click", "Light"], ["host", "click", "Forget"],
                  ["host", "click", "Exit to CraftOS"]], conf='{ mode = "server", server = 3 }')
ok, err = env.run_file("/startup.lua")
check("[/rom/programs/shell.lua]" in env.log(), "terminal: shell not started")
c = conf_of(env)
check(c.get("theme") == "light" and c.get("server") is None, "settings: not saved %s" % c)
check(any(m["to"] == SRV and m["msg"].get("t") == "pocket_unpair" for m in env.sent()), "settings: unpair not sent")
check(ok and "stopped" in env.log(), "settings: exit to CraftOS failed: %s" % err)
violations(env, "settings")

env = pocket_env([["host", "click", "Settings"], ["host", "click", "Update WardenOS"]], conf='{ mode = "local" }')
ok, err = env.run_file("/startup.lua")
check(env.M.rebooted and env.fs().get("/os/pocket/config") == '{ mode = "local" }'
      and "/os/kernel.lua" not in env.fs(), "update from settings failed: %s %s" % (err, env.log()[-300:]))
print("terminal/settings: ok" if len(fail) == nfail else "terminal/settings: FAILED")
nfail = len(fail)

# ---------------------------------------------------------------- 7. the server module, unit by unit
PS = """
local S = dofile("/os/lib/pocketserver.lua")
rednet.open("back")
local function msg(from, m) return S.event({ "rednet_message", from, m, "wardenos", n = 4 }) end
local function pump()                            -- deliver queued events (http replies, decisions) to the module
  while true do
    local ok, ev = pcall(function() return table.pack(os.pullEventRaw()) end)
    if not ok then return end
    S.event(ev)
  end
end
return S, msg, pump
"""
files = dict(DESK_FS)
env = Env(files=files, CW=51, CH=19, pocket=False,
          responses=[api_tool("tu_1", "run_lua", {"code": "return 6 * 7"}), api_text("It is 42.")])
S, msg, pump = env.rt.execute(PS)
L = env.lua
last = lambda: env.sent()[-1] if env.sent() else {}

msg(20, L({"t": "pocket_drones"}))
check(last() == {"to": 20, "msg": {"t": "pocket_error", "info": "not paired", "req": "pocket_drones"}},
      "server: unpaired pocket not refused: %s" % last())
msg(20, L({"t": "pocket_cmd", "drone": 12, "cmd": "home", "seq": 1}))
check(last()["msg"].get("info") == "not paired" and not any(m["msg"].get("t") == "cmd" for m in env.sent()),
      "server: unpaired command relayed")
changed = msg(20, L({"t": "pocket_pair"}))
check(changed is True and S.prompt() is not None and S.prompt().id == 20, "server: no pairing prompt")
S.decide(True)
check(last() == {"to": 20, "msg": {"t": "pocket_paired", "ok": True}}, "server: pairing not confirmed %s" % last())
check(env.fs().get("/os/pockets") == "{[20] = true}", "server: /os/pockets %s" % env.fs().get("/os/pockets"))
check(S.prompt() is None, "server: prompt stays after the answer")
msg(20, L({"t": "pocket_pair"}))
check(last()["msg"] == {"t": "pocket_paired", "ok": True} and S.prompt() is None, "server: re-pair not immediate")
msg(21, L({"t": "pocket_pair"}))
S.decide(False)
check(last() == {"to": 21, "msg": {"t": "pocket_paired", "ok": False, "info": "denied"}} and not S.isPaired(21),
      "server: deny path %s" % last())

st = status(7)
st["log"] = ["l%d" % i for i in range(8)]
msg(12, L(st))
msg(13, L({"t": "status", "kind": "computer", "label": "pc"}))
msg(20, L({"t": "pocket_drones"}))
r = last()
ds = r["msg"].get("drones", [])
check(r["to"] == 20 and r["msg"]["t"] == "pocket_drones" and len(ds) == 1 and ds[0]["id"] == 12 and ds[0]["online"] is True
      and ds[0]["log"] == ["l0", "l1", "l2", "l3", "l4"] and ds[0]["nav"] == {"x": 1, "y": 0, "z": -2, "f": 0}
      and ds[0]["homeSet"] is True and ds[0]["fuel"] == 500 and "items" not in ds[0],
      "server: pocket_drones reply %s" % r)

msg(20, L({"t": "pocket_cmd", "drone": 12, "cmd": "home", "seq": 5}))
relay = last()
check(relay["to"] == 12 and relay["msg"]["t"] == "cmd" and relay["msg"]["cmd"] == "home" and relay["msg"]["to"] == 12
      and relay["msg"]["seq"] != 5, "server: command not relayed to the drone %s" % relay)
n = len(env.sent())
msg(13, L({"t": "ack", "seq": relay["msg"]["seq"], "cmd": "home", "ok": True}))      # wrong sender: ignored
msg(12, L({"t": "ack", "seq": relay["msg"]["seq"] + 1, "cmd": "home", "ok": True}))  # wrong seq: ignored
check(len(env.sent()) == n, "server: foreign ack relayed")
msg(12, L({"t": "ack", "seq": relay["msg"]["seq"], "cmd": "home", "ok": True, "info": "started"}))
check(last() == {"to": 20, "msg": {"t": "pocket_ack", "seq": 5, "cmd": "home", "drone": 12, "ok": True, "info": "started"}},
      "server: ack not relayed back %s" % last())
msg(20, L({"t": "pocket_cmd", "drone": 12, "cmd": "forward", "seq": 6}))
S.event(L(["timer", env.M.lastTimer]))
check(last() == {"to": 20, "msg": {"t": "pocket_ack", "seq": 6, "cmd": "forward", "drone": 12, "ok": False, "info": "no answer"}},
      "server: relay timeout %s" % last())

# Claude relay: no key, then a turn with an approval decided on the pocket
msg(20, L({"t": "pocket_claude", "op": "poll"}))
check(last()["msg"].get("error") == "No Claude key on the server; open Claude on the computer first",
      "server claude: no-key error %s" % last())
msg(20, L({"t": "pocket_claude", "op": "send", "text": "hi"}))
check("No Claude key" in str(last()["msg"].get("error")) and not env.bodies, "server claude: sent without a key")
env.M.FS["/os/claude"] = True
env.M.FS["/os/claude/key"] = "sk-server"
msg(20, L({"t": "pocket_claude", "op": "send", "text": "what is 6*7?"}))
pump()
states = [m["msg"] for m in env.sent() if m["to"] == 20 and m["msg"].get("t") == "pocket_claude"]
ap = [s for s in states if s.get("approval")]
check(ap and ap[-1]["approval"]["name"] == "run_lua" and "6 * 7" in ap[-1]["approval"]["text"] and ap[-1]["busy"] is True,
      "server claude: approval not pushed %s" % states[-2:])
msg(20, L({"t": "pocket_claude", "op": "decision", "choice": "allow"}))
pump()
final = [m["msg"] for m in env.sent() if m["to"] == 20 and m["msg"].get("t") == "pocket_claude"][-1]
texts = [(e["kind"], e["text"]) for e in final.get("log", [])]
check(final.get("busy") is False and ("claude", "It is 42.") in texts and ("user", "what is 6*7?") in texts
      and any(k == "tool" for k, _ in texts), "server claude: final state %s" % final)
check(len(env.bodies) == 2 and env.bodies[0]["system"][0]["text"].find("Pocket") >= 0
      and env.bodies[1]["messages"][-1]["role"] == "user"
      and env.bodies[1]["messages"][-1]["content"][0]["type"] == "tool_result"
      and env.bodies[1]["messages"][-1]["content"][0]["content"] == "returned: 42"
      and env.bodies[1]["messages"][1]["content"] == json.loads(api_tool("tu_1", "run_lua", {"code": "return 6 * 7"})[1])["content"],
      "server claude: request bodies %s" % env.bodies)
msg(20, L({"t": "pocket_claude", "op": "new"}))
check(last()["msg"].get("log") in ([], {}, None), "server claude: new did not clear %s" % last())

msg(20, L({"t": "pocket_unpair"}))
check(not S.isPaired(20) and "20" not in env.fs().get("/os/pockets", ""), "server: unpair not saved")
msg(20, L({"t": "pocket_drones"}))
check(last()["msg"].get("info") == "not paired", "server: unpaired pocket still served")
check(not env.problems, "server: %s" % env.problems)
print("pocket server: ok" if len(fail) == nfail else "pocket server: FAILED")
nfail = len(fail)

# ---------------------------------------------------------------- 8. the desktop kernel shows the pairing card
login = [["key", ENTER]] + [["char", ch] for ch in "secret1"] + [["key", ENTER]]
for (cw, ch) in [(51, 19), (26, 20)]:
    shots = {}
    env = Env(events=login + [["rednet_message", 20, {"t": "pocket_pair"}, "wardenos"], ["host", "shot", "card"],
                              ["host", "click", "Allow"], ["host", "shot", "after"],
                              ["rednet_message", 20, {"t": "pocket_drones"}, "wardenos"], ["key", F12]],
              files=DESK_FS, CW=cw, CH=ch, pocket=False)
    env.hosts["shot"] = lambda name: (shots.__setitem__(name, env.screen()), None)[1]
    ok, err = env.run_file("/startup.lua")
    tag = "kernel %dx%d" % (cw, ch)
    check(ok and "stopped" in env.log() and "Kernel error" not in env.log(), "%s: %s %s" % (tag, err, env.log()[-300:]))
    want = "Pocket #20 wants to connect" if cw >= 30 else "Pocket #20: connect?"
    check(want in shots.get("card", "") and "Allow" in shots.get("card", ""), "%s: no card:\n%s" % (tag, shots.get("card")))
    check("Pocket #20" not in shots.get("after", ""), "%s: card stays after Allow" % tag)
    check(env.fs().get("/os/pockets") == "{[20] = true}", "%s: pairing not stored" % tag)
    replies = [m["msg"]["t"] for m in env.sent() if m["to"] == 20]
    check(replies == ["pocket_paired", "pocket_drones"], "%s: replies %s" % (tag, replies))
    violations(env, tag)
print("kernel hook: ok" if len(fail) == nfail else "kernel hook: FAILED")
nfail = len(fail)

# ---------------------------------------------------------------- 9. what Claude does with drones: kernel top bar,
# Drones app, pocket server replies, pocket screens
def ai_status(state="working"):
    st = status(7)
    st.update({"task": "goto 1 2 3", "state": state})
    if state == "working":
        st.update({"by": {"id": 7, "who": "claude"}, "taskTime": 34,
                   "progress": {"phase": "moving", "step": 5, "total": 20, "target": {"x": 1, "y": 2, "z": 3},
                                "replans": 1}})
    else:
        st.update({"task": "manual", "lastTask": {"name": "goto 1 2 3", "ok": True, "info": "", "by": {"id": 7, "who": "claude"}}})
    return st


for (cw, ch) in [(51, 19), (26, 20)]:
    shots = {}
    env = Env(events=login + [["rednet_message", 12, ai_status(), "wardenos"], ["host", "shot", "bar"],
                              ["host", "click", "AI>#12"], ["host", "shot", "detail"],
                              ["host", "click", " < "], ["host", "shot", "list"],
                              ["host", "click", "AI>#12"], ["host", "shot", "again"],
                              ["rednet_message", 12, ai_status("ready"), "wardenos"], ["host", "shot", "done"],
                              ["key", F12]],
              files=DESK_FS, CW=cw, CH=ch, pocket=False)
    env.hosts["shot"] = lambda name: (shots.__setitem__(name, env.screen()), None)[1]
    ok, err = env.run_file("/startup.lua")
    tag = "activity %dx%d" % (cw, ch)
    check(ok and "stopped" in env.log() and "Kernel error" not in env.log(), "%s: %s %s" % (tag, err, env.log()[-300:]))
    top = shots.get("bar", "").split("\n")[0]
    want = "AI>#12 goto 1 2 3" if cw >= 40 else "AI>#12"
    check(want in top and "12:" in top and len(top) == cw, "%s: indicator not in the top bar: %r" % (tag, top))
    det = shots.get("detail", "")
    check("Claude:" in det, "%s: Drones did not open on #12:\n%s" % (tag, det))
    if cw >= 40:
        check("Claude: goto 1 2 3 - moving step 5/20 - 34s" in det and "to 1 2 3  replans 1" in det,
              "%s: banner:\n%s" % (tag, det))
        check("goto 1 2 3  5/20" in shots.get("list", ""), "%s: list row:\n%s" % (tag, shots.get("list", "")))
    check("Claude:" in shots.get("again", ""), "%s: second tap (drones_open):\n%s" % (tag, shots.get("again", "")))
    check("AI>" not in shots.get("done", "").split("\n")[0], "%s: indicator stays after the task" % tag)
    if cw >= 40:
        check("by Claude" in shots.get("done", ""), "%s: lastTask by Claude:\n%s" % (tag, shots.get("done", "")))
    violations(env, tag)
print("activity indicator: ok" if len(fail) == nfail else "activity indicator: FAILED")
nfail = len(fail)

# pocket server: pocket_drones carries by/progress/taskTime, pocket_claude lists Claude's drones
env = Env(files=dict(DESK_FS), CW=51, CH=19, pocket=False)
S, msg, pump = env.rt.execute(PS)
L = env.lua
msg(20, L({"t": "pocket_pair"}))
S.decide(True)
msg(12, L(ai_status()))
msg(20, L({"t": "pocket_drones"}))
d = (env.sent()[-1]["msg"].get("drones") or [{}])[0]
check(d.get("by") == {"id": 7, "who": "claude"} and d.get("taskTime") == 34 and d.get("progress", {}).get("step") == 5,
      "server: pocket_drones without by/progress %s" % d)
msg(20, L({"t": "pocket_claude", "op": "poll"}))
r = env.sent()[-1]["msg"]
ds = r.get("drones") or []
check(r.get("t") == "pocket_claude" and len(ds) == 1 and ds[0]["id"] == 12 and ds[0]["phase"] == "moving"
      and ds[0]["step"] == 5 and ds[0]["total"] == 20 and ds[0]["action"] == "task goto 1 2 3"
      and ds[0]["text"] == "#12 task goto 1 2 3 - moving 5/20 34s", "server: pocket_claude drones %s" % ds)
check(not env.problems, "server activity: %s" % env.problems)

# pocket screens: list tag, detail banner + target, Claude screen drone line
d12 = dict(drones_reply["drones"][0])
d12.update({"task": "goto 1 2 3", "state": "working", "by": {"id": 3, "who": "claude"}, "taskTime": 34,
            "progress": {"phase": "moving", "step": 5, "total": 20, "target": {"x": 1, "y": 2, "z": 3}, "replans": 1},
            "lastTask": {"name": "dig", "ok": True, "info": "", "by": {"id": 3, "who": "player"}}})
reply_ai = {"t": "pocket_drones", "server": SRV, "drones": [d12]}
chat_ai = {"t": "pocket_claude", "busy": False, "status": "", "log": [{"kind": "claude", "text": "Going."}],
           "drones": [{"id": 12, "action": "goto 1 2 3", "phase": "moving", "step": 5, "total": 20,
                       "text": "#12 goto 1 2 3 - moving 5/20"}]}
shots = {}
env = pocket_env([["host", "click", "Drones"], ["rednet_message", SRV, reply_ai, "wardenos"], ["host", "shot", "list"],
                  ["host", "click", "#12 miner"], ["host", "shot", "detail"], ["host", "click", " < "],
                  ["host", "click", " < "], ["host", "click", "Claude"], ["rednet_message", SRV, chat_ai, "wardenos"],
                  ["host", "shot", "claude"], ["host", "timer"]],
                 conf='{ mode = "server", server = 3 }')
env.hosts["shot"] = lambda name: (shots.__setitem__(name, env.screen()), None)[1]
start(env)
check("AI goto 1 2 3 5/20" in shots.get("list", ""), "pocket list: no AI tag:\n" + shots.get("list", ""))
det = shots.get("detail", "")
check("AI: moving 5/20 34s" in det and "To 1 2 3  r1" in det and "dig ok by you" in det, "pocket detail:\n" + det)
check("#12 goto 1 2 3 - moving 5/" in shots.get("claude", "") and "Going." in shots.get("claude", ""),
      "pocket claude: no drone line:\n" + shots.get("claude", ""))
polls = [m for m in sent_of(env, "pocket_claude") if m["msg"].get("op") == "poll"]
check(len(polls) >= 2, "pocket claude: no live poll while Claude's drone works (%d polls)" % len(polls))
violations(env, "pocket activity")
print("pocket activity: ok" if len(fail) == nfail else "pocket activity: FAILED")
nfail = len(fail)

print()
if fail:
    print("%d problem(s)" % len(fail))
    sys.exit(1)
print("all pocket checks passed")
