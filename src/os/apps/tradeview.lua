-- TradeView: a little trading terminal for real markets (stocks, indices, crypto, forex, gold) on an in-game
-- computer. Data: Yahoo Finance (unofficial, delayed; Kraken for crypto when Yahoo fails) through /os/lib/market.lua.
-- Left: watchlist (price, change %). Main: candles or line/area chart, ranges 1D..5Y, tap for the crosshair
-- (time, O H L C, volume), scroll / arrow keys to pan, "1:1" / "fit" zoom, Search (type) to find and add symbols.
-- A worker coroutine fetches while the screen stays live; auto-refresh every 60 s; cached data opens offline.
local floor, max, min = math.floor, math.max, math.min

return {
  name = "TradeView", short = "Trade", icon = "$~", color = colors.green, order = 9,
  w = 51, h = 20,
  art = { { " | |", "0e0d", "77d7" }, { "  | ", "00d0", "de7d" } },   -- 4x2 icon: green/red candles
  main = function()
    local MK = dofile("/os/lib/market.lua")
    local T = WardenOS.theme
    local cfg = MK.loadConfig()
    local names = {}                              -- symbol -> display name
    for _, w in ipairs(cfg.watch) do if w.n then names[w.s] = w.n end end
    local sel = cfg.sel or (cfg.watch[1] and cfg.watch[1].s) or "BTC-USD"
    local range, mode = cfg.range, cfg.mode
    local view = "chart"                          -- chart | search
    local zoom, offset = false, 0                 -- zoom: one candle per column (else the whole range fits)
    local cross, crossY                           -- time of the bar under the crosshair, its screen row
    local listScroll, resScroll = 0, 0
    local query, results, searchErr, searched = "", nil, nil, nil
    local jobs, busy = {}, nil
    local errs, quoteErr = {}, nil
    local spin = 0
    local zones, geo = {}, {}
    local lastAuto = MK.now()

    local HEX = {}
    for i = 0, 15 do HEX[2 ^ i] = ("0123456789abcdef"):sub(i + 1, i + 1) end
    local W, H = 51, 19
    local function put(x, y, s, fg, bg)           -- clipped to the window
      s = tostring(s)
      if y < 1 or y > H or x > W then return end
      if x < 1 then s = s:sub(2 - x) x = 1 end
      s = s:sub(1, W - x + 1)
      if s == "" then return end
      term.setCursorPos(x, y)
      term.setTextColor(fg or T.text)
      term.setBackgroundColor(bg or T.bg)
      term.write(s)
    end
    local function fill(x, y, w, h, bg)
      if w <= 0 then return end
      for r = y, y + h - 1 do put(x, r, string.rep(" ", w), T.text, bg) end
    end
    local function zone(x1, y1, x2, y2, fn) zones[#zones + 1] = { x1, y1, x2, y2, fn } end
    local function button(x, y, label, fn, fg, bg)
      label = " " .. label .. " "
      put(x, y, label, fg or T.text, bg or T.panel)
      zone(x, y, x + #label - 1, y, fn)
      return x + #label
    end
    local function pad(s, w) s = tostring(s) return (s .. string.rep(" ", w)):sub(1, max(0, w)) end
    local function lpad(s, w) s = tostring(s) if #s >= w then return s:sub(1, w) end return string.rep(" ", w - #s) .. s end
    local function upColor(v) v = tonumber(v) or 0 return v > 0 and T.good or (v < 0 and T.bad or T.dim) end
    local function arrow(v) v = tonumber(v) or 0 return v > 0 and "^" or (v < 0 and "v" or "=") end

    ------------------------------------------------ jobs (run by the worker coroutine)
    local function save() cfg.sel, cfg.range, cfg.mode = sel, range, mode MK.saveConfig(cfg) end
    local function symbols() local t = {} for i, w in ipairs(cfg.watch) do t[i] = w.s end return t end
    local function queue(j)
      for _, o in ipairs(jobs) do
        if o.k == j.k and o.s == j.s and o.r == j.r and o.q == j.q then return end
      end
      jobs[#jobs + 1] = j
      os.queueEvent("tradeview_job")
    end
    local function refresh()
      lastAuto = MK.now()
      queue({ k = "chart", s = sel, r = range })
      if #cfg.watch > 0 then queue({ k = "quotes" }) end
    end
    local function show(sym)
      if sym ~= sel then sel, offset, cross, zoom = sym, 0, nil, false end
      save()
      queue({ k = "chart", s = sel, r = range })
    end
    local function worker()
      while true do
        if #jobs == 0 then
          os.pullEvent("tradeview_job")
        else
          local j = table.remove(jobs, 1)
          busy = j
          os.queueEvent("tradeview_busy")
          local ok, e = pcall(function()
            if j.k == "chart" then
              local _, err = MK.chart(j.s, j.r)
              errs[j.s .. "|" .. j.r] = err
            elseif j.k == "quotes" then
              local _, err = MK.quotes(symbols())
              quoteErr = err
            elseif j.k == "search" then
              local res, err = MK.search(j.q)
              if j.q == searched then results, searchErr = res, err end
            end
          end)
          if not ok then
            if tostring(e) == "Terminated" then error(e, 0) end
            errs[(j.s or "") .. "|" .. (j.r or "")] = tostring(e)
          end
          busy = nil
          os.queueEvent("tradeview_done")
        end
      end
    end

    ------------------------------------------------ data helpers
    local function quote(sym) return MK.peekQuotes()[sym] end
    local function nameOf(sym)
      local q = quote(sym)
      return names[sym] or (q and q.name) or sym
    end
    local function merge(cds, k)                  -- k candles per bar, groups end at the newest candle
      if k <= 1 then return cds end
      local out = {}
      local i = #cds
      while i >= 1 do
        local a = max(1, i - k + 1)
        local b = { t = cds[a].t, o = cds[a].o, c = cds[i].c, h = -math.huge, l = math.huge, v = 0, t2 = cds[i].t }
        for j = a, i do
          local c = cds[j]
          b.h, b.l, b.v = max(b.h, c.h), min(b.l, c.l), b.v + (c.v or 0)
        end
        table.insert(out, 1, b)
        i = a - 1
      end
      return out
    end
    local function timeFmt(long)
      if range == "1D" then return long and "%a %d.%m %H:%M" or "%H:%M" end
      if range == "5D" then return long and "%a %d.%m %H:%M" or "%d.%m" end
      if range == "5Y" then return long and "%d.%m.%Y" or "%m/%y" end
      return long and "%a %d.%m.%Y" or "%d.%m"
    end

    ------------------------------------------------ toolbar, header, status, footer
    local function drawToolbar()
      fill(1, 1, W, 1, T.panel)
      local need = #MK.RANGES * 4 + 8 + 8
      local x = 1
      if W - need >= 10 then
        put(2, 1, W - need >= 16 and "TradeView" or "Trade", T.accent, T.panel)
        x = W - need + 1
      elseif W > need then
        x = W - need + 1
      end
      for _, r in ipairs(MK.RANGES) do
        local on = r == range
        x = button(x, 1, r, function()
          if range ~= r then range, offset, cross, zoom = r, 0, nil, false save() end
          queue({ k = "chart", s = sel, r = range })
        end, on and T.bg or T.text, on and T.accent or T.panel)
      end
      x = button(x, 1, mode == "line" and "Candle" or " Line ", function()
        mode = mode == "line" and "candles" or "line"
        save()
      end, T.text, T.panel)
      button(x, 1, "Search", function() view, resScroll = "search", 0 end, T.bg, T.accent)
    end

    local function drawFooter()
      local s
      for _, t in ipairs({ "Data: Yahoo Finance (delayed). For fun, not financial advice.",
                           "Data: Yahoo Finance (delayed). Not financial advice",
                           "Yahoo Finance (delayed). Not financial advice", "Yahoo (delayed). Not advice" }) do
        if #t <= W then s = t break end
      end
      put(1, H, pad(s or "Yahoo, delayed", W), T.dim, T.bg)
    end

    local function drawHeader(d, bars)
      fill(1, 2, W, 2, T.bg)
      local x = 1
      local function seg(y, s, fg, bg)
        if x > W then return end
        put(x, y, s, fg, bg)
        x = x + #s
      end
      local off = d and d.quote and d.quote.gmtoffset or (quote(sel) and quote(sel).gmtoffset) or 0
      if cross then
        for _, b in ipairs(bars or {}) do
          if b.t == cross then
            local ref = b.h
            seg(2, MK.date(b.t, timeFmt(true), off), T.accent)
            if b.t2 and b.t2 ~= b.t then seg(2, "-" .. MK.date(b.t2, timeFmt(false), off), T.accent) end
            seg(2, "  ", T.text)
            seg(2, "Vol " .. MK.big(b.v) .. "  ", T.text)
            local ch = b.o ~= 0 and (b.c - b.o) / b.o * 100 or 0
            seg(2, MK.pct(ch), upColor(b.c - b.o))
            x = 1
            seg(3, "O " .. MK.price(b.o, ref) .. " ", T.text)
            seg(3, "H " .. MK.price(b.h, ref) .. " ", T.good)
            seg(3, "L " .. MK.price(b.l, ref) .. " ", T.bad)
            seg(3, "C " .. MK.price(b.c, ref), upColor(b.c - b.o))
            zone(1, 2, W, 3, function() cross = nil end)
            return
          end
        end
        cross = nil
      end
      local q = quote(sel) or (d and d.quote)
      seg(2, nameOf(sel) .. " ", T.text)
      if nameOf(sel) ~= sel then seg(2, sel .. " ", T.dim) end
      if q and q.price then
        seg(2, MK.price(q.price) .. " ", T.text, T.panel)
        x = x + 1
        seg(2, MK.change(q.change, q.price) .. " ", upColor(q.change))
        seg(2, arrow(q.pct) .. MK.pct(q.pct):gsub("^[%+%-]", "") .. " ", upColor(q.pct))
        if q.currency then seg(2, q.currency, T.dim) end
      else
        seg(2, "no price yet", T.dim)
      end
      -- status line
      x = 1
      local key = sel .. "|" .. range
      local err = errs[key]
      local loading = busy and ((busy.k == "chart" and busy.s == sel) or busy.k == "quotes")
      if loading then
        seg(3, ("|/-\\"):sub(spin % 4 + 1, spin % 4 + 1) .. " updating... ", T.warn)
      end
      if err and d then
        local why = tostring(err):find("429") and "rate-limited (429)" or
                    ((tostring(err):find("HTTP is disabled") or tostring(err):find("blocked")) and tostring(err) or "offline")
        seg(3, why .. ": cached, " .. MK.age(d.age) .. " old ", T.warn)
      elseif err then
        seg(3, tostring(err) .. " ", T.bad)
      elseif d then
        local s = "delayed, " .. MK.date((d.fetched or 0) / 1000, "%H:%M", 0) .. " UTC"
        local st = q and q.state
        if st then s = s .. ", " .. st end
        if d.source == "kraken" then s = s .. ", via Kraken" end
        if d.stale and not loading then s = "cached, " .. MK.age(d.age) .. " old" end
        seg(3, s .. " ", T.dim)
      elseif not loading then
        seg(3, "no data yet ", T.dim)
      end
      if d and #d.candles > 1 and x <= W - 9 then  -- change over the shown range
        local a, b = d.candles[1].o, d.candles[#d.candles].c
        if a and a ~= 0 then
          local s = range .. " " .. MK.pct((b - a) / a * 100)
          if x + #s <= W then put(W - #s + 1, 3, s, upColor(b - a)) end
        end
      end
    end

    ------------------------------------------------ watchlist
    local function drawWatch(x0, y0, w, h)
      fill(x0, y0, w, h, T.panel)
      put(x0, y0, pad(" Watchlist", w), T.dim, T.panel)
      local idx = MK.inWatch(cfg, sel)
      if idx then
        button(x0 + w - 3, y0, "-", function()
          table.remove(cfg.watch, idx)
          save()
        end, T.bg, T.bad)
      else
        button(x0 + w - 3, y0, "+", function()
          cfg.watch[#cfg.watch + 1] = { s = sel, n = names[sel] or (quote(sel) and quote(sel).name) }
          save()
          queue({ k = "quotes" })
        end, T.bg, T.good)
      end
      local two = w < 22
      local per = two and 2 or 1
      local rows = floor((h - 1) / per)
      listScroll = max(0, min(listScroll, #cfg.watch - rows))
      local qs = MK.peekQuotes()
      for i = 1, rows do
        local e = cfg.watch[listScroll + i]
        if not e then
          if i == 1 then put(x0 + 1, y0 + 1, "empty: Search", T.dim, T.panel) end
          break
        end
        local y = y0 + 1 + (i - 1) * per
        local q = qs[e.s]
        local on = e.s == sel
        local p = q and (arrow(q.pct) .. MK.pct(q.pct):gsub("^[%+%-]", "")) or ""
        local col = q and upColor(q.pct) or T.dim
        if two then
          put(x0, y, pad(" " .. e.s, w), on and T.bg or T.text, on and T.accent or T.panel)
          local pr = q and MK.compact(q.price, w - 2 - #p) or "--"
          put(x0, y + 1, pad(" " .. pr, w), T.text, T.panel)
          put(x0 + w - #p, y + 1, p, col, T.panel)
        else
          local sw = min(8, w - 16)
          put(x0, y, pad(" " .. e.s, sw + 1), on and T.bg or T.text, on and T.accent or T.panel)
          local pw = w - sw - 2 - 8
          local pr = q and MK.compact(q.price, pw) or "--"
          put(x0 + sw + 1, y, lpad(pr, pw + 1), T.text, T.panel)
          put(x0 + w - 8, y, lpad(p, 8), col, T.panel)
        end
        zone(x0, y, x0 + w - 1, y + per - 1, function() show(e.s) end)
      end
      if listScroll > 0 then put(x0 + w - 5, y0, "^", T.accent, T.panel) end
      if listScroll + rows < #cfg.watch then put(x0 + w - 4, y0, "v", T.accent, T.panel) end
      geo.list = { x0, y0, x0 + w - 1, y0 + h - 1 }
    end

    ------------------------------------------------ chart
    local function drawChart(d, x0, y0, aw0, ch, vh)
      local cw = W - x0 + 1 - aw0
      if cw < 4 or ch < 3 then return {} end
      local cds = d and d.candles or {}
      if #cds == 0 then
        fill(x0, y0, W - x0 + 1, ch + vh + 1, T.bg)
        put(x0 + 1, y0 + floor(ch / 2), busy and "loading..." or "no data", T.dim)
        geo.chart = nil
        return {}
      end
      -- bars: the whole range fits (merged), or one candle per column with panning
      local bars
      if zoom then
        bars = cds
      else
        bars = merge(cds, math.ceil(#cds / cw))
      end
      local n = #bars
      offset = max(0, min(offset, max(0, n - cw)))
      local last = n - offset
      local first = max(1, last - cw + 1)
      local vis = {}
      for i = first, last do vis[#vis + 1] = bars[i] end
      local lo, hi = math.huge, -math.huge
      for _, b in ipairs(vis) do lo, hi = min(lo, b.l), max(hi, b.h) end
      if hi == lo then hi, lo = hi * 1.001 + 0.0001, lo * 0.999 - 0.0001 end
      -- axis width from the labels
      local labels = { MK.price(hi, hi), MK.price(lo, hi), MK.price(vis[#vis].c, hi) }
      local aw = aw0
      for _, l in ipairs(labels) do aw = max(aw, #l + 1) end
      aw = min(aw, max(6, W - x0 - 8))
      cw = W - x0 + 1 - aw
      if #vis > cw then                            -- the axis took columns: drop the oldest bars
        local cut = #vis - cw
        for _ = 1, cut do table.remove(vis, 1) end
      end
      local axis = x0 + cw
      local slot = zoom and 1 or max(1, min(3, floor(cw / #vis)))   -- columns per bar (few bars: wider)
      local mid = floor((slot - 1) / 2)
      local col0 = x0 + cw - #vis * slot           -- newest bar at the right edge
      local function row(v) return y0 + ch - 1 - floor((v - lo) / (hi - lo) * (ch - 1) + 0.5) end
      local rows = ch + vh
      local txt, fg, bg = {}, {}, {}
      for r = 1, rows do
        txt[r], fg[r], bg[r] = {}, {}, {}
        for c = 1, cw do txt[r][c], fg[r][c], bg[r][c] = " ", T.dim, T.bg end
      end
      local vmax = 0
      for _, b in ipairs(vis) do vmax = max(vmax, b.v or 0) end
      local lineUp = vis[#vis].c >= vis[1].o
      local lineCol = lineUp and T.good or T.bad
      local prevRow
      for i, b in ipairs(vis) do
        local s0 = col0 - x0 + (i - 1) * slot      -- the bar's columns: s0 + 1 .. s0 + slot
        local c = s0 + 1 + mid
        local up = b.c >= b.o
        local color = up and T.good or T.bad
        if b.t == cross then for r = 1, rows do for k = 1, slot do bg[r][s0 + k] = T.panel end end end
        if mode == "line" then
          local rc = row(b.c) - y0 + 1
          for k = 1, slot do
            for r = rc + 1, ch do bg[r][s0 + k], txt[r][s0 + k] = T.panel, " " end
            local a, z = rc, rc
            if prevRow then a, z = min(rc, prevRow), max(rc, prevRow) end
            for r = a, z do bg[r][s0 + k] = lineCol end
            prevRow = rc
          end
        else
          local rh, rl = row(b.h) - y0 + 1, row(b.l) - y0 + 1
          for r = rh, rl do txt[r][c], fg[r][c] = "|", color end
          local b1, b2 = row(max(b.o, b.c)) - y0 + 1, row(min(b.o, b.c)) - y0 + 1
          for r = b1, b2 do txt[r][c], bg[r][c] = " ", color end
        end
        if vh > 0 and vmax > 0 and (b.v or 0) > 0 then
          local hgt = max(1, floor(b.v / vmax * vh + 0.5))
          for k = 1, hgt do bg[ch + vh - k + 1][c] = up and T.good or T.bad end
        end
      end
      if crossY and cross and crossY >= y0 and crossY < y0 + ch then
        local r = crossY - y0 + 1
        for c = 1, cw do if txt[r][c] == " " and bg[r][c] == T.bg then txt[r][c], fg[r][c] = "-", T.dim end end
      end
      for r = 1, rows do
        local t, f, b = {}, {}, {}
        for c = 1, cw do t[c], f[c], b[c] = txt[r][c], HEX[fg[r][c]] or "0", HEX[bg[r][c]] or "f" end
        term.setCursorPos(x0, y0 + r - 1)
        term.blit(table.concat(t), table.concat(f), table.concat(b))
      end
      -- price axis (right)
      fill(axis, y0, aw, rows, T.bg)
      put(axis + 1, y0, MK.price(hi, hi), T.dim)
      put(axis + 1, y0 + ch - 1, MK.price(lo, hi), T.dim)
      if ch >= 7 then put(axis + 1, y0 + floor((ch - 1) / 2), MK.price((hi + lo) / 2, hi), T.dim) end
      if vh > 0 then put(axis + 1, y0 + ch, ("V " .. MK.big(vmax)):sub(1, aw - 1), T.dim) end
      local lc = vis[#vis].c
      if offset == 0 then put(axis, row(lc), pad(" " .. MK.price(lc, hi), aw), T.bg, lineCol) end
      if crossY and cross and crossY >= y0 and crossY < y0 + ch then
        local v = lo + (y0 + ch - 1 - crossY) / (ch - 1) * (hi - lo)
        put(axis, crossY, pad(" " .. MK.price(v, hi), aw), T.bg, T.accent)
      end
      -- time axis
      local ty = y0 + rows
      fill(x0, ty, W - x0 + 1, 1, T.bg)
      local off = d.quote and d.quote.gmtoffset or 0
      local limit = axis                           -- labels must end left of this column
      local every = max(1, floor(9 / slot))
      for i = #vis, 1, -1 do
        local c = col0 + (i - 1) * slot + mid
        if (#vis - i) % every == floor(every / 2) or i == 1 then
          local s = MK.date(vis[i].t, timeFmt(false), off)
          local x = c - floor(#s / 2)
          if x >= x0 and x + #s <= limit then
            put(x, ty, s, T.dim)
            limit = x - 1
          end
        end
      end
      if zoom or #cds > cw then
        local lbl = zoom and "[fit]" or "[1:1]"
        put(axis + 1, ty, lbl:sub(1, aw - 1), T.accent)
        zone(axis, ty, W, ty, function() zoom, offset, cross = not zoom, 0, nil end)
      end
      if offset > 0 then put(x0, ty, "<" .. offset .. " ", T.warn) end
      geo.chart = { x0 = x0, y0 = y0, cw = cw, y1 = y0 + rows - 1, n = #cds }
      zone(x0, y0, x0 + cw - 1, y0 + rows - 1, function(px, py)
        local b = px >= col0 and vis[floor((px - col0) / slot) + 1]
        if not b or (cross == b.t and crossY == py) then cross, crossY = nil, nil return end
        cross, crossY = b.t, py
      end)
      return vis
    end

    local function drawChartView()
      drawToolbar()
      local d = MK.peek(sel, range)
      local lw = W >= 70 and 26 or max(15, min(22, floor(W * 0.33)))
      local vh = H >= 24 and 3 or 0
      local ch = H - 5 - vh                        -- rows 4 .. H-2-vh: price; then volume; time row H-1
      local vis = drawChart(d, lw + 2, 4, 6, ch, vh)
      drawHeader(d, vis)
      drawWatch(1, 4, lw, H - 4)
      drawFooter()
    end

    ------------------------------------------------ search
    local function drawSearch()
      fill(1, 1, W, 1, T.panel)
      local x = button(1, 1, "<", function() view = "chart" end, T.accent, T.panel)
      put(x + 1, 1, "Search symbols", T.text, T.panel)
      fill(1, 2, W, 1, T.panel)
      put(2, 2, "> " .. query:sub(-(W - 12)) .. "_", T.text, T.panel)
      button(W - 5, 2, "Go", function()
        if query ~= "" then searched, results, searchErr, resScroll = query, nil, nil, 0 queue({ k = "search", q = query }) end
      end, T.bg, T.accent)
      local status, scol
      if busy and busy.k == "search" then
        status, scol = ("|/-\\"):sub(spin % 4 + 1, spin % 4 + 1) .. " searching " .. tostring(busy.q) .. "...", T.warn
      elseif searchErr then
        status, scol = "search failed: " .. tostring(searchErr), T.bad
      elseif results then
        status, scol = (#results == 0 and "nothing found for " or (#results .. " results for ")) .. tostring(searched), T.dim
      else
        status, scol = "Type a name or symbol (apple, BTC, ^GSPC), Enter.", T.dim
      end
      put(1, 3, status, scol)
      local list = results or {}
      local per = W >= 60 and 1 or 2
      local rows = floor((H - 4) / per)
      resScroll = max(0, min(resScroll, #list - rows))
      for i = 1, rows do
        local r = list[resScroll + i]
        if not r then break end
        local y = 4 + (i - 1) * per
        local inList = MK.inWatch(cfg, r.symbol)
        local info = r.type .. ((r.type ~= "" and r.exch ~= "") and " - " or "") .. r.exch
        if inList then
          put(1, y, " * ", T.warn, T.panel)
        else
          button(1, y, "+", function()
            cfg.watch[#cfg.watch + 1] = { s = r.symbol, n = r.name }
            names[r.symbol] = r.name
            save()
            queue({ k = "quotes" })
          end, T.bg, T.good)
        end
        put(5, y, pad(r.symbol, 11), T.accent)
        if per == 1 then
          local iw = min(#info, 24)
          put(17, y, pad(r.name, W - 17 - iw - 1), T.text)
          put(W - iw + 1, y, info:sub(1, iw), T.dim)
        else
          put(17, y, r.name, T.text)
          put(5, y + 1, info, T.dim)
        end
        zone(4, y, W, y + per - 1, function()
          names[r.symbol] = names[r.symbol] or r.name
          view = "chart"
          show(r.symbol)
        end)
      end
      if resScroll > 0 then put(W, 4, "^", T.accent) end
      if resScroll + rows < #list then put(W, H - 1, "v", T.accent) end
      drawFooter()
    end

    ------------------------------------------------ render + loop
    local function render()
      T = WardenOS.theme
      local parent = term.current()
      W, H = parent.getSize()
      local buf = window.create(parent, 1, 1, W, H, false)
      term.redirect(buf)
      zones = {}
      term.setBackgroundColor(T.bg)
      term.clear()
      local ok, err = pcall(view == "search" and drawSearch or drawChartView)
      if not ok then put(1, H, pad("error: " .. tostring(err), W), T.bad) end
      term.redirect(parent)
      buf.setVisible(true)
      parent.setCursorBlink(false)
    end

    local function pan(steps)
      local g = geo.chart
      if not g then return end
      if not zoom then
        if g.n <= g.cw then return end
        zoom, offset = true, 0
      end
      offset, cross = max(0, offset + steps * max(1, floor(g.cw / 4))), nil
    end

    local function ui()
      local timer = os.startTimer(1)
      refresh()
      render()
      while true do
        local e, a, b, c = os.pullEvent()
        if e == "timer" then
          if a == timer then timer = os.startTimer(busy and 0.5 or 5) end
          spin = spin + 1
          if MK.now() - lastAuto >= MK.FRESH * 1000 then refresh() end
          render()
        elseif e == "tradeview_done" or e == "tradeview_busy" then
          render()
        elseif e == "mouse_click" or e == "monitor_touch" then
          for _, z in ipairs(zones) do
            if b >= z[1] and b <= z[3] and c >= z[2] and c <= z[4] then z[5](b, c) break end
          end
          render()
        elseif e == "mouse_scroll" then
          if view == "search" then
            resScroll = max(0, resScroll + a)
          elseif geo.list and b <= geo.list[3] then
            listScroll = max(0, listScroll + a)
          else
            pan(-a)
          end
          render()
        elseif e == "char" then
          if view ~= "search" then view, query, resScroll = "search", "", 0 end
          query = (query .. a):sub(1, 30)
          render()
        elseif e == "key" then
          if view == "search" then
            if a == keys.backspace then
              if query == "" then view = "chart" else query = query:sub(1, -2) end
            elseif a == keys.enter and query ~= "" then
              searched, results, searchErr, resScroll = query, nil, nil, 0
              queue({ k = "search", q = query })
            end
          else
            if a == keys.left then pan(1)
            elseif a == keys.right then pan(-1)
            elseif a == keys.up or a == keys.down then
              local i = MK.inWatch(cfg, sel) or 0
              i = max(1, min(#cfg.watch, i + (a == keys.up and -1 or 1)))
              if cfg.watch[i] then show(cfg.watch[i].s) end
            end
          end
          render()
        elseif e == "term_resize" or e == "theme_changed" then
          render()
        end
      end
    end

    parallel.waitForAny(ui, worker)
  end,
}
