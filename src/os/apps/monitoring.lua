-- System Monitor: the debug page.
-- Tabs: Overview (system, storage, checks), Devices, Net (live rednet log), Drones (every known drone),
-- Claude (API calls), Logs (errors, info, event counts), Disk (usage per folder, world map).
-- Extend it: add entries to `checks` (health checks) or `panels` (tabs) below.
local font = dofile("/os/lib/bigfont.lua")
local T = WardenOS.theme

return {
  name = "System Monitor", short = "Sys", icon = "/\\", color = colors.green, order = 6,
  w = 52, h = 22,
  main = function()
    local log
    do
      local ok, l = pcall(dofile, "/os/lib/log.lua")
      if ok and type(l) == "table" then log = l end
    end
    local function logList(kind) return log and log.list(kind) or {} end
    local map
    do
      local ok, m = pcall(dofile, "/os/lib/map.lua")
      if ok and type(m) == "table" then map = m end
    end
    local claudeLib
    if fs.exists("/os/lib/claude.lua") then
      local ok, c = pcall(dofile, "/os/lib/claude.lua")
      if ok and type(c) == "table" then claudeLib = c end
    end

    local me = os.getComputerID()
    local tab, zones = 1, {}
    local W, H = term.getSize()
    local scroll = {}                             -- [tab name] = first row shown
    local maxScroll = {}                          -- [tab name] = largest useful scroll
    local net = { filter = 1, paused = nil }      -- paused = frozen copy of the list
    local FILTERS = { "all", "wardenos", "drones" }
    local logView = "log"                         -- log | events
    local droneSel                                -- drone id shown in detail
    local disk                                    -- cached Disk tab numbers

    ------------------------------------------------ helpers (everything is clipped to the window)
    local function put(x, y, s, fg, bg)
      if y < 1 or y > H or x > W then return end
      s = tostring(s)
      if x < 1 then s = s:sub(2 - x) x = 1 end
      s = s:sub(1, W - x + 1)
      if s == "" then return end
      term.setCursorPos(x, y)
      term.setTextColor(fg or T.text)
      term.setBackgroundColor(bg or T.bg)
      term.write(s)
    end
    local function fill(x, y, w, h, bg)
      if x < 1 then w = w + x - 1 x = 1 end
      w = math.min(w, W - x + 1)
      if w <= 0 or h <= 0 then return end
      term.setBackgroundColor(bg)
      local s = string.rep(" ", w)
      for i = 0, h - 1 do
        if y + i >= 1 and y + i <= H then term.setCursorPos(x, y + i) term.write(s) end
      end
    end
    local function zone(x, y, w, fn) zones[#zones + 1] = { x, x + w - 1, y, fn } end
    local function button(x, y, label, fn, fg, bg)
      label = " " .. label .. " "
      put(x, y, label, fg or T.bg, bg or T.accent)
      zone(x, y, #label, fn)
      return x + #label + 1
    end
    local function card(x, y, w, h, title)
      fill(x, y, w, h, T.panel)
      put(x + 1, y, title:upper(), T.dim, T.panel)
    end
    local function kv(x, y, k, v, w)
      put(x, y, k, T.dim, T.panel)
      put(x + 9, y, tostring(v):sub(1, math.max(0, w - 9)), T.text, T.panel)
    end
    local function bar(x, y, w, frac, col)
      frac = math.max(0, math.min(1, frac))
      fill(x, y, w, 1, T.bg)
      fill(x, y, math.floor(w * frac + 0.5), 1, col)
    end
    local function cut(s, n)
      s = tostring(s)
      if n <= 0 then return "" end
      if #s > n then return s:sub(1, math.max(1, n - 1)) .. "~" end
      return s
    end
    local function pad(s, n) s = cut(s, n) return s .. string.rep(" ", n - #s) end
    local function age(clock)
      if type(clock) ~= "number" then return "?" end
      local s = math.max(0, math.floor(os.clock() - clock))
      if s < 60 then return s .. "s" end
      if s < 3600 then return math.floor(s / 60) .. "m" end
      return math.floor(s / 3600) .. "h"
    end
    local function num(n)
      n = tonumber(n)
      if not n then return "-" end
      if math.abs(n) >= 1e6 then return ("%.1fM"):format(n / 1e6) end
      if math.abs(n) >= 1e3 then return ("%.1fk"):format(n / 1e3) end
      return tostring(math.floor(n))
    end
    local function kb(n) return math.floor((n or 0) / 1024 + 0.5) .. " KB" end

    -- scrollable list: rows y1..y2, items drawn by row(item, y); arrows on the right when it overflows
    local function list(name, items, y1, y2, row)
      local rows = math.max(1, y2 - y1 + 1)
      local top = math.max(0, #items - rows)
      maxScroll[name] = top
      local s = math.max(0, math.min(scroll[name] or 0, top))
      scroll[name] = s
      for i = 1, rows do
        local it = items[s + i]
        if not it then break end
        row(it, y1 + i - 1, s + i)
      end
      if top > 0 then
        put(W, y1, "^", s > 0 and T.accent or T.dim, T.panel)
        zone(W, y1, 1, function() scroll[name] = math.max(0, s - rows) end)
        put(W, y2, "v", s < top and T.accent or T.dim, T.panel)
        zone(W, y2, 1, function() scroll[name] = math.min(top, s + rows) end)
        if y2 - y1 >= 2 then
          local pos = y1 + 1 + math.floor((y2 - y1 - 2) * s / top + 0.5)
          put(W, pos, "|", T.dim, T.bg)
        end
      end
    end

    ------------------------------------------------ health checks (add your own)
    local checks = {
      { name = "Monitor", test = function()
          return peripheral.find("monitor") ~= nil, "attached" end },
      { name = "Disk", test = function()
          local f = fs.getFreeSpace("/")
          return f > 20000, math.floor(f / 1024) .. " KB free" end },
      { name = "Modem", test = function()
          local m = peripheral.find("modem")
          return true, m and (rednet.isOpen() and "open" or "found, closed") or "none (optional)" end },
      { name = "Errors", test = function()
          local n = log and log.rate("error") or 0
          return n == 0, n == 0 and "none in the last minute" or (n .. " in the last minute") end },
    }

    local function storage()
      local free = fs.getFreeSpace("/")
      local ok, cap = pcall(function() return fs.getCapacity and fs.getCapacity("/") end)
      if ok and type(cap) == "number" and cap > 0 then return cap - free, cap, free end
      return nil, nil, free
    end

    local function drones()
      local out = {}
      for id, d in pairs(type(WardenOS.drones) == "table" and WardenOS.drones or {}) do
        if type(d) == "table" then out[#out + 1] = { id = id, d = d } end
      end
      table.sort(out, function(a, b) return (tonumber(a.id) or 0) < (tonumber(b.id) or 0) end)
      return out
    end
    local function protRev()
      if not map then return nil end
      local ok, p = pcall(map.protected)
      return ok and type(p) == "table" and tonumber(p.rev) or nil
    end
    -- warnings of one drone: { offline, lowFuel, version, protect } (true = flag)
    local function warnings(d)
      local w = {}
      w.offline = type(d.seen) ~= "number" or os.clock() - d.seen > 10
      w.lowFuel = type(d.fuel) == "number" and d.fuel < 200
      w.version = d.version ~= nil and tostring(d.version) ~= tostring(WardenOS.version)
      local rev = protRev()
      w.protect = d.owner == me and rev ~= nil and tonumber(d.protectRev) ~= rev
      return w
    end

    ------------------------------------------------ panels (tabs); each draws rows y..H
    local function overview(y)
      local w, x = W - 2, 2
      if H >= 21 and W >= 40 then
        local tx = font.width("WARDEN") + 4
        font.draw(term, "WARDEN", 2, y + 1, T.accent)
        put(tx, y + 1, "SYSTEM MONITOR", T.text, T.bg)
        put(tx, y + 2, "WardenOS " .. tostring(WardenOS.version), T.dim, T.bg)
        y = y + 4
      else
        put(2, y + 1, "SYSTEM MONITOR", T.text, T.bg)
        put(17, y + 1, "WardenOS " .. tostring(WardenOS.version), T.dim, T.bg)
      end
      local allok = true
      for _, c in ipairs(checks) do if not c.test() then allok = false end end
      local row = H >= 21 and W >= 40 and y or y + 2
      put(H >= 21 and W >= 40 and font.width("WARDEN") + 4 or 2, row,
          allok and "* all systems nominal" or "! attention needed", allok and T.good or T.warn, T.bg)
      y = row + 2

      local half = math.floor((w - 1) / 2)
      card(x, y, half, 6, "System")
      kv(x + 1, y + 1, "ID", "#" .. os.getComputerID(), half - 2)
      kv(x + 1, y + 2, "Label", os.getComputerLabel() or "-", half - 2)
      kv(x + 1, y + 3, "Time", textutils.formatTime(os.time(), true), half - 2)
      kv(x + 1, y + 4, "Uptime", math.floor(os.clock()) .. " s", half - 2)

      local x2, w2 = x + half + 1, w - half - 1
      card(x2, y, w2, 6, "Storage")
      local used, cap, free = storage()
      if cap then
        local frac = used / cap
        bar(x2 + 1, y + 2, w2 - 2, frac, frac > 0.9 and T.bad or (frac > 0.7 and T.warn or T.good))
        put(x2 + 1, y + 3, math.floor(used / 1024) .. " / " .. math.floor(cap / 1024) .. " KB", T.text, T.panel)
      else
        put(x2 + 1, y + 2, math.floor(free / 1024) .. " KB free", T.text, T.panel)
      end
      local ev, rate = 0, 0
      if log then ev, rate = log.count() end
      put(x2 + 1, y + 4, cut(("events %s, %d/min"):format(num(ev), rate), w2 - 2), T.dim, T.panel)

      y = y + 7
      if H - y + 1 >= 3 then
        card(x, y, w, H - y + 1, "Checks")
        for i, c in ipairs(checks) do
          if y + i <= H then
            local ok, msg = c.test()
            put(x + 1, y + i, ok and "OK  " or "WARN", ok and T.good or T.warn, T.panel)
            put(x + 6, y + i, cut(c.name .. ": " .. msg, w - 7), T.text, T.panel)
          end
        end
      end
    end

    local function devices(y)
      local names = peripheral.getNames()
      put(2, y, ("%d peripherals"):format(#names), T.dim)
      if #names == 0 then put(2, y + 2, "nothing attached", T.dim) end
      list("Devices", names, y + 1, H, function(n, ry)
        fill(1, ry, W, 1, T.panel)
        put(2, ry, pad(n, 20), T.text, T.panel)
        local types = { peripheral.getType(n) }
        for i, t in ipairs(types) do types[i] = tostring(t) end
        put(23, ry, cut(table.concat(types, ", "), W - 24), T.accent, T.panel)
      end)
    end

    local function modemText()
      local parts = {}
      for _, n in ipairs(peripheral.getNames()) do
        if peripheral.getType(n) == "modem" then
          local open = rednet.isOpen(n)
          local okw, wl = pcall(peripheral.call, n, "isWireless")
          parts[#parts + 1] = n .. (open and " open" or " closed") .. (okw and wl and " wl" or "")
        end
      end
      return #parts > 0 and table.concat(parts, ", ") or "no modem"
    end

    local function netPanel(y)
      local x = button(1, y, "show " .. FILTERS[net.filter], function()
        net.filter = net.filter % #FILTERS + 1
        scroll.Net = 0
      end, T.text, T.panel)
      x = button(x, y, net.paused and "resume" or "pause", function()
        if net.paused then net.paused = nil else net.paused = logList("rednet") end
      end, net.paused and T.bg or T.text, net.paused and T.warn or T.panel)
      local rate = log and log.rate("rednet") or 0
      put(x, y, cut(rate .. "/min", W - x + 1), T.dim)
      put(1, y + 1, cut("#" .. me .. "  " .. modemText(), W), T.dim)
      local items = {}
      for _, e in ipairs(net.paused or logList("rednet")) do
        local f = FILTERS[net.filter]
        if f == "all" or (f == "wardenos" and e.protocol == "wardenos") or (f == "drones" and e.drone) then
          items[#items + 1] = e
        end
      end
      if #items == 0 then
        put(2, y + 3, log and "no messages yet" or "log library missing", T.dim)
        return
      end
      list("Net", items, y + 2, H, function(e, ry)
        local proto = e.protocol == "wardenos" and "wos" or (e.protocol or "-")
        local head = ("%-4s %-5s %-4s %-4s "):format(age(e.clock), cut("#" .. tostring(e.from), 5),
          e.to and cut(">" .. e.to, 4) or "", cut(proto, 4))
        put(1, ry, head, e.drone and T.accent or T.dim)
        local sum = tostring(e.summary or "")
        local sz = e.size and (e.size >= 1000 and (" " .. num(e.size) .. "B") or "") or ""
        put(#head + 1, ry, cut(sum .. sz, W - #head - 1), T.text)
      end)
    end

    local function fuelStr(d)
      local f = d.fuel == "unlimited" and "inf" or (type(d.fuel) == "number" and tostring(math.floor(d.fuel)) or "?")
      if d.fuelItems then f = f .. "+" .. tostring(d.fuelItems) .. "c" end
      return f
    end
    local function posStr(d)
      if d.calibrated and type(d.abs) == "table" and tonumber(d.abs.x) then
        return ("%d %d %d"):format(d.abs.x, d.abs.y, d.abs.z)
      end
      return "uncal."
    end

    local function droneDetail(y)
      local d = type(WardenOS.drones) == "table" and WardenOS.drones[droneSel]
      button(1, y, "<", function() droneSel = nil end, T.accent, T.panel)
      if type(d) ~= "table" then
        put(5, y, "drone #" .. tostring(droneSel) .. " is gone", T.dim)
        return
      end
      put(5, y, cut(("#%s %s  seen %s ago"):format(tostring(droneSel), tostring(d.label or "-"), age(d.seen)), W - 5), T.text)
      local keys = {}
      for k in pairs(d) do keys[#keys + 1] = k end
      table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
      local rows = {}
      local wn = warnings(d)
      for _, k in ipairs(keys) do
        local v = d[k]
        local s
        if type(v) == "table" then
          local parts, n = {}, 0
          for kk, vv in pairs(v) do
            n = n + 1
            if n <= 6 then
              parts[#parts + 1] = (type(kk) == "number" and "" or (tostring(kk) .. "=")) ..
                (type(vv) == "table" and "{..}" or tostring(vv))
            end
          end
          s = "{" .. table.concat(parts, " ") .. (n > 6 and " +" .. (n - 6) or "") .. "}"
        else
          s = tostring(v)
        end
        local col = T.text
        if (k == "fuel" and wn.lowFuel) or (k == "seen" and wn.offline) then col = T.bad
        elseif (k == "version" and wn.version) or (k == "protectRev" and wn.protect) then col = T.warn end
        rows[#rows + 1] = { k = tostring(k), v = s, col = col }
      end
      list("Drone", rows, y + 1, H, function(r, ry)
        put(1, ry, pad(r.k, 11), T.dim)
        put(13, ry, cut(r.v, W - 13), r.col)
      end)
    end

    local function dronesPanel(y)
      if droneSel then return droneDetail(y) end
      local all = drones()
      local on, warn = 0, 0
      for _, e in ipairs(all) do
        local wn = warnings(e.d)
        if not wn.offline then on = on + 1 end
        if wn.offline or wn.lowFuel or wn.version or wn.protect then warn = warn + 1 end
      end
      put(1, y, cut((" %d drones, %d online, %d need attention  map rev %s"):format(#all, on, warn, tostring(protRev() or "-")), W), T.dim)
      if #all == 0 then
        put(2, y + 2, "No drone status received yet.", T.dim)
        put(2, y + 3, "Drones report every few seconds", T.dim)
        put(2, y + 4, "over rednet (protocol wardenos).", T.dim)
        return
      end
      -- two rows per drone
      local rows = {}
      for _, e in ipairs(all) do rows[#rows + 1] = { e = e, first = true } rows[#rows + 1] = { e = e } end
      list("Drones", rows, y + 1, H, function(r, ry)
        local d, id = r.e.d, r.e.id
        local wn = warnings(d)
        zone(1, ry, W - 1, function() droneSel = id end)
        if r.first then
          fill(1, ry, W - 1, 1, T.panel)
          put(1, ry, wn.offline and "-" or "*", wn.offline and T.bad or T.good, T.panel)
          put(2, ry, pad(("#%s %s"):format(tostring(id), tostring(d.label or "")), 12), T.text, T.panel)
          put(15, ry, pad(tostring(d.task or "?") .. "/" .. tostring(d.state or "?"), 12), T.text, T.panel)
          local fu = "f:" .. fuelStr(d) .. (wn.lowFuel and "!" or "")
          put(28, ry, pad(fu, W - 28 - 8), wn.lowFuel and T.bad or T.text, T.panel)
          local a = age(d.seen)
          if wn.offline then a = "off " .. a end
          put(W - #a - 1, ry, a, wn.offline and T.bad or T.dim, T.panel)
        else
          local p = posStr(d)
          put(2, ry, pad(p, 14), p == "uncal." and T.dim or T.text)
          local v = "v" .. tostring(d.version or "?") .. (wn.version and "!" or "")
          put(16, ry, pad(v, 8), wn.version and T.warn or T.dim)
          local pr = "prot " .. tostring(d.protectRev or "-") .. (wn.protect and "!" or "")
          put(25, ry, pad(pr, 8), wn.protect and T.warn or T.dim)
          if W >= 40 then
            local sd = d.safeDig == nil and "" or (d.safeDig and "safe" or "UNSAFE")
            put(34, ry, cut(sd, W - 35), d.safeDig == false and T.warn or T.dim)
          end
        end
      end)
    end

    local function claudePanel(y)
      local calls = logList("claude")
      local tin, tout, errs, ms = 0, 0, 0, 0
      for _, c in ipairs(calls) do
        tin = tin + (c.input or 0) + (c.cacheRead or 0) + (c.cacheWrite or 0)
        tout = tout + (c.output or 0)
        if c.error then errs = errs + 1 end
        ms = ms + (c.ms or 0)
      end
      local total = log and log.total("claude") or 0
      put(1, y, cut((" %d calls  in %s  out %s  errors %d"):format(total, num(tin), num(tout), errs), W), T.text)
      local st = rawget(WardenOS, "claude")
      local line
      if type(st) == "table" then
        local nd = 0
        if type(st.drones) == "table" then for _ in pairs(st.drones) do nd = nd + 1 end end
        line = ("chat: %s%s  drones %d"):format(st.busy and "busy" or "idle",
          st.status and (" - " .. tostring(st.status)) or "", nd)
      else
        local nd = 0
        if claudeLib then
          local ok, g = pcall(claudeLib.getDrones)
          if ok and type(g) == "table" then for _ in pairs(g) do nd = nd + 1 end end
        end
        local key = claudeLib and claudeLib.getKey and claudeLib.getKey() and "key set" or "no key"
        line = ("chat: not running  %s  drones given %d"):format(key, nd)
      end
      put(1, y + 1, cut(" " .. line, W), (type(st) == "table" and st.busy) and T.warn or T.dim)
      if #calls == 0 then
        put(2, y + 3, "No API calls since the computer started.", T.dim)
        return
      end
      list("Claude", calls, y + 2, H, function(c, ry)
        local model = tostring(c.model or "?"):gsub("^claude%-", "")
        local head = ("%-4s %-11s %-4s %6s "):format(age(c.clock), cut(model, 11), cut(c.effort or "-", 4),
          c.ms and (c.ms >= 10000 and (math.floor(c.ms / 1000) .. "s") or (c.ms .. "ms")) or "-")
        put(1, ry, head, T.dim)
        local res
        if c.error then
          res = "ERR " .. c.error
        else
          res = ("%s/%s"):format(num((c.input or 0) + (c.cacheRead or 0) + (c.cacheWrite or 0)), num(c.output))
          if (c.cacheRead or 0) > 0 then res = res .. " c" .. num(c.cacheRead) end
          res = res .. " " .. tostring(c.stop or "?")
        end
        if (c.retries or 0) > 0 then res = res .. " r" .. c.retries end
        put(#head + 1, ry, cut(res, W - #head - 1), c.error and T.bad or T.text)
      end)
    end

    local function logsPanel(y)
      local x = button(1, y, "log", function() logView = "log" scroll.Logs = 0 end,
        logView == "log" and T.bg or T.text, logView == "log" and T.accent or T.panel)
      x = button(x, y, "events", function() logView = "events" scroll.Logs = 0 end,
        logView == "events" and T.bg or T.text, logView == "events" and T.accent or T.panel)
      button(x, y, "clear", function()
        if log then
          if logView == "events" then log.clear("event") else log.clear("error") log.clear("info") end
        end
        scroll.Logs = 0
      end, T.bg, T.bad)
      if logView == "events" then
        local items = logList("event")
        local n, rate = 0, 0
        if log then n, rate = log.count() end
        put(1, y + 1, cut((" %s events, %d/min"):format(num(n), rate), W), T.dim)
        list("Logs", items, y + 2, H, function(e, ry)
          put(2, ry, pad(e.name, 20), T.text)
          put(23, ry, cut(("%8s  %d/min"):format(num(e.count), e.rate), W - 24), T.dim)
        end)
        return
      end
      local items = {}
      for _, e in ipairs(logList("error")) do items[#items + 1] = { e = e, err = true } end
      for _, e in ipairs(logList("info")) do items[#items + 1] = { e = e } end
      table.sort(items, function(a, b) return (a.e.seq or 0) > (b.e.seq or 0) end)
      local rows = {}                               -- wrap long lines
      local tw = math.max(10, W - 7)
      for _, it in ipairs(items) do
        local txt = (it.e.source and (tostring(it.e.source) .. ": ") or "") .. tostring(it.e.text or "")
        txt = txt:gsub("[%c]", " ")
        local first = true
        repeat
          rows[#rows + 1] = { t = txt:sub(1, tw), err = it.err, age = first and age(it.e.clock) or "" }
          txt, first = txt:sub(tw + 1), false
        until txt == "" or #rows > 400
      end
      put(1, y + 1, cut((" %d errors, %d info"):format(#logList("error"), #logList("info")), W), T.dim)
      if #rows == 0 then put(2, y + 3, "Nothing logged.", T.dim) return end
      list("Logs", rows, y + 2, H, function(r, ry)
        put(1, ry, pad(r.age, 5), T.dim)
        put(6, ry, r.t, r.err and T.bad or T.text)
      end)
    end

    local function dirSize(p, budget)
      local n = 0
      local okl, entries = pcall(fs.list, p)
      if not okl then return 0 end
      for _, f in ipairs(entries) do
        budget.left = budget.left - 1
        if budget.left < 0 then break end
        local q = fs.combine(p, f)
        if fs.isDir(q) then n = n + dirSize(q, budget) else
          local ok, s = pcall(fs.getSize, q)
          n = n + (ok and s or 0)
        end
      end
      return n
    end
    local function scanDisk()
      disk = { dirs = {}, at = os.clock() }
      local budget = { left = 3000 }
      local okl, entries = pcall(fs.list, "/os")
      if okl then
        local files = 0
        for _, f in ipairs(entries) do
          local q = "/os/" .. f
          if fs.isDir(q) then disk.dirs[#disk.dirs + 1] = { name = f .. "/", size = dirSize(q, budget) }
          else local ok, s = pcall(fs.getSize, q) files = files + (ok and s or 0) end
        end
        disk.dirs[#disk.dirs + 1] = { name = "(files in /os)", size = files }
        table.sort(disk.dirs, function(a, b) return a.size > b.size end)
      end
      disk.partial = budget.left < 0
      if map then
        local ok, info = pcall(map.info)
        if ok and type(info) == "table" then disk.map = info end
      end
    end

    local function diskPanel(y)
      if not disk or os.clock() - disk.at > 30 then scanDisk() end
      local used, cap, free = storage()
      if cap then
        local frac = used / cap
        put(1, y, cut((" %s free of %s"):format(kb(free), kb(cap)), W - 12), T.text)
        bar(2, y + 1, W - 12, frac, frac > 0.9 and T.bad or (frac > 0.7 and T.warn or T.good))
        put(W - 9, y + 1, ("%3d%% used"):format(math.floor(frac * 100 + 0.5)), T.dim)
      else
        put(1, y, " " .. kb(free) .. " free", T.text)
      end
      button(W - 8, y, "rescan", function() disk = nil end, T.text, T.panel)
      local m = disk.map
      local rows = {}
      if m then
        rows[#rows + 1] = { "World map", ("%s / %s blocks%s"):format(num(m.total), num(m.cap), m.full and "  FULL" or ""),
          m.full and T.bad or T.text, head = true }
        local p = type(m.protect) == "table" and m.protect or {}
        rows[#rows + 1] = { "  chunks", ("%s   protected %d (rev %s)"):format(tostring(m.chunks or 0),
          type(p.boxes) == "table" and #p.boxes or 0, tostring(p.rev or "-")), T.text }
        if type(m.bounds) == "table" then
          local b = m.bounds
          rows[#rows + 1] = { "  area", ("%s..%s x  %s..%s z"):format(b.x1, b.x2, b.z1, b.z2), T.dim }
        end
      else
        rows[#rows + 1] = { "World map", map and "no data" or "map library missing", T.dim, head = true }
      end
      rows[#rows + 1] = { "/os folders" .. (disk.partial and " (partial)" or ""), "", T.dim, head = true }
      for _, d in ipairs(disk.dirs) do
        rows[#rows + 1] = { "  " .. d.name, kb(d.size), T.text, frac = cap and d.size / cap }
      end
      list("Disk", rows, y + 3, H, function(r, ry)
        put(1, ry, pad(r[1], 18), r.head and T.accent or T.dim)
        put(19, ry, cut(r[2], W - 20), r[3])
        if r.frac and W >= 40 then
          local bw = math.min(12, W - 33)
          if bw >= 4 then bar(W - bw - 1, ry, bw, math.max(r.frac, 0), T.accent) end
        end
      end)
    end

    local panels = {
      { name = "Overview", short = "Sys",    draw = overview },
      { name = "Devices",  short = "Dev",    draw = devices },
      { name = "Net",      short = "Net",    draw = netPanel },
      { name = "Drones",   short = "Drones", draw = dronesPanel },
      { name = "Claude",   short = "Claude", draw = claudePanel },
      { name = "Logs",     short = "Logs",   draw = logsPanel },
      { name = "Disk",     short = "Disk",   draw = diskPanel },
    }

    ------------------------------------------------ render (double buffered)
    local function tabBar()
      local long = 0
      for _, p in ipairs(panels) do long = long + #p.name + 2 end
      local useLong = long <= W
      local x = 1
      for i, p in ipairs(panels) do
        local label = " " .. (useLong and p.name or p.short) .. " "
        if x + #label - 1 > W then break end
        put(x, 1, label, i == tab and T.bg or T.dim, i == tab and T.accent or T.panel)
        zone(x, 1, #label, function() tab = i end)
        x = x + #label
      end
      fill(x, 1, W - x + 1, 1, T.panel)
    end

    local function draw()
      W, H = term.getSize()
      zones = {}
      fill(1, 1, W, H, T.bg)
      tabBar()
      local ok, err = pcall(panels[tab].draw, 2)
      if not ok then
        put(2, 3, cut("panel error: " .. tostring(err), W - 2), T.bad)
        if log then log.add("error", { source = "monitor", text = tostring(err) }) end
      end
    end

    local function render()
      local parent = term.current()
      local w, h = parent.getSize()
      local buf = window.create(parent, 1, 1, w, h, false)
      term.redirect(buf)
      draw()
      term.redirect(parent)
      buf.setVisible(true)
    end

    ------------------------------------------------ loop
    local timer = os.startTimer(1)
    render()
    while true do
      local e, a, x, y = os.pullEvent()
      local dirty = false
      if e == "timer" and a == timer then
        timer = os.startTimer(1)
        dirty = true
      elseif e == "mouse_click" then
        for _, z in ipairs(zones) do
          if y == z[3] and x >= z[1] and x <= z[2] then z[4]() break end
        end
        dirty = true
      elseif e == "mouse_scroll" or (e == "key" and (a == keys.up or a == keys.down or a == keys.pageUp or a == keys.pageDown)) then
        local name = panels[tab].name
        if name == "Drones" and droneSel then name = "Drone" end
        local step = 1
        if e == "mouse_scroll" then step = a
        elseif a == keys.up then step = -1
        elseif a == keys.pageUp then step = -(H - 4)
        elseif a == keys.pageDown then step = H - 4 end
        scroll[name] = math.max(0, math.min((scroll[name] or 0) + step, maxScroll[name] or 0))
        dirty = true
      elseif e == "theme_changed" or e == "term_resize" then
        dirty = true
      end
      if dirty then render() end
    end
  end,
}
