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
              "network_scan", "drone_command", "drone_task", "drone_status", "drone_scan", "drone_goto", "drone_job",
              "map_view", "map_find", "map_info", "protect_area", "drone_send_map",
              "template_save", "template_list", "template_run"}
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
                  "os/lib/map.lua", "os/lib/templates.lua"):
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

# ---------------------------------------------------------------- world map, all drones, templates, goto
SEED_MAP = '''
local map = dofile("/os/lib/map.lua")
local obs = {}
for x = 0, 9 do for z = 0, 9 do obs[#obs + 1] = { x, 64, z, x == 5 and "minecraft:water" or "minecraft:grass_block" } end end
obs[#obs + 1] = { 3, 40, 3, "minecraft:diamond_ore" }
obs[#obs + 1] = { 4, 65, 4, "air" }
map.add(obs)
WardenOS.drones = {
  [12] = { kind = "turtle", owner = 7, label = "digger", calibrated = true, abs = { x = 2, y = 65, z = 2, f = 1 },
           origin = { x = 0, y = 65, z = 0, f = 0 }, fuel = 900, fuelItems = 16, task = "manual", state = "ready",
           seen = os.clock() },
  [15] = { kind = "turtle", owner = 7, label = "spare", calibrated = false, seen = os.clock() },
  [16] = { kind = "turtle", owner = 99, label = "neighbour", seen = os.clock() },
}
'''
ALL_DRONES = '''
fs.makeDir("/os/claude")
local f = fs.open("/os/claude/config", "w") f.write(textutils.serialize({ allDrones = true })) f.close()
'''


def last_cmd_ack(env, frm=None, ok=True, info="started"):
    def h(_=None):
        m = [x for x in env.sent() if x.msg.t == "cmd"][-1]
        return ["rednet_message", frm or m.to, {"t": "ack", "seq": m.msg.seq, "cmd": m.msg.cmd, "ok": ok, "info": info},
                "wardenos"]
    return h


def results(b, i):
    return [r for r in b[i]["messages"][-1]["content"]]


def map_tools():
    env = Env(typed("look"),
              [reply([tool_use("m1", "map_view", {"x1": 0, "z1": 0, "x2": 9, "z2": 9}),
                      tool_use("m2", "map_view", {"x1": 0, "z1": 0, "x2": 9, "z2": 9, "heights": True}),
                      tool_use("m3", "map_find", {"name": "diamond", "near_x": 0, "near_y": 64, "near_z": 0}),
                      tool_use("m4", "map_info", {}),
                      tool_use("m5", "protect_area", {"name": "base", "x1": 0, "z1": 0, "x2": 3, "z2": 3})], "tool_use"),
               reply([tool_use("m6", "map_view", {"x1": 0, "z1": 0, "x2": 9, "z2": 9, "y": 40})], "tool_use"),
               reply([text("Done.")])],
              modem=True, prelude='rednet.open("back")\n' + GIVE_12 + SEED_MAP).run()
    pr, b = env.problems, env.bodies
    expect(pr, "Claude wants" not in env.written, "map tools / protect_area asked for approval")
    if len(b) != 3:
        return pr + ["%d requests" % len(b)]
    r = results(b, 1)
    view, heights, find, info, prot = [x["content"] for x in r]
    expect(pr, not any(x["is_error"] for x in r), "errors %r" % r)
    lines = view.split("\n")
    row2 = [l for l in lines if l.startswith("z=2 ")]
    expect(pr, "Surface, x 0..9" in view and row2 and row2[0][8:18] == "::D::~::::" and "legend: ? unknown" in view
           and "surface y in view: 64..64" in view and 'drone #12 "digger" at 2 65 2 facing east' in view
           and "home 0 65 0" in view, "map_view %s" % view)
    expect(pr, "  64" in heights and "z=0" in heights, "heights %s" % heights)
    expect(pr, "3 40 3 minecraft:diamond_ore" in find, "map_find %s" % find)
    expect(pr, "102 blocks" in info and "Protected areas: none" in info and "drone #12" in info and "coal 16" in info,
           "map_info %s" % info)
    expect(pr, 'protected 1. "base" x 0..3' in prot, "protect_area %s" % prot)
    pf = env.M.FS["/os/map/protect"] or ""
    expect(pr, '"base"' in pf and "rev" in pf, "protect file %r" % pf)
    v2 = results(b, 2)[0]["content"]
    expect(pr, "Layer y=40" in v2 and "P" in v2 and "protected here: 1." in v2, "layer view %s" % v2)
    return pr


