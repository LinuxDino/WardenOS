-- Paint for WardenOS: pixel art with pen, bucket fill and eraser, saved as .nfp (the CC paint format)
-- in /os/data/paint. Keys: p pen, f fill, e eraser, s save, o open next, n new, q quit (saves first).
local DIR = "/os/data/paint"
local HEX = "0123456789abcdef"

local function toHex(c) local i = math.floor(math.log(c) / math.log(2) + 0.5) return HEX:sub(i + 1, i + 1) end
local function fromHex(ch) local i = HEX:find(ch:lower(), 1, true) return i and 2 ^ (i - 1) or nil end

local function main()
  local parent = term.current()
  local W, H = parent.getSize()
  local buf = window.create(parent, 1, 1, W, H, false)
  local img, color, tool, file, dirty, msg, zones = {}, colors.red, "pen", nil, false, "", {}
  local ox, oy = 0, 0                              -- view offset into the image

  local function files()
    local out = {}
    if fs.isDir(DIR) then
      for _, f in ipairs(fs.list(DIR)) do if f:match("%.nfp$") then out[#out + 1] = f end end
    end
    table.sort(out)
    return out
  end
  local function newName()
    local i = 1
    while fs.exists(("%s/picture-%d.nfp"):format(DIR, i)) do i = i + 1 end
    return ("picture-%d.nfp"):format(i)
  end

  local function save()
    file = file or newName()
    local maxY = 0
    for y in pairs(img) do maxY = math.max(maxY, y) end
    local rows = {}
    for y = 1, maxY do
      local row, maxX = img[y] or {}, 0
      for x in pairs(row) do maxX = math.max(maxX, x) end
      local s = {}
      for x = 1, maxX do s[x] = row[x] and toHex(row[x]) or " " end
      rows[y] = table.concat(s)
    end
    fs.makeDir(DIR)
    local f = fs.open(DIR .. "/" .. file, "w")
    if not f then msg = "can't save" return end
    f.write(table.concat(rows, "\n"))
    f.close()
    dirty, msg = false, "saved " .. file
  end

  local function load(name)
    local f = fs.open(DIR .. "/" .. name, "r")
    if not f then msg = "can't open " .. name return end
    local s = f.readAll() or ""
    f.close()
    img, file, dirty, ox, oy = {}, name, false, 0, 0
    local y = 0
    for line in (s .. "\n"):gmatch("([^\n]*)\n") do
      y = y + 1
      for x = 1, #line do
        local c = fromHex(line:sub(x, x))
        if c then img[y] = img[y] or {} img[y][x] = c end
      end
    end
    msg = "opened " .. name
  end

  local function openNext()
    if dirty then save() end
    local list = files()
    if #list == 0 then msg = "no pictures yet" return end
    local idx = 1
    for i, f in ipairs(list) do if f == file then idx = i % #list + 1 end end
    load(list[idx])
  end

  local function get(x, y) return img[y] and img[y][x] end
  local function set(x, y, c)
    if x < 1 or y < 1 then return end
    img[y] = img[y] or {}
    if img[y][x] ~= c then img[y][x] = c dirty = true end
  end

  local function flood(x, y, c, cw, ch)
    local target = get(x, y)
    if target == c then return end
    local stack, seen = { { x, y } }, {}
    while #stack > 0 do
      local p = table.remove(stack)
      local px, py = p[1], p[2]
      local key = py * 4096 + px
      if px >= 1 and py >= 1 and px <= cw and py <= ch and not seen[key] and get(px, py) == target then
        seen[key] = true
        set(px, py, c)
        stack[#stack + 1] = { px + 1, py } stack[#stack + 1] = { px - 1, py }
        stack[#stack + 1] = { px, py + 1 } stack[#stack + 1] = { px, py - 1 }
      end
    end
  end

  local function put(x, y, s, fg, bg)
    if y < 1 or y > H or x > W then return end
    if x < 1 then s = s:sub(2 - x) x = 1 end
    s = s:sub(1, W - x + 1)
    if s == "" then return end
    term.setCursorPos(x, y)
    term.setTextColor(fg or colors.white)
    term.setBackgroundColor(bg or colors.black)
    term.write(s)
  end
  local function button(x, y, label, fn, on)
    label = " " .. label .. " "
    if x + #label - 1 > W then return x end
    put(x, y, label, on and colors.black or colors.white, on and colors.cyan or colors.gray)
    zones[#zones + 1] = { x, x + #label - 1, y, fn }
    return x + #label
  end

  local function draw()
    zones = {}
    -- canvas: checkerboard where it is transparent
    for y = 2, H - 1 do
      local t, f, b = {}, {}, {}
      for x = 1, W do
        local c = get(x + ox, y - 1 + oy)
        t[x], f[x], b[x] = c and " " or (((x + y) % 2 == 0) and "." or " "), "7", c and toHex(c) or "f"
      end
      term.setCursorPos(1, y)
      term.blit(table.concat(t), table.concat(f), table.concat(b))
    end
    -- toolbar
    put(1, 1, string.rep(" ", W), colors.white, colors.gray)
    local x = 1
    x = button(x, 1, "pen", function() tool = "pen" end, tool == "pen")
    x = button(x, 1, "fill", function() tool = "fill" end, tool == "fill")
    x = button(x, 1, "erase", function() tool = "erase" end, tool == "erase")
    x = x + 1
    x = button(x, 1, "new", function()
      if dirty then save() end
      img, file, dirty, ox, oy, msg = {}, nil, false, 0, 0, "new picture"
    end)
    x = button(x, 1, "save", save)
    x = button(x, 1, "open", openNext)
    if x + 3 <= W then button(W - 2, 1, "x", function() error("quit", 0) end) end
    -- palette
    put(1, H, string.rep(" ", W), colors.white, colors.black)
    local sw = (W >= 40) and 2 or 1
    for i = 0, 15 do
      local c = 2 ^ i
      local sx = 1 + i * sw
      if sx + sw - 1 <= W then
        put(sx, H, (c == color) and ("[]"):sub(1, sw) or string.rep(" ", sw),
            (c == colors.white or c == colors.yellow) and colors.black or colors.white, c)
        zones[#zones + 1] = { sx, sx + sw - 1, H, function() color = c if tool == "erase" then tool = "pen" end end }
      end
    end
    local info = (msg ~= "" and msg or (file or "untitled")) .. (dirty and "*" or "")
    local ix = 16 * sw + 2
    if ix + 4 <= W then put(ix, H, info:sub(1, W - ix + 1), colors.lightGray, colors.black) end
  end

  local function render()
    buf.setVisible(false)
    local old = term.redirect(buf)
    draw()
    term.redirect(old)
    buf.setVisible(true)
  end

  local function paint(x, y)
    if y < 2 or y > H - 1 then return end
    local ix, iy = x + ox, y - 1 + oy
    if tool == "pen" then set(ix, iy, color)
    elseif tool == "erase" then if img[iy] and img[iy][ix] then img[iy][ix] = nil dirty = true end
    else flood(ix, iy, color, W + ox, H - 2 + oy) end
    msg = ""
  end

  render()
  local ok, err = pcall(function()
    while true do
      local e, a, b, c = os.pullEvent()
      if e == "mouse_click" or e == "monitor_touch" then
        local hit
        for _, z in ipairs(zones) do if c == z[3] and b >= z[1] and b <= z[2] then hit = z[4] end end
        if hit then hit() else
          if e == "mouse_click" and a == 2 then tool = "erase" end
          paint(b, c)
        end
      elseif e == "mouse_drag" then
        if tool ~= "fill" then paint(b, c) end
      elseif e == "char" then
        a = a:lower()
        if a == "q" then return
        elseif a == "p" then tool = "pen" elseif a == "f" then tool = "fill" elseif a == "e" then tool = "erase"
        elseif a == "s" then save() elseif a == "o" then openNext()
        elseif a == "n" then if dirty then save() end img, file, dirty, msg = {}, nil, false, "new picture" end
      elseif e == "key" then
        if a == keys.left then ox = math.max(0, ox - 4) elseif a == keys.right then ox = ox + 4
        elseif a == keys.up then oy = math.max(0, oy - 2) elseif a == keys.down then oy = oy + 2 end
      elseif e == "mouse_scroll" then
        oy = math.max(0, oy + a)
      elseif e == "term_resize" then
        W, H = parent.getSize()
        buf = window.create(parent, 1, 1, W, H, false)
      end
      render()
    end
  end)
  if dirty and next(img) then save() end
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
  if not ok and err ~= "quit" then error(err, 0) end
end

return {
  name = "Paint", short = "Paint", icon = "~/", color = colors.pink, order = 68, w = 44, h = 17,
  art = { { " ~  ", "0e00", "e14b" }, { "   /", "000c", "5d9f" } },
  main = main,
}
