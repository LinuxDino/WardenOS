-- To-Do: type a task, Enter adds it; tap the box to tick it off. Saved in /os/todo.dat
local FILE = "/os/todo.dat"
local PRIO = { [0] = { "", nil }, { "!", "warn" }, { "!!", "bad" } }   -- none, important, urgent

return {
  name = "To-Do", short = "ToDo", icon = "[v]", color = colors.lime, order = 7,
  w = 40, h = 16,
  art = { { "v ==", "d077", "0000" }, { "o ==", "8077", "0000" } },   -- 4x2 icon (blit; bg 7 = panel)
  main = function()
    local T = WardenOS.theme
    local tasks, nextId = {}, 1
    local filter = "open"                         -- all | open | done
    local input, scroll, sel = "", 0, nil
    local zones, msg = {}, ""

    ------------------------------------------------ storage
    local function load()
      if not fs.exists(FILE) then return end
      local f = fs.open(FILE, "r")
      local d = f and textutils.unserialize(f.readAll())
      if f then f.close() end
      if type(d) == "table" and type(d.tasks) == "table" then
        for _, t in ipairs(d.tasks) do
          if type(t) == "table" and type(t.text) == "string" then
            t.id = tonumber(t.id) or nextId
            t.prio = PRIO[t.prio] and t.prio or 0
            t.done = t.done == true
            tasks[#tasks + 1] = t
            nextId = math.max(nextId, t.id + 1)
          end
        end
      end
    end
    local function save()
      local f = fs.open(FILE, "w")
      if not f then msg = "can't save (disk full?)" return end
      f.write(textutils.serialize({ tasks = tasks }))
      f.close()
    end

    local function visible()
      local out = {}
      for _, t in ipairs(tasks) do
        if filter == "all" or (filter == "open" and not t.done) or (filter == "done" and t.done) then
          out[#out + 1] = t
        end
      end
      -- open first, then by priority (urgent first), then oldest first
      table.sort(out, function(a, b)
        if a.done ~= b.done then return not a.done end
        if a.prio ~= b.prio then return a.prio > b.prio end
        return a.id < b.id
      end)
      return out
    end
    local function counts()
      local open, done = 0, 0
      for _, t in ipairs(tasks) do if t.done then done = done + 1 else open = open + 1 end end
      return open, done
    end
    local function remove(task)
      for i, t in ipairs(tasks) do if t == task then table.remove(tasks, i) break end end
      if sel == task then sel = nil end
      save()
    end

    ------------------------------------------------ drawing
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
      return x + #label
    end

    local function draw(w, h)
      local open, done = counts()
      -- header: title + filters
      term.setCursorPos(1, 1)
      term.setBackgroundColor(T.panel)
      term.clearLine()
      local title = ("To-Do  %d open"):format(open)
      put(2, 1, title:sub(1, w - 1), T.text, T.panel)
      local fx = w + 1
      local labels = { { "all", "all" }, { "open", "open" }, { "done", "done" } }
      local width = 0
      for _, l in ipairs(labels) do width = width + #l[2] + 2 end
      fx = w - width + 1
      if fx > #title + 3 then
        for _, l in ipairs(labels) do
          local on = filter == l[1]
          fx = button(fx, 1, l[2], function() filter, scroll, sel = l[1], 0, nil end,
                      on and T.bg or T.dim, on and T.accent or T.panel)
        end
      end

      -- task rows
      local list = visible()
      local top, bottom = 2, h - 2
      local rows = bottom - top + 1
      scroll = math.max(0, math.min(scroll, #list - rows))
      if #list == 0 then
        local text = filter == "done" and "Nothing done yet." or (#tasks == 0 and "No tasks yet. Type below and press Enter."
          or "All done!")
        put(2, 3, text:sub(1, w - 2), T.dim)
      end
      for i = 1, rows do
        local t = list[scroll + i]
        if not t then break end
        local y = top + i - 1
        local bg = (sel == t) and T.panel or T.bg
        if sel == t then term.setCursorPos(1, y) term.setBackgroundColor(bg) term.clearLine() end
        put(2, y, t.done and "[x]" or "[ ]", t.done and T.good or T.accent, bg)
        zone(1, y, 4, function() t.done = not t.done t.doneAt = os.epoch("utc") save() end)
        local mark = PRIO[t.prio][1]
        local x = 6
        if mark ~= "" then put(x, y, mark, T[PRIO[t.prio][2]], bg) x = x + #mark + 1 end
        put(x, y, t.text:sub(1, math.max(0, w - x)), t.done and T.dim or T.text, bg)
        zone(5, y, w - 4, function() sel = (sel == t) and nil or t end)
      end

      -- row actions for the selected task, or the general buttons
      local by = h - 1
      term.setCursorPos(1, by)
      term.setBackgroundColor(T.bg)
      term.clearLine()
      if sel then
        local x = 1
        x = button(x, by, sel.done and "reopen" or "done", function()
          sel.done = not sel.done sel.doneAt = os.epoch("utc") save()
        end) + 1
        x = button(x, by, "priority " .. (sel.prio == 0 and "-" or PRIO[sel.prio][1]), function()
          sel.prio = (sel.prio + 1) % 3 save()
        end) + 1
        button(x, by, "delete", function() remove(sel) end, T.bad)
      else
        local x = 1
        if done > 0 then x = button(x, by, "clear done", function()
          for i = #tasks, 1, -1 do if tasks[i].done then table.remove(tasks, i) end end
          save()
          msg = "cleared"
        end) + 1 end
        if msg ~= "" then put(x + 1, by, msg:sub(1, math.max(0, w - x - 1)), T.warn) end
      end

      -- input line
      term.setCursorPos(1, h)
      term.setBackgroundColor(T.panel)
      term.clearLine()
      put(1, h, "+ ", T.accent, T.panel)
      local shown = input == "" and "new task, Enter adds" or input
      if #shown > w - 3 then shown = shown:sub(-(w - 3)) end
      put(3, h, shown, input == "" and T.dim or T.text, T.panel)
    end

    local function render()
      local parent = term.current()
      local w, h = parent.getSize()
      local buf = window.create(parent, 1, 1, w, h, false)
      term.redirect(buf)
      zones = {}
      term.setBackgroundColor(T.bg)
      term.clear()
      draw(w, h)
      term.redirect(parent)
      buf.setVisible(true)
      parent.setCursorPos(math.min(w, 3 + math.min(#input, w - 3)), h)
      parent.setTextColor(T.text)
      parent.setCursorBlink(true)
    end

    ------------------------------------------------ events
    load()
    render()
    while true do
      local e, a, b, c = os.pullEvent()
      if e == "char" or e == "paste" then
        input = (input .. a):sub(1, 120)
        msg = ""
      elseif e == "key" then
        if a == keys.backspace then input = input:sub(1, -2)
        elseif a == keys.enter then
          local text = input:gsub("^%s+", ""):gsub("%s+$", "")
          if text ~= "" then
            local prio = 0
            local bangs = text:match("^(!+)%s*")       -- "!! fix the base" = urgent
            if bangs then prio = math.min(2, #bangs) text = text:gsub("^!+%s*", "") end
            tasks[#tasks + 1] = { id = nextId, text = text, done = false, prio = prio, created = os.epoch("utc") }
            nextId = nextId + 1
            if filter == "done" then filter = "open" end
            save()
            msg = "added"
          end
          input = ""
        elseif a == keys.up then scroll = scroll - 1
        elseif a == keys.down then scroll = scroll + 1
        elseif a == keys.delete and sel then remove(sel) end
      elseif e == "mouse_scroll" then
        scroll = scroll + a
      elseif e == "mouse_click" then
        for _, z in ipairs(zones) do
          if c == z[3] and b >= z[1] and b <= z[2] then z[4]() break end   -- button, x, y
        end
      end
      render()
    end
  end,
}
