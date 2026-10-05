#!/usr/bin/env python3
"""TradeView checks (market library, app, ticker command). Run from anywhere:  python3 tests/test_tradeview.py
(needs: pip install lupa). Exit code 1 on failure. No network: http.request is answered by a fake Yahoo / Kraken
built from synthetic JSON shaped exactly like the real replies (nulls included).

1. library: User-Agent + Accept on every request, symbol URL encoding (^IXIC, EURUSD=X, GC=F), interval per range,
   parsing (null gaps skipped, error objects, json null fields), quote math, spark quotes, search, second host on a
   connection failure, Kraken fallback for BTC-USD, 60 s cache, 2 s rate limit, 429 backoff (Retry-After, no
   request while backing off), disk cache + offline open with its age, no http, formatting
2. app at 45x17, 45x18, 51x20, 79x36, 158x79: watchlist, candles (green + red), line mode, crosshair, every range
   button, pan + fit, watchlist select, search flow, add + remove from the watchlist, auto-refresh, nothing drawn
   outside the window; offline (cached, age), 429 and no-http states
3. ticker: quotes, search, mini chart, --help at 51x19 and 26x20
"""
import json, math, os, re, sys
from urllib.parse import urlparse, parse_qs, unquote
import lupa.lua52 as lua

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENTER, BACKSPACE, LEFT, RIGHT, UP, DOWN = 28, 14, 203, 205, 200, 208
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


VERSION = re.search(r'version\s*=\s*"([^"]+)"', read("src/os/config.lua")).group(1)
THEME = """WardenOS = { theme = { bg = colors.black, panel = colors.gray, text = colors.white,
  dim = colors.lightGray, accent = colors.cyan, good = colors.green, bad = colors.red, warn = colors.yellow },
  version = "%s" }""" % VERSION

# a controllable clock (os.epoch) and a sleep that advances it; strict bounds check for buffered windows
PRELUDE = r"""
CLOCK = 1791200000
os.epoch = function() return math.floor(CLOCK * 1000) end
SLEPT = 0
sleep = function(s) s = tonumber(s) or 0 SLEPT = SLEPT + s CLOCK = CLOCK + s end
WINDOW_VIOLATIONS, WINDOW_LOG, BLITS = 0, {}, {}
local create = window.create
window.create = function(parent, x, y, w, h, vis)
  local t = create(parent, x, y, w, h, vis)
  BLITS = {}
  local write = t.write
  t.write = function(s)
    s = tostring(s)
    local cx, cy = t.getCursorPos()
    local tw, th = t.getSize()
    for i = 1, #s do
      local px = cx + i - 1
      if s:sub(i, i) ~= " " and (px < 1 or px > tw or cy < 1 or cy > th) then
        WINDOW_VIOLATIONS = WINDOW_VIOLATIONS + 1
        WINDOW_LOG[#WINDOW_LOG + 1] = cx .. "," .. cy .. " " .. s
        break
      end
    end
    if (cx < 1 or cx + #s - 1 > tw or cy < 1 or cy > th) and s:match("^ +$") then
      WINDOW_VIOLATIONS = WINDOW_VIOLATIONS + 1 WINDOW_LOG[#WINDOW_LOG + 1] = "blank " .. cx .. "," .. cy
    end
    return write(s)
  end
  t.blit = function(s, f, b)
    local cx, cy = t.getCursorPos()
    if #s ~= #f or #s ~= #b then WINDOW_VIOLATIONS = WINDOW_VIOLATIONS + 1 WINDOW_LOG[#WINDOW_LOG + 1] = "blit lengths" end
    BLITS[#BLITS + 1] = { x = cx, y = cy, s = s, f = f, b = b }
    return t.write(s)
  end
  return t
end
"""

# ---------------------------------------------------------------- fake data sources
T_END = 1791199800
BASE = {"BTC-USD": 86000.0, "ETH-USD": 3200.0, "^IXIC": 27000.0, "^GSPC": 6600.0, "^DJI": 46000.0, "AAPL": 330.0,
        "NVDA": 180.0, "GC=F": 3900.0, "EURUSD=X": 1.12, "MSFT": 510.0, "APC.F": 285.0, "AAPL.MX": 6100.0}
NAMES = {"BTC-USD": "Bitcoin USD", "ETH-USD": "Ethereum USD", "^IXIC": "NASDAQ Composite", "AAPL": "Apple Inc.",
         "EURUSD=X": "EUR/USD", "GC=F": "Gold Dec 26", "MSFT": "Microsoft Corporation", "APC.F": "Apple Inc."}
STEP = {"5m": 300, "15m": 900, "1h": 3600, "1d": 86400, "1wk": 604800}
COUNT = {"1d": 78, "5d": 120, "1mo": 22, "6mo": 126, "1y": 250, "5y": 260}


def series(sym, n, step):
    base = BASE.get(sym, 100.0)
    out, prev = [], base
    for i in range(n):
        c = base * (1 + 0.03 * math.sin(i / 4.0) + 0.0004 * i)
        o = prev
        out.append({"t": T_END - (n - 1 - i) * step, "o": o, "h": max(o, c) * 1.002, "l": min(o, c) * 0.998, "c": c,
                    "v": 1000 + 13 * i})
        prev = c
    return out


