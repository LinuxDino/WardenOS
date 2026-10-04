#!/usr/bin/env python3
"""Claude app checks (no kernel, no network). Run from anywhere:  python3 tests/test_claude.py   (needs: pip install lupa)

Runs /os/apps/claude.lua's main() inside the CC: Tweaked mock (tests/mock_cc.lua) against a fake Messages API
(HOST_API, below), drives it with scripted events and checks every request against the API contract.
Scripted events of the form ["host", name, ...] are built by HOST_EVENT at the moment they are delivered
(clicking a button found on screen, answering with the seq the app just sent, the timer it just started...).
"""
import json, os, sys
import lupa.lua52 as lua

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
URL = "https://api.anthropic.com/v1/messages"
CW, CH = 48, 18
ENTER = 28
TOOL_NAMES = {"run_lua", "list_files", "read_file", "write_file", "list_peripherals", "call_peripheral",
              "network_scan", "drone_command", "drone_task", "drone_status", "drone_scan",
              "map_view", "map_find", "map_info", "protect_area"}
BODY_KEYS = {"model", "max_tokens", "system", "tools", "messages", "output_config", "fallbacks", "cache_control"}

failed = []


def read(rel):
    with open(os.path.join(ROOT, rel), "rb") as f:
        return f.read().decode("latin-1")


def typed(text):
    return [["char", c] for c in text] + [["key", ENTER]]


def reply(content, stop="end_turn"):
    body = {"id": "msg_1", "type": "message", "role": "assistant", "model": "claude-opus-5-5", "content": content,
            "stop_reason": stop, "stop_sequence": None,
            "usage": {"input_tokens": 10, "output_tokens": 5, "cache_read_input_tokens": 0}}
    return (200, json.dumps(body, ensure_ascii=False).encode("utf-8"), None)


def error(status, message, kind="api_error", retry_after=None):
    body = {"type": "error", "error": {"type": kind, "message": message}}
    return (status, json.dumps(body).encode("utf-8"), retry_after)


def text(t):
    return {"type": "text", "text": t}


def tool_use(id_, name, inp):
    return {"type": "tool_use", "id": id_, "name": name, "input": inp}


THINKING = {"type": "thinking", "thinking": "", "signature": "sig=="}