def all_drones():
    env = Env(typed("go") + [["host", "click", " Allow "], ["host", "ack"]],
              [reply([tool_use("a1", "drone_command", {"id": 15, "command": "forward"})], "tool_use"),
               reply([tool_use("a2", "drone_command", {"id": 16, "command": "forward"})], "tool_use"),
               reply([text("ok")])],
              modem=True, prelude='rednet.open("back")\n' + GIVE_12 + SEED_MAP + ALL_DRONES)
    env.hosts["ack"] = last_cmd_ack(env)
    env.run()
    pr, b = env.problems, env.bodies
    cmds = [x for x in env.sent() if x.msg.t == "cmd"]
    expect(pr, len(cmds) == 1 and cmds[0].to == 15 and cmds[0].msg.cmd == "forward", "sent %r" % [(c.to, c.msg.cmd) for c in cmds])
    if len(b) == 3:
        r1 = results(b, 1)[0]
        expect(pr, r1["content"] == "ok: started" and not r1["is_error"], "owned drone %r" % r1)
        r2 = results(b, 2)
        expect(pr, "belongs to computer #99" in r2[0]["content"] and r2[0]["is_error"], "foreign drone %r" % r2[0])
    else:
        pr.append("%d requests" % len(b))
    return pr


def all_drones_scan():
    # no kernel cache: the drones are found with a ping; only this computer's own count
    def st(owner):
        return {"t": "status", "kind": "turtle", "label": "x", "owner": owner, "state": "ready"}
    env = Env(typed("go") + [["rednet_message", 21, st(7), "wardenos"], ["rednet_message", 22, st(5), "wardenos"],
                             ["host", "tick"], ["host", "ack"]],
              [reply([tool_use("s1", "drone_command", {"command": "scan"})], "tool_use"), reply([text("ok")])],
              modem=True, prelude='rednet.open("back")\n' + ALL_DRONES + 'local c = dofile("/os/lib/claude.lua").loadConfig() c.auto = true dofile("/os/lib/claude.lua").saveConfig(c)')
    env.hosts["ack"] = last_cmd_ack(env)
    env.run()
    pr, b = env.problems, env.bodies
    cmds = [x for x in env.sent() if x.msg.t == "cmd"]
    pings = [x for x in env.sent() if x.msg.t == "ping"]
    expect(pr, len(pings) == 1 and pings[0].to == "all", "no ping scan")
    expect(pr, len(cmds) == 1 and cmds[0].to == 21, "sent %r" % [(c.to, c.msg.cmd) for c in cmds])
    expect(pr, len(b) == 2 and results(b, 1)[0]["content"] == "ok: started", "result")
    return pr


def templates():
    code = "local LENGTH = 5\nfor i = 1, LENGTH do turtle.forward() end\nreturn 'done'"
    env = Env(typed("save") + [["host", "snap", "card"], ["host", "click", " Allow "], ["host", "ack"]],
              [reply([tool_use("t1", "template_save", {"name": "Row 5", "description": "goes 5 forward", "code": code}),
                      tool_use("t2", "template_save", {"name": "bad", "description": "x", "code": "for do"}),
                      tool_use("t3", "template_save", {"name": "mine", "description": "x", "code": "return 1"}),
                      tool_use("t4", "template_list", {})], "tool_use"),
               reply([tool_use("t5", "template_run", {"name": "row 5"}),
                      tool_use("t6", "template_run", {"name": "nope"})], "tool_use"),
               reply([text("ok")])],
              modem=True, files={"/os/templates": True,
                                 "/os/templates/mine.dat": '{name = "mine", description = "player one", code = "return 2", author = "player"}'},
              prelude='rednet.open("back")\n' + GIVE_12)
    env.hosts["ack"] = last_cmd_ack(env)
    env.run()
    pr, b = env.problems, env.bodies
    if len(b) != 3:
        return pr + ["%d requests" % len(b)]
    r = results(b, 1)
    expect(pr, "saved template" in r[0]["content"] and not r[0]["is_error"], "save %r" % r[0])
    expect(pr, "syntax error" in r[1]["content"] and r[1]["is_error"], "bad code %r" % r[1])
    expect(pr, "player already has" in r[2]["content"] and r[2]["is_error"], "overwrote the player's %r" % r[2])
    expect(pr, "Row 5 (by you): goes 5 forward" in r[3]["content"] and "mine (by the player)" in r[3]["content"], "list %r" % r[3])
    fsv = env.M.FS["/os/templates/row_5.dat"] or ""
    expect(pr, "claude" in fsv and "LENGTH" in fsv, "file %r" % fsv)
    expect(pr, "Claude wants to use template_run" in env.snaps.get("card", "") and "LENGTH" in env.snaps.get("card", ""),
           "card:\n" + env.snaps.get("card", ""))
    cmds = [x for x in env.sent() if x.msg.t == "cmd"]
    expect(pr, len(cmds) == 1 and cmds[0].to == 12 and cmds[0].msg.cmd == "run" and cmds[0].msg.arg.name == "Row 5"
           and cmds[0].msg.arg.code == code, "run not sent")
    r2 = results(b, 2)
    expect(pr, r2[0]["content"] == "ok: started" and "No template named" in r2[1]["content"] and r2[1]["is_error"],
           "run results %r" % r2)
    return pr


