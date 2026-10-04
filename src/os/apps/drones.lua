-- Drones: everything on the WardenOS network (turtles + computers), live turtle status and remote control
local PROTO = "wardenos"

return {
  name = "Drones", short = "Drone", icon = "(T)", color = colors.orange, order = 7,
  w = 46, h = 18,
  main = function()
    local T = WardenOS.theme
    local me = os.getComputerID()
    local devices, sel, scroll = {}, nil, 0
    local zones, msg = {}, ""
    local seq, pending = 0, {}

    local function online(d) return d and (os.clock() - d.seen) < 10 end

    local function ping()
      if rednet.isOpen() then rednet.broadcast({ t = "ping" }, PROTO) end
    end

    local function list()
      local out = {}
      for _, d in pairs(devices) do out[#out + 1] = d end
      table.sort(out, function(a, b)
        if (a.kind == "turtle") ~= (b.kind == "turtle") then return a.kind == "turtle" end
        return a.id < b.id
      end)
      return out
    end

    local function send(cmd, arg)
      if not rednet.isOpen() then msg = "No modem attached" return end
      seq = seq + 1
      pending[seq] = cmd
      rednet.send(sel, { t = "cmd", to = sel, seq = seq, cmd = cmd, arg = arg }, PROTO)
      msg = "> " .. cmd
    end

    ------------------------------------------------ drawing helpers
    local function put(x, y, s, fg, bg)
      term.setCursorPos(x, y)
      term.setTextColor(fg or T.text)
      term.setBackgroundColor(bg or T.bg)
      term.write(s)
    end
    local function zone(x, y, w, fn) zones[#zones + 1] = { x, x + w - 1, y, fn } end

    -- buttons flow left to right and wrap; returns the next free row
    local function buttons(y, w, items)
      local x = 1
      for _, b in ipairs(items) do
        local label = " " .. b[1] .. " "
        if x > 1 and x + #label - 1 > w then x, y = 1, y + 1 end
        put(x, y, label, b.fg or T.text, b.bg or T.panel)
        zone(x, y, #label, b[2])
        x = x + #label + 1
      end
      return y + 1
    end

    local function fuelText(d)
      if d.fuel == "unlimited" then return "unlimited" end
      if type(d.fuel) ~= "number" then return "?" end
      return tostring(d.fuel)
    end

    ------------------------------------------------ list view
    local function drawList(w, h)
      local all = list()
      local on = 0
      for _, d in ipairs(all) do if online(d) then on = on + 1 end end
      term.setCursorPos(1, 1)
      term.setBackgroundColor(T.panel)
      term.clearLine()
      put(2, 1, ("Network  %d online"):format(on), T.text, T.panel)
      put(w - 9, 1, " refresh ", T.accent, T.panel)
      zone(w - 9, 1, 9, function() ping() msg = "Searching..." end)

      if not rednet.isOpen() then
        put(2, 3, "No modem attached.", T.bad)
        put(2, 4, "Attach a (wireless or ender) modem", T.dim)
        put(2, 5, "to this computer.", T.dim)
      elseif #all == 0 then
        put(2, 3, "Nothing found yet.", T.dim)
        put(2, 5, "Install the drone agent on a turtle:", T.dim)
        put(2, 6, "pastebin get CeQfPV78 install", T.text)
        put(2, 7, "or tap 'install disk' below.", T.dim)
      end
      local rows = h - 3
      scroll = math.max(0, math.min(scroll, #all - rows))
      for i = 1, rows do
        local d = all[scroll + i]
        if not d then break end
        local y = 2 + i
        local on_ = online(d)
        put(1, y, on_ and " *" or " -", on_ and T.good or T.dim)
        local name = ("#%d %s"):format(d.id, d.label or (d.kind == "turtle" and "turtle" or "computer"))
        put(4, y, (d.kind == "turtle" and "T " or "C ") .. name:sub(1, 20), on_ and T.text or T.dim)
        local info
        if d.kind == "turtle" then
          info = (d.task or "?") .. "  fuel " .. fuelText(d)
        else
          info = "WardenOS " .. tostring(d.version or "?")
        end
        info = info:sub(1, math.max(0, w - 27))
        if #info > 0 then put(w - #info, y, info, T.dim) end
        if d.kind == "turtle" then zone(1, y, w, function() sel, msg = d.id, "" end) end
      end
      buttons(h, w, {
        { "install disk", function()
          local ok, res = pcall(dofile, "/os/drone/disk.lua")
          if ok and type(res) == "function" then
            local ok2, info = res(me)
            msg = info or (ok2 and "Disk ready" or "Failed")
          else
            msg = "disk maker missing: " .. tostring(res)
          end
        end },
      })
      if msg ~= "" then put(17, h, msg:sub(1, w - 17), T.warn) end
    end

    ------------------------------------------------ detail view
    local function drawDetail(w, h)
      local d = devices[sel]
      term.setCursorPos(1, 1)
      term.setBackgroundColor(T.panel)
      term.clearLine()
      put(1, 1, " < ", T.accent, T.panel)
      zone(1, 1, 3, function() sel, msg = nil, "" end)
      put(4, 1, ("#%d %s"):format(sel, d.label or "turtle"):sub(1, w - 13), T.text, T.panel)
      local on = online(d)
      put(w - 7, 1, on and " online" or "offline", on and T.good or T.bad, T.panel)

      put(1, 3, "Task  ", T.dim) put(7, 3, (tostring(d.task) .. " (" .. tostring(d.state) .. ")"):sub(1, w - 7))
      put(1, 4, "Fuel  ", T.dim)
      if type(d.fuel) == "number" and type(d.fuelLimit) == "number" and d.fuelLimit > 0 then
        local bw = math.max(4, math.min(16, w - 20))
        local frac = math.max(0, math.min(1, d.fuel / d.fuelLimit))
        local fill_ = math.floor(bw * frac + 0.5)
        put(7, 4, string.rep(" ", fill_), T.text, d.fuel < 100 and T.bad or T.good)
        put(7 + fill_, 4, string.rep(" ", bw - fill_), T.text, T.panel)
        put(8 + bw, 4, tostring(d.fuel), d.fuel < 100 and T.bad or T.text)
      else
        put(7, 4, fuelText(d))
      end
      put(1, 5, "Pos   ", T.dim) put(7, 5, type(d.pos) == "table" and table.concat(d.pos, " ") or "no GPS")
      put(1, 6, "Slots ", T.dim)
      put(7, 6, ("%s/16 (slot %s)"):format(tostring(d.slots or "?"), tostring(d.selected or "?")))
      local owner = d.owner and (d.owner == me and "you" or ("#" .. d.owner)) or "nobody"
      put(1, 7, "Owner ", T.dim) put(7, 7, owner, d.owner == me and T.good or T.warn)

      local y = 9
      if d.owner ~= me then
        y = buttons(y, w, { { "Claim this drone", function() send("claim") end, bg = T.accent, fg = T.bg } })
      else
        y = buttons(y, w, {
          { "Fwd", function() send("forward") end }, { "Back", function() send("back") end },
          { "Left", function() send("turnLeft") end }, { "Right", function() send("turnRight") end },
          { "Up", function() send("up") end }, { "Down", function() send("down") end },
        })
        y = buttons(y, w, {
          { "Dig", function() send("dig") end }, { "Dig Up", function() send("digUp") end },
          { "Dig Dn", function() send("digDown") end }, { "Place", function() send("place") end },
          { "Refuel", function() send("refuel") end },
        })
        y = buttons(y, w, {
          { "Stop", function() send("stop") end, fg = T.bad }, { "Locate", function() send("locate") end },
          { "Update", function() send("update") end }, { "Release", function() send("release") end, fg = T.dim },
        })
      end
      if msg ~= "" and y <= h then put(1, y, msg:sub(1, w), T.warn) y = y + 1 end
      y = y + 1
      if y <= h then put(1, y, "Activity", T.dim) end
      for i, line in ipairs(type(d.log) == "table" and d.log or {}) do
        if y + i > h then break end
        put(1, y + i, tostring(line):sub(1, w), T.text)
      end
    end

    ------------------------------------------------ render + loop
    local function render()
      local parent = term.current()
      local w, h = parent.getSize()
      local buf = window.create(parent, 1, 1, w, h, false)
      term.redirect(buf)
      zones = {}
      term.setBackgroundColor(T.bg)
      term.clear()
      if sel and devices[sel] then drawDetail(w, h) else sel = nil drawList(w, h) end
      term.redirect(parent)
      buf.setVisible(true)
    end

    ping()
    local timer = os.startTimer(1)
    local tick = 0
    render()
    while true do
      local e, a, b, c = os.pullEvent()
      if e == "rednet_message" and c == PROTO and type(b) == "table" then
        if b.t == "status" and a ~= me then
          local d = devices[a] or { id = a }
          for k, v in pairs(b) do d[k] = v end
          d.id, d.seen = a, os.clock()
          devices[a] = d
          render()
        elseif b.t == "ack" and pending[b.seq] then
          msg = b.cmd .. (b.ok and " ok" or " failed") .. (b.info and (": " .. b.info) or "")
          pending[b.seq] = nil
          render()
        end
      elseif e == "timer" and a == timer then
        timer = os.startTimer(1)
        tick = tick + 1
        if tick % 5 == 0 then ping() end
        render()
      elseif e == "mouse_click" then
        for _, z in ipairs(zones) do
          if c == z[3] and b >= z[1] and b <= z[2] then z[4]() break end   -- button, x, y
        end
        render()
      elseif e == "mouse_scroll" then
        scroll = scroll + a
        render()
      elseif e == "theme_changed" or e == "term_resize" or e == "peripheral" or e == "peripheral_detach" then
        render()
      end
    end
  end,
}
