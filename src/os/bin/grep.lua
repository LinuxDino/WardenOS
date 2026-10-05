-- grep: search files for lines matching a Lua pattern (or plain text with -F)
local cli = dofile("/os/lib/cli.lua").init("grep", shell)

-- lowercase a Lua pattern without breaking classes like %A or %S
local function lowerPattern(p)
  local out, i = {}, 1
  while i <= #p do
    local c = p:sub(i, i)
    if c == "%" then out[#out + 1] = p:sub(i, i + 1) i = i + 2
    else out[#out + 1] = c:lower() i = i + 1 end
  end
  return table.concat(out)
end

return cli.main({
  usage = "grep [-inrvFcl] <pattern> <file|dir>...",
  about = "Print lines that match a Lua pattern (e.g. \"fuel%d+\", \"^local\"). CC has no pipes, so give "
    .. "files; with -r, directories are searched recursively (default: the current directory).",
  options = { "-i  ignore case", "-n  show line numbers", "-r  search directories recursively",
              "-v  print lines that do NOT match", "-F  plain text, not a pattern", "-c  count matching lines",
              "-l  only list files that match" },
  flags = { i = true, n = true, r = true, v = true, F = true, c = true, l = true, R = true },
  long = { ["ignore-case"] = "i", ["line-number"] = "n", recursive = "r", ["invert-match"] = "v",
           ["fixed-strings"] = "F", count = "c", ["files-with-matches"] = "l" },
  run = function(o, args)
    local pat = table.remove(args, 1)
    if not pat then cli.fail("missing pattern (try: grep --help)") end
    o.r = o.r or o.R
    if #args == 0 then
      if o.r then args = { "." } else cli.fail("no files given (CC has no stdin; try: grep -r " .. pat .. " .)") end
    end
    local plain = o.F
    local p = o.i and (plain and pat:lower() or lowerPattern(pat)) or pat
    if not plain then
      local ok, e = pcall(string.find, "", p)
      if not ok then cli.fail("bad pattern: " .. tostring(e):gsub("^.-:%d+: ", "")) end
    end
    local function find(line, init)
      local s = o.i and line:lower() or line
      local a, b = s:find(p, init, plain)
      if a and b < a then b = a - 1 end
      return a, b
    end

    local files = {}
    local function walk(path, shown)
      if fs.isDir(path) then
        if not o.r then cli.print("grep: " .. shown .. ": Is a directory", colors.yellow) return end
        for _, f in ipairs(fs.list(path)) do
          walk(fs.combine(path, f), cli.join(shown, f))
        end
      elseif fs.exists(path) then
        files[#files + 1] = { path = "/" .. fs.combine(path, ""), name = shown }
      else
        cli.print("grep: " .. shown .. ": No such file or directory", colors.red)
      end
    end
    for _, a in ipairs(args) do walk(cli.resolve(a), a) end
    local prefix = #files > 1 or o.r
    local total = 0
    for _, f in ipairs(files) do
      local h = fs.open(f.path, "r")
      local src = h and h.readAll() or ""
      if h then h.close() end
      local n = 0
      for num, line in ipairs(cli.splitLines(src)) do
        cli.yield(300)
        local hit = find(line, 1) ~= nil
        if hit ~= (o.v == true) then
          n = n + 1
          if not o.c and not o.l then
            if prefix then cli.write(f.name, colors.magenta) cli.write(":", colors.cyan) end
            if o.n then cli.write(tostring(num), colors.green) cli.write(":", colors.cyan) end
            if o.v then
              cli.print(line, colors.white)
            else
              local pos = 1
              while pos <= #line do
                local a, b = find(line, pos)
                if not a then break end
                cli.write(line:sub(pos, a - 1), colors.white)
                cli.write(line:sub(a, b), colors.red)
                pos = math.max(b + 1, a + 1)
                if b < a then cli.write(line:sub(a, a), colors.white) end
              end
              cli.print(line:sub(pos), colors.white)
            end
          end
        end
      end
      total = total + n
      if o.l and n > 0 then cli.print(f.name, colors.magenta)
      elseif o.c then
        if prefix then cli.write(f.name, colors.magenta) cli.write(":", colors.cyan) end
        cli.print(tostring(n), colors.white)
      end
    end
    return total > 0
  end,
}, ...)
