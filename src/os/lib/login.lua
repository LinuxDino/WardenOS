-- Login screen. Returns the logged-in user record.
-- Draws on the current term (kernel redirects it to the monitor / mirror).
-- Typing works with the computer's keyboard or, for touch-only monitors, with the on-screen keyboard:
-- letters, digits, shift (tap twice = caps lock), symbols page, space, backspace, enter, and show/hide for the
-- password. The layout shrinks with the screen (Warden art, labels and key gaps go first); below 20 columns
-- only the computer's keyboard is left, with a hint.
local sha  = dofile("/os/lib/sha256.lua")
local art
do
  local ok, m = pcall(dofile, "/os/lib/art.lua")
  if ok and type(m) == "table" then art = m end
end

local MSG_WRONG = "wrong username or password"

return function(users, o)
  local T = o.theme
  local f = { name = users.last or users.users[1].name, pass = "" }
  local focus = (f.name ~= "") and "pass" or "name"
  local msg, fails, dirty = "", 0, true
  local zones = {}                                -- { x1, x2, y, fn }
  local page, shift, show = "abc", 0, false       -- keyboard page, shift 0 off / 1 once / 2 caps lock
  local W, H = term.getSize()

  local function put(x, y, s, fg, bg)
    s = tostring(s)
    if y < 1 or y > H or x > W then return end
    if x < 1 then s, x = s:sub(2 - x), 1 end
    s = s:sub(1, W - x + 1)
    if s == "" then return end
    term.setCursorPos(x, y)
    term.setTextColor(fg or T.text)
    term.setBackgroundColor(bg or T.bg)
    term.write(s)
  end
  local function zone(x, y, w, fn) zones[#zones + 1] = { x, x + w - 1, y, fn } end
  local function centerX(s, x0, w) return x0 + math.floor((w - #s) / 2) end

  ---------------------------------------------------------------- input actions
  local function insert(s)
    if focus == "name" and #f.name >= 16 then return end
    if #f[focus] >= 64 then return end
    f[focus] = f[focus] .. s
    msg = ""
  end
  local function backspace() f[focus] = f[focus]:sub(1, -2) end
  local function toggleFocus() focus = (focus == "name") and "pass" or "name" end

  local submit                                    -- defined below (needs draw)

  ---------------------------------------------------------------- on-screen keyboard
  local function chars(s, out)
    out = out or {}
    for c in s:gmatch(".") do out[#out + 1] = { c, 1, c } end
    return out
  end
  local function keyRows(digits)
    local rows = {}
    if page == "abc" then
      if digits then rows[#rows + 1] = chars("1234567890") end
      rows[#rows + 1] = chars("qwertyuiop")
      rows[#rows + 1] = chars("asdfghjkl", nil)
      table.insert(rows[#rows], { "<-", 1, "bs" })
      local r = { { shift == 2 and "^^" or "^", 1, "shift" } }
      chars("zxcvbnm-_", r)
      rows[#rows + 1] = r
      rows[#rows + 1] = { { "123", 2, "page" }, { "space", 5, " " }, { "enter", 3, "enter" } }
    else
      rows[#rows + 1] = chars("1234567890")
      rows[#rows + 1] = chars("-_.@!#$%&")
      table.insert(rows[#rows], { "<-", 1, "bs" })
      rows[#rows + 1] = chars("*+=()/?:;,")
      if digits then rows[#rows + 1] = chars("[]{}<>~'\"|") end
      rows[#rows + 1] = { { "abc", 2, "page" }, { "space", 5, " " }, { "enter", 3, "enter" } }
    end
    return rows
  end

  local function press(act)
    if act == "bs" then backspace()
    elseif act == "shift" then shift = (shift + 1) % 3
    elseif act == "page" then page = (page == "abc") and "123" or "abc"
    elseif act == "enter" then
      if focus == "name" then focus = "pass" else return submit() end
    else
      local c = act
      if shift > 0 and c:match("%a") then c = c:upper() end
      insert(c)
      if shift == 1 then shift = 0 end
    end
  end

  -- keyboard at row y; u = columns per key unit, gap = blank row between key rows
  local function drawKeyboard(y, u, digits, gap)
    local kw = 10 * u
    local x0 = math.floor((W - kw) / 2) + 1
    for i, row in ipairs(keyRows(digits)) do
      local ky = y + (i - 1) * (gap + 1)
      local x = x0
      for _, k in ipairs(row) do
        local label, units, act = k[1], k[2], k[3]
        local w = units * u - (u >= 4 and 1 or 0)
        local fg, bg = T.text, T.panel
        if act == "enter" then fg, bg = T.bg, T.accent
        elseif act == "shift" and shift > 0 then fg, bg = T.bg, T.accent
        elseif act == "bs" or act == "shift" or act == "page" then fg, bg = T.bg, T.dim end
        if shift > 0 and #label == 1 and label:match("%a") then label = label:upper() end
        label = label:sub(1, w)
        put(x, ky, string.rep(" ", w), fg, bg)
        put(x + math.floor((w - #label) / 2), ky, label, fg, bg)
        zone(x, ky, units * u, function() return press(act) end)
        x = x + units * u
      end
    end
  end

  ---------------------------------------------------------------- layout
  -- the richest layout that fits: { art = size|nil, side = bool, form = "labeled"|"inline", kb = nil|{ rows, gap } }
  local KB = { roomy = { 5, 1 }, plain5 = { 5, 0 }, plain4 = { 4, 0 } }
  local function kbHeight(kb) return kb and (kb[1] + (kb[1] - 1) * kb[2]) or 0 end
  local function plan()
    local cw = math.min(34, W - 2)
    local function artW(s) local a = art and art.get("warden", s) return a and a.w or 0, a and a.h or 0 end
    local cands = {
      { art = "large", side = false, form = "labeled", kb = KB.roomy },
      { art = "medium", side = false, form = "labeled", kb = KB.roomy },
      { art = "medium", side = true, form = "labeled", kb = KB.roomy },
      { art = "small", side = true, form = "labeled", kb = KB.roomy },
      { art = "medium", side = true, form = "labeled", kb = KB.plain5 },
      { art = "small", side = true, form = "labeled", kb = KB.plain5 },
      { art = "small", side = false, form = "labeled", kb = KB.plain5 },
      { form = "labeled", kb = KB.plain5 },
      { form = "inline", kb = KB.plain5 },
      { form = "inline", kb = KB.plain4 },
      { form = "inline" },
    }
    local u = math.min(W >= 100 and 6 or 4, math.floor(W / 10))
    for _, c in ipairs(cands) do
      local aw, ah = 0, 0
      if c.art then aw, ah = artW(c.art) end
      local ok = (not c.art) or aw > 0
      if c.kb and u < 2 then ok = false end
      local formH = c.form == "labeled" and 8 or 3
      local h
      if c.art and not c.side then
        h = ah + 1 + 2 + formH
      elseif c.art then
        h = 2 + math.max(formH, ah)
        if W < cw + aw + 3 then ok = false end
      else
        h = (c.form == "labeled" and 2 or 1) + formH
      end
      if c.kb then h = h + 1 + kbHeight(c.kb) end
      if ok and h <= H then
        c.h, c.cw, c.u, c.aw, c.ah = h, cw, u, aw, ah
        return c
      end
    end
  end

  ---------------------------------------------------------------- drawing
  local function field(x, y, w, value, active, mask)
    put(x, y, string.rep(" ", w), T.text, T.panel)
    if active then put(x, y, " ", T.text, T.accent) end
    local shown = mask and string.rep("*", #value) or value
    if #shown > w - 3 then shown = shown:sub(-(w - 3)) end
    put(x + 2, y, shown, T.text, T.panel)
    if active then put(x + 2 + #shown, y, "_", T.accent, T.panel) end
  end

  local function draw()
    W, H = term.getSize()
    zones = {}
    term.setBackgroundColor(T.bg)
    term.clear()
    local L = plan()
    if not L then                                 -- tiny screen: just the essentials
      put(1, 1, "WardenOS login", T.accent)
      field(1, 2, W, f.name, focus == "name", false)
      field(1, 3, W, f.pass, focus == "pass", not show)
      if msg ~= "" then put(1, 4, msg, T.bad) end
      return
    end
    local cw = L.cw
    local y = math.max(1, math.floor((H - L.h) / 2) + 1)
    local fx = math.floor((W - cw) / 2) + 1       -- form column
    local title = "WardenOS"
    if L.art and not L.side then
      art.draw(term, "warden", L.art, math.floor((W - L.aw) / 2) + 1, y)
      y = y + L.ah + 1
    end
    if L.form == "inline" and msg ~= "" then
      put(math.max(1, centerX(msg, 1, W)), y, msg, T.bad)
    else
      put(centerX(title, 1, W), y, title, T.accent)
    end
    y = y + (L.form == "labeled" and 2 or 1)
    if L.art and L.side then                      -- Warden left of the form
      local bx = math.floor((W - (L.aw + 3 + cw)) / 2) + 1
      art.draw(term, "warden", L.art, bx, y + math.floor((8 - L.ah) / 2))
      fx = bx + L.aw + 3
    end
    local sw = 6                                  -- " show " / " hide " button next to the password
    local function showBtn(x, yy)
      local s = show and " hide " or " show "
      put(x, yy, s, T.bg, T.dim)
      zone(x, yy, #s, function() show = not show end)
    end
    if L.form == "labeled" then
      put(fx, y, "username", T.dim)
      field(fx, y + 1, cw, f.name, focus == "name", false)
      zone(fx, y + 1, cw, function() focus = "name" end)
      put(fx, y + 3, "password", T.dim)
      field(fx, y + 4, cw - sw - 1, f.pass, focus == "pass", not show)
      zone(fx, y + 4, cw - sw - 1, function() focus = "pass" end)
      showBtn(fx + cw - sw, y + 4)
      local label = " log in "
      local bx = fx + math.floor((cw - #label) / 2)
      put(bx, y + 6, label, T.bg, T.accent)
      zone(bx, y + 6, #label, function() return submit() end)
      if msg ~= "" then put(math.max(1, centerX(msg, fx, cw)), y + 7, msg, T.bad) end
      y = y + 8
    else
      local lw = 5
      put(fx, y, "user", T.dim)
      field(fx + lw, y, cw - lw, f.name, focus == "name", false)
      zone(fx + lw, y, cw - lw, function() focus = "name" end)
      put(fx, y + 1, "pass", T.dim)
      field(fx + lw, y + 1, cw - lw - sw - 1, f.pass, focus == "pass", not show)
      zone(fx + lw, y + 1, cw - lw - sw - 1, function() focus = "pass" end)
      showBtn(fx + cw - sw, y + 1)
      local label = " log in "
      local bx = fx + math.floor((cw - #label) / 2)
      put(bx, y + 2, label, T.bg, T.accent)
      zone(bx, y + 2, #label, function() return submit() end)
      y = y + 3
    end
    if L.kb then
      drawKeyboard(y + 1, L.u, L.kb[1] == 5, L.kb[2])
    elseif y <= H then
      local hint = "type with the computer's keyboard"
      put(math.max(1, centerX(hint:sub(1, W), 1, W)), H, hint, T.dim)
    end
  end

  function submit()
    local rec
    for _, u in ipairs(users.users) do
      if u.name == f.name:lower() then rec = u end
    end
    if rec and sha.hashPassword(f.pass, rec.salt) == rec.hash then
      return rec
    end
    fails = fails + 1
    msg = MSG_WRONG
    f.pass = ""
    focus = "pass"
    draw()
    local t = os.startTimer(math.min(fails, 5))     -- raw wait: Ctrl+T can't skip it
    repeat local e, id = os.pullEventRaw("timer") until id == t
    dirty = true
    return nil
  end

  while true do
    if dirty then draw() dirty = false end
    local e, a, b, c = os.pullEventRaw()
    if e == "char" or e == "paste" then
      insert(a)
      dirty = true
    elseif e == "key" then
      if a == keys.backspace then
        backspace()
        dirty = true
      elseif a == keys.tab or a == keys.up or a == keys.down then
        toggleFocus()
        dirty = true
      elseif a == keys.enter then
        if focus == "name" then
          focus = "pass"
          dirty = true
        else
          local r = submit()
          if r then return r end
          dirty = true
        end
      end
    elseif (e == "monitor_touch" and a == o.side) or (e == "mouse_click" and o.mirror and a == 1) then
      local x, y = b, c
      for i = #zones, 1, -1 do
        local z = zones[i]
        if y == z[3] and x >= z[1] and x <= z[2] then
          local r = z[4]()
          if r then return r end
          dirty = true
          break
        end
      end
    elseif e == "term_resize" or e == "monitor_resize" then
      dirty = true
    end
  end
end