class Env:
    """One run of the Claude app in a fresh mock."""

    def __init__(self, events, responses, key="sk-ant-test", modem=False, files=None, prelude="", crash_ok=False):
        self.rt = lua.LuaRuntime(unpack_returned_tuples=True)
        g = self.rt.globals()
        self.responses = list(responses)
        self.bodies, self.raw, self.snaps, self.problems = [], [], {}, []
        self.hosts = {"click": self.click, "snap": self.snap, "tick": self.tick}
        g.HOST_READ = lambda p: None
        g.CW, g.CH, g.MW, g.MH = CW, CH, 0, 0
        g.MODEM = modem
        g.SCRIPT_EVENTS = self.rt.table_from([self.lua(e) for e in events])
        g.SCRIPT_LINES = self.rt.table_from([])
        g.HOST_API = self.api
        g.HOST_EVENT = self.host_event
        self.M = self.rt.execute(read("tests/mock_cc.lua"))
        for p in ("os/apps/claude.lua", "os/lib/claude.lua", "os/lib/claudetools.lua", "os/lib/json.lua",
                  "os/lib/map.lua"):
            self.M.FS["/" + p] = read("src/" + p)
        for d in ("/os", "/os/apps", "/os/lib"):
            self.M.FS[d] = True
        if key:
            self.M.FS["/os/claude"] = True
            self.M.FS["/os/claude/key"] = key
        for k, v in (files or {}).items():
            self.M.FS[k] = v
        self.prelude = prelude
        self.crash_ok = crash_ok

    # Python value -> Lua value (nested)
    def lua(self, v):
        if isinstance(v, dict):
            return self.rt.table_from({k: self.lua(x) for k, x in v.items()})
        if isinstance(v, (list, tuple)):
            return self.rt.table_from([self.lua(x) for x in v])
        return v

    def api(self, body, headers):
        self.raw.append(body)
        try:
            self.bodies.append(json.loads(body))
        except Exception as e:
            self.problems.append("request body is not JSON: %s" % e)
            self.bodies.append(None)
        if not self.responses:
            self.problems.append("unexpected extra request #%d" % len(self.bodies))
            return error(400, "no more scripted responses")
        r = self.responses.pop(0)
        return r(self) if callable(r) else r

    def host_event(self, name, *args):
        ev = self.hosts[name](*args)
        return None if ev is None else self.lua(ev)

    def screen(self):
        t = self.M.native
        return "\n".join(t.rows[y] for y in range(1, t.h + 1))

    def find(self, label, min_row=1):
        t = self.M.native
        for y in range(min_row, t.h + 1):
            i = t.rows[y].find(label)
            if i >= 0:
                return i + 1, y
        return None

    def click(self, label):
        pos = self.find(label, 2) or self.find(label)
        if not pos:
            self.problems.append("button %r not on screen:\n%s" % (label, self.screen()))
            return None
        return ["mouse_click", 1, pos[0], pos[1]]

    def snap(self, name):
        self.snaps[name] = self.screen()
        return None

    def tick(self):
        return ["timer", self.M.lastTimer]

    def sent(self):
        out = []
        for i in range(1, len(self.M.sent) + 1):
            out.append(self.M.sent[i])
        return out

    def run(self):
        g = self.rt.globals()
        g.WardenOS = self.rt.eval("""{ theme = { bg = colors.black, panel = colors.gray, text = colors.white,
            dim = colors.lightGray, accent = colors.cyan, good = colors.green, bad = colors.red, warn = colors.yellow },
            version = "1.3.0" }""")
        f = self.rt.eval("function(pre) local p = assert(load(pre, '=prelude', 't', _G)) p() "
                         "return pcall(function() dofile('/os/apps/claude.lua').main() end) end")
        ok, err = f(self.prelude)
        self.written = "".join(self.M.written[i] for i in range(1, len(self.M.written) + 1))
        if ok or err != "SCRIPT_END":
            self.problems.append("app did not run to the end of the script: %r" % (err,))
        if not self.crash_ok and "crashed" in self.written:
            self.problems.append("the app reported a crash")
        if self.M.violations != 0:
            self.problems.append("%d characters drawn off-screen" % self.M.violations)
        if self.responses:
            self.problems.append("%d scripted responses were never requested" % len(self.responses))
        for i in range(1, len(self.M.requests) + 1):
            self.contract(self.M.requests[i], self.raw[i - 1] if i <= len(self.raw) else None,
                          self.bodies[i - 1] if i <= len(self.bodies) else None, i)
        return self

    # every point of the request contract
    def contract(self, req, raw, b, n, model=None, effort=None):
        p = lambda msg: self.problems.append("request %d: %s" % (n, msg))
        if req.url != URL: p("url %r" % req.url)
        if req.method != "POST": p("method %r" % req.method)
        if req.binary is not True: p("not binary")
        hdr = dict(req.headers.items())
        want = {"Content-Type": "application/json", "x-api-key": self.M.FS["/os/claude/key"],
                "anthropic-version": "2023-06-01", "anthropic-beta": "server-side-fallback-2026-07-01"}
        if hdr != want: p("headers %r" % hdr)
        if b is None: return
        if set(b) != BODY_KEYS: p("body keys %s" % sorted(b))
        if b.get("model") not in ("claude-opus-5-5", "claude-sonnet-5-5"): p("model %r" % b.get("model"))
        if b.get("max_tokens") != 16000 or not isinstance(b.get("max_tokens"), int): p("max_tokens")
        sysb = b.get("system")
        if not (isinstance(sysb, list) and len(sysb) == 1 and set(sysb[0]) == {"type", "text"}
                and sysb[0]["type"] == "text" and sysb[0]["text"].strip()):
            p("system %r" % (sysb,))
        tools = b.get("tools")
        if not isinstance(tools, list) or {t.get("name") for t in tools} != TOOL_NAMES or len(tools) != len(TOOL_NAMES):
            p("tools list")
        for t in tools or []:
            s = t.get("input_schema")
            if set(t) != {"name", "description", "input_schema"}: p("tool %s keys %s" % (t.get("name"), sorted(t)))
            if not (isinstance(s, dict) and s.get("type") == "object" and isinstance(s.get("properties"), dict)
                    and isinstance(s.get("required"), list) and all(r in s["properties"] for r in s["required"])
                    and all(isinstance(v, dict) for v in s["properties"].values())):
                p("tool %s schema %r" % (t.get("name"), s))
        if '"properties":[]' in raw or '"required":{}' in raw: p("empty schema part with the wrong JSON type")
        if b.get("output_config", {}).get("effort") not in ("low", "medium", "high") or set(b.get("output_config", {})) != {"effort"}:
            p("output_config %r" % b.get("output_config"))
        if b.get("fallbacks") != "default": p("fallbacks")
        if b.get("cache_control") != {"type": "ephemeral"}: p("cache_control")
        msgs = b.get("messages") or []
        for i, m in enumerate(msgs):
            if set(m) != {"role", "content"} or m["role"] != ("user" if i % 2 == 0 else "assistant"):
                p("message %d %r" % (i, m))
            if m["role"] == "user" and isinstance(m["content"], list):
                prev = msgs[i - 1]["content"] if i > 0 else []
                ids = [x["id"] for x in prev if x.get("type") == "tool_use"]
                got = [x.get("tool_use_id") for x in m["content"]]
                if ids != got or any(x.get("type") != "tool_result" or not isinstance(x.get("is_error"), bool)
                                     for x in m["content"]):
                    p("tool results %r for tool uses %r" % (m["content"], ids))
        if msgs and msgs[-1]["role"] != "user": p("last message is not from the user")


