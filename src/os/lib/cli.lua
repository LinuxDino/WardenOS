-- Shared helpers for the terminal commands in /os/bin (cat, grep, cowsay, ...).
--   local cli = dofile("/os/lib/cli.lua").init("cat", shell)
--   cli.main({ usage = "cat [-n] <file>...", about = "...", flags = { n = true }, run = function(o, args) end }, ...)
-- Output goes through cli.write / cli.print: wraps at the terminal edge, scrolls, never writes off-screen.
local M = {}

local function isColor() return term.isColour and term.isColour() end
M.color = isColor()

-- the caller's name and shell (programs get their own `shell` in their environment, not in _G)
function M.init(name, sh)
  M.name, M.shell = name, sh or rawget(_G, "shell")
  return M
end

---------------------------------------------------------------- colors + output
function M.fg(c) if c and isColor() then term.setTextColor(c) end end
function M.bg(c) if c and isColor() then term.setBackgroundColor(c) end end
function M.size() return term.getSize() end

local function newline()
  local _, y = term.getCursorPos()
  local _, h = term.getSize()
  if y >= h then
    term.scroll(1)
    term.setCursorPos(1, h)
  else
    term.setCursorPos(1, y + 1)
  end
end
M.newline = newline

-- like CraftOS write(): handles "\n", wraps words at the right edge (long words are split), scrolls
function M.write(s, fg)
  if fg then M.fg(fg) end
  s = tostring(s)
  local w = term.getSize()
  local first = true
  for line in (s .. "\n"):gmatch("(.-)\n") do
    if not first then newline() end
    first = false
    line = line:gsub("\t", "  ")
    while #line > 0 do
      local x, y = term.getCursorPos()
      if x < 1 then term.setCursorPos(1, y) x = 1 end
      local ws = line:match("^ +")
      if ws then
        if x <= w then term.write(ws:sub(1, w - x + 1)) end
        term.setCursorPos(x + #ws, y)             -- spaces past the edge only move the cursor
        line = line:sub(#ws + 1)
      else
        local word = line:match("^[^ ]+")
        line = line:sub(#word + 1)
        if x > 1 and x + #word - 1 > w and #word <= w then newline() end
        while #word > 0 do
          local cx = term.getCursorPos()
          if cx > w then newline() cx = 1 end
          local n = w - cx + 1
          term.write(word:sub(1, n))
          word = word:sub(n + 1)
        end
      end
    end
  end
end
function M.print(s, fg)
  M.write((s or "") .. "\n", fg)
end
-- one line, cut at the terminal edge instead of wrapping (art, tables)
function M.line(s, fg)
  if fg then M.fg(fg) end
  local x = term.getCursorPos()
  local w = term.getSize()
  term.write(tostring(s):sub(1, math.max(0, w - x + 1)))
  newline()
end
-- write at a position, clipped to the screen (full-screen programs)
function M.at(x, y, s, fg, bg)
  local w, h = term.getSize()
  s = tostring(s)
  if y < 1 or y > h or x > w then return end
  if x < 1 then s = s:sub(2 - x) x = 1 end
  s = s:sub(1, w - x + 1)
  if s == "" then return end
  term.setCursorPos(x, y)
  if fg then M.fg(fg) end
  if bg then M.bg(bg) end
  term.write(s)
end
-- word wrap to a width, keeping a line's leading indent for its continuation lines
function M.wrap(text, width)
  local out = {}
  for line in (tostring(text) .. "\n"):gmatch("(.-)\n") do
    line = line:gsub("\t", "  ")
    if #line <= width then
      out[#out + 1] = line
    else
      local indent = line:match("^(%s*)")
      if #indent > width / 2 then indent = "" end
      local cur = ""
      for word in line:gmatch("%S+") do
        local cand = cur == "" and indent .. word or cur .. " " .. word
        if #cand > width and cur ~= "" then
          out[#out + 1] = cur
          cur = indent .. word
        else
          cur = cand
        end
        while #cur > width do
          out[#out + 1] = cur:sub(1, width)
          cur = cur:sub(width + 1)
        end
      end
      out[#out + 1] = cur
    end
  end
  return out
end

-- color tags for echo/cowsay/...: "{red}hi{reset}"
M.NAMES = {}
for k, v in pairs(colors) do if type(v) == "number" then M.NAMES[k:lower()] = v end end
M.NAMES.grey, M.NAMES.lightgrey = colors.gray, colors.lightGray
function M.tagged(s, default)
  default = default or colors.white
  local pos = 1
  while true do
    local a, b, tag = s:find("{(%a+)}", pos)
    if not a then M.write(s:sub(pos)) return end
    M.write(s:sub(pos, a - 1))
    local t = tag:lower()
    if t == "reset" then M.fg(default)
    elseif M.NAMES[t] then M.fg(M.NAMES[t])
    else M.write(s:sub(a, b)) end
    pos = b + 1
  end
end

-- blit image { w=, h=, rows = { { text, fg, bg }, ... } } (as returned by /os/lib/art.lua), one row per line
function M.image(img, x)
  x = x or 1
  local w = term.getSize()
  for _, r in ipairs(img.rows) do
    local t, f, b = tostring(r[1] or r.text or ""), tostring(r[2] or r.fg or ""), tostring(r[3] or r.bg or "")
    local n = math.min(#t, w - x + 1)
    if n > 0 then
      local _, y = term.getCursorPos()
      term.setCursorPos(x, y)
      local ff = (f .. string.rep("0", n)):sub(1, n)
      local bb = (b .. string.rep("f", n)):sub(1, n)
      term.blit(t:sub(1, n), ff, bb)
    end
    newline()
  end
end
-- load a WardenOS art image if /os/lib/art.lua is there and the image fits (nil otherwise)
function M.art(name, sizes, maxW, maxH)
  if not isColor() or not fs.exists("/os/lib/art.lua") then return nil end
  local ok, art = pcall(dofile, "/os/lib/art.lua")
  if not ok or type(art) ~= "table" or type(art.get) ~= "function" then return nil end
  for _, sz in ipairs(sizes) do
    local ok2, img = pcall(art.get, name, sz)
    if ok2 and type(img) == "table" and type(img.rows) == "table" and #img.rows > 0 then
      local iw = tonumber(img.w or img[1]) or 0
      for _, r in ipairs(img.rows) do iw = math.max(iw, #tostring(r[1] or r.text or "")) end
      local ih = tonumber(img.h or img[2]) or #img.rows
      if iw <= (maxW or math.huge) and ih <= (maxH or math.huge) then img.w, img.h = iw, ih return img end
    end
  end
  return nil
end

-- ASCII art lines: shift left (dropping shared indentation) when too wide, then cut at the edge
function M.art_lines(lines, fg)
  local w = term.getSize()
  local maxl, minIndent = 0, math.huge
  for _, l in ipairs(lines) do
    maxl = math.max(maxl, #l)
    if l:match("%S") then minIndent = math.min(minIndent, #l:match("^ *")) end
  end
  local drop = math.max(0, math.min(maxl - w, minIndent == math.huge and 0 or minIndent))
  for _, l in ipairs(lines) do M.line(l:sub(drop + 1), fg) end
end

---------------------------------------------------------------- misc helpers
function M.human(n)
  n = tonumber(n) or 0
  if n >= 1048576 then return ("%.1fM"):format(n / 1048576) end
  if n >= 1024 then return ("%.1fK"):format(n / 1024) end
  return tostring(math.floor(n))
end
function M.device()
  local adv = isColor() and "Advanced " or ""
  if turtle then return adv .. "Turtle" end
  if pocket then return adv .. "Pocket Computer" end
  if commands then return "Command Computer" end
  return adv .. "Computer"
end
function M.lib(p)
  if not fs.exists(p) then return nil end
  local ok, m = pcall(dofile, p)
  return ok and type(m) == "table" and m or nil
end
function M.config() return M.lib("/os/config.lua") or {} end
function M.version()
  local W = rawget(_G, "WardenOS")
  return tostring((type(W) == "table" and W.version) or M.config().version or "?")
end
function M.user()
  local W = rawget(_G, "WardenOS")
  if type(W) == "table" and type(W.user) == "string" and W.user ~= "" then return W.user end
  return os.getComputerLabel() or ("computer-" .. os.getComputerID())
end
function M.hostname() return os.getComputerLabel() or ("computer-" .. os.getComputerID()) end

local yieldN = 0
function M.yield(every)            -- call in long loops so CC doesn't kill us for not yielding
  yieldN = yieldN + 1
  if yieldN >= (every or 200) then
    yieldN = 0
    os.queueEvent("cli_yield")
    if os.pullEventRaw("cli_yield") == "terminate" then error("Terminated", 0) end
  end
end

function M.resolve(p)
  if p:sub(1, 1) == "/" or not (M.shell and M.shell.resolve) then return "/" .. fs.combine(p, "") end
  return "/" .. fs.combine(M.shell.resolve(p), "")
end
function M.readFile(p)
  local path = M.resolve(p)
  if not fs.exists(path) then return nil, p .. ": No such file or directory" end
  if fs.isDir(path) then return nil, p .. ": Is a directory" end
  local f = fs.open(path, "r")
  if not f then return nil, p .. ": Permission denied" end
  local s = f.readAll() or ""
  f.close()
  return s, path
end
-- "dir" + "name" for display, keeping how the user wrote the directory ("/home", "sub", ".")
function M.join(dir, name)
  if dir == "." or dir == "" then return name end
  if dir:sub(-1) == "/" then return dir .. name end
  return dir .. "/" .. name
end
function M.splitLines(s)
  local out = {}
  if s == "" then return out end
  for l in (s:sub(-1) == "\n" and s or s .. "\n"):gmatch("(.-)\r?\n") do out[#out + 1] = l end
  return out
end
-- args are file names when they all exist, otherwise one piece of text (rev, lolcat, base64, ...)
function M.filesOrText(args)
  if #args == 0 then return nil end
  for _, a in ipairs(args) do
    local p = M.resolve(a)
    if not fs.exists(p) or fs.isDir(p) then return nil, table.concat(args, " ") end
  end
  return args
end

-- run another program file with arguments, in the caller's environment
function M.exec(path, env, ...)
  local f = fs.open(path, "r")
  if not f then M.fail(path .. ": not found") end
  local src = f.readAll()
  f.close()
  local fn, err = load(src, "@" .. path, "t", env or _G)
  if not fn then M.fail(err) end
  return fn(...)
end
function M.run(...)                -- a shell command (nano -> edit, top -> btop, sudo ...)
  if M.shell and M.shell.run then return M.shell.run(...) end
  M.fail("needs the CraftOS shell")
end

---------------------------------------------------------------- events
-- wait up to `secs`; false when the user quits (Ctrl+T, or q when allowQ). Resizes update M.resized.
function M.sleep(secs, allowQ)
  local t = os.startTimer(secs or 0.1)
  while true do
    local e, a = os.pullEventRaw()
    if e == "terminate" then return false end
    if allowQ ~= false and e == "char" and (a == "q" or a == "Q") then return false end
    if allowQ ~= false and e == "key" and a == keys.q then return false end
    if e == "term_resize" then M.resized = true end
    if e == "timer" and a == t then return true end
  end
end

-- full-screen pager (less, man): arrows/space/b/j/k/g/G, q or Ctrl+T quits
function M.pager(lines, title)
  local top = 1
  local function draw()
    local w, h = term.getSize()
    M.bg(colors.black)
    term.clear()
    for i = 1, h - 1 do
      local l = lines[top + i - 1]
      if l then M.at(1, i, type(l) == "table" and l[1] or l, type(l) == "table" and l[2] or colors.white) end
    end
    local last = math.min(#lines, top + h - 2)
    local st = (" %s %d-%d/%d q:quit"):format(title or "", top, last, #lines)
    if #st > w then st = (" %d-%d/%d q"):format(top, last, #lines) end
    M.at(1, h, st .. string.rep(" ", w), colors.black, colors.lightGray)
    M.bg(colors.black)
  end
  draw()
  while true do
    local _, h = term.getSize()
    local page = math.max(1, h - 2)
    local maxTop = math.max(1, #lines - (h - 1) + 1)
    local e, a = os.pullEventRaw()
    local old = top
    if e == "terminate" then break end
    if e == "char" then
      if a == "q" or a == "Q" then break
      elseif a == " " or a == "f" then top = top + page
      elseif a == "b" then top = top - page
      elseif a == "j" then top = top + 1
      elseif a == "k" then top = top - 1
      elseif a == "g" then top = 1
      elseif a == "G" then top = maxTop end
    elseif e == "key" then
      if a == keys.down or a == keys.enter then top = top + 1
      elseif a == keys.up then top = top - 1
      elseif a == keys.pageDown then top = top + page
      elseif a == keys.pageUp then top = top - page end
    elseif e == "mouse_scroll" then top = top + a * 2
    elseif e == "term_resize" then old = nil end
    top = math.max(1, math.min(top, maxTop))
    if top ~= old then draw() end
  end
  M.bg(colors.black)
  M.fg(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
end

-- leave a full-screen program: clean screen, default colors
function M.restore()
  M.bg(colors.black)
  M.fg(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
end

---------------------------------------------------------------- arguments + main
local USERERR = {}
function M.fail(msg) error(setmetatable({ msg = msg }, USERERR), 0) end

-- flags: { n = "num" | "str" | true, ... } single letters; long = { number = "n", ... } long names -> letter
function M.parse(spec, argv)
  local opts, args = {}, {}
  local flags, long = spec.flags or {}, spec.long or {}
  local i = 1
  local onlyArgs = false
  while i <= #argv do
    local a = tostring(argv[i])
    if onlyArgs or a == "-" or a:sub(1, 1) ~= "-" or (spec.numbers and a:match("^%-%d")) then
      args[#args + 1] = a
      if spec.stop then onlyArgs = true end
    elseif a == "--" then
      onlyArgs = true
    elseif a == "--help" then
      opts.help = true
    elseif a:sub(1, 2) == "--" then
      local name, val = a:match("^%-%-([^=]+)=(.*)$")
      name = name or a:sub(3)
      local letter = long[name]
      if not letter then M.fail("unrecognized option '" .. a .. "'") end
      local kind = flags[letter]
      if kind == "num" or kind == "str" then
        if not val then i = i + 1 val = argv[i] end
        if val == nil then M.fail("option '" .. a .. "' requires an argument") end
        if kind == "num" then val = tonumber(val) or M.fail("invalid number '" .. tostring(val) .. "'") end
        opts[letter] = val
      else
        opts[letter] = true
      end
    elseif spec.digits and a:match("^%-%d+$") then
      opts[spec.digits] = tonumber(a:sub(2))
    else
      local j = 2
      if spec.lenient then                         -- echo, pacman: unknown options are just text
        for k = 2, #a do if flags[a:sub(k, k)] == nil then j = #a + 1 args[#args + 1] = a break end end
        if j > #a and spec.stop then onlyArgs = true end
      end
      while j <= #a do
        local ch = a:sub(j, j)
        local kind = flags[ch]
        if ch == "h" and kind == nil then opts.help = true
        elseif kind == nil then M.fail("invalid option -- '" .. ch .. "'")
        elseif kind == "num" or kind == "str" then
          local val = a:sub(j + 1)
          if val == "" then i = i + 1 val = argv[i] end
          if val == nil then M.fail("option requires an argument -- '" .. ch .. "'") end
          if kind == "num" then val = tonumber(val) or M.fail("invalid number '" .. tostring(val) .. "'") end
          opts[ch] = val
          break
        else
          opts[ch] = true
        end
        j = j + 1
      end
    end
    i = i + 1
  end
  return opts, args
end

function M.usage(spec)
  local w = term.getSize()
  M.fg(colors.cyan)
  for _, l in ipairs(M.wrap("Usage: " .. spec.usage, w)) do M.print(l) end
  M.fg(colors.white)
  if spec.about then for _, l in ipairs(M.wrap(spec.about, w)) do M.print(l) end end
  if spec.options then
    M.fg(colors.lightGray)
    for _, o in ipairs(spec.options) do
      for k, l in ipairs(M.wrap(o, w)) do M.print((k > 1 and "    " or "") .. l) end
    end
  end
  M.fg(colors.white)
end

function M.main(spec, ...)
  local argv = { ... }
  local fg0 = term.getTextColor and term.getTextColor() or colors.white
  local bg0 = term.getBackgroundColor and term.getBackgroundColor() or colors.black
  local function back()
    if isColor() then term.setTextColor(fg0) term.setBackgroundColor(bg0) end
  end
  local ok, err = pcall(function()
    local opts, args = M.parse(spec, argv)
    if opts.help then M.usage(spec) return end
    return spec.run(opts, args)
  end)
  back()
  if not ok then
    if getmetatable(err) == USERERR then
      local x = term.getCursorPos()
      if x > 1 then newline() end
      M.fg(colors.red)
      M.print(M.name .. ": " .. tostring(err.msg))
      back()
      return false
    end
    error(err, 0)
  end
  return err
end

return M
