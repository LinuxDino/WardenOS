-- GPS: the Warden GPS hosts around you, a constellation check with advice, an accurate locate of this computer
-- (several pings over every host, outliers rejected) and the GPS state of your drones.
local PROTO = "wardenos"
local OFFLINE = 120                               -- seconds without an announcement: the host counts as offline

return {
  name = "GPS", short = "GPS", icon = "(o)", color = colors.cyan, order = 7,
  w = 46, h = 17,
  art = { { "-o- ", "9399", "ffff" }, { " /|\\", "0888", "ffff" } },   -- 4x2 icon (blit; bg 7 = panel)
  main = function()
    local T = WardenOS.theme
    local gpsx = dofile("/os/lib/gpsx.lua")
    local me = os.getComputerID()
    local tab = "hosts"                           -- hosts | check | locate | drones
    local zones, msg, msgColor = {}, "", nil
    local scroll = 0
    local heard = {}                              -- [id] = announcement heard by this app (+ seen)
    local pinged, pingedAt = nil, nil             -- replies of the last scan / locate: { { x, y, z, d } }
    local fix, fixErr                             -- last locate result / reason
    local samples = 3
    local busy

    ------------------------------------------------ data
    local function announced()
      local out = {}
      local cache = type(WardenOS.gpsHosts) == "table" and WardenOS.gpsHosts or {}
      for id, h in pairs(cache) do out[id] = h end
      for id, h in pairs(heard) do
        if not out[id] or (tonumber(h.seen) or 0) > (tonumber(out[id].seen) or 0) then out[id] = h end
      end
      local own = WardenOS.gpsHost
      if type(own) == "table" and type(own.status) == "function" then
        local ok, s = pcall(own.status)
        if ok and type(s) == "table" then s.seen = os.clock() s.self = true out[me] = s end
      end
      return out
    end

    -- every host: announced Warden GPS hosts, plus hosts that only answered a ping (plain `gps host`)
    local function hosts()
      local list, byPos = {}, {}
      local now = os.clock()
      for id, h in pairs(announced()) do
        local x, y, z = tonumber(h.x), tonumber(h.y), tonumber(h.z)
        if x and y and z then
          local e = { id = id, label = h.label, x = x, y = y, z = z, served = h.served, version = h.version,
                      seen = tonumber(h.seen) or now, modems = h.modems, self = h.self, kind = "warden" }
          e.online = now - e.seen <= OFFLINE
          list[#list + 1] = e
          byPos[x .. "," .. y .. "," .. z] = e
        end
      end
      for _, f in ipairs(pinged or {}) do
        local key = f.x .. "," .. f.y .. "," .. f.z
        local e = byPos[key]
        if e then
          e.dist, e.online = f.d, true
        else
          e = { x = f.x, y = f.y, z = f.z, dist = f.d, kind = "plain", online = true, seen = pingedAt }
          list[#list + 1] = e
          byPos[key] = e
        end
      end
      table.sort(list, function(a, b)
        if a.online ~= b.online then return a.online end
        if (a.id ~= nil) ~= (b.id ~= nil) then return a.id ~= nil end
        if a.id and b.id then return a.id < b.id end
        if a.y ~= b.y then return a.y > b.y end
        return a.x < b.x
      end)
      return list
    end

    local function onOther(ev)                    -- events that arrive while a scan / locate is running
      if ev[1] == "rednet_message" and ev[4] == PROTO and type(ev[3]) == "table" and ev[3].t == "gps_host" then
        local d = {}
        for k, v in pairs(ev[3]) do d[k] = v end
        d.seen = os.clock()
        heard[ev[2]] = d
      end
    end

    local function age(s)
      s = math.max(0, math.floor(s))
      if s < 60 then return s .. "s" end
      if s < 3600 then return math.floor(s / 60) .. "m" end
      return math.floor(s / 3600) .. "h"
    end

    ------------------------------------------------ drawing
    local W, H = 1, 1
    local function put(x, y, s, fg, bg)
      if y < 1 or y > H or x > W then return end
      s = tostring(s)
      if x < 1 then s = s:sub(2 - x) x = 1 end
      term.setCursorPos(x, y)
      term.setTextColor(fg or T.text)
      term.setBackgroundColor(bg or T.bg)
      term.write(s:sub(1, W - x + 1))
    end
    local function zone(x, y, w, fn) zones[#zones + 1] = { x, x + w - 1, y, fn } end
    local function button(x, y, label, fn, fg, bg)
      label = " " .. label .. " "
      if x + #label - 1 > W then return x end
      put(x, y, label, fg or T.text, bg or T.panel)
      zone(x, y, #label, fn)
      return x + #label
    end
    local function wrap(s, width)
      local out, line = {}, ""
      for word in s:gmatch("%S+") do
        if line ~= "" and #line + 1 + #word > width then out[#out + 1] = line line = word
        else line = line == "" and word or (line .. " " .. word) end
      end
      if line ~= "" then out[#out + 1] = line end
      return out
    end

    local scan, locate                            -- defined below

    local function drawHosts(top, bottom)
      local list = hosts()
      if #list == 0 then
        local y = top + 1
        for _, l in ipairs(wrap("No GPS hosts heard yet. Tap scan to ping every host in range.", W - 2)) do
          put(2, y, l, T.dim) y = y + 1
        end
        if not gpsx.modem() then
          for _, l in ipairs(wrap("This computer has no wireless or ender modem: attach one to use GPS.", W - 2)) do
            put(2, y + 1, l, T.warn) y = y + 1
          end
        end
        return
      end
      local posW = math.max(12, math.min(20, W - 16))
      put(1, top, ("%-6s%-" .. posW .. "s%s"):format("host", "x y z", "state"), T.dim)
      local rows = bottom - top
      scroll = math.max(0, math.min(scroll, #list - rows))
      for i = 1, rows do
        local e = list[scroll + i]
        if not e then break end
        local y = top + i
        local id = e.id and ("#" .. e.id) or "gps"
        local pos = ("%d %d %d"):format(e.x, e.y, e.z)
        local state, sc
        if e.self then state, sc = "this pc", T.accent
        elseif not e.online then state, sc = "off " .. age(os.clock() - (e.seen or 0)), T.bad
        elseif e.kind == "plain" then state, sc = "plain gps host", T.dim
        elseif e.modems == 0 and not e.dist then state, sc = "no modem!", T.warn
        else state, sc = "ok " .. age(os.clock() - (e.seen or 0)), T.good end
        if e.served and W - 6 - posW >= #state + 10 then state = state .. "  served " .. tostring(e.served) end
        put(1, y, id, e.online and T.text or T.dim)
        put(7, y, pos:sub(1, posW - 1), e.online and T.text or T.dim)
        put(7 + posW, y, state, sc)
      end
    end

    local function advice(list)
      local online, out = {}, {}
      for _, e in ipairs(list) do
        if e.online then online[#online + 1] = e end
      end
      local r = gpsx.analyze(online)
      for _, e in ipairs(list) do
        if not e.online and e.id then
          out[#out + 1] = { ("Host #%d has not been heard for %s: offline, or its chunk is not loaded?")
            :format(e.id, age(os.clock() - (e.seen or 0))), T.warn }
        elseif e.online and e.modems == 0 and not e.dist then
          out[#out + 1] = { ("Host #%d has no wireless modem attached."):format(e.id), T.bad }
        end
      end
      local good = #r.advice == 1 and r.advice[1]:find("^Looks great")
      for _, a in ipairs(r.advice) do out[#out + 1] = { a, good and T.good or T.text } end
      return r, out
    end

    local function drawCheck(top, bottom)
      local r, lines = advice(hosts())
      local gc = (r.grade == "excellent" or r.grade == "good") and T.good or (r.grade == "fair" and T.warn or T.bad)
      put(2, top, "Constellation: ", T.dim)
      put(17, top, ("%s %d/100"):format(r.grade:upper(), r.score), gc)
      if r.n > 0 then
        put(2, top + 1, ("%d host%s  spread %d  lowest y %d"):format(r.n, r.n == 1 and "" or "s",
          math.floor(r.maxSep + 0.5), math.floor(r.minY)), T.dim)
      end
      local text = {}
      for _, l in ipairs(lines) do
        local first = true
        for _, wl in ipairs(wrap(l[1], W - 4)) do
          text[#text + 1] = { (first and "- " or "  ") .. wl, l[2] }
          first = false
        end
      end
      local y0 = top + 3
      local rows = bottom - y0 + 1
      scroll = math.max(0, math.min(scroll, #text - rows))
      for i = 1, rows do
        local l = text[scroll + i]
        if not l then break end
        put(2, y0 + i - 1, l[1], l[2])
      end
    end

    local function drawLocate(top, bottom)
      local y = top
      local function line(label, value, c)
        if y > bottom then return end
        put(2, y, label, T.dim)
        put(12, y, value, c or T.text)
        y = y + 1
      end
      if busy then
        put(2, y, ("Locating: %d pings over every host..."):format(samples), T.warn)
        return
      end
      if not fix and not fixErr then
        for _, l in ipairs(wrap(("Locate pings every GPS host %d times, solves over all of them and rejects "
            .. "outliers. More accurate than gps locate."):format(samples), W - 2)) do
          if y > bottom then break end
          put(2, y, l, T.dim) y = y + 1
        end
        return
      end
      if not fix then
        line("No fix", tostring(fixErr), T.bad)
        return
      end
      local qc = fix.quality == "exact" and T.good or (fix.quality == "good" and T.text or T.warn)
      line("Position", ("%d %d %d"):format(fix.x, fix.y, fix.z), T.accent)
      line("Fix", ("%s, %d/%d agree"):format(fix.quality, fix.agree, fix.tried), qc)
      line("Hosts", ("%d answered"):format(fix.hosts), fix.hosts >= 4 and T.text or T.warn)
      line("Raw", ("%.2f %.2f %.2f"):format(fix.raw.x, fix.raw.y, fix.raw.z), T.dim)
      line("Error", ("%.2f blocks"):format(math.max(fix.residual or 0, fix.spread or 0)), T.dim)
      local notes = {}
      for _, b in ipairs(fix.bad or {}) do
        notes[#notes + 1] = { ("The host at %d %d %d is off by %.1f blocks: fix its coordinates.")
          :format(b.x, b.y, b.z, b.off or 0), T.bad }
      end
      if (fix.residual or 0) > 0.5 and #(fix.bad or {}) == 0 then
        notes[#notes + 1] = { "The hosts disagree: one has wrong coordinates. A 5th host lets GPS find it.", T.bad }
      end
      local own = WardenOS.gpsHost
      if type(own) == "table" and tonumber(own.x) then
        if own.x == fix.x and own.y == fix.y and own.z == fix.z then
          notes[#notes + 1] = { "Matches this computer's GPS host position.", T.good }
        else
          notes[#notes + 1] = { ("This computer hosts GPS as %d %d %d: fix /os/gps/host.cfg."):format(own.x, own.y, own.z), T.bad }
        end
      end
      for _, n in ipairs(notes) do
        for _, l in ipairs(wrap(n[1], W - 2)) do
          if y > bottom then return end
          put(2, y, l, n[2]) y = y + 1
        end
      end
    end

    local function drawDrones(top, bottom)
      local c = type(WardenOS.drones) == "table" and WardenOS.drones or {}
      local ids = {}
      for id in pairs(c) do ids[#ids + 1] = id end
      table.sort(ids)
      if #ids == 0 then
        put(2, top + 1, ("No drones heard yet."):sub(1, W - 2), T.dim)
        return
      end
      local rows = bottom - top + 1
      scroll = math.max(0, math.min(scroll, #ids - rows))
      for i = 1, rows do
        local id = ids[scroll + i]
        if not id then break end
        local d = c[id]
        local y = top + i - 1
        local name = ("#%d %s"):format(id, tostring(d.label or "")):sub(1, 14)
        put(1, y, name, T.text)
        local x = 16
        if type(d.pos) == "table" and tonumber(d.pos[1]) then
          local s = ("GPS %s %s %s"):format(tostring(d.pos[1]), tostring(d.pos[2]), tostring(d.pos[3]))
          put(x, y, s, T.good)
          x = x + #s + 1
        else
          put(x, y, "no GPS fix", T.warn)
          x = x + 11
        end
        if d.calibrated ~= nil then
          put(x, y, d.calibrated and "calibrated" or "not calibrated", d.calibrated and T.dim or T.warn)
        end
      end
    end

    local TABS = { { "hosts", "hosts", "hst" }, { "check", "check", "chk" }, { "locate", "locate", "loc" },
                   { "drones", "drones", "drn" } }

    local function draw()
      -- header: title + tabs
      term.setCursorPos(1, 1)
      term.setBackgroundColor(T.panel)
      term.clearLine()
      local short = W < 30
      local width = 0
      for _, t in ipairs(TABS) do width = width + #(short and t[3] or t[2]) + 2 end
      if W >= width + 6 then put(2, 1, "GPS", T.accent, T.panel) end
      local x = math.max(1, W - width + 1)
      for _, t in ipairs(TABS) do
        local on = tab == t[1]
        x = button(x, 1, short and t[3] or t[2], function() tab, scroll = t[1], 0 end,
                   on and T.bg or T.dim, on and T.accent or T.panel)
      end

      local top, bottom = 2, H - 1
      if tab == "hosts" then drawHosts(top, bottom)
      elseif tab == "check" then drawCheck(top, bottom)
      elseif tab == "locate" then drawLocate(top, bottom)
      else drawDrones(top, bottom) end

      -- footer: actions + message
      term.setCursorPos(1, H)
      term.setBackgroundColor(T.bg)
      term.clearLine()
      local bx = 1
      if tab == "locate" then
        bx = button(bx, H, "locate", function() locate() end, T.bg, T.accent) + 1
        bx = button(bx, H, "x" .. samples, function() samples = samples >= 7 and 3 or samples + 2 end) + 1
      elseif tab ~= "drones" then
        bx = button(bx, H, "scan", function() scan() end, T.bg, T.accent) + 1
      end
      if msg ~= "" and bx < W then put(bx + 1, H, msg, msgColor or T.dim) end
    end

    local function render()
      local parent = term.current()
      W, H = parent.getSize()
      local buf = window.create(parent, 1, 1, W, H, false)
      term.redirect(buf)
      zones = {}
      term.setBackgroundColor(T.bg)
      term.clear()
      draw()
      term.redirect(parent)
      buf.setVisible(true)
    end

    ------------------------------------------------ actions
    function scan()
      msg, msgColor = "scanning...", T.warn
      render()
      if rednet.isOpen() then rednet.broadcast({ t = "gps_who" }, PROTO) end
      local fixes, err = gpsx.ping({ timeout = 1, other = onOther })
      if fixes then
        pinged, pingedAt = fixes, os.clock()
        msg, msgColor = ("%d host%s answered"):format(#fixes, #fixes == 1 and "" or "s"), #fixes >= 4 and T.good or T.warn
      else
        msg, msgColor = tostring(err), T.bad
      end
    end

    function locate()
      busy = true
      msg = ""
      render()
      local r, err = gpsx.locate({ samples = samples, timeout = 1, other = onOther })
      busy = false
      fix, fixErr = r, err
      if r and r.fixes then pinged, pingedAt = r.fixes, os.clock() end
    end

    ------------------------------------------------ events
    render()
    local tick = os.startTimer(2)
    while true do
      local ev = table.pack(os.pullEvent())
      local e, a, b, c = ev[1], ev[2], ev[3], ev[4]
      onOther(ev)
      if e == "timer" and a == tick then
        tick = os.startTimer(2)
      elseif e == "mouse_click" then
        for _, z in ipairs(zones) do
          if c == z[3] and b >= z[1] and b <= z[2] then z[4]() break end   -- button, x, y
        end
      elseif e == "mouse_scroll" then
        scroll = math.max(0, scroll + a)
      elseif e == "key" then
        local idx = 1
        for i, t in ipairs(TABS) do if t[1] == tab then idx = i end end
        if a == keys.right then tab, scroll = TABS[idx % #TABS + 1][1], 0
        elseif a == keys.left then tab, scroll = TABS[(idx - 2) % #TABS + 1][1], 0
        elseif a == keys.up then scroll = math.max(0, scroll - 1)
        elseif a == keys.down then scroll = scroll + 1
        elseif a == keys.enter then
          if tab == "locate" then locate() elseif tab ~= "drones" then scan() end
        end
      end
      render()
    end
  end,
}