def goto_mapdata():
    env = Env(typed("go") + [["host", "click", " Allow "], ["host", "ack"], ["host", "ack"]],
              [reply([tool_use("g1", "drone_command", {"command": "goto", "arg": {"x": 8, "y": 65, "z": 8}})], "tool_use"),
               reply([tool_use("g2", "drone_command", {"command": "protect", "arg": {}})], "tool_use"),
               reply([text("ok")])],
              modem=True, prelude='rednet.open("back")\n' + GIVE_12 + SEED_MAP)
    env.hosts["ack"] = last_cmd_ack(env)
    env.run()
    pr, b = env.problems, env.bodies
    cmds = [x for x in env.sent() if x.msg.t == "cmd"]
    expect(pr, [c.msg.cmd for c in cmds] == ["mapdata", "goto"], "sent %r" % [c.msg.cmd for c in cmds])
    if len(cmds) == 2:
        blocks = cmds[0].msg.arg.blocks
        expect(pr, len(blocks) == 101 and blocks[1][4] != "air", "mapdata %d blocks" % len(blocks))
        expect(pr, cmds[1].msg.arg.x == 8 and cmds[1].msg.arg.z == 8, "goto arg")
    if len(b) == 3:
        r = results(b, 1)[0]["content"]
        expect(pr, r.startswith("ok: started") and "sent 101 known blocks" in r, "goto result %r" % r)
        r2 = results(b, 2)[0]
        expect(pr, "protect_area" in r2["content"] and r2["is_error"], "protect cmd %r" % r2)
    else:
        pr.append("%d requests" % len(b))
    return pr