def is_null(i):
    return i % 7 == 3


def chart_json(sym, interval, rng):
    n = COUNT.get(rng, 60)
    s = series(sym, n, STEP.get(interval, 300))
    q = {"open": [], "high": [], "low": [], "close": [], "volume": []}
    for i, c in enumerate(s):
        nul = is_null(i)
        q["open"].append(None if nul else c["o"])
        q["high"].append(None if nul else c["h"])
        q["low"].append(None if nul else c["l"])
        q["close"].append(None if nul or i == 5 else c["c"])      # i == 5: only the close is missing
        q["volume"].append(None if nul else c["v"])
    last = s[-1]["c"]
    meta = {"currency": None if sym == "GC=F" else "USD", "symbol": sym, "exchangeName": "NMS",
            "fullExchangeName": "NasdaqGS", "instrumentType": "CRYPTOCURRENCY" if sym.endswith("-USD") else "EQUITY",
            "regularMarketTime": T_END, "gmtoffset": 0 if sym.endswith("-USD") else -14400,
            "exchangeTimezoneName": "UTC" if sym.endswith("-USD") else "America/New_York",
            "regularMarketPrice": last, "chartPreviousClose": BASE.get(sym, 100.0), "shortName": NAMES.get(sym),
            "currentTradingPeriod": {"regular": {"start": T_END - 3600, "end": T_END + 20000}},
            "dataGranularity": interval, "range": rng}
    if sym == "TEST":
        meta.update({"regularMarketPrice": 110.0, "chartPreviousClose": 100.0})
    if sym == "TEST2":                            # previousClose wins over chartPreviousClose
        meta.update({"regularMarketPrice": 50.0, "chartPreviousClose": 10.0, "previousClose": 40.0})
    if sym == "TEST3":                            # only a change percent
        meta.update({"regularMarketPrice": 99.0, "chartPreviousClose": None, "regularMarketChangePercent": -1.0})
    return json.dumps({"chart": {"result": [{"meta": meta, "timestamp": [c["t"] for c in s],
                                              "indicators": {"quote": [q]}}], "error": None}})


def expected_candles(sym, rng):
    n = COUNT.get(rng, 60)
    return n - sum(1 for i in range(n) if is_null(i) or i == 5)


def spark_json(syms):
    out = {}
    for s in syms:
        if s == "NOPE":
            continue
        out[s] = {"timestamp": [T_END - 60, T_END], "close": [None, BASE.get(s, 100.0) * 1.01], "end": None,
                  "symbol": s, "previousClose": None, "chartPreviousClose": BASE.get(s, 100.0), "dataGranularity": 300}
    return json.dumps(out)


SEARCH = json.dumps({"explains": [], "count": 5, "quotes": [
    {"exchange": "NMS", "shortname": "Apple Inc.", "quoteType": "EQUITY", "symbol": "AAPL", "index": "quotes",
     "typeDisp": "Equity", "longname": "Apple Inc.", "exchDisp": "NASDAQ", "isYahooFinance": True},
    {"exchange": "FRA", "shortname": "Apple Inc.", "quoteType": "EQUITY", "symbol": "APC.F", "typeDisp": "Equity",
     "exchDisp": "Frankfurt"},
    {"index": "news-like entry without a symbol"},
    {"exchange": "MEX", "shortname": None, "longname": "Apple Inc. (MX)", "quoteType": "EQUITY", "symbol": "AAPL.MX",
     "typeDisp": None, "exchDisp": "Mexico"},
], "news": []})
NOT_FOUND = json.dumps({"chart": {"result": None, "error": {"code": "Not Found",
                                                            "description": "No data found, symbol may be delisted"}}})


def kraken_json(pair, interval):
    step = int(interval) * 60
    rows = []
    for c in series("BTC-USD", 720, step):
        rows.append([c["t"], "%.1f" % c["o"], "%.1f" % c["h"], "%.1f" % c["l"], "%.1f" % c["c"], "%.1f" % c["c"],
                     "%.8f" % (c["v"] / 1000.0), 123])
    return json.dumps({"error": [], "result": {"XXBTZUSD": rows, "last": T_END}})


