-- App Store: games, tools and terminal commands from the WardenOS catalog on GitHub (/os/lib/store.lua)
local TABS = { "featured", "games", "tools", "commands", "installed", "updates" }
local LABELS = {                                 -- tab labels, longest first: the first set that fits is used
  { "Featured", "Games", "Tools", "Commands", "Installed", "Updates" },
  { "Featured", "Games", "Tools", "Cmds", "Mine", "Updates" },
  { "Top", "Games", "Tools", "Cmds", "Mine", "Upd" },
  { "Top", "Game", "Tool", "Cmd", "Mine", "Up" },
}

local function kb(n)
  n = tonumber(n) or 0
  if n >= 1024 then return ("%.1f KB"):format(n / 1024) end
  return n .. " B"
end

local function wrap(s, width)
  local out = {}
  width = math.max(4, width)
  for para in (tostring(s) .. "\n"):gmatch("(.-)\n") do
    local line = ""
    for word in para:gmatch("%S+") do
      while #word > width do
        if line ~= "" then out[#out + 1] = line line = "" end
        out[#out + 1] = word:sub(1, width)
        word = word:sub(width + 1)
      end
      if line == "" then line = word
      elseif #line + 1 + #word <= width then line = line .. " " .. word
      else out[#out + 1] = line line = word end
    end
    out[#out + 1] = line
  end
  return out
end

return {
  name = "App Store", short = "Store", icon = "(+)", color = colors.lightBlue, order = 10,
  w = 46, h = 18,
  art = { { " /\\ ", "0bb0", "3333" }, { "[++]", "b00b", "3333" } },
  main = function()
    local T = WardenOS.theme
    local store = dofile("/os/lib/store.lua")
    local list, offline = {}, false
    local tab, query, scroll = 1, "", 0
    local view, pkg, dscroll, confirm = "list", nil, 0, false
    local busy, frac, msg, msgColor = nil, nil, "", nil
    local zones, status, inst = {}, {}, {}
    local cursor                                   -- where the search cursor blinks
    local render                                   -- defined below

    ---------------------------------------------- data
    local function refreshStatus()
      status, inst = {}, {}
      for _, e in ipairs(store.installed()) do inst[e.id] = e end
      for _, p in ipairs(list) do
        local e = inst[p.id]
        if e then status[p.id] = store.newer(p.version, e.version) and "update" or "installed" end
      end
    end
    local function say(text, color) msg, msgColor = text or "", color end

    local function loadCatalog(refresh)
      if refresh then
        busy, frac = "Refreshing the catalog...", nil
        render()
      end
      local l, m, off = store.catalog(refresh)
      list, offline = l or {}, off
      busy = nil
      if m and (off or refresh) then say(m, off and T.warn or T.dim) end
      refreshStatus()
    end

    local function updatesCount()
      local n = 0
      for _, s in pairs(status) do if s == "update" then n = n + 1 end end
      return n
    end

    local function shown()
      local out = {}
      local q = query:lower()
      local t = TABS[tab]
      if q ~= "" then
        for _, p in ipairs(list) do
          local hay = (p.id .. " " .. p.name .. " " .. p.description .. " " .. p.category):lower()
          if hay:find(q, 1, true) then out[#out + 1] = p end
        end
        return out
      end
      for _, p in ipairs(list) do
        local ok = (t == "featured" and p.featured) or (t == "games" and p.category == "game")
          or (t == "tools" and p.category == "tool") or (t == "commands" and p.kind == "command")
          or (t == "installed" and status[p.id] ~= nil) or (t == "updates" and status[p.id] == "update")
        if ok then out[#out + 1] = p end
      end
      if t == "installed" then                     -- installed, but no longer in the catalog
        local known = {}
        for _, p in ipairs(list) do known[p.id] = true end
        for id, e in pairs(inst) do
          if not known[id] then
            out[#out + 1] = { id = id, name = e.name or id, version = e.version, kind = e.kind or "app",
              category = "", summary = "not in the catalog any more", description = "", files = {},
              icon = "?", color = T.dim, size = 0, author = "?", gone = true }
          end
        end
      end
      return out
    end

    ---------------------------------------------- drawing helpers
    local W, H = term.getSize()
    local function put(x, y, s, fg, bg)
      if y < 1 or y > H or x > W then return end
      s = tostring(s)
      if x < 1 then s = s:sub(2 - x) x = 1 end
      s = s:sub(1, W - x + 1)
      if s == "" then return end
      term.setCursorPos(x, y)
      term.setTextColor(fg or T.text)
      term.setBackgroundColor(bg or T.bg)
      term.write(s)
    end
    local function fill(y, bg) put(1, y, string.rep(" ", W), T.text, bg) end
    local function zone(x1, x2, y1, y2, fn) zones[#zones + 1] = { x1, x2, y1, y2, fn } end
    local function button(x, y, label, fn, fg, bg)
      label = " " .. label .. " "
      if x + #label - 1 > W or x < 1 then return x end
      put(x, y, label, fg or T.bg, bg or T.accent)
      zone(x, x + #label - 1, y, y, fn)
      return x + #label + 1
    end
    local function icon(p, x, y)
      if x + 3 > W or y + 1 > H then return end
      if p.art then
        for i = 1, 2 do
          term.setCursorPos(x, y + i - 1)
          term.blit(p.art[i][1], p.art[i][2], p.art[i][3])
        end
      else
        local s = tostring(p.icon or "?"):sub(1, 3)
        put(x, y, "    ", T.text, T.panel)
        put(x, y + 1, "    ", T.text, T.panel)
        put(x + math.floor((4 - #s) / 2), y, s, p.color or T.text, T.panel)
      end
    end

    ---------------------------------------------- actions
    local function progress(text, f)
      busy, frac = text, f
      render()
    end
    local function act(fn, id)
      busy, frac, confirm = "Working...", 0, false
      render()
      local ok, m = fn(id, progress)
      busy, frac = nil, nil
      say(m, ok and T.good or T.bad)
      refreshStatus()
    end
    local function install(p) act(store.install, p.id) end
    local function update(p) act(store.update, p.id) end
    local function remove(p)
      if not confirm then confirm = true say("Tap Remove again to remove " .. p.name, T.warn) return end
      act(function(id) return store.remove(id) end, p.id)
    end
    local function open(p) os.queueEvent("os_launch", p.id) end
    local function updateAll()
      local ups = store.upgrades()
      if #ups == 0 then say("Everything is up to date.", T.good) return end
      local done, failed = 0, 0
      for i, u in ipairs(ups) do
        busy, frac = ("Updating %s (%d/%d)"):format(u.name, i, #ups), (i - 1) / #ups
        render()
        local ok = store.update(u.id, function(text) busy = ("%s: %s (%d/%d)"):format(u.name, text, i, #ups) render() end)
        if ok then done = done + 1 else failed = failed + 1 end
      end
      busy, frac = nil, nil
      refreshStatus()
      say(("Updated %d package%s%s"):format(done, done == 1 and "" or "s", failed > 0 and (", " .. failed .. " failed") or ""),
          failed > 0 and T.bad or T.good)
    end
    local function showDetail(p) view, pkg, dscroll, confirm = "detail", p, 0, false end

    -- the main action of a package: { label, fn, fg, bg } or nil
    local function mainAction(p)
      local s = status[p.id]
      if p.gone then return { "Remove", function() remove(p) end, T.bg, T.bad } end
      if s == "update" then return { "Update", function() update(p) end, T.bg, T.warn } end
      if s == "installed" then
        if p.kind == "app" then return { "Open", function() open(p) end, T.text, T.panel } end
        return { "Installed", function() showDetail(p) end, T.good, T.bg }
      end
      return { "Get", function() install(p) end, T.bg, T.accent }
    end

    ---------------------------------------------- list view
    local function drawTabs(y)
      fill(y, T.bg)
      local n = updatesCount()
      for _, set in ipairs(LABELS) do
        local width = 0
        for _, l in ipairs(set) do width = width + #l + 2 end
        if width <= W then
          local x = 1
          for i, l in ipairs(set) do
            local label = " " .. l .. " "
            local on = (i == tab and query == "")
            local fg = on and T.bg or ((TABS[i] == "updates" and n > 0) and T.warn or T.dim)
            put(x, y, label, fg, on and T.accent or T.bg)
            zone(x, x + #label - 1, y, y, function() tab, scroll, query = i, 0, "" end)
            x = x + #label
          end
          return
        end
      end
      -- too narrow for all tabs: < name >
      local label = LABELS[1][tab]
      if #label + 4 > W then label = LABELS[4][tab] end
      put(1, y, "<", T.accent) put(W, y, ">", T.accent)
      put(math.floor((W - #label) / 2) + 1, y, label, query == "" and T.accent or T.text)
      zone(1, 2, y, y, function() tab, scroll, query = (tab - 2) % #TABS + 1, 0, "" end)
      zone(W - 1, W, y, y, function() tab, scroll, query = tab % #TABS + 1, 0, "" end)
    end

    local function drawItem(p, x, y, w)
      icon(p, x + 1, y)
      local a = mainAction(p)
      local label = " " .. a[1] .. " "
      local bx = x + w - #label - 1
      if w < 26 then bx = x + w end                -- narrow: no button, the name gets the room
      local tx = x + 6
      local room = bx - tx - 1
      local name = p.name
      local ver = p.version and (" " .. p.version) or ""
      if #name > room then name = name:sub(1, math.max(1, room)) ver = "" end
      if #name + #ver > room then ver = "" end
      put(tx, y, name, T.text)
      put(tx + #name, y, ver, T.dim)
      if bx > tx + 3 then
        put(bx, y, label, a[3], a[4])
        zone(bx, bx + #label - 1, y, y, a[2])
      end
      local sum = p.summary ~= "" and p.summary or p.description
      if status[p.id] == "update" and inst[p.id] then sum = ("update %s -> %s"):format(inst[p.id].version, p.version) end
      put(tx, y + 1, sum:sub(1, math.max(0, x + w - tx - 1)), status[p.id] == "update" and T.warn or T.dim)
      zone(x, (bx > tx + 3 and bx - 1) or (x + w - 1), y, y + 1, function() showDetail(p) end)
      zone(x, x + w - 1, y + 1, y + 1, function() showDetail(p) end)
    end

    local function drawList()
      -- header: title + search
      fill(1, T.panel)
      local title = W >= 30 and " App Store" or " Store"
      put(1, 1, title, T.accent, T.panel)
      local sx = #title + 2
      local sw = W - sx
      if sw >= 6 then
        local shown_ = query ~= "" and query or "search"
        if #shown_ > sw - 3 then shown_ = shown_:sub(-(sw - 3)) end
        put(sx, 1, " " .. shown_ .. string.rep(" ", sw - #shown_ - 1), query ~= "" and T.text or T.dim, T.bg)
        if query ~= "" then cursor = { sx + 1 + #shown_, 1 } end
        if query ~= "" then
          put(W, 1, "x", T.bad, T.bg)
          zone(W, W, 1, 1, function() query, scroll = "", 0 end)
        end
      end
      drawTabs(2)

      local items = shown()
      local top, bottom = 3, H - 1
      local cols = math.max(1, math.floor(W / 38))
      local cw = math.floor(W / cols)
      local gap = (H >= 24) and 1 or 0
      local per = 2 + gap
      local rowsFit = math.max(1, math.floor((bottom - top + 1 + gap) / per))
      local totalRows = math.ceil(#items / cols)
      scroll = math.max(0, math.min(scroll, totalRows - rowsFit))
      if #items == 0 then
        local t = TABS[tab]
        local text = query ~= "" and ("Nothing matches '" .. query .. "'.")
          or (#list == 0 and (offline and "Can't reach GitHub. Tap Refresh to try again." or "The catalog is empty."))
          or (t == "updates" and "No updates. Everything is up to date.")
          or (t == "installed" and "Nothing installed yet. Get something from Featured!")
          or "Nothing here yet."
        for i, l in ipairs(wrap(text, W - 4)) do put(3, top + i, l, T.dim) end
      end
      for r = 1, rowsFit do
        for c = 1, cols do
          local p = items[(scroll + r - 1) * cols + c]
          local y = top + (r - 1) * per
          if p and y + 1 <= bottom then drawItem(p, (c - 1) * cw + 1, y, cw) end
        end
      end
      if totalRows > rowsFit then
        local pos = ("%d/%d"):format(math.min(totalRows, scroll + rowsFit), totalRows)
        if W > #pos + 2 then put(W - #pos + 1, bottom, pos, T.dim) end
      end

      -- footer
      fill(H, T.panel)
      local right
      if TABS[tab] == "updates" and query == "" and updatesCount() > 0 then
        right = { "Update all (" .. updatesCount() .. ")", updateAll }
      else
        right = { "Refresh", function() loadCatalog(true) end }
      end
      local label = " " .. right[1] .. " "
      local bx = W - #label + 1
      if busy then
        local text = busy
        if frac then
          local bw = math.max(0, math.min(12, W - #text - 3))
          if bw >= 4 then
            put(W - bw, H, string.rep(" ", bw), T.text, T.bg)
            put(W - bw, H, string.rep(" ", math.floor(bw * frac + 0.5)), T.text, T.accent)
            put(2, H, text:sub(1, W - bw - 3), T.text, T.panel)
            return
          end
        end
        put(2, H, text:sub(1, W - 2), T.text, T.panel)
        return
      end
      if bx > 8 then
        put(bx, H, label, T.bg, T.accent)
        zone(bx, W, H, H, right[2])
      else bx = W + 1 end
      local left = msg ~= "" and msg or (offline and "offline" or ("%d packages"):format(#list))
      put(2, H, left:sub(1, math.max(0, bx - 3)), msg ~= "" and (msgColor or T.dim) or T.dim, T.panel)
    end

    ---------------------------------------------- detail view
    local function drawDetail()
      local p = pkg
      fill(1, T.panel)
      local x = button(1, 1, "<", function() view, confirm = "list", false end, T.text, T.panel)
      put(x, 1, p.name, T.text, T.panel)

      -- content width: centered column when maximized
      local cw = math.min(W - 2, 72)
      local cx = math.floor((W - cw) / 2) + 1
      local lines = {}                               -- { text, color } (scrolls)
      local function add(t, c)
        local ind = t:match("^%s*")
        for _, l in ipairs(wrap(t, cw - #ind)) do lines[#lines + 1] = { (l:sub(1, #ind) == ind and l or ind .. l), c or T.text } end
      end

      -- fixed part: icon, name, version, buttons
      icon(p, cx, 3)
      put(cx + 5, 3, p.name, T.text)
      local by = (p.author ~= "?" and ("by " .. p.author) or "")
      put(cx + 5, 4, (p.version and ("v" .. p.version .. "  ") or "") .. by, T.dim)
      local kind = p.kind == "command" and "Terminal command" or "App"
      local cat = ({ game = "Game", tool = "Tool" })[p.category]
      local meta = kind .. (cat and (" - " .. cat) or "") .. (p.size > 0 and ("  " .. kb(p.size)) or "")
      put(cx, 5, meta:sub(1, cw), T.dim)

      local s = status[p.id]
      local bx = cx
      if busy then
        put(cx, 7, busy:sub(1, cw), T.text)
        if frac then
          local bw = cw
          put(cx, 8, string.rep(" ", bw), T.text, T.panel)
          put(cx, 8, string.rep(" ", math.floor(bw * frac + 0.5)), T.text, T.accent)
        end
      else
        if p.gone then
          bx = button(bx, 7, confirm and "Remove?" or "Remove", function() remove(p) end, T.bg, T.bad)
        elseif not s then
          bx = button(bx, 7, "Install", function() install(p) end, T.bg, T.accent)
        else
          if s == "update" then bx = button(bx, 7, "Update", function() update(p) end, T.bg, T.warn) end
          if p.kind == "app" then bx = button(bx, 7, "Open", function() open(p) end, T.text, T.panel) end
          bx = button(bx, 7, confirm and "Remove?" or "Remove", function() remove(p) end, T.bg, T.bad)
        end
        if s == "installed" and bx + 10 <= cx + cw then put(bx, 7, "installed", T.good) end
        if s == "update" and inst[p.id] and bx + 8 <= cx + cw then put(bx, 7, "v" .. inst[p.id].version, T.warn) end
      end

      add(p.description ~= "" and p.description or p.summary)
      add("")
      if p.kind == "command" then
        local cmd = (p.files[1] and p.files[1].to or ""):match("/os/bin/(.-)%.lua$")
        if cmd then add("Run it in the Terminal: " .. cmd, T.accent) add("") end
      end
      if p.requires then add("Needs WardenOS " .. p.requires .. " or newer", T.dim) end
      add("Files", T.text)
      for _, f in ipairs(p.files) do add("  " .. f.to, T.dim) end
      if p.gone and inst[p.id] then for _, f in ipairs(inst[p.id].files) do add("  " .. f, T.dim) end end

      local top, bottom = 9, H - 1
      local rows = bottom - top + 1
      dscroll = math.max(0, math.min(dscroll, #lines - rows))
      for i = 1, rows do
        local l = lines[dscroll + i]
        if l then put(cx, top + i - 1, l[1]:sub(1, cw), l[2]) end
      end
      fill(H, T.panel)
      local foot = msg ~= "" and msg or (dscroll < #lines - rows and "scroll for more" or "")
      put(2, H, foot:sub(1, W - 2), msg ~= "" and (msgColor or T.dim) or T.dim, T.panel)
    end

    function render()
      local parent = term.current()
      W, H = parent.getSize()
      local buf = window.create(parent, 1, 1, W, H, false)
      term.redirect(buf)
      zones, cursor = {}, nil
      term.setBackgroundColor(T.bg)
      term.clear()
      local ok, err = pcall(view == "detail" and pkg and drawDetail or drawList)
      term.redirect(parent)
      buf.setVisible(true)
      if not ok then error(err, 0) end
      if cursor and cursor[1] <= W then
        parent.setCursorPos(cursor[1], cursor[2])
        parent.setTextColor(T.text)
        parent.setCursorBlink(true)
      else
        parent.setCursorBlink(false)
      end
    end

    ---------------------------------------------- events
    loadCatalog(false)
    render()
    loadCatalog(true)
    if msg:match("^%d+ packages$") then msg = "" end
    render()
    while true do
      local e, a, b, c = os.pullEvent()
      if e == "mouse_click" or e == "monitor_touch" then
        if not busy then
          local hit
          for _, z in ipairs(zones) do
            if b >= z[1] and b <= z[2] and c >= z[3] and c <= z[4] then hit = z[5] break end
          end
          if hit then
            local before = confirm
            if msg ~= "" and not confirm then msg = "" end
            hit()
            if before and confirm then confirm = false end
          end
        end
      elseif e == "mouse_scroll" then
        if view == "detail" then dscroll = math.max(0, dscroll + a) else scroll = math.max(0, scroll + a) end
      elseif e == "char" or e == "paste" then
        if view == "list" then query = (query .. a):sub(1, 30) scroll = 0 end
      elseif e == "key" then
        if a == keys.backspace then
          if view == "detail" then view, confirm = "list", false else query = query:sub(1, -2) end
        elseif a == keys.up then if view == "detail" then dscroll = math.max(0, dscroll - 1) else scroll = math.max(0, scroll - 1) end
        elseif a == keys.down then if view == "detail" then dscroll = dscroll + 1 else scroll = scroll + 1 end
        elseif a == keys.left and view == "list" then tab, scroll, query = (tab - 2) % #TABS + 1, 0, ""
        elseif a == keys.right and view == "list" then tab, scroll, query = tab % #TABS + 1, 0, ""
        elseif a == keys.tab and view == "list" then tab, scroll, query = tab % #TABS + 1, 0, "" end
      end
      render()
    end
  end,
}
