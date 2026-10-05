-- Peripheral Inspector: every attached (or networked) peripheral and its methods.
-- Made for modded setups: shows what a block from any mod exposes to Lua.
return {
  name = "Peripheral Inspector", short = "Peri", icon = "<>", color = colors.magenta, order = 5,
  w = 44, h = 18,
  art = { { "-[]-", "8008", "7227" }, { "    ", "0000", "7227" } },   -- 4x2 icon (blit; bg 7 = panel)
  main = function()
    local T = WardenOS.theme
    local list, sel, methods = {}, nil, {}
    local scroll = 0

    local function load()
      list = {}
      for _, n in ipairs(peripheral.getNames()) do
        local types = { peripheral.getType(n) }
        list[#list + 1] = { name = n, types = types }
      end
      table.sort(list, function(a, b) return a.name < b.name end)
    end

    local function open(p)
      sel, scroll = p, 0
      methods = peripheral.getMethods(p.name) or {}
      table.sort(methods)
    end

    local function rows()
      if sel then return methods end
      return list
    end

    local function put(x, y, s, fg, bg)
      term.setCursorPos(x, y)
      term.setTextColor(fg)
      term.setBackgroundColor(bg)
      term.write(s)
    end

    local function draw()
      local w, h = term.getSize()
      term.setBackgroundColor(T.bg)
      term.clear()
      term.setCursorPos(1, 1)
      term.setBackgroundColor(T.panel)
      term.clearLine()
      if sel then
        put(1, 1, " < ", T.accent, T.panel)
        put(4, 1, (sel.name .. "  " .. table.concat(sel.types, ", ")):sub(1, w - 4), T.text, T.panel)
      else
        put(2, 1, (#list .. " peripheral(s)"):sub(1, w - 2), T.dim, T.panel)
      end
      local r = rows()
      for row = 2, h - 1 do
        local item = r[scroll + row - 1]
        if item then
          if sel then
            put(2, row, (item .. "()"):sub(1, w - 2), T.text, T.bg)
          else
            put(2, row, item.name:sub(1, w - 2), T.text, T.bg)
            local t = table.concat(item.types, ", ")
            local tx = math.max(math.floor(w / 2), #item.name + 4)
            if tx < w then put(tx, row, t:sub(1, w - tx), T.accent, T.bg) end
          end
        end
      end
      if #r == 0 then
        put(2, 2, sel and "no methods" or "nothing attached", T.dim, T.bg)
      end
      term.setCursorPos(1, h)
      term.setBackgroundColor(T.panel)
      term.clearLine()
      put(1, h, sel and " back   ^    v" or " refresh   ^    v", T.dim, T.panel)
      if sel then
        local c = #methods .. " methods"
        if #c < w - 16 then put(w - #c, h, c, T.dim, T.panel) end
      end
    end

    local function clamp()
      local _, h = term.getSize()
      scroll = math.max(0, math.min(scroll, #rows() - (h - 2)))
    end

    load()
    while true do
      draw()
      local e, a, x, y = os.pullEvent()
      local _, h = term.getSize()
      if e == "mouse_click" then
        local pg = h - 3
        if y == 1 and sel and x <= 3 then
          sel, scroll = nil, 0
        elseif y == h then
          local up, down = sel and 8 or 11, sel and 13 or 16
          if sel and x <= 5 then sel, scroll = nil, 0
          elseif not sel and x <= 8 then load() clamp()
          elseif x >= up - 1 and x <= up + 1 then scroll = scroll - pg clamp()
          elseif x >= down - 1 and x <= down + 1 then scroll = scroll + pg clamp() end
        elseif y >= 2 and not sel then
          local p = list[scroll + y - 1]
          if p then open(p) end
        end
      elseif e == "mouse_scroll" then
        scroll = scroll + a
        clamp()
      elseif e == "key" then
        if a == keys.up then scroll = scroll - 1 clamp()
        elseif a == keys.down then scroll = scroll + 1 clamp()
        elseif a == keys.backspace and sel then sel, scroll = nil, 0 end
      elseif e == "peripheral" or e == "peripheral_detach" then
        load()
        if sel then
          local still
          for _, p in ipairs(list) do if p.name == sel.name then still = p end end
          if still then open(still) else sel, scroll = nil, 0 end
        end
        clamp()
      end
    end
  end,
}
