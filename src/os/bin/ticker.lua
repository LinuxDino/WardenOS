-- ticker: market prices in the terminal (Yahoo Finance, delayed; Kraken for crypto when Yahoo fails)
local cli = dofile("/os/lib/cli.lua").init("ticker", shell)

local function market()
  if not fs.exists("/os/lib/market.lua") then cli.fail("/os/lib/market.lua is missing (reinstall WardenOS)") end
  return dofile("/os/lib/market.lua")
end

local function quoteLine(MK, sym, q, w)
  local name = q and q.name
  local col = (q and q.change or 0) > 0 and colors.green or ((q and q.change or 0) < 0 and colors.red or colors.lightGray)
  if not q or not q.price then
    cli.write(sym, colors.white)
    cli.print("  no data", colors.red)
    return false
  end
  local arrow = (q.change or 0) > 0 and "^" or ((q.change or 0) < 0 and "v" or "=")
  local price = MK.price(q.price)
  local chg = MK.change(q.change, q.price)
  local pct = MK.pct(q.pct)
  if w >= 40 then
    cli.write(("%-10s"):format(sym), colors.white)
    cli.write(("%12s "):format(price), colors.yellow)
    cli.write(("%s %s %s"):format(arrow, chg, pct), col)
    if q.currency then cli.write(" " .. q.currency, colors.lightGray) end
    cli.print("")
    if name and name ~= sym then cli.print("  " .. name, colors.lightGray) end
  else
    cli.write(sym .. " ", colors.white)
    cli.print(price, colors.yellow)
    cli.print(("  %s %s %s"):format(arrow, chg, pct), col)
  end
  return true
end