class Env:
    def __init__(self, events=(), CW=51, CH=19, files=None, app=True):
        self.rt = lua.LuaRuntime(unpack_returned_tuples=True, encoding="latin-1")
        g = self.rt.globals()
        g.HOST_READ = lambda p: read(p)
        g.CW, g.CH, g.MW, g.MH = CW, CH, 0, 0
        g.HOST_EVENT = self.host_event
        g.PY_API = self.api
        g.SCRIPT_EVENTS = self.rt.table_from([self.lua(e) for e in events])
        g.SCRIPT_LINES = self.rt.table_from([])
        self.M = self.rt.execute(read("tests/mock_cc.lua"))
        self.reqs, self.problems, self.shots, self.blits = [], [], {}, {}
        self.rules = []                           # (predicate(url), (code, body[, retryAfter])) tried first
        self.hosts = {"click": self.click, "shot": self.shot, "at": self.at, "lua": self.run_lua, "tick": self.tick}
        for d in ("/os", "/os/lib", "/os/apps", "/os/bin", "/os/man"):
            self.M.FS[d] = True
        for p in ("os/config.lua", "os/lib/json.lua", "os/lib/market.lua", "os/lib/cli.lua", "os/apps/tradeview.lua",
                  "os/bin/ticker.lua"):
            self.M.FS["/" + p] = read("src/" + p)
        for k, v in (files or {}).items():
            self.M.FS[k] = v
        g.MOCK = self.M
        self.rt.execute(THEME + "\n" + PRELUDE + """
HOST_API = function(body, h)       -- the URL of the request being answered + its headers, as plain values
  h = h or {}
  return PY_API(MOCK.requests[#MOCK.requests].url, h["User-Agent"], h["Accept"])
end""")

    def lua(self, v):
        if isinstance(v, dict):
            return self.rt.table_from({k: self.lua(x) for k, x in v.items()})
        if isinstance(v, (list, tuple)):
            return self.rt.table_from([self.lua(x) for x in v])
        return v

    # ---- the fake internet
    def api(self, url, ua, accept):
        hd = {}
        if ua is not None:
            hd["User-Agent"] = ua
        if accept is not None:
            hd["Accept"] = accept
        self.reqs.append({"url": url, "headers": hd, "t": float(self.rt.globals().CLOCK)})
        for pred, resp in self.rules:
            if pred(url):
                return resp
        u = urlparse(url)
        q = parse_qs(u.query)
        if "finance.yahoo.com" in u.netloc:
            if "User-Agent" not in hd:
                return 429, "Too Many Requests"   # like the real Yahoo
            if u.path.startswith("/v8/finance/chart/"):
                sym = unquote(u.path.rsplit("/", 1)[1])
                if sym == "NOPE":
                    return 404, NOT_FOUND
                return 200, chart_json(sym, q["interval"][0], q["range"][0])
            if u.path == "/v8/finance/spark":
                return 200, spark_json(q["symbols"][0].split(","))
            if u.path == "/v1/finance/search":
                return 200, SEARCH
        if u.netloc == "api.kraken.com":
            if q.get("pair", [""])[0] != "XBTUSD":
                return 200, json.dumps({"error": ["EQuery:Unknown asset pair"]})
            return 200, kraken_json(q["pair"][0], q["interval"][0])
        self.problems.append("unexpected URL " + url)
        return 404, "not found"

    # ---- scripted UI events
    def host_event(self, name, *args):
        ev = self.hosts[name](*args)
        return None if ev is None else self.lua(ev)

    def screen(self):
        t = self.M.native
        return "\n".join(t.rows[y] for y in range(1, t.h + 1))

    def click(self, label, nth=1, min_row=1):
        t = self.M.native
        seen = 0
        for y in range(min_row, t.h + 1):
            start = 0
            while True:
                i = t.rows[y].find(label, start)
                if i < 0:
                    break
                seen += 1
                if seen == nth:
                    return ["mouse_click", 1, i + 1 + (len(label) - len(label.lstrip())), y]
                start = i + 1
        self.problems.append("not on screen: %r\n%s" % (label, self.screen()))
        return None

    def at(self, x, y):
        t = self.M.native
        return ["mouse_click", 1, t.w + x + 1 if x < 0 else x, t.h + y + 1 if y < 0 else y]

    def shot(self, name):
        self.shots[name] = self.screen()
        b = self.rt.globals().BLITS
        self.blits[name] = [(b[i].x, b[i].y, b[i].s, b[i].f, b[i].b) for i in range(1, len(b) + 1)] if b else []
        return None

    def run_lua(self, code):
        self.rt.execute(code)
        return None

    def tick(self):
        return ["timer", 999999]

    def run_app(self):
        f = self.rt.eval("function() return pcall(function() dofile('/os/apps/tradeview.lua').main() end) end")
        ok, err = f()
        g = self.rt.globals()
        return ok, err, int(g.WINDOW_VIOLATIONS or 0) + int(self.M.violations), list((g.WINDOW_LOG or {}).values())[:3]

    def plain(self, v):
        if lua.lua_type(v) == "table":
            keys = list(v.keys())
            if keys and all(isinstance(k, int) for k in keys):
                return [self.plain(v[i]) for i in sorted(keys)]
            return {k: self.plain(x) for k, x in v.items()}
        return v

    def call(self, code, n=2):
        """run Lua (the library is MK); its first n results as plain Python values (one value when n == 1)"""
        r = self.rt.execute("MK = MK or dofile('/os/lib/market.lua')\nlocal r = table.pack((function()\n" + code
                            + "\nend)()) return r")
        out = tuple(self.plain(r[i]) for i in range(1, max(n, int(r.n)) + 1))
        return out[0] if n == 1 else out

    def fs(self):
        return {k: v for k, v in self.M.FS.items()}


