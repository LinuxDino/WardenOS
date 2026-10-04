-- Drones: everything on the WardenOS network (turtles + computers), live turtle status and remote control
-- main(id): open the detail view of drone id. While it runs, the kernel sends "drones_open", id instead of
-- starting a second copy (os_launch "drones", id).
local PROTO = "wardenos"

return {
  name = "Drones", short = "Drone", icon = "(T)", color = colors.orange, order = 7,
  w = 46, h = 18, openEvent = "drones_open",
  main = function(arg)
    local T = WardenOS.theme
    local me = os.getComputerID()
    local devices, sel, scroll = {}, nil, 0
    local want = tonumber(arg)                    -- drone asked for (detail view as soon as it is known)
    sel = want
    -- start from the kernel's status cache, so the list (and an asked-for drone) shows at once
    if type(WardenOS.drones) == "table" then
      for id, st in pairs(WardenOS.drones) do
        if type(id) == "number" and type(st) == "table" then
          local d = { id = id }
          for k, v in pairs(st) do d[k] = v end
          d.id, d.seen = id, tonumber(st.seen) or os.clock()
          devices[id] = d
        end
      end
    end
    local zones, msg = {}, ""
    local seq, pending = 0, {}
    local calib                                   -- calibrate form: { input = "x y z facing" } while open
    local tv                                      -- templates view: { slug = shown template | nil, drone = preselected,
                                                  --                   scroll, del = asked to delete }
    local tplLib = fs.exists("/os/lib/templates.lua") and dofile("/os/lib/templates.lua")
    local FACES = { [0] = "N", "E", "S", "W" }
    local FACE_IN = { n = 0, north = 0, e = 1, east = 1, s = 2, south = 2, w = 3, west = 3,
                      ["0"] = 0, ["1"] = 1, ["2"] = 2, ["3"] = 3 }

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

    local claudeLib = fs.exists("/os/lib/claude.lua") and dofile("/os/lib/claude.lua")
    local function claudeDrones() return claudeLib and claudeLib.getDrones() or {} end

    -- who runs d's task now: "claude" | "player" | nil
    local function runBy(d)
      return d.state == "working" and type(d.by) == "table" and (d.by.who == "claude" and "claude" or "player") or nil
    end
    local function claudeAction(id)               -- what Claude told the drone (WardenOS.claude, claudetools)
      local A = type(WardenOS.claude) == "table" and WardenOS.claude or nil
      local e = A and type(A.drones) == "table" and A.drones[id]
      return type(e) == "table" and e.action or nil
    end
    local function stepText(p)
      if type(p) ~= "table" or not (tonumber(p.total) and p.total > 0) then return nil end
      return ("%d/%d"):format(tonumber(p.step) or 0, p.total)
    end

    local function sendTo(id, cmd, arg)
      if not rednet.isOpen() then msg = "No modem attached" return end
      seq = seq + 1
      pending[seq] = cmd
      rednet.send(id, { t = "cmd", to = id, seq = seq, cmd = cmd, arg = arg }, PROTO)
      msg = "> " .. cmd
    end
    local function send(cmd, arg) sendTo(sel, cmd, arg) end

    -- "x y z facing" -> { x, y, z, facing = 0-3 } | nil, why
    local function parseCalib(text)
      local x, y, z, f = text:match("^%s*(%-?%d+)[%s,]+(%-?%d+)[%s,]+(%-?%d+)[%s,]*(%w*)%s*$")
      if not x then return nil, "type: x y z facing, e.g. 120 64 -30 N" end
      local face = FACE_IN[f:lower()]
      if not face then return nil, "facing: N, E, S or W (F3 'Facing')" end
      return { x = tonumber(x), y = tonumber(y), z = tonumber(z), facing = face }
    end
    local function absText(d)                     -- "120 64 -30 N" when calibrated
      if not d.calibrated or type(d.abs) ~= "table" or not tonumber(d.abs.x) then return nil end
      return ("%d %d %d %s"):format(d.abs.x, d.abs.y, d.abs.z, FACES[tonumber(d.abs.f) or -1] or "?")
    end

    local function navText(d)                     -- "3 0 -5" blocks from home
      if not d.homeSet or type(d.nav) ~= "table" then return nil end
      return ("%s %s %s"):format(tostring(d.nav.x), tostring(d.nav.y), tostring(d.nav.z))
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
        local by = d.kind == "turtle" and runBy(d)
        local tx = 4 + 2 + math.min(#name, 20) + 1
        local used = tx - 2                       -- last column taken by the name / tag
        if by == "claude" then
          put(tx, y, "AI", T.bg, T.accent)        -- busy with a task Claude started
          used = tx + 1
        elseif by == "player" then
          put(tx, y, "task", T.warn)
          used = tx + 3
        elseif d.kind == "turtle" and claudeDrones()[d.id] then
          put(tx, y, "AI", T.dim)                 -- Claude may use it
          used = tx + 1
        end
        local info
        if by then
          local st = stepText(d.progress)
          info = (by == "claude" and claudeAction(d.id) or d.task or "?") .. (st and ("  " .. st) or "")
        elseif d.kind == "turtle" then
          info = (d.task or "?") .. "  fuel " .. fuelText(d)
        else
          info = "WardenOS " .. tostring(d.version or "?")
        end
        info = info:sub(1, math.max(0, math.min(w - 27, w - used - 2)))
        if #info > 0 then put(w - #info, y, info, by == "claude" and T.accent or T.dim) end
        if d.kind == "turtle" then zone(1, y, w, function() sel, msg = d.id, "" end) end
      end
      buttons(h, w, {
        { "all home", function()
          local n = 0
          for _, d in ipairs(all) do
            if d.kind == "turtle" and d.owner == me and online(d) then sendTo(d.id, "home") n = n + 1 end
          end
          msg = n > 0 and ("Calling " .. n .. " drone(s) home") or "No drones of yours online"
        end, fg = T.accent },
        { "update all", function()
          local n = 0
          for _, d in ipairs(all) do
            if d.kind == "turtle" and d.owner == me and online(d) then sendTo(d.id, "update") n = n + 1 end
          end
          msg = n > 0 and ("Updating " .. n .. " drone(s) from GitHub") or "No drones of yours online"
        end },
        { "templates", function() tv, msg = { scroll = 0 }, "" end },
      })
      if msg ~= "" then put(2, 2, msg:sub(1, w - 2), T.warn) end   -- row 2 is free: the list starts at row 3
    end

    ------------------------------------------------ detail view
    local function drawDetail(w, h)
      local d = devices[sel]
      term.setCursorPos(1, 1)
      term.setBackgroundColor(T.panel)
      term.clearLine()
      put(1, 1, " < ", T.accent, T.panel)
      zone(1, 1, 3, function() sel, msg, calib = nil, "", nil end)
      put(4, 1, ("#%d %s"):format(sel, d.label or "turtle"):sub(1, w - 13), T.text, T.panel)
      local on = online(d)
      put(w - 7, 1, on and " online" or "offline", on and T.good or T.bad, T.panel)

      -- row 2: who runs the task and how far it got, else the last task and who started it
      local by = runBy(d)
      local p = type(d.progress) == "table" and d.progress or {}
      if by then
        local parts = { (by == "claude" and "Claude: " or "Task: ") .. tostring(d.task or "?") }
        if p.phase then parts[#parts + 1] = tostring(p.phase) .. (stepText(p) and (" step " .. stepText(p)) or "") end
        if tonumber(d.taskTime) then parts[#parts + 1] = math.floor(d.taskTime) .. "s" end
        put(1, 2, (" " .. table.concat(parts, " - ") .. string.rep(" ", w)):sub(1, w), T.bg,
            by == "claude" and T.accent or T.warn)
      elseif type(d.lastTask) == "table" then
        local lb = type(d.lastTask.by) == "table" and (d.lastTask.by.who == "claude" and " - by Claude" or " - by you") or ""
        put(1, 2, ("Last: %s %s%s"):format(tostring(d.lastTask.name), d.lastTask.ok and "ok" or "failed", lb):sub(1, w),
            d.lastTask.ok and T.dim or T.bad)
      end
      local tline = tostring(d.task) .. " (" .. tostring(d.state) .. ")"
      local tg = by and type(p.target) == "table" and tonumber(p.target.x) and p.target
      if tg then
        tline = tostring(d.task) .. ("  to %d %d %d"):format(tg.x, tg.y, tg.z)   -- the banner shows the state
          .. (tonumber(p.replans) and p.replans > 0 and ("  replans " .. p.replans) or "")
      end
      put(1, 3, "Task  ", T.dim) put(7, 3, tline:sub(1, math.max(0, w - 7)))
      put(1, 4, "Fuel  ", T.dim)
      if type(d.fuel) == "number" and type(d.fuelLimit) == "number" and d.fuelLimit > 0 then
        local bw = math.max(4, math.min(16, w - 20))
        local frac = math.max(0, math.min(1, d.fuel / d.fuelLimit))
        local fill_ = math.floor(bw * frac + 0.5)
        put(7, 4, string.rep(" ", fill_), T.text, d.fuel < 100 and T.bad or T.good)
        put(7 + fill_, 4, string.rep(" ", bw - fill_), T.text, T.panel)
        put(8 + bw, 4, tostring(d.fuel), d.fuel < 100 and T.bad or T.text)
        if d.fuelItems then
          local cx_ = 9 + bw + #tostring(d.fuel)
          put(cx_, 4, ("coal: %s"):format(tostring(d.fuelItems)):sub(1, math.max(0, w - cx_ + 1)),
              d.fuelItems == 0 and T.warn or T.dim)
        end
      else
        put(7, 4, fuelText(d) .. (d.fuelItems and ("  coal: " .. tostring(d.fuelItems)) or ""))
      end
      local abs = absText(d)
      local where
      if abs then
        where = abs
      else
        where = (d.calibrated == false and "not calibrated  " or "")
          .. (type(d.pos) == "table" and ("GPS " .. table.concat(d.pos, " ")) or "no GPS")
      end
      local nt = navText(d)
      where = where .. (nt and ("  home: " .. nt) or "  no home set")
      put(1, 5, "Pos   ", T.dim) put(7, 5, where:sub(1, w - 7), abs and T.text or T.dim)
      put(1, 6, "Slots ", T.dim)
      local slots = ("%s/16 (slot %s)"):format(tostring(d.slots or "?"), tostring(d.selected or "?"))
      put(7, 6, slots)
      if d.safeDig ~= nil then
        put(9 + #slots, 6, (d.safeDig and "safe dig on" or "safe dig OFF"):sub(1, math.max(0, w - 8 - #slots)),
            d.safeDig and T.good or T.warn)
      end
      local owner = d.owner and (d.owner == me and "you" or ("#" .. d.owner)) or "nobody"
      put(1, 7, "Owner ", T.dim) put(7, 7, owner, d.owner == me and T.good or T.warn)

      local y = 9
      if d.owner ~= me then
        y = buttons(y, w, { { "Claim this drone", function() send("claim") end, bg = T.accent, fg = T.bg } })
      elseif calib then
        put(1, y, "Calibrate: where is the drone now?", T.text)
        put(1, y + 1, "F3: x y z and facing N/E/S/W", T.dim)
        local shown = calib.input
        if #shown > w - 3 then shown = shown:sub(-(w - 3)) end
        put(1, y + 2, ("> " .. shown .. string.rep(" ", w)):sub(1, w), T.text, T.panel)
        y = buttons(y + 3, w, {
          { "Send", function()
            local arg, why = parseCalib(calib.input)
            if not arg then msg = why return end
            send("calibrate", arg)
            calib = nil
          end, bg = T.accent, fg = T.bg },
          { "Use GPS", function() send("calibrate") calib = nil end },
          { "Cancel", function() calib, msg = nil, "" end, fg = T.bad },
        })
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
        local isClaude = claudeDrones()[sel]
        local items = {
          { "Go home", function() send("home") end, bg = T.accent, fg = T.bg },
          { "Set home here", function() send("sethome") end },
        }
        if claudeLib then
          items[#items + 1] = { isClaude and "Take from Claude" or "Give to Claude", function()
            claudeLib.setDrone(sel, not isClaude)
            msg = isClaude and "Claude no longer controls this drone" or "Claude can now use this drone"
          end, fg = isClaude and T.warn or T.accent }
        end
        y = buttons(y, w, items)
        y = buttons(y, w, {
          { "Calibrate", function()
            local pre = ""
            local a = type(d.abs) == "table" and d.calibrated and d.abs
            if a and tonumber(a.x) then pre = ("%d %d %d %s"):format(a.x, a.y, a.z, FACES[tonumber(a.f) or -1] or "")
            elseif type(d.pos) == "table" and #d.pos == 3 then pre = table.concat(d.pos, " ") .. " " end
            calib, msg = { input = pre }, ""
          end },
          { "Scan", function() send("scan") end },
          { "Templates", function() tv, msg = { scroll = 0, drone = sel }, "" end, fg = T.accent },
          { d.safeDig == false and "Safe dig: off" or "Safe dig: on", function() send("safedig", d.safeDig == false) end,
            fg = d.safeDig == false and T.warn or T.text },
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

    ------------------------------------------------ templates (saved drone programs)
    local function wrapText(text, width, maxLines)
      local out, line = {}, ""
      for word in tostring(text):gmatch("%S+") do
        if line == "" then line = word:sub(1, width)
        elseif #line + 1 + #word <= width then line = line .. " " .. word
        else out[#out + 1] = line line = word:sub(1, width) end
        if #out >= maxLines then return out end
      end
      if line ~= "" and #out < maxLines then out[#out + 1] = line end
      return out
    end

    local function drawTemplates(w, h)
      term.setCursorPos(1, 1)
      term.setBackgroundColor(T.panel)
      term.clearLine()
      put(1, 1, " < ", T.accent, T.panel)
      local t = tv.slug and tplLib and tplLib.get(tv.slug)
      if tv.slug and not t then tv.slug = nil end
      if not t then
        zone(1, 1, 3, function() tv, msg = nil, "" end)
        local all = tplLib and tplLib.list() or {}
        put(4, 1, ("Templates (%d)%s"):format(#all, tv.drone and (" for #" .. tv.drone) or ""):sub(1, w - 4), T.text, T.panel)
        if #all == 0 then
          put(2, 3, "No templates yet.", T.dim)
          for i, l in ipairs(wrapText("Ask Claude to save a drone program as a template; then run it here with one tap.", w - 2, 3)) do
            put(2, 4 + i, l, T.dim)
          end
        end
        local rows = h - 3
        if msg ~= "" then put(1, h, msg:sub(1, w), T.warn) end
        tv.scroll = math.max(0, math.min(tv.scroll or 0, #all - rows))
        for i = 1, rows do
          local e = all[tv.scroll + i]
          if not e then break end
          local y = 2 + i
          local tag = e.author == "claude" and "AI " or "   "
          put(1, y, tag, T.accent)
          put(4, y, e.name:sub(1, 20), T.text)
          if w > 26 then put(26, y, e.description:sub(1, w - 26), T.dim) end
          zone(1, y, w, function() tv.slug, tv.del = e.slug, nil end)
        end
        return
      end
      zone(1, 1, 3, function() tv.slug, tv.del = nil, nil end)
      put(4, 1, t.name:sub(1, w - 4), T.text, T.panel)
      put(1, 3, t.author == "claude" and "by Claude" or "by you", t.author == "claude" and T.accent or T.dim)
      local y = 4
      for _, l in ipairs(wrapText(t.description, w, 2)) do put(1, y, l, T.text) y = y + 1 end
      y = y + 1
      local lines = 0
      for line in (t.code .. "\n"):gmatch("(.-)\n") do
        if lines >= 4 or y > h - 4 then break end
        put(1, y, line:sub(1, w), T.dim)
        y, lines = y + 1, lines + 1
      end
      y = y + 1
      local items = {}
      local targets = {}
      if tv.drone then
        targets[1] = tv.drone
      else
        for _, d in ipairs(list()) do
          if d.kind == "turtle" and d.owner == me and online(d) then targets[#targets + 1] = d.id end
        end
      end
      for _, id in ipairs(targets) do
        items[#items + 1] = { "Run on #" .. id, function() sendTo(id, "run", { name = t.name:sub(1, 32), code = t.code }) end,
                              bg = T.accent, fg = T.bg }
      end
      items[#items + 1] = { tv.del and "Sure? delete" or "Delete", function()
        if tv.del then
          tplLib.delete(t.slug)
          tv.slug, tv.del, msg = nil, nil, "deleted " .. t.name
        else
          tv.del = true
        end
      end, fg = T.bad }
      y = buttons(math.min(y, h - 1), w, items)
      if #targets == 0 and y <= h then put(1, y, "No drone of yours online", T.dim) y = y + 1 end
      if msg ~= "" and y <= h then put(1, y, msg:sub(1, w), T.warn) end
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
      if tv then drawTemplates(w, h)
      elseif sel and devices[sel] then
        if sel == want then want = nil end
        drawDetail(w, h)
      else
        if sel ~= want then sel = nil end         -- an asked-for drone not heard yet: list until it answers
        drawList(w, h)
      end
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
        if tv then tv.scroll = (tv.scroll or 0) + a else scroll = scroll + a end
        render()
      elseif (e == "char" or e == "paste") and calib then
        calib.input = (calib.input .. a):sub(1, 40)
        render()
      elseif e == "key" and calib then
        if a == keys.backspace then calib.input = calib.input:sub(1, -2)
        elseif a == keys.enter then
          local arg, why = parseCalib(calib.input)
          if arg then send("calibrate", arg) calib = nil else msg = why end
        end
        render()
      elseif e == "drones_open" then              -- the kernel: show this drone (top bar activity tap)
        local id = tonumber(a)
        if id then sel, want, tv, calib, msg = id, id, nil, nil, "" end
        render()
      elseif e == "theme_changed" or e == "term_resize" or e == "peripheral" or e == "peripheral_detach" then
        render()
      end
    end
  end,
}