def scenario(name, fn):
    try:
        problems = fn()
    except Exception as e:
        import traceback
        problems = ["exception: %s\n%s" % (e, traceback.format_exc())]
    if problems:
        failed.append(name)
        print("FAIL", name)
        for x in problems:
            print("   -", x)
    else:
        print("ok  ", name)


def expect(problems, cond, msg):
    if not cond:
        problems.append(msg)


# ---------------------------------------------------------------- scenarios
def plain_chat():
    first = [THINKING, text("Hello! café ☕ ok")]
    env = Env(typed("hi") + typed("again"), [reply(first), reply([text("Bye")])]).run()
    pr, b = env.problems, env.bodies
    expect(pr, len(b) == 2, "%d requests" % len(b))
    if len(b) == 2:
        expect(pr, b[0]["messages"] == [{"role": "user", "content": "hi"}], "first messages %r" % b[0]["messages"])
        expect(pr, b[1]["messages"] == [{"role": "user", "content": "hi"}, {"role": "assistant", "content": first},
                                        {"role": "user", "content": "again"}], "history not echoed exactly: %r" % b[1]["messages"])
        expect(pr, b[0]["model"] == "claude-opus-5-5" and b[0]["output_config"] == {"effort": "low"}, "defaults")
        expect(pr, "☕".encode() in env.raw[1].encode(), "UTF-8 text not echoed as UTF-8")
    expect(pr, "Hello! caf? ? ok" in env.written and "Bye" in env.written, "reply not shown:\n" + env.screen())
    return pr


def tool_allow():
    env = Env(typed("add") + [["host", "snap", "card"], ["host", "click", " Allow "]],
              [reply([text("Let me check."), tool_use("toolu_1", "run_lua", {"code": "print(1+1) return 'x'"})], "tool_use"),
               reply([text("It is 2.")])]).run()
    pr, b = env.problems, env.bodies
    expect(pr, "Claude wants to use run_lua" in env.snaps.get("card", "") and " Deny " in env.snaps.get("card", ""),
           "no approval card:\n" + env.snaps.get("card", ""))
    expect(pr, len(b) == 2, "%d requests" % len(b))
    if len(b) == 2:
        last = b[1]["messages"][-1]
        expect(pr, len(b[1]["messages"]) == 3 and last["role"] == "user" and len(last["content"]) == 1, "shape %r" % b[1]["messages"])
        r = last["content"][0]
        expect(pr, r["tool_use_id"] == "toolu_1" and "2" in r["content"] and "returned" in r["content"]
               and r["is_error"] is False, "tool result %r" % r)
    expect(pr, "It is 2." in env.written, "final text not shown")
    return pr


