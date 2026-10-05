-- Notes for WardenOS: a light multi-note editor. The first line is the note's title. Saved in /os/data/notes.
-- List: tap / Enter opens, n new, q quits.  Editor: type, arrows, Tab back to the list, Ctrl+S saves, Ctrl+Q quits.
local DIR = "/os/data/notes"

local function main()
  local parent = term.current()
  local W, H = parent.getSize()
  local buf = window.create(parent, 1, 1, W, H, false)
  local T = (rawget(_G, "WardenOS") and WardenOS.theme) or {}
  local BG, PANEL, TEXT, DIM, ACC = T.bg or colors.black, T.panel or colors.gray, T.text or colors.white,
    T.dim or colors.lightGray, T.accent or colors.cyan
  local BAD = T.bad or colors.red

  local notes, sel, focus = {}, 1, "list"        -- notes: { file, title }
  local lines, cx, cy, sx, sy = { "" }, 1, 1, 0, 0
  local dirty, saveTimer, ctrl, confirm, zones, msg = false, nil, false, false, {}, ""
  local current                                  -- file of the open note

  local function titleOf(text)
    local t = (text or ""):match("^[ \t]*([^\n]*)") or ""
    t = t:gsub("^#+%s*", "")
    return t ~= "" and t or "(empty)"
  end
  local function readText(file)
    local f = fs.open(DIR .. "/" .. file, "r")
    if not f then return "" end
    local s = f.readAll() or ""
    f.close()
    return s
  end
  local function scan()
    notes = {}
    if fs.isDir(DIR) then
      for _, f in ipairs(fs.list(DIR)) do
        if f:match("%.txt$") then notes[#notes + 1] = { file = f, title = titleOf(readText(f)) } end
      end
    end
    table.sort(notes, function(a, b) return a.title:lower() < b.title:lower() end)
    sel = math.max(1, math.min(sel, #notes))
  end

  local function save()
    if not current or not dirty then return end
    fs.makeDir(DIR)
    local f = fs.open(DIR .. "/" .. current, "w")
    if f then f.write(table.concat(lines, "\n")) f.close() msg = "saved" else msg = "can't save" end
    dirty = false
    for _, n in ipairs(notes) do if n.file == current then n.title = titleOf(lines[1]) end end
  end
  local function changed()
    dirty = true
    msg = ""
    saveTimer = os.startTimer(1.5)
  end

  local function open(i)
    save()
    local n = notes[i]
    if not n then return end
    sel, current = i, n.file
    lines = {}
    for l in (readText(n.file) .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = l end
    if #lines == 0 then lines = { "" } end
    cx, cy, sx, sy, focus, confirm = 1, 1, 0, 0, "edit", false
  end
  local function new()
    save()
    fs.makeDir(DIR)
    local id = 1
    while fs.exists(("%s/note-%d.txt"):format(DIR, id)) do id = id + 1 end
    local file = ("note-%d.txt"):format(id)
    local f = fs.open(DIR .. "/" .. file, "w")
    if f then f.write("") f.close() end
    scan()
    for i, n in ipairs(notes) do if n.file == file then open(i) end end
  end
  local function delete()
    local n = notes[sel]
    if not n then return end
    if not confirm then confirm = true msg = "tap del again" return end
    fs.delete(DIR .. "/" .. n.file)
    if current == n.file then current, lines, dirty = nil, { "" }, false end
    confirm, focus, msg = false, "list", "deleted"
    scan()
  end

  ---------------------------------------------- layout + drawing
  local function put(x, y, s, fg, bg)
    if y < 1 or y > H or x > W then return end
    if x < 1 then s = s:sub(2 - x) x = 1 end
    s = s:sub(1, W - x + 1)
    if s == "" then return end
    term.setCursorPos(x, y)
    term.setTextColor(fg or TEXT)
    term.setBackgroundColor(bg or BG)
    term.write(s)
  end
  local function button(x, y, label, fn, fg, bg)
    label = " " .. label .. " "
    if x + #label - 1 > W then return x end
    put(x, y, label, fg or TEXT, bg or PANEL)
    zones[#zones + 1] = { x, x + #label - 1, y, y, fn }
    return x + #label
  end
  local function geom()
    local wide = W >= 40
    local lw = wide and math.min(18, math.floor(W / 3)) or W
    local ex = wide and lw + 2 or 1                -- editor area
    return wide, lw, ex, W - ex + 1, H - 2         -- editor: x, width, height (rows 2..H-1)
  end

  local function scrollTo()
    local _, _, _, ew, eh = geom()
    if cy - sy < 1 then sy = cy - 1 elseif cy - sy > eh then sy = cy - eh end
    if cx - sx < 1 then sx = cx - 1 elseif cx - sx > ew - 1 then sx = cx - ew + 1 end
    sx, sy = math.max(0, sx), math.max(0, sy)
  end

  local function draw()
    zones = {}
    term.setBackgroundColor(BG)
    term.clear()
    local wide, lw, ex, ew, eh = geom()
    put(1, 1, string.rep(" ", W), TEXT, PANEL)
    local x = 1
    if not wide and focus == "edit" then x = button(x, 1, "<", function() save() focus = "list" end, ACC)
    else put(2, 1, "Notes", ACC, PANEL) x = 8 end
    x = button(x, 1, "+ new", new, TEXT, PANEL)
    if notes[sel] and (wide or focus == "list") then
      x = button(x, 1, confirm and "del?" or "del", delete, confirm and BG or BAD, confirm and BAD or PANEL)
    end
    if W - x > 4 then button(W - 2, 1, "x", function() save() error("quit", 0) end, BAD) end

    -- list
    if wide or focus == "list" then
      for i = 1, H - 2 do
        local n = notes[i]
        if not n then break end
        local on = i == sel
        local bg = on and (focus == "list" and ACC or PANEL) or BG
        local fg = on and (focus == "list" and BG or TEXT) or DIM
        put(1, i + 1, (" " .. n.title .. string.rep(" ", lw)):sub(1, lw), fg, bg)
        zones[#zones + 1] = { 1, lw, i + 1, i + 1, function() open(i) end }
      end
      if #notes == 0 then put(2, 3, ("No notes yet."):sub(1, lw - 1), DIM) put(2, 4, ("Tap + new."):sub(1, lw - 1), DIM) end
      if wide then for y = 2, H - 1 do put(lw + 1, y, " ", DIM, PANEL) end end
    end

    -- editor
    if wide or focus == "edit" then
      if current then
        for r = 1, eh do
          local l = lines[sy + r]
          if l then put(ex, r + 1, l:sub(sx + 1, sx + ew), (sy + r == 1) and ACC or TEXT) end
        end
        zones[#zones + 1] = { ex, W, 2, H - 1, function(mx, my)
          focus = "edit"
          cy = math.max(1, math.min(#lines, sy + my - 1))
          cx = math.max(1, math.min(#lines[cy] + 1, sx + mx - ex + 1))
        end }
      elseif wide then
        put(ex + 1, 3, "Pick a note or tap + new.", DIM)
      end
    end
    put(1, H, string.rep(" ", W), DIM, PANEL)
    local status = focus == "edit" and current and (("Ln %d Col %d  %s"):format(cy, cx, dirty and "*" or msg))
      or (msg ~= "" and msg or "Enter open  n new  q quit")
    put(2, H, status, DIM, PANEL)
  end

  local function render()
    buf.setVisible(false)
    local old = term.redirect(buf)
    draw()
    term.redirect(old)
    buf.setVisible(true)
    local _, _, ex = geom()
    if focus == "edit" and current then
      parent.setCursorPos(ex + cx - sx - 1, cy - sy + 1)
      parent.setTextColor(TEXT)
      parent.setCursorBlink(true)
    else
      parent.setCursorBlink(false)
    end
  end

  ---------------------------------------------- editing
  local function insert(s)
    local l = lines[cy]
    lines[cy] = l:sub(1, cx - 1) .. s .. l:sub(cx)
    cx = cx + #s
    changed()
  end
  local function editKey(k)
    local l = lines[cy]
    if k == keys.enter then
      local indent = l:match("^%s*")
      lines[cy] = l:sub(1, cx - 1)
      table.insert(lines, cy + 1, indent .. l:sub(cx))
      cy, cx = cy + 1, #indent + 1
      changed()
    elseif k == keys.backspace then
      if cx > 1 then lines[cy] = l:sub(1, cx - 2) .. l:sub(cx) cx = cx - 1 changed()
      elseif cy > 1 then
        cx = #lines[cy - 1] + 1
        lines[cy - 1] = lines[cy - 1] .. l
        table.remove(lines, cy)
        cy = cy - 1
        changed()
      end
    elseif k == keys.delete then
      if cx <= #l then lines[cy] = l:sub(1, cx - 1) .. l:sub(cx + 1) changed()
      elseif cy < #lines then lines[cy] = l .. lines[cy + 1] table.remove(lines, cy + 1) changed() end
    elseif k == keys.left then
      if cx > 1 then cx = cx - 1 elseif cy > 1 then cy = cy - 1 cx = #lines[cy] + 1 end
    elseif k == keys.right then
      if cx <= #l then cx = cx + 1 elseif cy < #lines then cy, cx = cy + 1, 1 end
    elseif k == keys.up then cy = math.max(1, cy - 1) cx = math.min(cx, #lines[cy] + 1)
    elseif k == keys.down then cy = math.min(#lines, cy + 1) cx = math.min(cx, #lines[cy] + 1)
    elseif k == keys.home then cx = 1
    elseif k == keys["end"] then cx = #l + 1
    elseif k == keys.tab then save() focus = "list"
    end
  end

  scan()
  render()
  local ok, err = pcall(function()
    while true do
      local e, a, b, c = os.pullEvent()
      if e == "timer" and a == saveTimer then save()
      elseif e == "key" and (a == keys.leftCtrl or a == keys.rightCtrl) then ctrl = true
      elseif e == "key_up" and (a == keys.leftCtrl or a == keys.rightCtrl) then ctrl = false
      elseif e == "key" and ctrl then
        if a == keys.s then save() msg = "saved"
        elseif a == keys.q then save() return
        elseif a == keys.n then new() end
      elseif e == "char" and ctrl then                   -- ignore the char of a Ctrl shortcut
      elseif focus == "edit" and current and (e == "char" or e == "paste") then
        insert((a:gsub("[\r\n]", " ")))
      elseif focus == "edit" and current and e == "key" then
        editKey(a)
      elseif e == "char" then
        if a == "q" then save() return
        elseif a == "n" then new() end
      elseif e == "key" then
        if a == keys.up then sel = math.max(1, sel - 1) confirm = false
        elseif a == keys.down then sel = math.min(#notes, sel + 1) confirm = false
        elseif a == keys.enter then open(sel)
        elseif a == keys.delete then delete()
        elseif a == keys.tab and current then focus = "edit" end
      elseif e == "mouse_scroll" then
        if focus == "edit" then sy = math.max(0, math.min(#lines - 1, sy + a)) end
      elseif e == "mouse_click" or e == "monitor_touch" then
        local hit
        for _, z in ipairs(zones) do if b >= z[1] and b <= z[2] and c >= z[3] and c <= z[4] then hit = z end end
        if hit then
          if hit[5] ~= delete then confirm = false end
          hit[5](b, c)
        end
      elseif e == "term_resize" then
        W, H = parent.getSize()
        buf = window.create(parent, 1, 1, W, H, false)
      end
      if focus == "edit" and e ~= "mouse_scroll" then scrollTo() end
      render()
    end
  end)
  save()
  parent.setCursorBlink(false)
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
  if not ok and err ~= "quit" then error(err, 0) end
end

return {
  name = "Notes", short = "Notes", icon = "=/", color = colors.yellow, order = 67, w = 44, h = 16,
  art = { { "=== ", "7770", "4444" }, { "== /", "777f", "4444" } },
  main = main,
}
