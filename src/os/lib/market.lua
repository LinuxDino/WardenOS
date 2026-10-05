-- Market data for TradeView and `ticker`: stocks, indices, crypto, forex, futures from Yahoo Finance (unofficial,
-- no key, delayed), Kraken public OHLC as a fallback for crypto. Must run inside a coroutine that gets events
-- (an app, a program): requests wait with os.pullEvent, like /os/lib/claude.lua.
--
--   M.chart(symbol, range)   -> data | nil, err   range: "1D" "5D" "1M" "6M" "1Y" "5Y"
--       data = { symbol, range, interval, candles = { { t, o, h, l, c, v }, ... }, quote = q, source, fetched,
--                age (s), stale = true + err when it is cached data because the network failed }
--   M.quotes({ symbol, ... }) -> { [symbol] = q }, err      one request for the whole list (Yahoo spark)
--       q = { symbol, name, price, prev, change, pct, currency, type, exchange, state, gmtoffset, time }
--   M.search(text)           -> { { symbol, name, type, exch }, ... } | nil, err
--   M.peek(symbol, range) / M.peekQuotes()   cached data only, never a request (memory, then disk)
--   M.loadConfig() / M.saveConfig(c)          watchlist + settings in /os/tradeview/config
--   M.price(n) M.big(n) M.pct(p) M.change(n, ref) M.compact(n, width)   number formatting
--
-- Polite by design: every request carries a User-Agent (Yahoo answers 429 without one), at most one request per
-- 2 s (shared by every program on this computer), a chart or quote is fetched at most once per 60 s, a 429 backs
-- off (Retry-After, else 30 s doubling up to 5 min), and the last good data is kept on disk so it opens offline.
local json = dofile("/os/lib/json.lua")

local M = { json = json }
M.HOSTS = { "https://query1.finance.yahoo.com", "https://query2.finance.yahoo.com" }
M.KRAKEN_URL = "https://api.kraken.com/0/public/OHLC"
M.GAP = 2                    -- seconds between two requests
M.FRESH = 60                 -- seconds a chart / quote stays fresh
M.TIMEOUT = 20
M.DIR = "/os/tradeview"
M.CACHE = M.DIR .. "/cache"
M.CONFIG = M.DIR .. "/config"
M.MAX_FILES = 12             -- charts kept on disk (~15 KB each at most)
M.MAX_CANDLES = 400

M.RANGES = { "1D", "5D", "1M", "6M", "1Y", "5Y" }
M.RANGE = {                  -- Yahoo range + interval, Kraken interval (minutes), seconds shown
  ["1D"] = { range = "1d", interval = "5m", kraken = 5, span = 86400 },
  ["5D"] = { range = "5d", interval = "1h", kraken = 60, span = 5 * 86400 },
  ["1M"] = { range = "1mo", interval = "1d", kraken = 1440, span = 31 * 86400 },
  ["6M"] = { range = "6mo", interval = "1d", kraken = 1440, span = 183 * 86400 },
  ["1Y"] = { range = "1y", interval = "1d", kraken = 1440, span = 366 * 86400 },
  ["5Y"] = { range = "5y", interval = "1wk", kraken = 10080, span = 5 * 366 * 86400 },
}
M.KRAKEN = { ["BTC-USD"] = "XBTUSD", ["ETH-USD"] = "ETHUSD", ["SOL-USD"] = "SOLUSD", ["XRP-USD"] = "XRPUSD",
             ["DOGE-USD"] = "XDGUSD", ["LTC-USD"] = "LTCUSD", ["ADA-USD"] = "ADAUSD", ["BTC-EUR"] = "XBTEUR",
             ["ETH-EUR"] = "ETHEUR" }
M.DEFAULT_WATCH = {
  { s = "BTC-USD", n = "Bitcoin" }, { s = "ETH-USD", n = "Ethereum" }, { s = "^IXIC", n = "NASDAQ" },
  { s = "^GSPC", n = "S&P 500" }, { s = "^DJI", n = "Dow Jones" }, { s = "AAPL", n = "Apple" },
  { s = "NVDA", n = "NVIDIA" }, { s = "GC=F", n = "Gold" }, { s = "EURUSD=X", n = "EUR/USD" },
}

