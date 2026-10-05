-- MineView: "TradingView for Minecraft resources". Candlestick charts of every item in the storage system,
-- recorded by the desktop (/os/lib/mineview.lua, run through /os/lib/world.lua as WardenOS.mineview).
-- Left: watchlist (type to filter, tap the star to pin). Main: candles + produced/consumed flow, timeframes,
-- tap a candle for its values, scroll / arrow keys to pan, "now" to jump back. Settings: interval, sources,
-- item limit, history size, clear.
local floor, max, min = math.floor, math.max, math.min

local function fmt(n)                             -- 12345 -> "12.3k"
  n = tonumber(n)
  if not n then return "-" end
  local a = math.abs(n)
  for _, s in ipairs({ { 1e12, "T" }, { 1e9, "G" }, { 1e6, "M" }, { 1e3, "k" } }) do
    if a >= s[1] then
      local v = n / s[1]
      return (math.abs(v) >= 100 and ("%d"):format(floor(v + 0.5)) or ("%.1f"):format(v)) .. s[2]
    end
  end
  return tostring(floor(n + 0.5))
end
local function signed(n) n = tonumber(n) or 0 return (n > 0 and "+" or "") .. fmt(n) end
local function pct(p)
  if not p then return "" end
  if math.abs(p) >= 1000 then return p > 0 and ">+999%" or "<-999%" end
  if math.abs(p) < 0.05 then return "0%" end
  local s = math.abs(p) >= 10 and ("%d"):format(floor(math.abs(p) + 0.5)) or ("%.1f"):format(math.abs(p))
  return (p > 0 and "+" or (p < 0 and "-" or "")) .. s .. "%"
end
local function clock(t, tf)
  if not t then return "--:--" end
  local f = (tf == "1d") and "%d.%m" or "%H:%M"
  local ok, s = pcall(os.date, f, t)
  if ok and type(s) == "string" and #s <= 5 then return s end
  local d = t % 86400
  return ("%02d:%02d"):format(floor(d / 3600), floor(d / 60) % 60)