def goto_job_tools():
    # drone_goto / drone_job: send the command (map first), then wait for the task's result (lastTask.n = ack.job)
    def done(n, ok, info):
        return ["rednet_message", 12, {"t": "status", "kind": "turtle", "owner": 7, "task": "manual", "state": "ready",
                                       "fuel": 880, "calibrated": True, "abs": {"x": 8, "y": 65, "z": 8, "f": 2},
                                       "lastTask": {"name": "x", "n": n, "ok": ok, "info": info}}, "wardenos"]
    allow = ["host", "click", " Allow "]
    env = Env(typed("go") + [allow, ["host", "ack"], ["host", "ackjob", 3], done(2, True, "old task"),
                             done(3, True, "arrived 8 65 8"),
                             allow, ["host", "ackjob", 4], done(4, False, "tunnel 5 x 1 x 2: mined nothing; protected"),
                             allow, ["host", "ackjob", None, True, "fuel 500 (+100)"],
                             allow, ["host", "ackjob", 6],
                             allow, ["host", "ackjob", None, False, "not enough fuel: needs about 90, has 10; bring 1 coal"]],
              [reply([tool_use("g1", "drone_goto", {"x": 8, "y": 65, "z": 8})], "tool_use"),
               reply([tool_use("j1", "drone_job", {"job": "tunnel", "length": 5, "direction": 1})], "tool_use"),
               reply([tool_use("j2", "drone_job", {"job": "refuel", "fuel_target": 500})], "tool_use"),
               reply([tool_use("g2", "drone_goto", {"home": True, "wait_seconds": 0})], "tool_use"),
               reply([tool_use("g3", "drone_goto", {"x": 1, "y": 2, "z": 3, "rel": True})], "tool_use"),
               reply([text("ok")])],
              modem=True, prelude='rednet.open("back")\n' + GIVE_12 + SEED_MAP)
    env.hosts["ack"] = last_cmd_ack(env, info="101 blocks")

    def ackjob(job, ok=True, info="started"):
        m = [x for x in env.sent() if x.msg.t == "cmd"][-1]
        a = {"t": "ack", "seq": m.msg.seq, "cmd": m.msg.cmd, "ok": ok, "info": info}
        if job is not None:
            a["job"] = job
        return ["rednet_message", m.to, a, "wardenos"]
    env.hosts["ackjob"] = ackjob
    env.run()
    pr, b = env.problems, env.bodies
    cmds = [x for x in env.sent() if x.msg.t == "cmd"]
    expect(pr, [c.msg.cmd for c in cmds] == ["mapdata", "goto", "tunnel", "refuel", "home", "goto"],
           "sent %r" % [c.msg.cmd for c in cmds])
    if len(cmds) == 6:
        expect(pr, cmds[1].msg.arg.x == 8 and cmds[1].msg.by == "claude", "goto arg")
        expect(pr, cmds[2].msg.arg.length == 5 and cmds[2].msg.arg.dir == 1 and cmds[2].msg.arg.width is None, "tunnel arg")
        expect(pr, cmds[3].msg.arg == 500, "refuel arg %r" % cmds[3].msg.arg)
        expect(pr, cmds[5].msg.arg.rel is True and cmds[5].msg.arg.z == 3, "rel goto arg")
    if len(b) != 6:
        return pr + ["%d requests" % len(b)]
    r = [results(b, i)[0] for i in range(1, 6)]
    expect(pr, r[0]["content"].startswith("done: arrived 8 65 8") and "now at 8 65 8 facing south, fuel 880" in r[0]["content"]
           and "sent 101 known blocks" in r[0]["content"] and not r[0]["is_error"], "goto result %r" % r[0])
    expect(pr, r[1]["content"].startswith("FAILED: tunnel 5 x 1 x 2: mined nothing") and r[1]["is_error"], "tunnel %r" % r[1])
    expect(pr, r[2]["content"] == "ok: fuel 500 (+100)" and not r[2]["is_error"], "refuel %r" % r[2])
    expect(pr, r[3]["content"].startswith("started (task 6)") and not r[3]["is_error"], "home %r" % r[3])
    expect(pr, r[4]["content"].startswith("failed: not enough fuel") and r[4]["is_error"], "fuel refusal %r" % r[4])
    system = b[0]["system"][0]["text"]
    expect(pr, "drone_goto" in system and "drone_job" in system and "Plan before acting" in system, "system prompt")
    return pr


def status_fields():
    d = {"t": "status", "kind": "turtle", "label": "digger", "task": "manual", "state": "ready", "fuel": 400,
         "fuelLimit": 20000, "fuelItems": 7, "calibrated": True, "abs": {"x": 10, "y": 70, "z": -5, "f": 3},
         "origin": {"x": 0, "y": 64, "z": 0, "f": 0}, "safeDig": False, "protectRev": 0, "homeSet": True,
         "nav": {"x": 1, "y": 0, "z": 0, "f": 0}, "items": [], "log": []}
    env = Env(typed("s") + [["rednet_message", 12, d, "wardenos"], ["host", "tick"]],
              [reply([tool_use("s1", "drone_status", {})], "tool_use"), reply([text("ok")])],
              modem=True, prelude='rednet.open("back")\n' + GIVE_12).run()
    pr, b = env.problems, env.bodies
    if len(b) == 2:
        r = results(b, 1)[0]["content"]
        expect(pr, "position: 10 70 -5 facing west" in r and "home: 0 64 0 facing north" in r
               and "fuel items (coal): 7" in r and "safe dig OFF" in r and "rev 0" in r, "status %r" % r)
    else:
        pr.append("%d requests" % len(b))
    return pr


def options_all():
    env = Env([["host", "click", " options "], ["host", "click", " All mine "], ["host", "snap", "o"],
               ["host", "click", " Back "]], []).run()
    pr = env.problems
    cfg = env.rt.eval('function() return dofile("/os/lib/claude.lua").loadConfig() end')()
    expect(pr, cfg.allDrones is True, "allDrones not saved")
    expect(pr, "Drones Claude may use" in env.snaps.get("o", ""), "option not shown")
    return pr