---------------------------------------------------------------- helpers
local function now()                              -- ms (UTC)
  local ok, t = pcall(os.epoch, "utc")
  if ok and tonumber(t) then return tonumber(t) end
  return os.clock() * 1000
end
M.now = now
local function num(v) return type(v) == "number" and v == v and v or nil end
local function str(v)                             -- non-empty string; UTF-8 folded to "?" (CC's font is 8-bit)
  if type(v) ~= "string" or v == "" then return nil end
  return (v:gsub("[\192-\255][\128-\191]*", "?"))
end
local function tab(v) return type(v) == "table" and v ~= json.null and v or nil end

-- state shared by every program on this computer (rate limit, backoff, memory cache)
local function S()
  local G = rawget(_G, "WardenMarket")
  if type(G) ~= "table" then
    G = { last = -1e12, backoff = {}, n429 = {}, mem = {}, quotes = {}, requests = 0 }
    rawset(_G, "WardenMarket", G)
  end
  return G
end
M.state = S

function M.version()
  local W = rawget(_G, "WardenOS")
  if type(W) == "table" and W.version then return tostring(W.version) end
  if fs.exists("/os/config.lua") then
    local ok, c = pcall(dofile, "/os/config.lua")
    if ok and type(c) == "table" and c.version then return tostring(c.version) end
  end
  return "1"
end
function M.headers()
  return { ["User-Agent"] = "WardenOS/" .. M.version() .. " (CC: Tweaked)", ["Accept"] = "application/json" }
end

function M.encode(s)                              -- URL-encode a symbol / query (^IXIC -> %5EIXIC)
  return (tostring(s):gsub("[^%w%-%._~]", function(c) return ("%%%02X"):format(c:byte()) end))
end
function M.norm(s)                                -- user input -> symbol
  s = tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""):upper()
  return s
end
function M.isCrypto(sym, q)
  if q and q.type == "CRYPTOCURRENCY" then return true end
  return M.KRAKEN[sym] ~= nil
end

function M.chartUrl(sym, range, host)
  local r = M.RANGE[range] or M.RANGE["1D"]
  return ("%s/v8/finance/chart/%s?interval=%s&range=%s"):format(host or M.HOSTS[1], M.encode(sym), r.interval, r.range)
end
function M.sparkUrl(list, host)
  local enc = {}
  for i, s in ipairs(list) do enc[i] = M.encode(s) end
  return ("%s/v8/finance/spark?symbols=%s&range=1d&interval=1d"):format(host or M.HOSTS[1], table.concat(enc, ","))
end
function M.searchUrl(text, host)
  return ("%s/v1/finance/search?q=%s&quotesCount=10&newsCount=0&listsCount=0"):format(host or M.HOSTS[1],
    M.encode(text))
end
function M.krakenUrl(sym, range)
  local r = M.RANGE[range] or M.RANGE["1D"]
  return ("%s?pair=%s&interval=%d"):format(M.KRAKEN_URL, M.KRAKEN[sym] or "", r.kraken)
end