def tool_always():
    # "Always" once -> the second run_lua call of the same turn is not asked again
    env = Env(typed("go") + [["host", "click", " Always "], ["host", "snap", "after"]],
              [reply([tool_use("t1", "run_lua", {"code": "return 1"})], "tool_use"),
               reply([tool_use("t2", "run_lua", {"code": "return 2"})], "tool_use"),
               reply([text("done")])]).run()
    pr, b = env.problems, env.bodies
    expect(pr, len(b) == 3, "%d requests (second call was not run without asking?)" % len(b))
    if len(b) == 3:
        expect(pr, b[2]["messages"][-1]["content"][0]["content"] == "returned: 2", "result %r" % b[2]["messages"][-1])
    return pr


def tool_deny():
    code = 'local f = fs.open("/pwned", "w") f.write("x") f.close()'
    env = Env(typed("do it") + [["host", "click", " Deny "]],
              [reply([tool_use("toolu_9", "run_lua", {"code": code})], "tool_use"), reply([text("OK, I won't.")])]).run()
    pr, b = env.problems, env.bodies
    expect(pr, "/pwned" not in dict(env.M.FS.items()), "denied code ran")
    if len(b) == 2:
        r = b[1]["messages"][-1]["content"][0]
        expect(pr, r["tool_use_id"] == "toolu_9" and "denied" in r["content"] and r["is_error"] is True, "result %r" % r)
    else:
        pr.append("%d requests" % len(b))
    return pr


def parallel_tools():
    env = Env(typed("look"),
              [reply([text("Looking."), tool_use("a1", "list_files", {"path": "/docs"}),
                      tool_use("a2", "read_file", {"path": "/docs/notes.txt"})], "tool_use"),
               reply([text("Found your notes.")])],
              files={"/docs": True, "/docs/notes.txt": "hello notes"}).run()
    pr, b = env.problems, env.bodies
    if len(b) == 2:
        msgs = b[1]["messages"]
        expect(pr, len(msgs) == 3, "messages %r" % msgs)
        res = msgs[-1]["content"]
        expect(pr, [r["tool_use_id"] for r in res] == ["a1", "a2"], "order %r" % res)
        expect(pr, "notes.txt" in res[0]["content"] and res[1]["content"] == "hello notes"
               and not res[0]["is_error"] and not res[1]["is_error"], "results %r" % res)
    else:
        pr.append("%d requests" % len(b))
    expect(pr, "Claude wants" not in env.written, "non-risky tools asked for approval")
    return pr


def retries():
    env = Env(typed("hi") + [["host", "snap", "waiting"], ["timer", 901], ["timer", 902]],
              [error(500, "overloaded", retry_after=1), error(503, "busy"), reply([text("Finally here.")])]).run()
    pr, b = env.problems, env.bodies
    expect(pr, len(b) == 3 and b[0] == b[1] == b[2], "%d requests / bodies differ" % len(b))
    expect(pr, "retrying in 1s" in env.snaps.get("waiting", ""), "retry status (Retry-After) not shown:\n" + env.snaps.get("waiting", ""))
    expect(pr, "Finally here." in env.written, "reply not shown after retries")
    return pr


def retries_exhausted():
    env = Env(typed("hi") + [["timer", 1], ["timer", 2]] + typed("again"),
              [error(500, "down"), error(500, "down"), error(529, "Overloaded"), reply([text("Back.")])]).run()
    pr, b = env.problems, env.bodies
    expect(pr, len(b) == 4, "%d requests" % len(b))
    expect(pr, "HTTP 529: Overloaded" in env.written, "error not shown")
    if len(b) == 4:
        expect(pr, b[3]["messages"] == [{"role": "user", "content": "again"}], "not rolled back: %r" % b[3]["messages"])
    return pr


def unauthorized():
    env = Env(typed("hi") + [["host", "snap", "err"]] + typed("second"),
              [error(401, "invalid x-api-key", "authentication_error"), reply([text("Works now.")])]).run()
    pr, b = env.problems, env.bodies
    expect(pr, "API key rejected" in env.snaps.get("err", ""), "401 not shown:\n" + env.snaps.get("err", ""))
    if len(b) == 2:
        expect(pr, b[1]["messages"] == [{"role": "user", "content": "second"}], "not rolled back: %r" % b[1]["messages"])
    else:
        pr.append("%d requests" % len(b))
    return pr


