-- Map: top-down view of the world map the drones build (/os/lib/map.lua), drone markers, protected areas
local PROTO = "wardenos"

return {
  name = "Map", short = "Map", icon = "[#]", color = colors.lime, order = 7,
  w = 46, h = 18,
  main = function()
    local T = WardenOS.theme
    local map = dofile("/os/lib/map.lua")
    local me = os.getComputerID()
    local zones, msg = {}, ""
    local cx, cz = 0, 0                           -- block at the center of the view
    local layer                                   -- nil = surface view, else the y shown
    local zoom = 1                                -- blocks per character: 1, 2, 4, 8, 16
    local view = "map"                            -- map | areas
    local tapped                                  -- { x, z, x2, z2, y, name } the last tapped cell (block range)
    local prot                                    -- protect flow: { step = 1 | 2 | "name", a = cell, b = cell }
                                                  -- (cell = { x, z, x2, z2 }: the block range of a tapped cell)
    local input = ""
    local target = 0                              -- index into the center targets
    local delAsk                                  -- area index waiting for a second "sure?" tap
    local areaScroll = 0
    local heard = {}                              -- statuses heard by this app (when there is no kernel cache)
    local grid = { x = 1, y = 2, w = 1, h = 1, left = 0, top = 0 }

    local function setZoom(z)                     -- the block at the center stays at the center
      z = map.zoom(z)
      if z ~= zoom then zoom, msg = z, "zoom: " .. map.scale(z) end
    end
    local function zoomIn() setZoom(math.max(1, zoom / 2)) end
    local function zoomOut() setZoom(math.min(16, zoom * 2)) end
    local function steps()                        -- pan steps in blocks: a part of the screen, scaled by zoom
      return math.max(4, math.floor(grid.w / 4)) * zoom, math.max(2, math.floor(grid.h / 3)) * zoom
    end

    ------------------------------------------------ drones
    local function drones()
      local c = WardenOS.drones
      if type(c) == "table" and next(c) ~= nil then return c end
      return heard
    end
    local function targets()                      -- places to center on: drones, then their homes
      local out = {}
      local ids = {}
      for id in pairs(drones()) do ids[#ids + 1] = id end
      table.sort(ids)
      for _, id in ipairs(ids) do
        local d = drones()[id]
        if d.calibrated and type(d.abs) == "table" and tonumber(d.abs.x) then
          out[#out + 1] = { "drone #" .. id, tonumber(d.abs.x), tonumber(d.abs.z) }
        end
      end
      for _, id in ipairs(ids) do
        local o = drones()[id].origin
        if type(o) == "table" and tonumber(o.x) and tonumber(o.z) then
          out[#out + 1] = { "home of #" .. id, tonumber(o.x), tonumber(o.z) }
        end
      end
      return out
    end
    local function marks()
      local m = {}
      for _, d in pairs(drones()) do
        if type(d.origin) == "table" and tonumber(d.origin.x) then
          m[math.floor(d.origin.x) .. "," .. math.floor(d.origin.z)] = "H"
        end
      end
      for _, d in pairs(drones()) do
        if d.calibrated and type(d.abs) == "table" and tonumber(d.abs.x) then
          m[math.floor(d.abs.x) .. "," .. math.floor(d.abs.z)] = "D"
        end
      end
      return m
    end

    -- start: on a drone, else on the chunk with the most blocks
    do
      local t = targets()[1]
      if t then
        cx, cz = math.floor(t[2]), math.floor(t[3])
      else
        local best, n = nil, 0
        for k, c in pairs(map.chunks()) do if c > n then best, n = k, c end end
        local a, b = best and best:match("^(%-?%d+)_(%-?%d+)$")
        if a then cx, cz = tonumber(a) * 16 + 8, tonumber(b) * 16 + 8 end
      end
    end

    ------------------------------------------------ drawing helpers
    local HEX = {}
    for i = 0, 15 do HEX[2 ^ i] = ("0123456789abcdef"):sub(i + 1, i + 1) end
    local function put(x, y, s, fg, bg)
      term.setCursorPos(x, y)
      term.setTextColor(fg or T.text)
      term.setBackgroundColor(bg or T.bg)
      term.write(s)
    end
    local function zone(x, y, w, fn) zones[#zones + 1] = { x, x + w - 1, y, fn } end
    local function button(x, y, label, fn, fg, bg)
      label = " " .. label .. " "
      put(x, y, label, fg or T.text, bg or T.panel)
      zone(x, y, #label, fn)
      return x + #label + 1
    end
    -- buttons flow left to right on one row, as many as fit
    local function buttons(y, w, items)
      local x = 1
      for _, b in ipairs(items) do
        if x + #b[1] + 1 > w then break end
        x = button(x, y, b[1], b[2], b.fg, b.bg)
      end
    end

    local function palette()                      -- map char -> text color (the theme can change)
      return {
        ["#"] = T.dim, [":"] = colors.brown, [","] = colors.lime, ["~"] = colors.blue, ["^"] = colors.orange,
        ["T"] = colors.green, ["o"] = colors.magenta, ["="] = T.warn, ["."] = T.panel, ["?"] = T.bg,
      }
    end

    -- protect flow, last step: input is "name" or "name y1 y2"
    local function saveArea()
      local name, y1, y2 = input:match("^%s*(.-)%s+(%-?%d+)%s+(%-?%d+)%s*$")
      if not name then name = input:match("^%s*(.-)%s*$") end
      local a, b = prot.a, prot.b                 -- the two corner cells: the box covers both completely
      local i, err = map.protect({ name = name ~= "" and name or "area",
                                   x1 = math.min(a.x, b.x), z1 = math.min(a.z, b.z),
                                   x2 = math.max(a.x2, b.x2), z2 = math.max(a.z2, b.z2),
                                   y1 = tonumber(y1), y2 = tonumber(y2) })
      msg = i and ("protected: " .. map.protected().boxes[i].name) or ("not saved: " .. tostring(err))
      prot, input = nil, ""
    end

    ------------------------------------------------ map view
    local function drawMap(w, h)
      term.setCursorPos(1, 1)
      term.setBackgroundColor(T.panel)
      term.clearLine()
      put(2, 1, "Map", T.accent, T.panel)
      local mode = layer and ("y=" .. layer) or "surface"
      local right = w - (layer and 24 or 15) + 1    -- [" y- " " y+ "] " - " " + " " Surf " | " Layer "
      put(6, 1, (mode .. " x" .. zoom .. " " .. cx .. "," .. cz):sub(1, math.max(0, right - 7)), T.dim, T.panel)
      local x = right
      if layer then
        x = button(x, 1, "y-", function() layer = math.max(map.YMIN, layer - 1) end, T.text, T.panel)
        x = button(x, 1, "y+", function() layer = math.min(map.YMAX, layer + 1) end, T.text, T.panel)
      end
      x = button(x, 1, "-", zoomOut, T.text, T.panel)
      x = button(x, 1, "+", zoomIn, T.text, T.panel)
      button(x, 1, layer and "Surf" or "Layer", function()
        if layer then layer = nil
        else layer = (tapped and tapped.y) or map.surface(cx, cz) or 64 end
      end, T.accent, T.panel)

      -- the grid: one cell per zoom x zoom blocks, north at the top; cells sit on multiples of zoom
      local gw, gh = w, math.max(1, h - 4)
      local left = (math.floor(cx / zoom) - math.floor(gw / 2)) * zoom
      local top = (math.floor(cz / zoom) - math.floor(gh / 2)) * zoom
      grid = { x = 1, y = 2, w = gw, h = gh, left = left, top = top, zoom = zoom }
      -- map.grid caches its result until the map or the protected areas change: redraws and timer ticks
      -- with the same view reuse it
      local g = map.grid(left, top, left + gw * zoom - 1, top + gh * zoom - 1, layer, zoom)
      local mk = marks()
      local mcell = {}                            -- marks by cell (a drone wins over its home)
      for k, m in pairs(mk) do
        local mx, mz = k:match("^(%-?%d+),(%-?%d+)$")
        local c, r = math.floor((tonumber(mx) - left) / zoom), math.floor((tonumber(mz) - top) / zoom)
        if c >= 0 and c < gw and r >= 0 and r < gh then
          local i = r * gw + c + 1
          if mcell[i] ~= "D" then mcell[i] = m end
        end
      end
      local function inCell(p, bx, bz)            -- does block range p overlap the cell at bx, bz?
        return p and p.x <= bx + zoom - 1 and (p.x2 or p.x) >= bx and p.z <= bz + zoom - 1 and (p.z2 or p.z) >= bz
      end
      local COLOR = palette()
      local fgOf, bgOf = HEX[T.text] or "0", HEX[T.bg] or "f"
      for r = 1, gh do
        local z = top + (r - 1) * zoom
        local text, fg, bg = {}, {}, {}
        for c = 1, gw do
          local bx = left + (c - 1) * zoom
          local i = (r - 1) * g.w + c
          local ch = g.ch[i] or "?"
          local f, b = COLOR[ch] or T.text, T.bg
          local m = mcell[(r - 1) * gw + c]
          if m then
            ch, f, b = m, T.bg, m == "D" and T.accent or T.warn
          else
            if g.prot[i] then b = colors.purple end
            if ch == "?" then ch = " " end
          end
          if prot and inCell(prot.a, bx, z) then b = T.accent end
          if tapped and inCell(tapped, bx, z) and not m then b = T.accent f = T.bg end
          text[c], fg[c], bg[c] = ch, HEX[f] or fgOf, HEX[b] or bgOf
        end
        term.setCursorPos(1, 1 + r)
        term.blit(table.concat(text), table.concat(fg), table.concat(bg))
      end
      local function short(n) return n and (n:match("^minecraft:(.*)$") or n) or "unknown" end
      local function tapAt(px, py)                -- screen cell -> its block range
        local c, r = px - 1, py - 2
        local bx, bz = left + c * zoom, top + r * zoom
        local cell = { x = bx, z = bz, x2 = bx + zoom - 1, z2 = bz + zoom - 1 }
        if prot and (prot.step == 1 or prot.step == 2) then
          local where = zoom == 1 and ("%d %d"):format(bx, bz)
            or ("%d..%d %d..%d"):format(cell.x, cell.x2, cell.z, cell.z2)
          if prot.step == 1 then
            prot.a, prot.step = cell, 2
            msg = "corner 1: " .. where .. " - tap the other corner"
          else
            prot.b, prot.step, input = cell, "name", ""
            msg = ""
          end
          return
        end
        local i = r * g.w + c + 1
        local ch, name, y = g.ch[i] or "?", g.name[i], g.by[i]
        cell.y, cell.name = y, name
        tapped = cell
        local who = ""
        for id, s in pairs(drones()) do
          local dx, dz = math.floor(tonumber(s.calibrated and type(s.abs) == "table" and s.abs.x) or 1e9),
                         math.floor(tonumber(s.calibrated and type(s.abs) == "table" and s.abs.z) or 1e9)
          if dx >= cell.x and dx <= cell.x2 and dz >= cell.z and dz <= cell.z2 then who = " drone #" .. id end
        end
        local p
        for _, b in ipairs(map.protected().boxes) do
          if b.x1 <= cell.x2 and b.x2 >= cell.x and b.z1 <= cell.z2 and b.z2 >= cell.z
             and (layer == nil or (layer >= b.y1 and layer <= b.y2)) then p = b break end
        end
        msg = (p and ("protected: " .. p.name) or "") .. who
        if ch == "?" and who == "" then msg = (msg ~= "" and msg .. " " or "") .. "(not seen yet)" end
      end
      for r = 1, gh do
        zones[#zones + 1] = { 1, gw, 1 + r, function(px, py) tapAt(px, py) end }
      end

      -- info row, buttons, status row
      local iy = h - 2
      if prot and prot.step == "name" then
        local s = "Name (y1 y2 optional): " .. input
        if #s > w - 1 then s = s:sub(-(w - 1)) end
        put(1, iy, s, T.text, T.panel)
        put(#s + 1, iy, string.rep(" ", math.max(0, w - #s)), T.text, T.panel)
      elseif tapped and tapped.x2 > tapped.x then  -- a cell of several blocks: its range + the block shown
        local s = ("x%d..%d z%d..%d y%s %s"):format(tapped.x, tapped.x2, tapped.z, tapped.z2,
                                                     tapped.y and tostring(tapped.y) or "?", short(tapped.name))
        put(1, iy, s:sub(1, w), T.text)
      elseif tapped then
        local s = ("%d %s %d  %s"):format(tapped.x, tapped.y and tostring(tapped.y) or "?", tapped.z,
                                           tapped.name or "unknown")
        put(1, iy, s:sub(1, w), T.text)
      else
        put(1, iy, ("%d blocks known%s"):format(map.count(), map.full and " - map FULL" or ""):sub(1, w), T.dim)
      end
      local step, zstep = steps()
      if prot then
        local items = {}
        if prot.step == "name" then items[1] = { "Save", saveArea, fg = T.bg, bg = T.accent } end
        items[#items + 1] = { "Cancel", function() prot, input, msg = nil, "", "" end, fg = T.bad }
        buttons(h - 1, w, items)
        if prot and prot.step ~= "name" then
          msg = prot.step == 1 and "Tap the first corner of the area" or msg
        end
      else
        buttons(h - 1, w, {
          { "<", function() cx = cx - step end }, { "^", function() cz = cz - zstep end },
          { "v", function() cz = cz + zstep end }, { ">", function() cx = cx + step end },
          { "Protect", function() prot, tapped, msg = { step = 1 }, nil, "Tap the first corner of the area" end,
            fg = T.accent },
          { "Center", function()
            local ts = targets()
            if #ts == 0 then msg = "No calibrated drone or home known" return end
            target = target % #ts + 1
            local t = ts[target]
            cx, cz, msg = math.floor(t[2]), math.floor(t[3]), "centered on " .. t[1]
          end },
          { "Areas", function() view, delAsk, areaScroll = "areas", nil, 0 end },
        })
      end
      local status = msg ~= "" and msg or "#stone :dirt ~water ^lava Ttree oore =built"
      put(1, h, status:sub(1, w), msg ~= "" and T.warn or T.dim)
    end

    ------------------------------------------------ protected areas
    local function drawAreas(w, h)
      term.setCursorPos(1, 1)
      term.setBackgroundColor(T.panel)
      term.clearLine()
      put(1, 1, " < ", T.accent, T.panel)
      zone(1, 1, 3, function() view, delAsk = "map", nil end)
      local p = map.protected()
      put(5, 1, ("Protected areas (%d)"):format(#p.boxes):sub(1, w - 5), T.text, T.panel)
      if #p.boxes == 0 then
        put(2, 3, "No protected areas yet.", T.dim)
        put(2, 5, "Drones never dig inside them. Tap", T.dim)
        put(2, 6, "Protect on the map and two corners.", T.dim)
      end
      local rows = math.floor((h - 3) / 2)
      areaScroll = math.max(0, math.min(areaScroll, #p.boxes - rows))
      for i = 1, rows do
        local n = areaScroll + i
        local b = p.boxes[n]
        if not b then break end
        local y = 2 + (i - 1) * 2
        put(1, y, ("%d %s"):format(n, b.name):sub(1, w - 10), T.text)
        local label = delAsk == n and "sure?" or "delete"
        local bx = w - #label - 1
        button(bx, y, label, function()
          if delAsk == n then
            map.unprotect(n)
            delAsk, msg = nil, "removed " .. b.name
          else
            delAsk = n
          end
        end, T.bg, T.bad)
        put(2, y + 1, ("x %d..%d  y %d..%d  z %d..%d"):format(b.x1, b.x2, b.y1, b.y2, b.z1, b.z2):sub(1, w - 1), T.dim)
        zone(1, y + 1, w, function() view, cx, cz = "map", math.floor((b.x1 + b.x2) / 2), math.floor((b.z1 + b.z2) / 2) end)
      end
      put(1, h, ((msg ~= "" and msg) or "Only you can remove protection (rev " .. p.rev .. ")"):sub(1, w), T.dim)
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
      if view == "areas" then drawAreas(w, h) else drawMap(w, h) end
      term.redirect(parent)
      buf.setVisible(true)
      if prot and prot.step == "name" then
        parent.setCursorPos(math.min(w, #("Name (y1 y2 optional): " .. input) + 1), h - 2)
        parent.setTextColor(T.text)
        parent.setCursorBlink(true)
      else
        parent.setCursorBlink(false)
      end
    end

    if rednet.isOpen() and not (type(WardenOS.drones) == "table" and next(WardenOS.drones)) then
      rednet.broadcast({ t = "ping" }, PROTO)
    end
    local timer = os.startTimer(2)
    render()
    while true do
      local e, a, b, c = os.pullEvent()
      if e == "rednet_message" and c == PROTO and type(b) == "table" and b.t == "status" and b.kind == "turtle"
         and a ~= me then
        local d = {}
        for k, v in pairs(b) do d[k] = v end
        d.seen = os.clock()
        heard[a] = d
      elseif e == "timer" and a == timer then
        timer = os.startTimer(2)
        render()
      elseif e == "mouse_click" then
        for _, z in ipairs(zones) do
          if c == z[3] and b >= z[1] and b <= z[2] then z[4](b, c) break end   -- button, x, y
        end
        render()
      elseif e == "mouse_scroll" then
        if view == "areas" then areaScroll = areaScroll + a
        else cz = cz + a * select(2, steps()) end
        render()
      elseif e == "char" or e == "paste" then
        if prot and prot.step == "name" then input = (input .. a):sub(1, 40) render()
        elseif e == "char" and view == "map" and (a == "+" or a == "=" or a == "-") then
          if a == "-" then zoomOut() else zoomIn() end
          render()
        end
      elseif e == "key" then
        if prot and prot.step == "name" then
          if a == keys.backspace then input = input:sub(1, -2)
          elseif a == keys.enter then saveArea() end
        elseif view == "map" then
          local step, zstep = steps()
          if a == keys.left then cx = cx - step
          elseif a == keys.right then cx = cx + step
          elseif a == keys.up then cz = cz - zstep
          elseif a == keys.down then cz = cz + zstep
          elseif a == keys.pageUp then zoomIn()
          elseif a == keys.pageDown then zoomOut() end
        end
        render()
      elseif e == "theme_changed" or e == "term_resize" then
        render()
      end
    end
  end,
}
