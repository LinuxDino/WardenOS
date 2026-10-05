-- tail: last lines of files; -f follows a growing file
local cli = dofile("/os/lib/cli.lua").init("tail", shell)
return cli.main({
  usage = "tail [-n N] [-f] <file>...",
  about = "Print the last 10 lines of each file (or N lines). With -f, keep printing what is added to the "
    .. "file until Ctrl+T or q.",
  options = { "-n N  print the last N lines (also: -N)", "-f    follow: print new lines as the file grows" },
  flags = { n = "num", f = true }, long = { lines = "n", follow = "f" }, digits = "n",
  run = function(o, args)
    if #args == 0 then cli.fail("missing file operand (try: tail -n 5 <file>)") end
    local count = math.max(0, math.floor(o.n or 10))
    for i, a in ipairs(args) do
      local s, err = cli.readFile(a)
      if not s then cli.print("tail: " .. err, colors.red)
      else
        if #args > 1 then cli.print((i > 1 and "\n" or "") .. "==> " .. a .. " <==", colors.cyan) end
        local lines = cli.splitLines(s)
        for k = math.max(1, #lines - count + 1), #lines do cli.print(lines[k], colors.white) end
      end
    end
    if not o.f then return end
    -- follow the last file
    local name = args[#args]
    local path = cli.resolve(name)
    local function get()
      if not fs.exists(path) or fs.isDir(path) then return nil end
      local f = fs.open(path, "r")
      if not f then return nil end
      local s = f.readAll() or ""
      f.close()
      return s
    end
    local last = get() or ""
    local partial = ""                      -- an unfinished last line, printed when it is completed
    while cli.sleep(0.5) do
      local now = get()
      if now == nil then
        if last ~= nil then cli.print("tail: " .. name .. ": file disappeared", colors.yellow) end
        last = nil
      elseif last == nil or #now < #last or now:sub(1, #last) ~= last then
        cli.print("tail: " .. name .. ": file truncated", colors.yellow)
        last, partial = "", ""
      end
      if now and #now > #last then
        local add = partial .. now:sub(#last + 1)
        local cut = add:match("^.*\n") or ""
        partial = add:sub(#cut + 1)
        for _, l in ipairs(cli.splitLines(cut)) do cli.print(l, colors.white) end
        last = now
      end
    end
    if partial ~= "" then cli.print(partial, colors.white) end
  end,
}, ...)