def refusal():
    first = [text("Hi there.")]
    env = Env(typed("hi") + typed("bad") + [["host", "snap", "ref"]] + typed("third"),
              [reply(first), reply([text("")], "refusal"), reply([text("Sure.")])]).run()
    pr, b = env.problems, env.bodies
    expect(pr, "declined" in env.snaps.get("ref", ""), "refusal notice not shown:\n" + env.snaps.get("ref", ""))
    if len(b) == 3:
        expect(pr, b[2]["messages"] == [{"role": "user", "content": "hi"}, {"role": "assistant", "content": first},
                                        {"role": "user", "content": "third"}], "not rolled back: %r" % b[2]["messages"])
    else:
        pr.append("%d requests" % len(b))
    return pr


def error_mid_turn():
    # a tool round happened, then a non-retryable error: the whole turn is undone
    env = Env(typed("look") + [["host", "snap", "err"]] + typed("again"),
              [reply([tool_use("x1", "list_files", {"path": "/"})], "tool_use"),
               error(400, "messages: something is wrong", "invalid_request_error"), reply([text("ok")])]).run()
    pr, b = env.problems, env.bodies
    expect(pr, "undone" in env.snaps.get("err", "") and "HTTP 400" in env.snaps.get("err", ""), "notice:\n" + env.snaps.get("err", ""))
    if len(b) == 3:
        expect(pr, b[2]["messages"] == [{"role": "user", "content": "again"}], "not rolled back: %r" % b[2]["messages"])
    else:
        pr.append("%d requests" % len(b))
    return pr


def empty_reply():
    env = Env(typed("hi") + typed("again"), [reply([]), reply([text("Hm?")])]).run()
    pr, b = env.problems, env.bodies
    if len(b) == 2:
        expect(pr, b[1]["messages"][1]["content"] and all(x.get("text", "x").strip() for x in b[1]["messages"][1]["content"]),
               "empty assistant message kept in history: %r" % b[1]["messages"])
    else:
        pr.append("%d requests" % len(b))
    return pr


def malformed_reply():
    env = Env(typed("hi") + [["host", "snap", "crash"]] + typed("again"), [reply([1]), reply([text("Fine.")])],
              crash_ok=True).run()
    pr, b = env.problems, env.bodies
    expect(pr, "crashed" in env.snaps.get("crash", ""), "crash not reported:\n" + env.snaps.get("crash", ""))
    if len(b) == 2:
        expect(pr, b[1]["messages"] == [{"role": "user", "content": "again"}], "not rolled back: %r" % b[1]["messages"])
    else:
        pr.append("%d requests" % len(b))
    return pr


def drones_none():
    env = Env(typed("dig") + [["claude_decision", "allow"]],
              [reply([tool_use("d1", "drone_command", {"command": "dig"})], "tool_use"), reply([text("No drone.")])],
              modem=True, prelude='rednet.open("back")').run()
    pr, b = env.problems, env.bodies
    if len(b) == 2:
        r = b[1]["messages"][-1]["content"][0]
        expect(pr, "hasn't given you a drone" in r["content"] and r["is_error"] is True, "result %r" % r)
    else:
        pr.append("%d requests" % len(b))
    expect(pr, len(env.sent()) == 0, "something was sent")
    return pr


GIVE_12 = '''rednet.open("back")
fs.makeDir("/os/claude")
local f = fs.open("/os/claude/drones", "w") f.write(textutils.serialize({ [12] = true })) f.close()
assert(dofile("/os/lib/claude.lua").getDrones()[12] == true, "getDrones does not read the file back")
'''