---------------------------------------------------------------- one request
-- host: "yahoo" | "kraken" (rate-limit / backoff bucket). Returns body | nil, message, code
-- code: HTTP status, 0 = connection failed / timed out, "nohttp", "blocked", "backoff"
function M.get(url, host)
  local G = S()
  if type(http) ~= "table" or type(http.request) ~= "function" then
    return nil, "HTTP is disabled (enable it in the CC: Tweaked config)", "nohttp"
  end
  local until_ = G.backoff[host] or 0
  if until_ > now() then
    return nil, ("rate-limited (429), retry in %ds"):format(math.ceil((until_ - now()) / 1000)), "backoff"
  end
  local wait = G.last + M.GAP * 1000 - now()
  if wait > 0 then sleep(wait / 1000) end
  G.last = now()
  G.requests = G.requests + 1
  local req = { url = url, headers = M.headers(), method = "GET" }
  local ok, res, why
  for _, t in ipairs({ M.TIMEOUT, false }) do     -- servers may refuse a timeout ("timeout out of range")
    req.timeout = t or nil
    ok, res, why = pcall(http.request, req)
    if ok or not tostring(res):lower():find("timeout") then break end
  end
  if not ok then return nil, "could not send the request: " .. tostring(res), 0 end
  if res == false then
    local msg = tostring(why or "request refused")
    if msg:lower():find("permit") or msg:lower():find("blocked") or msg:lower():find("not allowed") then
      return nil, "blocked by the server's HTTP rules: " .. msg, "blocked"
    end
    return nil, msg, 0
  end
  local timer = os.startTimer(M.TIMEOUT + 5)
  while true do
    local e, a, b, c = os.pullEvent()
    if e == "timer" and a == timer then
      return nil, "no answer (timed out)", 0
    elseif e == "http_success" and a == url then
      local text = b.readAll() or ""
      local code = b.getResponseCode and b.getResponseCode() or 200
      b.close()
      G.n429[host] = 0
      return text, nil, code
    elseif e == "http_failure" and a == url then
      local code, text, after
      if c then
        code = c.getResponseCode and c.getResponseCode()
        text = c.readAll and c.readAll()
        local h = c.getResponseHeaders and c.getResponseHeaders() or {}
        after = tonumber(h["Retry-After"] or h["retry-after"] or "")
        c.close()
      end
      if code == 429 then
        local n = (G.n429[host] or 0) + 1
        G.n429[host] = n
        local secs = math.min(300, math.max(after or 0, 30 * 2 ^ (n - 1)))
        G.backoff[host] = now() + secs * 1000
        return nil, ("rate-limited (429), retry in %ds"):format(secs), 429
      end
      if code then
        local msg = ("HTTP %d"):format(code)
        local okj, d = pcall(json.decode, text or "")
        local err = okj and tab(d) and tab(d.chart) and tab(d.chart.error)
        if err and str(err.description) then msg = msg .. ": " .. err.description end
        return nil, msg, code, text
      end
      return nil, "offline: " .. tostring(b or "could not connect"), 0
    end
  end
end

---------------------------------------------------------------- parsing (defensive: nulls, missing fields)
local function arr(v) v = tab(v) return v or {} end

function M.marketState(meta)
  if str(meta.marketState) then return meta.marketState:lower() end
  if meta.instrumentType == "CRYPTOCURRENCY" then return "24/7" end
  local p = tab(meta.currentTradingPeriod)
  local r = p and tab(p.regular)
  local s, e = r and num(r.start), r and num(r["end"])
  if s and e then
    local t = now() / 1000
    return (t >= s and t < e) and "open" or "closed"
  end
end

