-- Login screen. Returns the logged-in user record.
-- Draws on the current term (kernel redirects it to the monitor / mirror).
local sha  = dofile("/os/lib/sha256.lua")
local font = dofile("/os/lib/bigfont.lua")

return function(users, o)
  local T = o.theme
  local f = { name = users.last or users.users[1].name, pass = "" }
  local focus = (f.name ~= "") and "pass" or "name"
  local msg, fails, dirty = "", 0, true
  local zones = {}

  local function put(x, y, s, fg, bg)
    term.setCursorPos(x, y)
    term.setTextColor(fg or T.text)
    term.setBackgroundColor(bg or T.bg)
    term.write(s)
  end

  local function field(x, y, w, label, value, active, mask)
    put(x, y - 1, label, T.dim, T.bg)
    term.setBackgroundColor(T.panel)
    term.setCursorPos(x, y)
    term.write(string.rep(" ", w))
    local shown = mask and string.rep("*", #value) or value
    if #shown > w - 2 then shown = shown:sub(-(w - 2)) end
    put(x + 1, y, shown, T.text, T.panel)
    if active then put(x + 1 + #shown, y, "_", T.accent, T.panel) end
  end

  local function draw()
    local W, H = term.getSize()
    term.setBackgroundColor(T.bg)
    term.clear()
    local cw = math.min(34, W - 2)
    local cx = math.floor((W - cw) / 2) + 1
    local big = H >= 17
    local top = math.max(1, math.floor((H - (big and 17 or 11)) / 2) + 1)
    local fy
    if big then
      font.draw(term, "WARDEN", math.floor((W - font.width("WARDEN")) / 2) + 1, top, T.accent)
      local s = "operating system"
      put(math.floor((W - #s) / 2) + 1, top + 6, s, T.dim, T.bg)
      fy = top + 8
    else
      local s = "WardenOS"
      put(math.floor((W - #s) / 2) + 1, top, s, T.accent, T.bg)
      fy = top + 2
    end
    field(cx, fy + 1, cw, "username", f.name, focus == "name", false)
    field(cx, fy + 4, cw, "password", f.pass, focus == "pass", true)
    local label = " log in "
    local bx = math.floor((W - #label) / 2) + 1
    put(bx, fy + 6, label, T.bg, T.accent)
    if msg ~= "" then put(math.floor((W - #msg) / 2) + 1, fy + 8, msg, T.bad, T.bg) end
    zones = {
      name = { cx, fy + 1, cx + cw - 1 },
      pass = { cx, fy + 4, cx + cw - 1 },
      btn  = { bx, fy + 6, bx + #label - 1 },
    }
  end

  local function submit()
    local rec
    for _, u in ipairs(users.users) do
      if u.name == f.name:lower() then rec = u end
    end
    if rec and sha.hashPassword(f.pass, rec.salt) == rec.hash then
      return rec
    end
    fails = fails + 1
    msg = "wrong username or password"
    f.pass = ""
    focus = "pass"
    draw()
    local t = os.startTimer(math.min(fails, 5))     -- raw wait: Ctrl+T can't skip it
    repeat local e, id = os.pullEventRaw("timer") until id == t
    return nil
  end

  while true do
    if dirty then draw() dirty = false end
    local e, a, b, c = os.pullEventRaw()
    if e == "char" or e == "paste" then
      f[focus] = f[focus] .. a
      msg, dirty = "", true
    elseif e == "key" then
      if a == keys.backspace then
        f[focus] = f[focus]:sub(1, -2)
        dirty = true
      elseif a == keys.tab or a == keys.up or a == keys.down then
        focus = (focus == "name") and "pass" or "name"
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
      local function hit(z) return z and y == z[2] and x >= z[1] and x <= z[3] end
      if hit(zones.name) then focus = "name" dirty = true
      elseif hit(zones.pass) then focus = "pass" dirty = true
      elseif hit(zones.btn) then
        local r = submit()
        if r then return r end
        dirty = true
      end
    end
  end
end
