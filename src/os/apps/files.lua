-- Files: touch file browser. Tap a folder to enter, tap a file to edit.
return {
  name = "Files", short = "Files", icon = "[]", color = colors.yellow, order = 3,
  w = 34, h = 16,
  main = function()
    local T = WardenOS.theme
    local cwd, scroll, items = "", 0, {}

    local function load()
      local list = fs.list(cwd)
      table.sort(list, function(a, b)
        local da, db = fs.isDir(fs.combine(cwd, a)), fs.isDir(fs.combine(cwd, b))
        if da ~= db then return da end
        return a:lower() < b:lower()
      end)
      items, scroll = list, 0
    end

    local function draw()
      local w, h = term.getSize()
      term.setBackgroundColor(T.bg)
      term.clear()
      term.setCursorPos(1, 1)
      term.setBackgroundColor(T.panel)
      term.setTextColor(T.dim)
      term.clearLine()
      term.write(("/" .. cwd):sub(1, w))
      for row = 2, h - 1 do
        local item = items[scroll + row - 1]
        term.setCursorPos(1, row)
        term.setBackgroundColor(T.bg)
        if item then
          if fs.isDir(fs.combine(cwd, item)) then
            term.setTextColor(T.accent)
            term.write(("> " .. item):sub(1, w))
          else
            term.setTextColor(T.text)
            term.write(("  " .. item):sub(1, w))
          end
        end
      end
      term.setCursorPos(1, h)
      term.setBackgroundColor(T.panel)
      term.setTextColor(T.dim)
      term.clearLine()
      term.write(" up    ^    v")
    end

    local function clamp()
      local _, h = term.getSize()
      scroll = math.max(0, math.min(scroll, #items - (h - 2)))
    end

    load()
    while true do
      draw()
      local e, a, x, y = os.pullEvent()
      local _, h = term.getSize()
      if e == "mouse_click" then
        if y == h then
          if x <= 4 then
            if cwd ~= "" then
              cwd = fs.getDir(cwd)
              if cwd == ".." then cwd = "" end
              load()
            end
          elseif x >= 6 and x <= 8 then scroll = scroll - (h - 3) clamp()
          elseif x >= 11 and x <= 13 then scroll = scroll + (h - 3) clamp() end
        elseif y >= 2 then
          local item = items[scroll + y - 1]
          if item then
            local p = fs.combine(cwd, item)
            if fs.isDir(p) then cwd = p load()
            else os.queueEvent("os_launch", "edit", p) end
          end
        end
      elseif e == "mouse_scroll" then
        scroll = scroll + a
        clamp()
      end
    end
  end,
}