end
local function wrap(s, w)
  local out, line = {}, ""
  for word in s:gmatch("%S+") do
    if line == "" then line = word
    elseif #line + 1 + #word <= w then line = line .. " " .. word
    else out[#out + 1] = line line = word end
  end
  if line ~= "" then out[#out + 1] = line end
  return out
end

local MODE_INFO = {
  auto = "ME/RS bridges if there is one, else every inventory",
  inventories = "every chest, barrel, ... (also over wired modems)",
  bridges = "only ME Bridge / RS Bridge (Advanced Peripherals)",
  all = "inventories + bridges (counts twice if a chest is in the network)",
  selected = "only the sources ticked below",
}

return {
  name = "MineView", short = "MView", icon = "$^", color = colors.lime, order = 9,
  w = 51, h = 20,
  main = function()
    local T = WardenOS.theme
    local MV = dofile("/os/lib/mineview.lua")
    local mv = WardenOS.mineview
    if type(mv) ~= "table" or type(mv.items) ~= "function" then mv = MV.new({ readonly = true }) end
    local ro = mv.readonly and true or false

    local view = "chart"                          -- chart | settings
    local tf = "5m"
    local sel                                     -- selected item name
    local filter = ""
    local listScroll, setScroll = 0, 0
    local offset = 0                              -- candles hidden at the right (panned back in time)
    local cross                                   -- t of the candle under the crosshair
    local clearAsk = false
    local msg = ""
    local zones = {}
    local geo = {}                                -- chart geometry of the last render

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
      for r = y, y + h - 1 do put(x, r, string.rep(" ", w), T.text, bg) end
    end
    local function zone(x1, y1, x2, y2, fn) zones[#zones + 1] = { x1, y1, x2, y2, fn } end
    local function button(x, y, label, fn, fg, bg)
      label = " " .. label .. " "
      put(x, y, label, fg or T.text, bg or T.panel)
      zone(x, y, x + #label - 1, y, fn)
      return x + #label
    end

    ------------------------------------------------ data
    local function allItems()
      local ok, l = pcall(mv.items)
      return ok and type(l) == "table" and l or {}
    end
    local function entries(l)
      l = l or allItems()
      if filter == "" then return l end
      local f, out = filter:lower(), {}
      for _, e in ipairs(l) do
        if e.display:lower():find(f, 1, true) or e.name:lower():find(f, 1, true) then out[#out + 1] = e end
      end
      return out
    end
    local function status()
      local ok, s = pcall(mv.status)
      return ok and type(s) == "table" and s or { samples = 0, items = 0 }
    end

    ------------------------------------------------ chart view
    local function drawToolbar(st)
      fill(1, 1, W, 1, T.panel)
      local labels = {}
      for _, k in ipairs(MV.TIMEFRAMES) do labels[#labels + 1] = k end
      local need = 0
      for _, k in ipairs(labels) do need = need + #k + 2 end
      need = need + 5 + 5
      local x = 1
      if W - need >= 10 then
        local title = ro and "MineView (read-only)" or "MineView"
        if st.disk == "low" then title = "DISK LOW" end
        if #title > W - need - 2 then title = st.disk == "low" and "DISK LOW" or "MineView" end
        put(2, 1, title, st.disk == "low" and T.bad or T.accent, T.panel)
        x = max(x, W - need + 1)
      end
      for _, k in ipairs(labels) do
        local on = k == tf
        x = button(x, 1, k, function() tf, offset, cross = k, 0, nil end, on and T.bg or T.text, on and T.accent or T.panel)
      end
      x = button(x, 1, "now", function() offset, cross = 0, nil end, offset > 0 and T.bg or T.dim, offset > 0 and T.warn or T.panel)
      button(x, 1, "set", function() view, setScroll, clearAsk = "settings", 0, false end, T.text, T.panel)
    end

    local function drawEmpty(st)
      local y = 3
      local function line(s, fg)
        for _, l in ipairs(wrap(s, W - 2)) do
          if y <= H then put(2, y, l, fg or T.dim) end
          y = y + 1
        end
      end
      line("No data yet", T.text)
      y = y + 1
      line("MineView charts every item in your storage. Attach chests or barrels (wired modem on each) "
        .. "or an ME Bridge / RS Bridge from Advanced Peripherals.")
      local found = { inv = 0, bridge = 0 }
      local okS, srcs = pcall(mv.sources)
      for _, s in ipairs(okS and srcs or {}) do if found[s.kind] then found[s.kind] = found[s.kind] + 1 end end
      line(("Found %d inventories, %d bridges."):format(found.inv, found.bridge), T.text)
      line(("Samples: %d. The first chart appears after 2 samples (every %d s)."):format(st.samples or 0,
        st.interval or 60))
      if ro then line("Read-only: recording runs on the desktop.", T.warn) end
    end

    local function drawWatch(list, x0, y0, w, h, st)
      fill(x0, y0, w, h, T.panel)
      local f = filter ~= "" and ("/" .. filter) or "/ type to find"
      put(x0, y0, f:sub(-w), filter ~= "" and T.text or T.dim, T.panel)
      local two = w < 22
      local per = two and 2 or 1
      local rows = floor((h - 1) / per)
      listScroll = max(0, min(listScroll, #list - rows))
      for i = 1, rows do
        local e = list[listScroll + i]
        if not e then break end
        local y = y0 + 1 + (i - 1) * per
        local selected = e.name == sel
        local nbg = selected and T.accent or T.panel
        local nfg = selected and T.bg or T.text
        put(x0, y, e.pinned and "*" or ".", e.pinned and T.warn or T.dim, T.panel)
        local ch = e.pct1h or 0
        local col = (e.ch1h or 0) > 0 and T.good or ((e.ch1h or 0) < 0 and T.bad or T.dim)
        local arrow = (e.ch1h or 0) > 0 and "^" or ((e.ch1h or 0) < 0 and "v" or "=")
        if two then
          put(x0 + 1, y, (" " .. e.display .. string.rep(" ", w)):sub(1, w - 1), nfg, nbg)
          local v = fmt(e.current)
          put(x0 + 1, y + 1, (" " .. v .. string.rep(" ", w)):sub(1, w - 1), T.text, T.panel)
          local p = arrow .. pct(ch):gsub("^[%+%-]", "")
          put(x0 + w - #p, y + 1, p, col, T.panel)
        else
          local v, p = fmt(e.current), arrow .. pct(ch):gsub("^[%+%-]", "")
          local nw = w - 1 - 6 - 7
          put(x0 + 1, y, (" " .. e.display .. string.rep(" ", w)):sub(1, nw), nfg, nbg)
          put(x0 + 1 + nw, y, ("%6s"):format(v), T.text, T.panel)
          put(x0 + w - 7, y, ("%7s"):format(p), col, T.panel)
        end
        zone(x0, y, x0 + 1, y + per - 1, function()
          pcall(mv.pin, e.name, not e.pinned)
        end)
        zone(x0 + 2, y, x0 + w - 1, y + per - 1, function()
          if sel ~= e.name then sel, offset, cross = e.name, 0, nil end
        end)
      end
      local note = (not ro and st.disk == "low") and "DISK LOW: not saved" or (ro and "read-only" or nil)
      if note and h >= 4 then put(x0, y0 + h - 1, (note .. string.rep(" ", w)):sub(1, w), st.disk == "low" and T.bad or T.warn, T.panel) end
      zone(x0, y0, x0 + w - 1, y0, function() filter = "" end)
    end

    local function drawHeader(e, cds)
      fill(1, 2, W, 1, T.bg)
      local x = 1
      local function seg(s, fg)
        if x > W then return end
        put(x, 2, s, fg)
        x = x + #s
      end
      if cross then
        for _, cd in ipairs(cds) do
          if cd.t == cross then
            seg(clock(cd.t, tf) .. " ", T.accent)
            seg("O" .. fmt(cd.o) .. " H" .. fmt(cd.h) .. " L" .. fmt(cd.l) .. " ", T.text)
            seg("C" .. fmt(cd.c) .. " ", cd.c >= cd.o and T.good or T.bad)
            seg("+" .. fmt(cd.prod) .. " ", T.good)
            seg("-" .. fmt(cd.cons), T.bad)
            zone(1, 2, W, 2, function() cross = nil end)
            return
          end
        end
        cross = nil
      end
      if not e then seg("Select an item", T.dim) return end
      seg(e.display .. " ", T.text)
      seg(fmt(e.current) .. " ", T.accent)
      if e.pct1h then seg(pct(e.pct1h) .. " ", (e.ch1h or 0) > 0 and T.good or ((e.ch1h or 0) < 0 and T.bad or T.dim)) end
      seg("+" .. fmt(e.prodH or 0) .. "/h ", T.good)
      seg("-" .. fmt(e.consH or 0) .. "/h ", T.bad)
      local r = e.rate or 0
      seg("net " .. signed(r) .. "/h", r > 0 and T.good or (r < 0 and T.bad or T.dim))
    end

    local function drawChart(e, all, x0, y0, cw, ch, fh)
      -- x0..x0+cw-1 candle columns; rows y0..y0+ch-1 price; then fh flow rows; then the time row
      local axis = x0 + cw
      local n = #all
      offset = max(0, min(offset, max(0, n - cw)))
      local last = n - offset
      local first = max(1, last - cw + 1)
      local vis = {}
      for i = first, last do vis[#vis + 1] = all[i] end
      local col0 = x0 + cw - #vis                  -- newest candle at the right edge
      geo = { x0 = x0, cw = cw, y0 = y0, y1 = y0 + ch + fh - 1, col0 = col0, vis = vis }
      if #vis == 0 then
        fill(x0, y0, cw, ch + fh, T.bg)
        put(x0 + 1, y0 + floor(ch / 2), "no candles yet", T.dim)
        return
      end
      local lo, hi = math.huge, -math.huge
      for _, cd in ipairs(vis) do lo, hi = min(lo, cd.l), max(hi, cd.h) end
      if hi == lo then hi, lo = hi + 1, max(0, lo - 1) end
      if hi == lo then hi = lo + 1 end
      local function row(v) return y0 + ch - 1 - floor((v - lo) / (hi - lo) * (ch - 1) + 0.5) end
      -- cells
      local txt, fg, bg = {}, {}, {}
      for r = 1, ch + fh do
        txt[r], fg[r], bg[r] = {}, {}, {}
        for c = 1, cw do txt[r][c], fg[r][c], bg[r][c] = " ", T.dim, T.bg end
      end
      local half = floor(fh / 2)
      local fmaxP, fmaxC = 0, 0
      for _, cd in ipairs(vis) do fmaxP, fmaxC = max(fmaxP, cd.prod), max(fmaxC, cd.cons) end
      local fmaxAll = max(fmaxP, fmaxC)
      for i, cd in ipairs(vis) do
        local c = col0 - x0 + i
        local up = cd.c >= cd.o
        local color = up and T.good or T.bad
        if cd.t == cross then
          for r = 1, ch + fh do bg[r][c] = T.panel end
        end
        local rh, rl = row(cd.h) - y0 + 1, row(cd.l) - y0 + 1
        for r = rh, rl do txt[r][c], fg[r][c] = "|", color end
        local b1, b2 = row(max(cd.o, cd.c)) - y0 + 1, row(min(cd.o, cd.c)) - y0 + 1
        for r = b1, b2 do txt[r][c], bg[r][c] = " ", color end
        if fmaxAll > 0 and half > 0 then
          local hp = cd.prod > 0 and max(1, floor(cd.prod / fmaxAll * half + 0.5)) or 0
          local hc = cd.cons > 0 and max(1, floor(cd.cons / fmaxAll * (fh - half) + 0.5)) or 0
          for k = 1, hp do bg[ch + half - k + 1][c] = T.good end
          for k = 1, hc do bg[ch + half + k][c] = T.bad end
        end
      end
      if half > 0 then                            -- zero line of the flow
        for c = 1, cw do if bg[ch + half][c] ~= T.good then txt[ch + half][c], fg[ch + half][c] = "_", T.panel end end
      end
      for r = 1, ch + fh do
        local t, f, b = {}, {}, {}
        for c = 1, cw do
          t[c], f[c], b[c] = txt[r][c], HEX[fg[r][c]] or "0", HEX[bg[r][c]] or "f"
        end
        term.setCursorPos(x0, y0 + r - 1)
        term.blit(table.concat(t), table.concat(f), table.concat(b))
      end
      -- y axis (right)
      local aw = W - axis + 1
      fill(axis, y0, aw, ch + fh, T.bg)
      put(axis + 1, y0, fmt(hi), T.dim)
      put(axis + 1, y0 + ch - 1, fmt(lo), T.dim)
      if ch >= 7 then put(axis + 1, y0 + floor((ch - 1) / 2), fmt((hi + lo) / 2), T.dim) end
      local lc = vis[#vis].c
      if offset == 0 then put(axis, row(lc), (" " .. fmt(lc) .. "     "):sub(1, aw), T.bg, T.accent) end
      if fh > 0 then
        put(axis, y0 + ch, ("+" .. fmt(fmaxP)):sub(1, aw), T.good)
        put(axis, y0 + ch + fh - 1, ("-" .. fmt(fmaxC)):sub(1, aw), T.bad)
      end
      -- time labels
      local ty = y0 + ch + fh
      fill(x0, ty, W - x0 + 1, 1, T.bg)
      for i = #vis, 1, -1 do                      -- from the newest, every ~8 columns
        local c = col0 + i - 1
        if (#vis - i) % 8 == 0 then
          local s = clock(vis[i].t, tf)
          local x = c - #s + 1
          if x >= x0 then put(x, ty, s, T.dim) end
        end
      end
      if offset > 0 then put(axis, ty, ("<" .. offset):sub(1, aw), T.warn) end
      zone(x0, y0, x0 + cw - 1, y0 + ch + fh - 1, function(px)
        local i = px - col0 + 1
        local cd = vis[i]
        if not cd then cross = nil return end
        cross = (cross == cd.t) and nil or cd.t
      end)
    end

    local function drawChartView()
      local st = status()
      drawToolbar(st)
      local items = allItems()
      local list = entries(items)
      if #items == 0 or ((st.samples or 0) < 2 and (st.hours or 0) == 0) then
        drawEmpty(st)
        return
      end
      local e
      for _, x in ipairs(items) do if x.name == sel then e = x end end
      if not e then e = list[1] or items[1] sel = e.name end
      local lw = max(14, min(30, floor(W * 0.3)))
      if W >= 70 then lw = max(lw, 28) end           -- room for full item names
      local fh = H >= 30 and 6 or (H >= 22 and 4 or 2)
      local aw = 6
      local x0 = lw + 2
      local cw = W - aw - x0 + 1
      local ch = H - 3 - fh
      local okc, cds = pcall(mv.candles, sel, tf)
      cds = okc and type(cds) == "table" and cds or {}
      drawHeader(e, cds)
      drawWatch(list, 1, 3, lw, H - 2, st)
      if cw >= 4 and ch >= 3 then drawChart(e, cds, x0, 3, cw, ch, fh) end
    end

    ------------------------------------------------ settings
    local function drawSettings()
      local st = status()
      local cfg = mv.config()
      fill(1, 1, W, 1, T.panel)
      button(1, 1, "<", function() view, clearAsk = "chart", false end, T.accent, T.panel)
      put(5, 1, "MineView settings", T.text, T.panel)
      local lines = {}
      local function L(fn) lines[#lines + 1] = fn end
      local function set(k, v) local c = {} c[k] = v pcall(mv.setConfig, c) end
      L(function(y)
        put(2, y, "Sample every", T.text)
        local x = button(16, y, "-", function() set("interval", cfg.interval - (cfg.interval > 60 and 30 or 10)) end)
        put(x + 1, y, ("%ds"):format(cfg.interval), T.accent)
        button(x + 6, y, "+", function() set("interval", cfg.interval + (cfg.interval >= 60 and 30 or 10)) end)
      end)
      L(function(y)
        put(2, y, "Sources", T.text)
        button(16, y, cfg.mode, function()
          local i = 1
          for k, m in ipairs(MV.MODES) do if m == cfg.mode then i = k end end
          set("mode", MV.MODES[i % #MV.MODES + 1])
        end, T.bg, T.accent)
      end)
      for _, l in ipairs(wrap(MODE_INFO[cfg.mode] or "", W - 4)) do
        L(function(y) put(4, y, l, T.dim) end)
      end
      if cfg.mode == "selected" then
        local okS, srcs = pcall(mv.sources)
        srcs = okS and srcs or {}
        if #srcs == 0 then L(function(y) put(4, y, "no inventories or bridges found", T.warn) end) end
        for _, s in ipairs(srcs) do
          L(function(y)
            put(4, y, s.selected and "[x]" or "[ ]", s.selected and T.good or T.dim)
            put(8, y, (s.name .. " (" .. (s.kind == "inv" and "inventory" or s.kind) .. ")"):sub(1, W - 8),
              s.kind == "missing" and T.bad or T.text)
            zone(4, y, W, y, function()
              local list = {}
              for _, n in ipairs(cfg.selected) do if n ~= s.name then list[#list + 1] = n end end
              if not s.selected then list[#list + 1] = s.name end
              set("selected", list)
            end)
          end)
        end
      end
      L(function(y)
        put(2, y, "Track up to", T.text)
        local x = button(16, y, "-", function() set("limit", cfg.limit - 10) end)
        put(x + 1, y, ("%d items"):format(cfg.limit), T.accent)
        button(x + 11, y, "+", function() set("limit", cfg.limit + 10) end)
      end)
      L(function(y)
        put(2, y, "History max", T.text)
        local x = button(16, y, "-", function() set("maxKB", cfg.maxKB >= 512 and cfg.maxKB - 256 or cfg.maxKB - 64) end)
        put(x + 1, y, ("%d KB"):format(cfg.maxKB), T.accent)
        button(x + 9, y, "+", function() set("maxKB", cfg.maxKB >= 256 and cfg.maxKB + 256 or cfg.maxKB + 64) end)
      end)
      L(function(y)
        local x = 2
        if not ro then
          x = button(x, y, "Sample now", function()
            local ok, why = mv.sampleNow()
            msg = ok and "sampling..." or ("not now: " .. tostring(why))
          end, T.bg, T.accent) + 1
        end
        button(x, y, clearAsk and "Sure? tap again" or "Clear history", function()
          if clearAsk then
            pcall(mv.clear)
            clearAsk, msg, sel = false, "history cleared", nil
          else
            clearAsk = true
          end
        end, T.bg, T.bad)
      end)
      L(function() end)
      local status = {}
      local function S(s, fg) status[#status + 1] = { s, fg } end
      if ro then S("Read-only: recording runs on the desktop.", T.warn) end
      if st.lastT then
        S(("Last sample %s, %d ms, %d/%d sources ok (%s)"):format(clock(st.lastT), st.ms or 0, st.okCount or 0,
          st.sources or 0, tostring(st.using or "-")), T.text)
      else
        S(ro and "No sample recorded." or "No sample yet (first one a few seconds after start).", T.dim)
      end
      for n, e2 in pairs(st.failed or {}) do S("skipped " .. n .. ": " .. tostring(e2), T.bad) end
      S(("%d items, %d samples, %d hourly candles"):format(st.items or 0, st.samples or 0, st.hours or 0), T.dim)
      S(("Disk: %d KB history, %d KB free"):format(floor((st.bytes or 0) / 1024 + 0.5), floor((st.free or 0) / 1024)),
        st.disk == "low" and T.bad or T.dim)
      if st.disk == "low" then S("DISK LOW (< 200 KB free): history is not saved", T.bad) end
      if st.error then S("error: " .. tostring(st.error), T.bad) end
      if msg ~= "" then S(msg, T.warn) end
      for _, s in ipairs(status) do
        for _, l in ipairs(wrap(s[1], W - 3)) do L(function(y) put(2, y, l, s[2]) end) end
      end
      local rows = H - 1
      setScroll = max(0, min(setScroll, #lines - rows))
      for i = 1, rows do
        local f = lines[setScroll + i]
        if f then f(1 + i) end
      end
      if setScroll > 0 then put(W, 2, "^", T.accent) end
      if setScroll + rows < #lines then put(W, H, "v", T.accent) end
    end

    ------------------------------------------------ render + loop
    local function render()
      local parent = term.current()
      W, H = parent.getSize()
      local buf = window.create(parent, 1, 1, W, H, false)
      term.redirect(buf)
      zones = {}
      term.setBackgroundColor(T.bg)
      term.clear()
      local ok, err = pcall(view == "settings" and drawSettings or drawChartView)
      if not ok then put(1, H, ("error: " .. tostring(err)):sub(1, W), T.bad) end
      term.redirect(parent)
      buf.setVisible(true)
      parent.setCursorBlink(false)
    end

    local timer = os.startTimer(5)
    render()
    while true do
      local e, a, b, c = os.pullEvent()
      if e == "timer" and a == timer then
        timer = os.startTimer(5)
        render()
      elseif e == "mineview_update" then
        render()
      elseif e == "mouse_click" then
        msg = ""
        for _, z in ipairs(zones) do
          if b >= z[1] and b <= z[3] and c >= z[2] and c <= z[4] then z[5](b, c) break end
        end
        render()
      elseif e == "mouse_scroll" then
        if view == "settings" then setScroll = setScroll + a
        elseif geo.x0 and b >= geo.x0 then
          offset, cross = max(0, offset - a * max(1, floor((geo.cw or 8) / 4))), nil
        else listScroll = max(0, listScroll + a) end
        render()
      elseif e == "char" and view == "chart" then
        filter, listScroll = (filter .. a):sub(1, 20), 0
        render()
      elseif e == "key" then
        if view == "chart" then
          if a == keys.backspace then filter = filter:sub(1, -2)
          elseif a == keys.left then offset, cross = offset + max(1, floor((geo.cw or 8) / 4)), nil
          elseif a == keys.right then offset, cross = max(0, offset - max(1, floor((geo.cw or 8) / 4))), nil
          elseif a == keys.up or a == keys.down then
            local list = entries()
            local i = 0
            for k, x in ipairs(list) do if x.name == sel then i = k end end
            i = max(1, min(#list, i + (a == keys.up and -1 or 1)))
            if list[i] then sel, offset, cross = list[i].name, 0, nil end
          end
        elseif a == keys.backspace then
          view = "chart"
        end
        render()
      elseif e == "term_resize" or e == "theme_changed" then
        render()
      end
    end
  end,
}
