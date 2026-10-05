-- Settings: system + updates, display, theme, dock and boot menu
local Settings = dofile("/os/lib/settings.lua")

return {
  name = "Settings", short = "Set", icon = "{o}", color = colors.lightGray, order = 8,
  w = 44, h = 17,
  art = { { "-O--", "8088", "7777" }, { "--O-", "8808", "7777" } },   -- 4x2 icon (blit; bg 7 = panel)
  main = function()
    local T = WardenOS.theme
    local TABS = { "System", "Display", "Theme", "Dock", "Boot" }
    local tab = 1
    local s = Settings.load()
    local boot = Settings.loadBoot()
    local zones = {}                              -- { x1, x2, y, fn }
    local upd = { state = "idle" }                -- idle | checking | latest | available | error
    local applied = { display = s.display, scale = s.scale }
    local render                                  -- defined below

    local function put(x, y, str, fg, bg)
      term.setCursorPos(x, y)
      term.setTextColor(fg or T.text)
      term.setBackgroundColor(bg or T.bg)
      term.write(str)
    end
    local function zone(x, y, w, fn) zones[#zones + 1] = { x, x + w - 1, y, fn } end
    local function button(x, y, label, fn, color)
      label = " " .. label .. " "
      put(x, y, label, T.bg, color or T.accent)
      zone(x, y, #label, fn)
      return x + #label + 1
    end
    -- one selectable row: "(*) label"
    local function option(y, label, on, fn, w)
      put(2, y, on and "(*)" or "( )", on and T.accent or T.dim)
      put(6, y, label:sub(1, w - 6), on and T.text or T.dim)
      zone(1, y, w, fn)
    end
    local function save()
      Settings.save(s)
      os.queueEvent("os_settings")
    end

    ------------------------------------------------ updates
    local function check()
      upd = { state = "checking" }
      render()                                    -- show "Checking..." while the request runs
      local url = ("https://raw.githubusercontent.com/%s/%s/manifest.lua?t=%d")
        :format(WardenOS.repo, WardenOS.branch, os.epoch("utc"))
      local h, err = http and http.get(url)
      if not h then
        upd = { state = "error", msg = tostring(err or "http API disabled") }
        return
      end
      local src = h.readAll()
      h.close()
      local fn = load(src, "=manifest", "t", {})
      local ok, m = pcall(fn or error)
      if not ok or type(m) ~= "table" or not m.version then
        upd = { state = "error", msg = "bad manifest" }
        return
      end
      upd = { state = Settings.newer(m.version, WardenOS.version) and "available" or "latest", version = m.version }
    end

    ------------------------------------------------ pages
    local pages = {}

    function pages.System(y, w)
      put(2, y, "WardenOS " .. WardenOS.version, T.accent)
      put(2, y + 1, ("Computer #%d  %s"):format(os.getComputerID(), os.getComputerLabel() or ""):sub(1, w - 2), T.dim)
      put(2, y + 2, ("User: %s   Display: %s"):format(WardenOS.user or "-", WardenOS.display or "-"):sub(1, w - 2), T.dim)
      y = y + 4
      put(2, y, "Updates", T.text)
      y = y + 1
      if upd.state == "idle" then
        put(2, y, "Get the newest WardenOS from GitHub.", T.dim)
        button(2, y + 2, "Check for updates", function() check() end)
      elseif upd.state == "checking" then
        put(2, y, "Checking...", T.dim)
      elseif upd.state == "error" then
        put(2, y, ("Failed: " .. upd.msg):sub(1, w - 2), T.bad)
        button(2, y + 2, "Try again", function() check() end)
      elseif upd.state == "available" then
        put(2, y, ("Version %s is available."):format(upd.version):sub(1, w - 2), T.good)
        put(2, y + 1, "Accounts, settings and files are kept.", T.dim)
        button(2, y + 3, "Update now", function() os.queueEvent("os_update") end)
      else
        put(2, y, ("Up to date (%s)."):format(upd.version):sub(1, w - 2), T.good)
        local nx = button(2, y + 2, "Check again", function() check() end)
        button(nx, y + 2, "Reinstall", function() os.queueEvent("os_update") end, T.dim)
      end
    end

    function pages.Display(y, w)
      put(2, y, "Where the desktop is shown", T.text)
      local names = {
        auto = "Auto: monitor if attached",
        monitor = "Monitor (full size)",
        mirror = "Mirror on computer + monitor",
        computer = "Computer screen only",
      }
      for i, m in ipairs(Settings.DISPLAYS) do
        option(y + i, names[m], s.display == m, function() s.display = m save() end, w)
      end
      y = y + #Settings.DISPLAYS + 2
      put(2, y, "Monitor text size", T.text)
      local x = 2
      for _, v in ipairs(Settings.SCALES) do
        local label = tostring(v) .. "x"
        local on = s.scale == v
        put(x, y + 1, " " .. label .. " ", on and T.bg or T.text, on and T.accent or T.panel)
        zone(x, y + 1, #label + 2, function() s.scale = v save() end)
        x = x + #label + 3
      end
      put(2, y + 2, "Smaller = more space.", T.dim)
      if s.display ~= applied.display or s.scale ~= applied.scale then
        button(2, y + 4, "Restart to apply", function() os.reboot() end, T.warn)
      end
    end

    function pages.Theme(y, w)
      put(2, y, "Color theme", T.text)
      option(y + 1, "Dark", s.theme == "dark", function() s.theme = "dark" save() end, w)
      option(y + 2, "Light", s.theme == "light", function() s.theme = "light" save() end, w)
    end

    function pages.Dock(y, w, h)
      put(2, y, "Apps pinned to the dock", T.text)
      local row = y + 1
      for _, id in ipairs(WardenOS.apps or {}) do
        if row > h - 1 then break end
        local pinned, at = false, nil
        for i, d in ipairs(s.dock) do if d == id then pinned, at = true, i end end
        local label = (WardenOS.appNames or {})[id] or id
        put(2, row, pinned and "[x]" or "[ ]", pinned and T.accent or T.dim)
        put(6, row, label:sub(1, w - 6), pinned and T.text or T.dim)
        zone(1, row, w, function()
          if pinned then table.remove(s.dock, at) else s.dock[#s.dock + 1] = id end
          save()
        end)
        row = row + 1
      end
    end

    function pages.Boot(y, w)
      local function saveBoot() Settings.saveBoot(boot) end
      put(2, y, "Start by default", T.text)
      option(y + 1, "WardenOS", boot.default == "wardenos", function() boot.default = "wardenos" saveBoot() end, w)
      option(y + 2, "CraftOS", boot.default == "craftos", function() boot.default = "craftos" saveBoot() end, w)
      put(2, y + 4, "Boot menu wait", T.text)
      local x = 2
      for _, v in ipairs({ 1, 2, 5, 10 }) do
        local label = v .. "s"
        local on = boot.timeout == v
        put(x, y + 5, " " .. label .. " ", on and T.bg or T.text, on and T.accent or T.panel)
        zone(x, y + 5, #label + 2, function() boot.timeout = v saveBoot() end)
        x = x + #label + 3
      end
      put(2, y + 6, "Time before the default starts.", T.dim)
    end

    ------------------------------------------------ render
    local function draw()
      local w, h = term.getSize()
      zones = {}
      term.setBackgroundColor(T.bg)
      term.clear()
      term.setCursorPos(1, 1)
      term.setBackgroundColor(T.panel)
      term.clearLine()
      local x = 1
      for i, name in ipairs(TABS) do
        local label = " " .. name .. " "
        if x + #label - 1 > w then break end
        put(x, 1, label, i == tab and T.bg or T.dim, i == tab and T.accent or T.panel)
        zone(x, 1, #label, function() tab = i end)
        x = x + #label
      end
      pages[TABS[tab]](3, w, h)
    end

    function render()
      local parent = term.current()
      local w, h = parent.getSize()
      local buf = window.create(parent, 1, 1, w, h, false)
      term.redirect(buf)
      draw()
      term.redirect(parent)
      buf.setVisible(true)
    end

    render()
    while true do
      local e, a, x, y = os.pullEvent()
      if e == "mouse_click" then
        for _, z in ipairs(zones) do
          if y == z[3] and x >= z[1] and x <= z[2] then z[4]() break end
        end
        render()
      elseif e == "theme_changed" or e == "term_resize" then
        render()
      end
    end
  end,
}