# ================================================================ 1. library
nf = len(fail)
env = Env(app=False)
d, err = env.call('return MK.chart("^IXIC", "1Y")')
check(err is None and d and d["source"] == "yahoo", "chart ^IXIC 1Y: %s %s" % (err, d and d.get("source")))
r0 = env.reqs[0]
check(r0["url"] == "https://query1.finance.yahoo.com/v8/finance/chart/%5EIXIC?interval=1d&range=1y", "url: %s" % r0["url"])
check(r0["headers"].get("User-Agent") == "WardenOS/%s (CC: Tweaked)" % VERSION, "User-Agent: %s" % r0["headers"])
check(r0["headers"].get("Accept") == "application/json", "Accept header: %s" % r0["headers"])
cds = d["candles"]
check(len(cds) == expected_candles("^IXIC", "1y"), "null gaps: %d candles, want %d" % (len(cds), expected_candles("^IXIC", "1y")))
check(all(c["h"] >= max(c["o"], c["c"]) and c["l"] <= min(c["o"], c["c"]) for c in cds), "candle h/l not sane")
check(all(cds[i]["t"] < cds[i + 1]["t"] for i in range(len(cds) - 1)), "candles not in time order")
q = d["quote"]
check(q["name"] == "NASDAQ Composite" and q["currency"] == "USD" and q["state"] in ("open", "closed"),
      "quote meta: %s" % q)
# interval per range + URL encoding (each one a fresh symbol, so nothing comes from the cache)
want = {"1D": ("5m", "1d"), "5D": ("1h", "5d"), "1M": ("1d", "1mo"), "6M": ("1d", "6mo"), "1Y": ("1d", "1y"),
        "5Y": ("1wk", "5y")}
for rng, (iv, yr) in want.items():
    n0 = len(env.reqs)
    d, err = env.call('return MK.chart("EURUSD=X", "%s")' % rng)
    url = env.reqs[n0]["url"] if len(env.reqs) > n0 else ""
    check(url == "https://query1.finance.yahoo.com/v8/finance/chart/EURUSD%%3DX?interval=%s&range=%s" % (iv, yr),
          "range %s: %s" % (rng, url))
    check(d and len(d["candles"]) == expected_candles("EURUSD=X", yr), "range %s: candles %s" % (rng, d and len(d["candles"])))
n0 = len(env.reqs)
d, err = env.call('return MK.chart("gc=f", "1D")')          # lower case input is normalised
check(env.reqs[n0]["url"].endswith("/chart/GC%3DF?interval=5m&range=1d"), "GC=F url: %s" % env.reqs[n0]["url"])
check(d and d["quote"].get("currency") is None and d["quote"]["price"], "json null currency: %s" % (d and d["quote"]))
check(env.call('return MK.encode("^IXIC"), MK.encode("EURUSD=X"), MK.encode("BTC-USD"), MK.encode("a b&c")', 4)
      == ("%5EIXIC", "EURUSD%3DX", "BTC-USD", "a%20b%26c"), "encode")
# every Yahoo request carried the User-Agent
check(all("User-Agent" in r["headers"] for r in env.reqs), "a request without User-Agent")
# rate limit: at least 2 s between requests (sleep advances the fake clock)
ts = [r["t"] for r in env.reqs]
check(all(ts[i + 1] - ts[i] >= 2 - 1e-9 for i in range(len(ts) - 1)), "requests closer than 2 s: %s" % ts)
# 60 s cache: same chart again -> no request; after 61 s -> a new one
n0 = len(env.reqs)
env.call('return MK.chart("^IXIC", "1Y")')
check(len(env.reqs) == n0, "cached chart was fetched again")
env.rt.execute("CLOCK = CLOCK + 61")
env.call('return MK.chart("^IXIC", "1Y")')
check(len(env.reqs) == n0 + 1, "stale chart not refreshed after 60 s")

# quote math
d, _ = env.call('return MK.chart("TEST", "1D")')
q = d["quote"]
check(abs(q["change"] - 10) < 1e-9 and abs(q["pct"] - 10) < 1e-9 and q["prev"] == 100, "quote math: %s" % q)
d, _ = env.call('return MK.chart("TEST2", "1D")')
check(abs(d["quote"]["pct"] - 25) < 1e-9, "previousClose not preferred: %s" % d["quote"])
d, _ = env.call('return MK.chart("TEST3", "1D")')
check(abs(d["quote"]["pct"] + 1) < 1e-9 and abs(d["quote"]["prev"] - 100) < 1e-9, "change percent only: %s" % d["quote"])
d, _ = env.call('return MK.chart("TEST", "1Y")')           # a range's chartPreviousClose is not the day's
check(d["quote"].get("prev") is None and d["quote"].get("pct") is None, "1Y chartPreviousClose used as previous close: %s" % d["quote"])

# spark quotes for the watchlist: one request, encoded symbols
n0 = len(env.reqs)
qs, err = env.call('return MK.quotes({ "AAPL", "^GSPC", "EURUSD=X", "NOPE" })')
check(len(env.reqs) == n0 + 1 and "symbols=AAPL,%5EGSPC,EURUSD%3DX,NOPE&" in env.reqs[n0]["url"], "spark url: %s" % env.reqs[n0:])
check(abs(qs["AAPL"]["price"] - 333.3) < 1e-6 and abs(qs["AAPL"]["pct"] - 1.0) < 1e-6, "spark quote: %s" % qs.get("AAPL"))
check("NOPE" not in qs, "unknown symbol got a quote")
n0 = len(env.reqs)
env.call('return MK.quotes({ "AAPL", "^GSPC" })')
check(len(env.reqs) == n0, "fresh quotes were fetched again")