def drones_task():
    seqs = []

    def ack(_=None):
        m = env.sent()[-1].msg
        seqs.append(m.seq)
        return ["rednet_message", 12, {"t": "ack", "seq": m.seq, "cmd": m.cmd, "ok": True, "info": "started"}, "wardenos"]

    def stale(kind):       # acks for other commands (the Drones app's, other seq) must be ignored
        m = env.sent()[-1].msg
        seq, cmd = (m.seq, "dig") if kind == "drones-app" else (m.seq + 100, "run")
        return ["rednet_message", 12, {"t": "ack", "seq": seq, "cmd": cmd, "ok": False, "info": "stale"}, "wardenos"]

    env = Env(typed("dig") + [["host", "click", " Allow "], ["host", "stale", "drones-app"], ["host", "stale", "seq"],
                              ["rednet_message", 5, {"t": "ack", "seq": 1, "cmd": "run", "ok": False, "info": "x"}, "wardenos"],
                              ["host", "ack"], ["claude_decision", "allow"]],
              [reply([tool_use("d1", "drone_task", {"name": "dig", "code": "turtle.dig()"})], "tool_use"),
               reply([tool_use("d2", "drone_command", {"id": 99, "command": "forward"})], "tool_use"),
               reply([text("Started.")])],
              modem=True, prelude=GIVE_12)
    env.hosts["ack"], env.hosts["stale"] = ack, stale
    env.run()
    pr, b = env.problems, env.bodies
    sent = env.sent()
    expect(pr, len(sent) == 1, "%d rednet messages sent (drone 99 must get nothing)" % len(sent))
    if sent:
        s = sent[0]
        expect(pr, s.to == 12 and s.proto == "wardenos" and s.msg.t == "cmd" and s.msg.to == 12 and s.msg.cmd == "run"
               and s.msg.arg.name == "dig" and s.msg.arg.code == "turtle.dig()" and s.msg.seq == 1,
               "sent %r" % dict(s.msg.items()))
    if len(b) == 3:
        r1 = b[1]["messages"][-1]["content"][0]
        r2 = b[2]["messages"][-1]["content"][0]
        expect(pr, r1["content"] == "ok: started" and r1["is_error"] is False, "task result %r" % r1)
        expect(pr, "not yours" in r2["content"] and r2["is_error"] is True, "drone 99 result %r" % r2)
    else:
        pr.append("%d requests" % len(b))
    return pr


def drones_status():
    def status(state):
        last = {"name": "dig", "ok": True, "info": "mined 3"} if state == "ready" else None
        d = {"t": "status", "kind": "turtle", "label": "digger", "task": "dig", "state": state, "fuel": 400,
             "fuelLimit": 20000, "log": ["dig ok", "started dig"], "items": [{"slot": 1, "name": "minecraft:dirt", "count": 3}],
             "nav": {"x": 0, "y": 0, "z": 2, "f": 0}, "homeSet": True, "selected": 1}
        if last:
            d["lastTask"] = last
        return d

    env = Env(typed("status?") + [["host", "st", "working"], ["host", "tick"], ["host", "st", "ready"], ["host", "tick"]],
              [reply([tool_use("s1", "drone_status", {"wait_seconds": 10})], "tool_use"), reply([text("Done.")])],
              modem=True, prelude=GIVE_12)
    env.hosts["st"] = lambda state: ["rednet_message", 12, status(state), "wardenos"]
    env.run()
    pr, b = env.problems, env.bodies
    if len(b) == 2:
        r = b[1]["messages"][-1]["content"][0]["content"]
        expect(pr, "state=ready" in r and "last task: dig ok mined 3" in r and "dig ok | started dig" in r
               and "minecraft:dirt x3" in r, "status result %r" % r)
    else:
        pr.append("%d requests" % len(b))
    pings = [s for s in env.sent() if s.msg.t == "ping"]
    expect(pr, len(pings) == 2 and all(s.to == 12 for s in pings), "pings %d" % len(pings))
    return pr


def options():
    env = Env([["host", "click", " options "], ["host", "click", " sonnet-5-5 "], ["host", "click", " high "],
               ["host", "snap", "opts"], ["host", "click", " Back "]] + typed("hi"),
              [reply([text("Hello from sonnet.")])]).run()
    pr, b = env.problems, env.bodies
    if len(b) == 1:
        expect(pr, b[0]["model"] == "claude-sonnet-5-5" and b[0]["output_config"] == {"effort": "high"},
               "options not used: %s %s" % (b[0]["model"], b[0]["output_config"]))
    else:
        pr.append("%d requests" % len(b))
    cfg = env.rt.eval('function() return dofile("/os/lib/claude.lua").loadConfig() end')()
    expect(pr, cfg.model == "claude-sonnet-5-5" and cfg.effort == "high" and cfg.auto is False, "config not saved")
    expect(pr, "/os/claude/config" in dict(env.M.FS.items()), "no config file")
    expect(pr, "Effort" in env.snaps.get("opts", ""), "options view not shown")
    return pr


