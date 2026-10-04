-- System Monitor
-- Extend it: add entries to `checks` (health checks) or `panels` (tabs) below.
local font = dofile("/os/lib/bigfont.lua")
local T = WardenOS.theme

return {
  name = "System Monitor", short = "Sys", icon = "/\\", color = colors.green, order = 6,
  w = 52, h = 22,
  main = function()
    local tab, zones = 1, {}

    ------------------------------------------------ helpers
    local function put(x, y, s, fg, bg)
      term.setCursorPos(x, y)
      term.setTextColor(fg or T.text)
      term.setBackgroundColor(bg or T.bg)
      term.write(s)
    end
    local function fill(x, y, w, h, bg)
      if w <= 0 or h <= 0 then return end
      term.setBackgroundColor(bg)
      local s = string.rep(" ", w)
      for i = 0, h - 1 do term.setCursorPos(x, y + i) term.write(s) end
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

    ------------------------------------------------ health checks (add your own)
    local checks = {
      { name = "Monitor", test = function()
          return peripheral.find("monitor") ~= nil, "attached" end },
      { name = "Disk", test = function()
          local f = fs.getFreeSpace("/")
          return f > 20000, math.floor(f / 1024) .. " KB free" end },
      { name = "Modem", test = function()
          local m = peripheral.find("modem")
          return true, m and "found" or "none (optional)" end },
    }

    local function storage()
      local free = fs.getFreeSpace("/")
      local ok, cap = pcall(function() return fs.getCapacity and fs.getCapacity("/") end)
      if ok and type(cap) == "number" and cap > 0 then return cap - free, cap, free end
      return nil, nil, free
    end

    ------------------------------------------------ panels (tabs)
    local function overview(x, y, w, h)
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
        bar(x2 + 1, y + 2, w2 - 2, frac, frac > 0.9 and T.bad or (frac > 0.7 and T.warn or colors.green))
        put(x2 + 1, y + 3, math.floor(used / 1024) .. " / " .. math.floor(cap / 1024) .. " KB", T.text, T.panel)
      else
        put(x2 + 1, y + 2, math.floor(free / 1024) .. " KB free", T.text, T.panel)
      end

      if h >= 10 then
        card(x, y + 7, w, h - 7, "Checks")
        for i, c in ipairs(checks) do
          if y + 7 + i < y + h then
            local ok, msg = c.test()
            put(x + 1, y + 7 + i, ok and "OK  " or "WARN", ok and colors.green or T.warn, T.panel)
            put(x + 6, y + 7 + i, (c.name .. ": " .. msg):sub(1, w - 7), T.text, T.panel)
          end
        end
      end
    end

    local function devices(x, y, w, h)
      card(x, y, w, h, "Peripherals")
      local names = peripheral.getNames()
      if #names == 0 then put(x + 1, y + 1, "nothing attached", T.dim, T.panel) end
      for i, n in ipairs(names) do
        if i > h - 2 then break end
        put(x + 1, y + i, n:sub(1, 18), T.text, T.panel)
        put(x + 21, y + i, tostring(peripheral.getType(n)):sub(1, math.max(0, w - 23)), T.accent, T.panel)
      end
    end

    local function network(x, y, w, h)
      card(x, y, w, 6, "Rednet")
      local m = peripheral.find("modem")
      kv(x + 1, y + 1, "Modem", m and "yes" or "no", w - 2)
      kv(x + 1, y + 2, "Wireless", (m and m.isWireless and m.isWireless()) and "yes" or "no", w - 2)
      kv(x + 1, y + 3, "Open", rednet.isOpen() and "yes" or "no", w - 2)
      kv(x + 1, y + 4, "My ID", "#" .. os.getComputerID(), w - 2)
      if h >= 10 then
        card(x, y + 7, w, h - 7, "Coming soon")
        put(x + 1, y + 8, "Add panels in os/apps/monitoring.lua", T.dim, T.panel)
      end
    end

    local panels = {
      { name = "Overview", draw = overview },
      { name = "Devices",  draw = devices },
      { name = "Network",  draw = network },
    }

    ------------------------------------------------ render (double buffered)
    local function draw()
      local w, h = term.getSize()
      fill(1, 1, w, h, T.bg)
      local tx = font.width("WARDEN") + 4
      font.draw(term, "WARDEN", 2, 2, T.accent)
      put(tx, 2, "SYSTEM MONITOR", T.text, T.bg)
      put(tx, 3, "WardenOS " .. WardenOS.version, T.dim, T.bg)
      local allok = true
      for _, c in ipairs(checks) do if not c.test() then allok = false end end
      put(tx, 5, allok and "* all systems nominal" or "! attention needed",
          allok and colors.green or T.warn, T.bg)

      zones = {}
      local x = 2
      for i, p in ipairs(panels) do
        local label = " " .. p.name .. " "
        if i == tab then put(x, 8, label, T.bg, T.accent) else put(x, 8, label, T.dim, T.panel) end
        zones[i] = { x, x + #label - 1 }
        x = x + #label + 1
      end
      panels[tab].draw(2, 10, w - 2, h - 10)
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
      elseif e == "mouse_click" and y == 8 then
        for i, z in ipairs(zones) do
          if x >= z[1] and x <= z[2] then tab = i dirty = true end
        end
      elseif e == "theme_changed" or e == "term_resize" then
        dirty = true
      end
      if dirty then render() end
    end
  end,
}