# error object (404, delisted): one request, a clear message
n0 = len(env.reqs)
d, err = env.call('return MK.chart("NOPE", "1D")')
check(d is None and "delisted" in str(err) and len(env.reqs) == n0 + 1, "404 symbol: %s %s %d" % (d, err, len(env.reqs) - n0))

# search
res, err = env.call('return MK.search("apple")')
check(env.reqs[-1]["url"].startswith("https://query1.finance.yahoo.com/v1/finance/search?q=apple&"), "search url")
check([r["symbol"] for r in res] == ["AAPL", "APC.F", "AAPL.MX"] and res[0]["type"] == "Equity"
      and res[0]["exch"] == "NASDAQ" and res[2]["name"] == "Apple Inc. (MX)" and res[2]["type"] == "EQUITY",
      "search parse: %s" % res)

# connection failure on query1 -> query2
env.rules = [(lambda u: u.startswith("https://query1."), (0, ""))]
d, err = env.call('return MK.chart("NVDA", "1D")')
check(d and d["source"] == "yahoo" and env.reqs[-1]["url"].startswith("https://query2.finance.yahoo.com/"),
      "second host: %s %s" % (err, env.reqs[-1]["url"]))

# Yahoo down for BTC-USD -> Kraken
env.rules = [(lambda u: "finance.yahoo.com" in u, (500, "oops"))]
d, err = env.call('return MK.chart("BTC-USD", "1D")')
kr = [r for r in env.reqs if "kraken" in r["url"]]
check(kr and kr[-1]["url"] == "https://api.kraken.com/0/public/OHLC?pair=XBTUSD&interval=5", "kraken url: %s" % kr)
check(d and d["source"] == "kraken" and len(d["candles"]) == 288 and isinstance(d["candles"][0]["o"], float),
      "kraken candles: %s %s" % (err, d and (d["source"], len(d["candles"]))))
check(d and d["quote"]["price"] == d["candles"][-1]["c"] and d["quote"]["pct"] is not None, "kraken quote: %s" % (d and d["quote"]))
check(all("User-Agent" in r["headers"] for r in env.reqs), "kraken request without User-Agent")
env.rules = []

# 429: Retry-After respected, no request while backing off, query2 not hammered, then it works again
env.rt.execute("WardenMarket.backoff = {} WardenMarket.n429 = {}")
env.rules = [(lambda u: "finance.yahoo.com" in u, (429, "Too Many Requests", 45))]
n0 = len(env.reqs)
d, err = env.call('return MK.chart("MSFT", "1D")')
check(d is None and "429" in str(err) and len(env.reqs) == n0 + 1, "429: %s %s %d requests" % (d, err, len(env.reqs) - n0))
env.rt.execute("CLOCK = CLOCK + 10")
d, err = env.call('return MK.chart("MSFT", "1D")')
check(len(env.reqs) == n0 + 1 and "retry in" in str(err), "request sent while backing off: %s" % err)
q2, err2 = env.call('return MK.quotes({ "MSFT" })')
check(len(env.reqs) == n0 + 1, "spark request sent while backing off")
env.rules = []
env.rt.execute("CLOCK = CLOCK + 40")
d, err = env.call('return MK.chart("MSFT", "1D")')
check(d and err is None and len(env.reqs) == n0 + 2, "after the backoff: %s %s" % (err, len(env.reqs) - n0))
# without Retry-After: 30 s, doubling
env.rules = [(lambda u: "finance.yahoo.com" in u, (429, "Too Many Requests"))]
env.call('return MK.chart("AAPL", "5D")')
b1 = env.call("return (WardenMarket.backoff.yahoo / 1000) - CLOCK", 1)
env.rt.execute("CLOCK = CLOCK + 31")
env.call('return MK.chart("AAPL", "5D")')
b2 = env.call("return (WardenMarket.backoff.yahoo / 1000) - CLOCK", 1)
check(29 <= b1 <= 31 and 59 <= b2 <= 61, "backoff not 30 s doubling: %s %s" % (b1, b2))
env.rules = []

# disk cache: files exist, few and small; a fresh computer opens it offline with its age
files = env.fs()
cache = {k: v for k, v in files.items() if k.startswith("/os/tradeview/cache/") and isinstance(v, str)}
check("/os/tradeview/cache/_5EIXIC_1Y" in cache and "/os/tradeview/cache/quotes" in cache, "disk cache files: %s" % sorted(cache))
check(len([k for k in cache if k.rsplit("/", 1)[1] not in ("index", "quotes")]) <= 12, "more than 12 charts on disk")
check(max(len(v) for v in cache.values()) < 20000, "a cache file is too big: %d" % max(len(v) for v in cache.values()))
off = Env(app=False, files={k: v for k, v in files.items() if k.startswith("/os/tradeview")})
off.rules = [(lambda u: True, (0, ""))]
off.rt.execute("CLOCK = %r" % (float(env.rt.globals().CLOCK) + 300))
d, err = off.call('return MK.chart("^IXIC", "1Y")')
check(d and d["stale"] and d["age"] >= 300 and len(d["candles"]) == expected_candles("^IXIC", "1y") and err,
      "offline open: %s %s" % (err, d and (d.get("stale"), d.get("age"))))