-- a mini chart: one column per bar (closes, merged to fit), green/red by the range's direction
local function mini(MK, d, w, h)
  local cds = d.candles
  local aw = 0
  local hi, lo = -math.huge, math.huge
  for _, c in ipairs(cds) do hi, lo = math.max(hi, c.h), math.min(lo, c.l) end
  local lh, ll = MK.price(hi, hi), MK.price(lo, hi)
  aw = math.max(#lh, #ll) + 1
  local cw = math.max(4, w - aw)
  if aw + cw > w then aw = 0 cw = w end
  local k = math.ceil(#cds / cw)
  local bars = {}
  local i = #cds
  while i >= 1 do                                 -- groups end at the newest candle
    local a = math.max(1, i - k + 1)
    local b = { o = cds[a].o, c = cds[i].c, h = -math.huge, l = math.huge }
    for j = a, i do b.h, b.l = math.max(b.h, cds[j].h), math.min(b.l, cds[j].l) end
    table.insert(bars, 1, b)
    i = a - 1
  end
  if hi == lo then hi, lo = hi + 1, lo - 1 end
  local up = bars[#bars].c >= bars[1].o
  local color = cli.color
  local function row(v) return h - math.floor((v - lo) / (hi - lo) * (h - 1) + 0.5) end
  local grid = {}
  for r = 1, h do grid[r] = {} for c = 1, #bars do grid[r][c] = " " end end
  local prev
  for c, b in ipairs(bars) do
    local rc = row(b.c)
    local a, z = rc, rc
    if prev then a, z = math.min(rc, prev), math.max(rc, prev) end
    for r = a, z do grid[r][c] = "#" end
    for r = z + 1, h do if grid[r][c] == " " then grid[r][c] = "." end end
    prev = rc
  end
  local x = term.getCursorPos()
  if x > 1 then cli.newline() end
  for r = 1, h do
    local t, f, bg = {}, {}, {}
    for c = 1, #bars do
      local ch = grid[r][c]
      if color then
        t[c] = " "
        f[c] = "0"
        bg[c] = ch == "#" and (up and "d" or "e") or (ch == "." and "7" or "f")
      else
        t[c] = ch
      end
    end
    local _, y = term.getCursorPos()
    term.setCursorPos(1, y)
    if color then term.blit(table.concat(t), table.concat(f), table.concat(bg))
    else term.write(table.concat(t)) end
    if aw > 0 then
      local label = r == 1 and lh or (r == h and ll or "")
      if label ~= "" then
        cli.fg(colors.lightGray)
        term.setCursorPos(#bars + 2, y)
        term.write(label:sub(1, math.max(0, w - #bars - 1)))
      end
    end
    cli.newline()
  end
end

return cli.main({
  usage = "ticker [SYMBOL...] | -s <text> | -c SYMBOL [range]",
  about = "Delayed market prices from Yahoo Finance: price, change and change % in color. Without symbols it "
    .. "shows your TradeView watchlist. Symbols as on Yahoo: AAPL, BTC-USD, ^IXIC (NASDAQ), ^GSPC, GC=F (gold), "
    .. "EURUSD=X. For fun, not financial advice.",
  options = { "-s text   search for a symbol by name", "-c SYM [range]  mini chart; 1D 5D 1M 6M 1Y 5Y or 1m..4h",
              "--help    show this help" },
  flags = { s = true, c = true }, long = { search = "s", chart = "c" },
  run = function(o, args)
    local MK = market()
    local w, h = term.getSize()
    if o.s then
      local q = table.concat(args, " ")
      if q == "" then cli.fail("usage: ticker -s <text>") end
      cli.print("searching " .. q .. "...", colors.lightGray)
      local res, err = MK.search(q)
      if not res then cli.fail("search failed: " .. tostring(err)) end
      if #res == 0 then cli.print("nothing found", colors.yellow) return false end
      for _, r in ipairs(res) do
        local info = r.type .. ((r.type ~= "" and r.exch ~= "") and ", " or "") .. r.exch
        if w >= 40 then
          cli.write(("%-11s"):format(r.symbol), colors.yellow)
          cli.write(r.name, colors.white)
          cli.print(" (" .. info .. ")", colors.lightGray)
        else
          cli.write(r.symbol .. " ", colors.yellow)
          cli.print(r.name, colors.white)
          if info ~= "" then cli.print("  " .. info, colors.lightGray) end
        end
      end
      return true
    end
    if o.c then
      local sym = args[1] and MK.norm(args[1])
      if not sym or sym == "" then cli.fail("usage: ticker -c SYMBOL [range]") end
      local range = args[2] or "1D"
      if not MK.RANGE[range] then range = range:upper() end   -- 1m = minutes, 1M = month
      if not MK.RANGE[range] then cli.fail("range must be one of 1D 5D 1M 6M 1Y 5Y or 1m 5m 15m 1h 4h") end
      cli.print(("loading %s %s..."):format(sym, range), colors.lightGray)
      local d, err = MK.chart(sym, range)
      if not d or #d.candles == 0 then cli.fail(tostring(err or "no data")) end
      local q = MK.peekQuotes()[sym] or d.quote
      quoteLine(MK, sym, q, w)
      mini(MK, d, w, math.max(3, math.min(10, h - 8)))
      local a, b = d.candles[1], d.candles[#d.candles]
      local off = d.quote and d.quote.gmtoffset or 0
      local intraday = range == "1D" or range == "5D" or ({ ["1m"] = 1, ["5m"] = 1, ["15m"] = 1, ["1h"] = 1, ["4h"] = 1 })[range]
      local fmt = intraday and "%d.%m %H:%M" or "%d.%m.%Y"
      cli.print(("%s .. %s"):format(MK.date(a.t, fmt, off), MK.date(b.t, fmt, off)), colors.lightGray)
      local chg = a.o ~= 0 and (b.c - a.o) / a.o * 100 or 0
      cli.print(("%s %s"):format(MK.label(range), MK.pct(chg)), chg >= 0 and colors.green or colors.red)
      if err then cli.print(("(cached, %s old: %s)"):format(MK.age(d.age), err), colors.yellow) end
      if d.source == "kraken" then cli.print("(via Kraken)", colors.lightGray) end
      return true
    end
    local list = {}
    for _, a in ipairs(args) do list[#list + 1] = MK.norm(a) end
    if #list == 0 then
      for _, x in ipairs(MK.loadConfig().watch) do list[#list + 1] = x.s end
    end
    if #list == 0 then cli.fail("no symbols (ticker AAPL BTC-USD, or add some in TradeView)") end
    local qs, err = MK.quotes(list)
    local missing = {}
    for _, s in ipairs(list) do if not (qs[s] and qs[s].price) then missing[#missing + 1] = s end end
    for _, s in ipairs(missing) do                -- e.g. Yahoo down: the chart (Kraken for crypto, cache)
      local d = MK.chart(s, "1D")
      if d and d.quote and d.quote.price then qs[s] = qs[s] or d.quote end
    end
    local any = false
    for _, s in ipairs(list) do
      if quoteLine(MK, s, qs[s], w) then any = true end
    end
    if err then cli.print("(" .. tostring(err) .. ")", colors.yellow) end
    cli.print("Delayed data from Yahoo Finance. Not financial advice.", colors.lightGray)
    return any
  end,
}, ...)