def no_key():
    env = Env([["host", "snap", "key"], ["paste", "  sk-ant-new  "], ["key", ENTER]] + typed("hi"),
              [reply([text("Connected.")])], key=None).run()
    pr, b = env.problems, env.bodies
    expect(pr, "Connect Claude" in env.snaps.get("key", ""), "key screen not shown")
    expect(pr, env.M.FS["/os/claude/key"] == "sk-ant-new", "key not saved: %r" % env.M.FS["/os/claude/key"])
    expect(pr, len(b) == 1 and env.M.requests[1].headers["x-api-key"] == "sk-ant-new", "key not used")
    expect(pr, "Connected." in env.written, "reply not shown")
    return pr


# servers cap the http timeout; CC: Tweaked throws "Timeout out of range" right away
CAP_TIMEOUT = """
local real = http.request
http.request = function(req)
  if type(req) == "table" and req.timeout and req.timeout > LIMIT then error("Timeout out of range", 2) end
  return real(req)
end
"""

def timeout_capped():
    env = Env(typed("hi"), [reply([text("Works now.")])], prelude=CAP_TIMEOUT.replace("LIMIT", "60")).run()
    pr = env.problems
    expect(pr, len(env.bodies) == 1, "%d requests" % len(env.bodies))
    expect(pr, len(env.bodies) == 1 and env.M.requests[1].timeout == 60, "should fall back to timeout 60")
    expect(pr, "Works now." in env.written and "out of range" not in env.written, "reply not shown:\n" + env.screen())
    return pr

def timeout_refused():
    # a server that rejects every timeout value: the request goes out without one
    env = Env(typed("hi"), [reply([text("Default timeout.")])], prelude=CAP_TIMEOUT.replace("LIMIT", "-1")).run()
    pr = env.problems
    expect(pr, len(env.bodies) == 1 and env.M.requests[1].timeout is None, "should send without a timeout")
    expect(pr, "Default timeout." in env.written, "reply not shown:\n" + env.screen())
    return pr

def send_error():
    # any other error thrown by http.request: shown, not a crash, history rolled back
    pre = 'http.request = function() error("Domain not permitted", 2) end'
    env = Env(typed("hi"), [], prelude=pre).run()
    pr = env.problems
    shown = " ".join(env.screen().split())
    expect(pr, "could not send the request: Domain not permitted" in shown,
           "error not shown:\n" + env.screen())
    expect(pr, "crashed" not in env.written, "app crashed")
    return pr

SCENARIOS = [("a plain chat + exact history echo", plain_chat), ("b tool loop, Allow button", tool_allow),
                 ("b2 Always button", tool_always), ("c Deny button", tool_deny), ("d parallel tool calls", parallel_tools),
                 ("e1 500/503 retries then 200", retries), ("e2 retries exhausted -> rollback", retries_exhausted),
                 ("e3 401 -> rollback", unauthorized), ("e4 refusal -> rollback", refusal),
                 ("e5 error after a tool round -> rollback", error_mid_turn),
                 ("e6 empty reply keeps the history valid", empty_reply),
                 ("e7 malformed reply -> crash notice + rollback", malformed_reply),
                 ("f1 drone tool without drones", drones_none), ("f2 drone_task + foreign drone refused", drones_task),
                 ("g drone_status wait_seconds", drones_status), ("h options view", options), ("i no key -> key screen", no_key),
                 ("j server caps the timeout", timeout_capped), ("j2 server refuses any timeout", timeout_refused),
                 ("j3 request can't be sent", send_error)]
for name, fn in SCENARIOS:
    scenario(name, fn)

print("claude app: %d scenarios, %d failed" % (len(SCENARIOS), len(failed)))
sys.exit(1 if failed else 0)