check(re.match(r"\d+ min$", off.call('return MK.age(%d)' % d["age"], 1)), "age text: %s" % off.call('return MK.age(%d)' % d["age"], 1))
qs = off.call("return MK.peekQuotes()", 1)
check("AAPL" in qs and qs["AAPL"]["price"], "quotes not on disk: %s" % sorted(qs))
# no http at all
nohttp = Env(app=False)
nohttp.rt.execute("http = nil")
d, err = nohttp.call('return MK.chart("AAPL", "1D")')
check(d is None and "HTTP is disabled" in str(err), "no http: %s" % err)
# domain blocked (http.request returns false + reason)
blk = Env(app=False)
blk.rt.execute('http.request = function() return false, "Domain not permitted" end')
d, err = blk.call('return MK.chart("AAPL", "1D")')
check(d is None and "Domain not permitted" in str(err), "blocked: %s" % err)

# formatting
fmt = env.call('return MK.price(86133.354), MK.price(1.120437), MK.price(0.054321), MK.big(1234567), MK.big(987), '
               'MK.big(2.5e9), MK.pct(1.0559), MK.pct(-0.4), MK.change(-380.03, 86133), MK.compact(86133.35, 6), '
               'MK.compact(27190.86, 8)', 11)
check(fmt == ("86133.35", "1.1204", "0.05432", "1.23M", "987", "2.50B", "+1.06%", "-0.40%", "-380.03", "86133", "27190.86"),
      "formatting: %s" % (fmt,))
# config: default watchlist, saved + loaded
c = env.call("return MK.loadConfig()", 1)
check([w["s"] for w in c["watch"]] == ["BTC-USD", "ETH-USD", "^IXIC", "^GSPC", "^DJI", "AAPL", "NVDA", "GC=F", "EURUSD=X"]
      and c["range"] == "1D" and c["mode"] == "candles", "default config: %s" % c)
check(not env.problems, "library: %s" % env.problems[:3])
print("market library: ok" if len(fail) == nf else "market library: FAILED")


# ================================================================ 2. app
def app_events(lw, wide):
    ev = [["host", "shot", "start"]]
    for r in ("5D", "1M", "6M", "1Y", "5Y", "1D"):
        ev += [["host", "click", " %s " % r], ["host", "shot", "r-" + r]]
    ev += [["host", "click", " Line "], ["host", "shot", "line"], ["host", "click", " Candle "], ["host", "shot", "candle"]]
    ev += [["host", "at", -12, 8], ["host", "shot", "cross"], ["host", "at", 5, 2], ["host", "shot", "uncross"]]
    ev += [["mouse_scroll", -1, 30, 8], ["mouse_scroll", -1, 30, 8], ["host", "shot", "pan"]]
    if wide < 100:
        ev += [["host", "click", "[fit]"], ["host", "shot", "fit"]]
    ev += [["host", "click", "ETH-USD"], ["host", "shot", "eth"], ["key", DOWN], ["host", "shot", "down"]]
    ev += [["host", "click", " Search "]] + [["char", ch] for ch in "apple"] + [["key", ENTER], ["host", "shot", "results"]]
    ev += [["host", "click", " + ", 1, 4], ["host", "shot", "added"],
           ["host", "lua", "ADDED = dofile('/os/lib/market.lua').inWatch(dofile('/os/lib/market.lua').loadConfig(), 'APC.F')"], ["host", "click", "APC.F"], ["host", "shot", "apc"],
           ["host", "at", lw - 1, 4], ["host", "shot", "removed"]]
    ev += [["host", "lua", "CLOCK = CLOCK + 61"], ["host", "tick"], ["host", "shot", "refresh"]]
    return ev