function M.quoteFromMeta(meta, candles, range)
  meta = tab(meta) or {}
  candles = candles or {}
  local last = candles[#candles]
  local price = num(meta.regularMarketPrice) or (last and last.c)
  if not price then return nil end
  local prev = num(meta.previousClose)
  if not prev and (range == "1D" or range == nil) then prev = num(meta.chartPreviousClose) end
  local change, pct
  if prev and prev ~= 0 then
    change = price - prev
    pct = change / prev * 100
  elseif num(meta.regularMarketChangePercent) then
    pct = meta.regularMarketChangePercent
    prev = price / (1 + pct / 100)
    change = price - prev
  end
  return {
    symbol = str(meta.symbol), name = str(meta.shortName) or str(meta.longName), price = price, prev = prev,
    change = change, pct = pct, currency = str(meta.currency), type = str(meta.instrumentType),
    exchange = str(meta.fullExchangeName) or str(meta.exchangeName), tz = str(meta.exchangeTimezoneName),
    gmtoffset = num(meta.gmtoffset) or 0, state = M.marketState(meta), time = num(meta.regularMarketTime),
  }
end

-- Yahoo chart JSON -> candles, quote | nil, err
function M.parseChart(text, range)
  local ok, d = pcall(json.decode, text or "")
  if not ok or not tab(d) then return nil, "unreadable reply" end
  local ch = tab(d.chart)
  if not ch then
    local f = tab(d.finance)
    local e = f and tab(f.error)
    return nil, e and (str(e.description) or str(e.code)) or "unexpected reply"
  end
  local e = tab(ch.error)
  if e then return nil, str(e.description) or str(e.code) or "error" end
  local r = tab(ch.result)
  r = r and tab(r[1])
  if not r then return nil, "no data for this symbol" end
  local ts = arr(r.timestamp)
  local ind = tab(r.indicators)
  local q = ind and tab(ind.quote)
  q = q and tab(q[1]) or {}
  local O, Hh, L, C, V = arr(q.open), arr(q.high), arr(q.low), arr(q.close), arr(q.volume)
  local out = {}
  for i = 1, #ts do
    local t, o, h, l, c = num(ts[i]), num(O[i]), num(Hh[i]), num(L[i]), num(C[i])
    if t and o and h and l and c then           -- null gaps (no trades / holidays) are skipped
      out[#out + 1] = { t = t, o = o, h = math.max(h, o, c), l = math.min(l, o, c), c = c, v = num(V[i]) or 0 }
    end
  end
  local quote = M.quoteFromMeta(r.meta, out, range)
  return out, quote
end

-- Kraken OHLC JSON -> candles | nil, err
function M.parseKraken(text)
  local ok, d = pcall(json.decode, text or "")
  if not ok or not tab(d) then return nil, "unreadable reply" end
  local errs = tab(d.error)
  if errs and errs[1] then return nil, tostring(errs[1]) end
  local res = tab(d.result)
  if not res then return nil, "unexpected reply" end
  local rows
  for k, v in pairs(res) do if k ~= "last" and tab(v) then rows = v end end
  if not rows then return nil, "no data" end
  local out = {}
  for _, row in ipairs(rows) do
    row = tab(row)
    if row then
      local t, o, h, l, c = tonumber(row[1]), tonumber(row[2]), tonumber(row[3]), tonumber(row[4]), tonumber(row[5])
      if t and o and h and l and c then
        out[#out + 1] = { t = t, o = o, h = math.max(h, o, c), l = math.min(l, o, c), c = c, v = tonumber(row[7]) or 0 }
      end
    end
  end
  return out
end

-- Yahoo spark JSON (several symbols) -> { [symbol] = quote }
function M.parseSpark(text)
  local ok, d = pcall(json.decode, text or "")
  if not ok or not tab(d) then return nil, "unreadable reply" end
  local out = {}
  local fin = tab(d.finance)
  if fin and tab(fin.error) then return nil, str(fin.error.description) or "error" end
  local sp = tab(d.spark)
  if sp then                                      -- older format: { spark = { result = { { symbol, response } } } }
    local e = tab(sp.error)
    if e then return nil, str(e.description) or "error" end
    for _, it in ipairs(arr(sp.result)) do
      local resp = tab(it) and tab(it.response)
      local r = resp and tab(resp[1])
      if r then
        local cds = {}
        local ind = tab(r.indicators)
        local q = ind and tab(ind.quote)
        q = q and tab(q[1]) or {}
        for i, c in ipairs(arr(q.close)) do if num(c) then cds[#cds + 1] = { c = c } end end
        local qt = M.quoteFromMeta(r.meta, cds, "1D")
        if qt and qt.symbol then out[qt.symbol] = qt end
      end
    end
    return out
  end
  for sym, v in pairs(d) do
    v = tab(v)
    if v and type(sym) == "string" then
      local price
      for _, c in ipairs(arr(v.close)) do price = num(c) or price end
      local prev = num(v.previousClose) or num(v.chartPreviousClose)
      if price then
        local q = { symbol = sym, price = price, prev = prev }
        if prev and prev ~= 0 then q.change = price - prev q.pct = q.change / prev * 100 end
        out[sym] = q
      end
    end
  end
  return out
end

-- Yahoo search JSON -> { { symbol, name, type, exch } }
function M.parseSearch(text)
  local ok, d = pcall(json.decode, text or "")
  if not ok or not tab(d) then return nil, "unreadable reply" end
  local out = {}
  for _, q in ipairs(arr(d.quotes)) do
    q = tab(q)
    if q and str(q.symbol) then
      out[#out + 1] = { symbol = q.symbol, name = str(q.shortname) or str(q.longname) or q.symbol,
                        type = str(q.typeDisp) or str(q.quoteType) or "", exch = str(q.exchDisp) or str(q.exchange) or "" }
    end
  end
  return out
end

---------------------------------------------------------------- disk cache
local function readFile(p)
  if not fs.exists(p) then return nil end
  local f = fs.open(p, "r")
  if not f then return nil end
  local s = f.readAll()
  f.close()
  return s
end
local function writeFile(p, s)
  local okFree, free = pcall(fs.getFreeSpace, M.DIR)
  if okFree and tonumber(free) and free < #s + 64 * 1024 then return false end    -- keep the disk usable
  pcall(fs.makeDir, fs.getDir(p))
  local f = fs.open(p, "w")
  if not f then return false end
  f.write(s)
  f.close()
  return true
end
local function g10(n) return ("%.10g"):format(n) end
local function packCandles(cds)
  local out = {}
  local from = math.max(1, #cds - M.MAX_CANDLES + 1)
  for i = from, #cds do
    local c = cds[i]
    out[#out + 1] = table.concat({ g10(c.t), g10(c.o), g10(c.h), g10(c.l), g10(c.c), g10(c.v or 0) }, ",")
  end
  return table.concat(out, ";")
end
local function unpackCandles(s)
  local out = {}
  for rec in tostring(s or ""):gmatch("[^;]+") do
    local t, o, h, l, c, v = rec:match("^([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+)$")
    t, o, h, l, c, v = tonumber(t), tonumber(o), tonumber(h), tonumber(l), tonumber(c), tonumber(v)
    if t and o and h and l and c then out[#out + 1] = { t = t, o = o, h = h, l = l, c = c, v = v or 0 } end
  end
  return out
end
local function cacheFile(sym, range) return ("%s/%s_%s"):format(M.CACHE, M.encode(sym):gsub("%%", "_"), range) end
local function cleanQuote(q)
  if type(q) ~= "table" then return nil end
  local o = {}
  for k, v in pairs(q) do if type(v) == "number" or type(v) == "string" then o[k] = v end end
  return o
end

local function saveDisk(d)
  local p = cacheFile(d.symbol, d.range)
  local s = textutils.serialize({ symbol = d.symbol, range = d.range, interval = d.interval, source = d.source,
    fetched = d.fetched, quote = cleanQuote(d.quote), candles = packCandles(d.candles) })
  if not writeFile(p, s) then return end
  -- keep the newest M.MAX_FILES charts (index = most recent first)
  local idx = textutils.unserialize(readFile(M.CACHE .. "/index") or "")
  idx = type(idx) == "table" and idx or {}
  local out = { p }
  for _, f in ipairs(idx) do
    if f ~= p then
      if #out < M.MAX_FILES then out[#out + 1] = f elseif fs.exists(f) then pcall(fs.delete, f) end
    end
  end
  writeFile(M.CACHE .. "/index", textutils.serialize(out))
end
local function loadDisk(sym, range)
  local d = textutils.unserialize(readFile(cacheFile(sym, range)) or "")
  if type(d) ~= "table" or type(d.candles) ~= "string" then return nil end
  d.candles = unpackCandles(d.candles)
  d.fetched = tonumber(d.fetched) or 0
  d.symbol, d.range = sym, range
  d.disk = true
  return d
end
local function saveQuotes()
  local G = S()
  local out = {}
  for k, q in pairs(G.quotes) do out[k] = cleanQuote(q) end
  writeFile(M.CACHE .. "/quotes", textutils.serialize(out))
end
local function loadQuotes()
  local G = S()
  if G.quotesLoaded then return end
  G.quotesLoaded = true
  local d = textutils.unserialize(readFile(M.CACHE .. "/quotes") or "")
  if type(d) == "table" then
    for k, q in pairs(d) do if type(q) == "table" and G.quotes[k] == nil then G.quotes[k] = q end end
  end
end

local function withAge(d)
  if not d then return nil end
  d.age = math.max(0, math.floor((now() - (d.fetched or 0)) / 1000))
  return d
end

function M.peek(sym, range)
  local G = S()
  local key = sym .. "|" .. range
  local d = G.mem[key]
  if not d then
    d = loadDisk(sym, range)
    if d then d.stale = true G.mem[key] = d end
  end
  return withAge(d)
end
function M.peekQuotes()
  loadQuotes()
  return S().quotes
end
function M.forget()                               -- memory only (tests, "refresh now")
  local G = S()
  G.mem, G.quotes, G.quotesLoaded = {}, {}, false
end

---------------------------------------------------------------- public calls
local function trimSpan(cds, range)
  local r = M.RANGE[range]
  if not r or #cds == 0 then return cds end
  local cut = cds[#cds].t - r.span
  local out = {}
  for _, c in ipairs(cds) do if c.t > cut then out[#out + 1] = c end end
  return out
end

local function setQuote(sym, q, t)
  if not q then return end
  q.symbol = q.symbol or sym
  q.fetched = t or now()
  local old = S().quotes[sym]
  if old then                                     -- keep a name / currency learned earlier
    for _, k in ipairs({ "name", "currency", "type", "exchange", "state", "tz" }) do
      if q[k] == nil then q[k] = old[k] end
    end
  end
  S().quotes[sym] = q
end

function M.chart(sym, range, opts)
  opts = opts or {}
  sym, range = M.norm(sym), M.RANGE[range] and range or "1D"
  local G = S()
  local key = sym .. "|" .. range
  local cached = G.mem[key] or loadDisk(sym, range)
  if cached and not cached.stale and not opts.force and now() - (cached.fetched or 0) < M.FRESH * 1000 then
    return withAge(cached)
  end
  local r = M.RANGE[range]
  local errs, code, lastCode = {}, nil, nil
  for _, host in ipairs(M.HOSTS) do
    local body, err
    body, err, code = M.get(M.chartUrl(sym, range, host), "yahoo")
    if body then
      local cds, q = M.parseChart(body, range)
      if cds then
        local d = { symbol = sym, range = range, interval = r.interval, candles = cds, quote = q, source = "yahoo",
                    fetched = now() }
        if range == "1D" or not G.quotes[sym] then setQuote(sym, q) saveQuotes() end
        G.mem[key] = d
        saveDisk(d)
        return withAge(d)
      end
      err = q                                     -- parse error message
      errs[#errs + 1] = err
      if err == "no data for this symbol" or tostring(err):lower():find("delisted") then break end
    else
      errs[#errs + 1] = err
      lastCode = code
      if code == 404 then break end               -- unknown symbol: the other host says the same
      if code == 429 or code == "backoff" or code == "nohttp" or code == "blocked" then break end
    end
  end
  if M.KRAKEN[sym] and lastCode ~= "nohttp" then  -- crypto: Kraken public OHLC
    local body, err = M.get(M.krakenUrl(sym, range), "kraken")
    local cds = body and M.parseKraken(body)
    if cds and #cds > 0 then
      cds = trimSpan(cds, range)
      local first, last = cds[1], cds[#cds]
      local prev = range == "1D" and first.o or nil
      local q = { symbol = sym, name = (G.quotes[sym] and G.quotes[sym].name) or sym, price = last.c, prev = prev,
                  currency = sym:match("%-(%u+)$") or "USD", type = "CRYPTOCURRENCY", exchange = "Kraken", state = "24/7",
                  gmtoffset = 0 }
      if prev and prev ~= 0 then q.change = last.c - prev q.pct = q.change / prev * 100 end
      local d = { symbol = sym, range = range, interval = r.interval, candles = cds, quote = q, source = "kraken",
                  fetched = now() }
      if range == "1D" then setQuote(sym, q) saveQuotes() end
      G.mem[key] = d
      saveDisk(d)
      return withAge(d), errs[1]
    end
    errs[#errs + 1] = "Kraken: " .. tostring(err or "no data")
  end
  local msg = errs[1] or "no data"
  if cached then
    cached.stale, cached.err = true, msg
    G.mem[key] = cached
    return withAge(cached), msg
  end
  return nil, msg
end

function M.quotes(list)
  loadQuotes()
  local G = S()
  local want, errs = {}, nil
  for _, s in ipairs(list or {}) do
    s = M.norm(s)
    local q = G.quotes[s]
    if not (q and q.fetched and now() - q.fetched < M.FRESH * 1000) then want[#want + 1] = s end
  end
  local i = 1
  while i <= #want do                             -- up to 10 symbols per request
    local part = {}
    for k = i, math.min(#want, i + 9) do part[#part + 1] = want[k] end
    i = i + 10
    local got
    for _, host in ipairs(M.HOSTS) do
      local body, err, code = M.get(M.sparkUrl(part, host), "yahoo")
      if body then
        got, err = M.parseSpark(body)
        if got then
          for sym, q in pairs(got) do setQuote(sym, q) end
          break
        end
      end
      errs = errs or err
      if code == 429 or code == "backoff" or code == "nohttp" or code == "blocked" then break end
    end
    if not got then break end
  end
  saveQuotes()
  return G.quotes, errs
end

function M.search(text)
  text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return {} end
  local G = S()
  local key = "search|" .. text:lower()
  local c = G.mem[key]
  if c and now() - c.fetched < 300 * 1000 then return c.list end
  local lastErr
  for _, host in ipairs(M.HOSTS) do
    local body, err, code = M.get(M.searchUrl(text, host), "yahoo")
    if body then
      local list, perr = M.parseSearch(body)
      if list then
        G.mem[key] = { fetched = now(), list = list }
        return list
      end
      err = perr
    end
    lastErr = err
    if code == 429 or code == "backoff" or code == "nohttp" or code == "blocked" then break end
  end
  return nil, lastErr
end

---------------------------------------------------------------- config (watchlist + settings)
function M.loadConfig()
  local c = { watch = {}, range = "1D", mode = "candles" }
  local d = textutils.unserialize(readFile(M.CONFIG) or "")
  if type(d) == "table" and type(d.watch) == "table" then
    for _, w in ipairs(d.watch) do
      if type(w) == "table" and type(w.s) == "string" and w.s ~= "" then
        c.watch[#c.watch + 1] = { s = w.s, n = type(w.n) == "string" and w.n or nil }
      end
    end
  else
    for i, w in ipairs(M.DEFAULT_WATCH) do c.watch[i] = { s = w.s, n = w.n } end
  end
  if type(d) == "table" then
    if M.RANGE[d.range] then c.range = d.range end
    if d.mode == "line" then c.mode = "line" end
    if type(d.sel) == "string" then c.sel = d.sel end
  end
  return c
end
function M.saveConfig(c)
  local w = {}
  for i, x in ipairs(c.watch or {}) do w[i] = { s = x.s, n = x.n } end
  writeFile(M.CONFIG, textutils.serialize({ watch = w, range = c.range, mode = c.mode, sel = c.sel }))
end
function M.inWatch(c, sym)
  for i, w in ipairs(c.watch) do if w.s == sym then return i end end
end

---------------------------------------------------------------- formatting
function M.decimals(n)
  local a = math.abs(tonumber(n) or 0)
  if a >= 10 or a == 0 then return 2 end
  if a >= 1 then return 4 end
  if a >= 0.01 then return 5 end
  return 8
end
function M.price(n, ref)
  n = tonumber(n)
  if not n then return "-" end
  return ("%." .. M.decimals(ref or n) .. "f"):format(n)
end
function M.big(n)                                 -- 1234567 -> 1.23M
  n = tonumber(n)
  if not n then return "-" end
  local a = math.abs(n)
  for _, s in ipairs({ { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "k" } }) do
    if a >= s[1] then
      local v = n / s[1]
      local f = math.abs(v) >= 100 and "%.0f" or (math.abs(v) >= 10 and "%.1f" or "%.2f")
      return f:format(v) .. s[2]
    end
  end
  return ("%.0f"):format(n)
end
function M.compact(n, w)                          -- a price that fits in w characters
  n = tonumber(n)
  if not n then return "-" end
  local s = M.price(n)
  if #s <= w then return s end
  s = ("%.0f"):format(n)
  if #s <= w then return s end
  return M.big(n)
end
function M.pct(p)
  p = tonumber(p)
  if not p then return "--" end
  local a = math.abs(p)
  local s = a >= 1000 and ("%.0f"):format(a) or (a >= 100 and ("%.1f"):format(a) or ("%.2f"):format(a))
  return (p > 0 and "+" or (p < 0 and "-" or "")) .. s .. "%"
end
function M.change(n, ref)
  n = tonumber(n)
  if not n then return "--" end
  local s = M.price(math.abs(n), ref or n)
  return (n > 0 and "+" or (n < 0 and "-" or "")) .. s
end
function M.age(secs)
  secs = tonumber(secs) or 0
  if secs < 90 then return ("%ds"):format(secs) end
  if secs < 5400 then return ("%d min"):format(math.floor(secs / 60 + 0.5)) end
  if secs < 172800 then return ("%d h"):format(math.floor(secs / 3600 + 0.5)) end
  return ("%d days"):format(math.floor(secs / 86400 + 0.5))
end
function M.date(t, fmt, offset)                   -- time in the exchange's zone
  t = tonumber(t)
  if not t then return "--" end
  local ok, s = pcall(os.date, "!" .. fmt, math.floor(t + (offset or 0)))
  if ok and type(s) == "string" then return s end
  local d = (t + (offset or 0)) % 86400
  return ("%02d:%02d"):format(math.floor(d / 3600), math.floor(d / 60) % 60)
end

return M