# ---------------------------------------------------------------- what Claude does with drones (activity)
def exec_host(env):
    def h(code):
        env.rt.execute(code)
        return ["claude_noop"]
    return h


RUNNING_12 = """
local d = WardenOS.drones[12]
d.task, d.state, d.seen = "build", "working", os.clock()
d.by = { id = 7, who = "claude" }
d.taskTime = 34
d.progress = { phase = "moving", step = 5, total = 20, target = { x = 1, y = 2, z = 3 }, replans = 1 }
"""
DONE_12 = """
local d = WardenOS.drones[12]
d.task, d.state, d.by, d.progress, d.taskTime = "manual", "ready", nil, nil, nil
d.lastTask = { name = "build", ok = true, info = "", by = { id = 7, who = "claude" } }
d.seen = os.clock() + 5
"""


def activity():
    probe = {}
    env = Env(typed("build") + [["host", "click", " Allow "], ["host", "ack"], ["host", "grab"],
                                ["host", "exec", RUNNING_12], ["host", "snap", "running"],
                                ["host", "exec", DONE_12], ["host", "snap", "done"]],
              [reply([tool_use("b1", "drone_task", {"name": "build", "code": "return 1"})], "tool_use"),
               reply([text("Started.")])],
              modem=True, prelude='rednet.open("back")\n' + GIVE_12 + SEED_MAP)

    def grab(_=None):          # the shared activity table right after the ack
        a = env.rt.eval("WardenOS.claude")
        e = a.drones[12] if a and a.drones else None
        probe["entry"] = (e.action, e.task, e.pending, e.since) if e else None
        return ["claude_noop"]
    env.hosts["ack"], env.hosts["exec"], env.hosts["grab"] = last_cmd_ack(env), exec_host(env), grab
    env.run()
    pr = env.problems
    cmds = [x for x in env.sent() if x.msg.t == "cmd"]
    expect(pr, len(cmds) == 1 and cmds[0].msg.by == "claude", "by not sent: %r" % [dict(c.msg.items()) for c in cmds])
    expect(pr, probe.get("entry") and probe["entry"][0] == "task build" and probe["entry"][1] is True
           and not probe["entry"][2] and probe["entry"][3] == 123456, "activity entry %r" % (probe.get("entry"),))
    run = env.snaps.get("running", "")
    expect(pr, "#12 task build - moving 5/20 34s" in run, "drone line not shown:\n" + run)
    done = env.snaps.get("done", "")
    expect(pr, "#12 task build" not in done, "drone line stays after the task:\n" + done)
    a = env.rt.eval("WardenOS.claude")
    expect(pr, a.drones[12] is None and a.busy is False, "entry not cleared / still busy")
    return pr


LINES_LUA = """function()
  local K = dofile("/os/lib/claudetools.lua")
  local A = K.activity()
  A.drones[3] = { action = "goto 1 2 3", at = os.clock(), task = true }
  local cache = { [3] = { by = { who = "claude" }, state = "working", seen = os.clock(),
                          progress = { phase = "digging", step = 2, total = 9 } },
                  [4] = { by = { who = "claude" }, state = "working", task = "x", seen = os.clock() },
                  [5] = { by = { who = "player" }, state = "working", seen = os.clock() } }
  local out = {}
  for i, e in ipairs(K.lines(cache)) do out[i] = e.text end
  return table.concat(out, "|")
end"""


def activity_fail_lines():
    # a failed command leaves no entry; lines() = Claude's entries + drones running Claude's tasks
    env = Env(typed("go") + [["host", "click", " Allow "], ["host", "ack_fail"]],
              [reply([tool_use("g1", "drone_command", {"command": "forward"})], "tool_use"),
               reply([text("ok")])],
              modem=True, prelude='rednet.open("back")\n' + GIVE_12)
    env.hosts["ack_fail"] = last_cmd_ack(env, ok=False, info="busy: x")
    env.run()
    pr = env.problems
    a = env.rt.eval("WardenOS.claude")
    expect(pr, a.drones[12] is None, "failed command left an entry")
    t = env.rt.eval(LINES_LUA)()
    expect(pr, t == "#3 goto 1 2 3 - digging 2/9|#4 task x", "lines %r" % t)
    return pr