for (cw, ch) in [(45, 17), (45, 18), (51, 20), (79, 36), (158, 79)]:
    tag = "app %dx%d" % (cw, ch)
    lw = 26 if cw >= 70 else max(15, min(22, cw * 33 // 100))
    env = Env(events=app_events(lw, cw), CW=cw, CH=ch)
    ok, err, viol, vlog = env.run_app()
    sh = env.shots
    ADDED_IN_CONFIG = {tag: env.rt.globals().ADDED}
    check(err == "SCRIPT_END", "%s: stopped early: %s" % (tag, err))
    check(viol == 0, "%s: %d chars outside the window %s" % (tag, viol, vlog))
    check(not env.problems, "%s: %s" % (tag, env.problems[:2]))
    s = sh.get("start", "")
    rows = s.split("\n")
    for label in (" 1D ", " 5D ", " 1M ", " 6M ", " 1Y ", " 5Y ", " Line ", " Search "):
        check(label in rows[0], "%s: toolbar misses %r: %r" % (tag, label, rows[0]))
    check("Bitcoin" in rows[1] and "BTC-USD" in rows[1] and "%" in rows[1] and re.search(r"\d+\.\d\d", rows[1]),
          "%s: header:\n%s" % (tag, s))
    check("delayed" in rows[2], "%s: delayed note:\n%s" % (tag, s))
    for sym in ("BTC-USD", "ETH-USD", "^IXIC", "^GSPC"):
        check(sym in s, "%s: watchlist misses %s:\n%s" % (tag, sym, s))
    check(re.search(r"[\^v]\d+\.\d\d%", s) is not None, "%s: watchlist change column:\n%s" % (tag, s))
    check("not financial advice" in rows[-1].lower() and "Yahoo" in rows[-1], "%s: footer: %r" % (tag, rows[-1]))
    check(re.search(r"\d\d:\d\d", rows[-2]) is not None, "%s: no time labels: %r" % (tag, rows[-2]))
    bg = "".join(b[4] for b in env.blits.get("start", []))
    check("d" in bg and "e" in bg, "%s: candles not green and red" % tag)
    check("|" in "".join(b[2] for b in env.blits.get("start", [])), "%s: no wicks" % tag)
    first = [r["url"] for r in env.reqs[:2]]
    check(any("/chart/BTC-USD?interval=5m&range=1d" in u for u in first) and any("/spark?" in u for u in first),
          "%s: first requests: %s" % (tag, first))
    for rng, iv in (("5D", "1h"), ("1M", "1d"), ("6M", "1d"), ("1Y", "1d"), ("5Y", "1wk")):
        sr = sh.get("r-" + rng, "")
        check("error" not in sr and "Bitcoin" in sr.split("\n")[1] and ("%s " % rng) in sr.split("\n")[2],
              "%s: range %s:\n%s" % (tag, rng, sr))
        yr = {"5D": "5d", "1M": "1mo", "6M": "6mo", "1Y": "1y", "5Y": "5y"}[rng]
        check(any(r["url"].endswith("BTC-USD?interval=%s&range=%s" % (iv, yr)) for r in env.reqs), "%s: no %s request" % (tag, rng))
    lb = env.blits.get("line", [])
    check(" Candle " in sh.get("line", "").split("\n")[0] and lb and "|" not in "".join(b[2] for b in lb),
          "%s: line mode:\n%s" % (tag, sh.get("line")))
    check(" Line " in sh.get("candle", "").split("\n")[0], "%s: back to candles" % tag)
    cr = sh.get("cross", "").split("\n")
    check(len(cr) > 3 and re.search(r"O \d+\.\d+ H \d+\.\d+ L \d+\.\d+", cr[2]) and "Vol " in cr[1],
          "%s: crosshair:\n%s" % (tag, sh.get("cross")))
    check("Bitcoin" in sh.get("uncross", "").split("\n")[1], "%s: crosshair not cleared" % tag)
    if cw < 100:                                  # 66 candles: only a narrower chart can pan
        check("<" in sh.get("pan", "").split("\n")[-2] and "[fit]" in sh.get("pan", ""), "%s: pan:\n%s" % (tag, sh.get("pan")))
        check("<" not in sh.get("fit", "").split("\n")[-2], "%s: fit:\n%s" % (tag, sh.get("fit")))
    check("Ethereum" in sh.get("eth", "").split("\n")[1], "%s: watchlist select:\n%s" % (tag, sh.get("eth")))
    check("NASDAQ" in sh.get("down", "").split("\n")[1], "%s: down key:\n%s" % (tag, sh.get("down")))
    rs = sh.get("results", "")
    check("AAPL" in rs and "APC.F" in rs and "Equity" in rs and "> apple" in rs and "results for apple" in rs,
          "%s: search results:\n%s" % (tag, rs))
    check(" * " in rs, "%s: AAPL (in the watchlist) not marked:\n%s" % (tag, rs))
    check(" * " in sh.get("added", "") and ADDED_IN_CONFIG.get(tag), "%s: + did not add:\n%s" % (tag, sh.get("added")))
    check("Apple Inc." in sh.get("apc", "").split("\n")[1] and "APC.F" in sh.get("apc", "").split("\n")[1],
          "%s: result tap:\n%s" % (tag, sh.get("apc")))
    rm = sh.get("removed", "")
    check(" + " in rm.split("\n")[3] and not env.call("return MK.inWatch(MK.loadConfig(), 'APC.F')", 1),
          "%s: remove from the watchlist:\n%s" % (tag, rm))
    check(any(r["url"].endswith("/chart/APC.F?interval=5m&range=1d") for r in env.reqs), "%s: APC.F chart not fetched" % tag)
    n_before = len([r for r in env.reqs if "/spark?" in r["url"]])
    check(n_before >= 2, "%s: auto-refresh did not refresh quotes (%d spark requests)" % (tag, n_before))
    check(all("User-Agent" in r["headers"] for r in env.reqs), "%s: a request without User-Agent" % tag)
    ts = [r["t"] for r in env.reqs]
    check(all(ts[i + 1] - ts[i] >= 2 - 1e-9 for i in range(len(ts) - 1)), "%s: requests closer than 2 s" % tag)
    if cw == 51:
        SAVED = {k: v for k, v in env.fs().items() if k.startswith("/os/tradeview")}
        SAVED_CLOCK = float(env.rt.globals().CLOCK)
print("app: ok" if len(fail) == nf else "app: FAILED")

# offline / 429 / no http, from the cache of the run above
nf = len(fail)
for kind, rule, want in [("offline", (0, ""), "offline: cached"), ("429", (429, "Too Many", 60), "rate-limited (429)")]:
    for (cw, ch) in [(45, 17), (51, 20)]:
        env = Env(events=[["host", "shot", "s"]], CW=cw, CH=ch, files=SAVED)
        env.rules = [(lambda u: True, rule)]
        env.rt.execute("CLOCK = %r" % (SAVED_CLOCK + 600))
        ok, err, viol, vlog = env.run_app()
        s = env.shots.get("s", "")
        rows = s.split("\n")
        check(err == "SCRIPT_END" and viol == 0, "%s %dx%d: %s %d %s" % (kind, cw, ch, err, viol, vlog))
        check(want in rows[2] and re.search(r"1\d min old", rows[2]), "%s %dx%d: status:\n%s" % (kind, cw, ch, s))
        check("d" in "".join(b[4] for b in env.blits.get("s", [])), "%s %dx%d: cached candles not drawn" % (kind, cw, ch))
        if kind == "429":
            check(len([r for r in env.reqs if "yahoo" in r["url"]]) <= 1, "429: Yahoo asked again: %s" % [r["url"] for r in env.reqs])
env = Env(events=[["host", "shot", "s"]], CW=51, CH=20)
env.rt.execute("http = nil")
ok, err, viol, vlog = env.run_app()
s = env.shots.get("s", "")
check(err == "SCRIPT_END" and viol == 0 and "HTTP is disabled" in s.split("\n")[2], "no http app:\n%s" % s)
print("app offline / 429 / no http: ok" if len(fail) == nf else "app offline / 429 / no http: FAILED")


# ================================================================ 3. ticker
nf = len(fail)


def ticker(*args, w=51, h=19, rules=None, files=None):
    env = Env(CW=w, CH=h, files=files)
    env.rules = rules or []
    f = env.rt.eval("function(...) local src = fs.open('/os/bin/ticker.lua', 'r').readAll() "
                    "local fn = assert(load(src, '=ticker', 't', _G)) return pcall(fn, ...) end")
    ok, res = f(*args)
    t = env.M.native
    text = "\n".join(t.rows[y].rstrip() for y in range(1, t.h + 1)).strip("\n")
    return env, ok, res, text


for (w, h) in [(51, 19), (26, 20)]:
    tag = "ticker %dx%d" % (w, h)
    env, ok, res, out = ticker("BTC-USD", "^IXIC", w=w, h=h)
    check(ok and res is True and "BTC-USD" in out and "^IXIC" in out and "86860" in out and "+1.00%" in out,
          "%s quotes:\n%s" % (tag, out))
    check(env.M.violations == 0 and len(env.reqs) == 1 and "/spark?symbols=BTC-USD,%5EIXIC&" in env.reqs[0]["url"],
          "%s: requests %s" % (tag, [r["url"] for r in env.reqs]))
    env, ok, res, out = ticker("-s", "apple", w=w, h=h)
    check(ok and "AAPL" in out and "Apple Inc." in out and "NASDAQ" in out and env.M.violations == 0, "%s -s:\n%s" % (tag, out))
    env, ok, res, out = ticker("-c", "BTC-USD", "1Y", w=w, h=h)
    bl = "".join(b for b in [])
    check(ok and res is True and "BTC-USD" in out and "1Y " in out and env.M.violations == 0
          and env.reqs and env.reqs[-1]["url"].endswith("BTC-USD?interval=1d&range=1y"), "%s -c:\n%s" % (tag, out))
    env, ok, res, out = ticker("--help", w=w, h=h)
    check(ok and "Usage: ticker" in out and "-s" in out and "-c" in out and not env.reqs and env.M.violations == 0,
          "%s --help:\n%s" % (tag, out))
    env, ok, res, out = ticker("NOPE", w=w, h=h)
    check(ok and "no data" in out and env.M.violations == 0, "%s unknown:\n%s" % (tag, out))
    env, ok, res, out = ticker("-c", "BTC-USD", "2W", w=w, h=h)
    check("range must be" in out, "%s bad range:\n%s" % (tag, out))
# Yahoo down: crypto quote comes from Kraken
env, ok, res, out = ticker("BTC-USD", rules=[(lambda u: "yahoo" in u, (503, "down"))])
check(ok and "BTC-USD" in out and re.search(r"\d+\.\d\d", out) and any("kraken" in r["url"] for r in env.reqs),
      "ticker via Kraken:\n%s" % out)
# the watchlist when no symbols are given
env, ok, res, out = ticker()
check(ok and "EURUSD=X" in out and "GC=F" in out, "ticker watchlist:\n%s" % out)
print("ticker: ok" if len(fail) == nf else "ticker: FAILED")

print()
if fail:
    print("%d problem(s)" % len(fail))
    sys.exit(1)
print("all TradeView checks passed")