ZOOM_STUB = """
local M = { LEGEND = { { "?", "unknown" } } }
function M.view(x1, z1, x2, z2, y, marks)      -- an old map.lua: no zoom argument
  local rows = {}
  for z = z1, math.min(z2, z1 + 39) do rows[#rows + 1] = string.rep(":", math.min(x2, x1 + 59) - x1 + 1) end
  return rows, "? unknown", { x1 = x1, z1 = z1, x2 = math.min(x2, x1 + 59), z2 = math.min(z2, z1 + 39) }
end
function M.surface() return 64 end
function M.protected() return { rev = 0, boxes = {} } end
function M.box() return {} end
function M.count() return 0 end
return M
"""
WRAP_VIEW = """
ZOOMS = {}
local real = dofile
dofile = function(p)
  local m = real(p)
  if p == "/os/lib/map.lua" and type(m) == "table" and not m._wrapped then
    local v = m.view
    m.view = function(...) local a = table.pack(...) ZOOMS[#ZOOMS + 1] = a[7] or 0 return v(...) end
    m._wrapped = true
  end
  return m
end
"""


def map_zoom():
    env = Env(typed("look"),
              [reply([tool_use("z1", "map_view", {"x1": 0, "z1": 0, "x2": 199, "z2": 99, "zoom": 4}),
                      tool_use("z2", "map_view", {"x1": 0, "z1": 0, "x2": 9, "z2": 9})], "tool_use"),
               reply([text("ok")])],
              modem=True, prelude=WRAP_VIEW + 'rednet.open("back")\n' + GIVE_12 + SEED_MAP).run()
    pr, b = env.problems, env.bodies
    tools = {t["name"]: t for t in b[0]["tools"]} if b else {}
    z = tools.get("map_view", {}).get("input_schema", {}).get("properties", {}).get("zoom")
    expect(pr, z and z.get("type") == "integer" and z.get("enum") == [1, 2, 4, 8, 16]
           and "zoom" in tools["map_view"]["description"], "zoom schema %r" % z)
    zs = env.rt.globals().ZOOMS
    expect(pr, zs and [zs[i] for i in range(1, len(zs) + 1)] == [4, 1], "map.view zoom args %r"
           % ([zs[i] for i in range(1, len(zs) + 1)] if zs else None))
    if len(b) == 2:
        v1, v2 = [x["content"] for x in results(b, 1)]
        expect(pr, "4 x 4 blocks" in v1 and "x 0..199" in v1 and "z=4 " in v1 and "z=96" in v1,
               "zoomed view %s" % v1[:600])
        expect(pr, "x 4 blocks" not in v2 and "z=1 " in v2, "zoom 1 view %s" % v2[:300])
    else:
        pr.append("%d requests" % len(b))
    # an old map.lua without zoom: the result is still labelled right (1 block per character)
    env2 = Env(typed("look"),
               [reply([tool_use("z1", "map_view", {"x1": 0, "z1": 0, "x2": 199, "z2": 99, "zoom": 4})], "tool_use"),
                reply([text("ok")])],
               modem=True, files={"/os/lib/map.lua": ZOOM_STUB},
               prelude='rednet.open("back")\n' + GIVE_12
               + 'WardenOS.drones = { [12] = { kind = "turtle", owner = 7, seen = os.clock() } }').run()
    b2 = env2.bodies
    pr += env2.problems
    if len(b2) == 2:
        v = results(b2, 1)[0]["content"]
        expect(pr, "x 4 blocks" not in v and "x 0..59" in v and "z=1 " in v and "cut to 60 x 40" in v,
               "old map %s" % v[:400])
    else:
        pr.append("old map: %d requests" % len(b2))
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
                 ("j3 request can't be sent", send_error),
                 ("k1 map tools + protect_area without approval", map_tools),
                 ("k2 all my drones: owned drone allowed, foreign refused", all_drones),
                 ("k3 all my drones found by a ping", all_drones_scan),
                 ("k4 templates: save, list, run", templates),
                 ("k5 goto sends the map first; protect command refused", goto_mapdata),
                 ("k6 drone_status: abs, home, coal, safe dig", status_fields),
                 ("k7 options: all my drones", options_all),
                 ("k8 drone_goto / drone_job wait for the task result", goto_job_tools),
                 ("l1 activity: by=claude, live drone line, cleared when done", activity),
                 ("l2 activity: failed command, lines", activity_fail_lines),
                 ("l3 map_view zoom (+ an old map.lua)", map_zoom)]
for name, fn in SCENARIOS:
    scenario(name, fn)

print("claude app: %d scenarios, %d failed" % (len(SCENARIOS), len(failed)))
sys.exit(1 if failed else 0)
