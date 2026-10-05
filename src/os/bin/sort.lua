-- sort: sort the lines of files
local cli = dofile("/os/lib/cli.lua").init("sort", shell)
return cli.main({
  usage = "sort [-rnuf] <file>...",
  about = "Print the lines of the files in sorted order.",
  options = { "-r  reverse", "-n  numeric (by the leading number)", "-u  drop duplicate lines",
              "-f  ignore case" },
  flags = { r = true, n = true, u = true, f = true },
  long = { reverse = "r", ["numeric-sort"] = "n", unique = "u", ["ignore-case"] = "f" },
  run = function(o, args)
    if #args == 0 then cli.fail("missing file operand (try: sort <file>)") end
    local lines = {}
    for _, a in ipairs(args) do
      local s, err = cli.readFile(a)
      if not s then cli.fail(err) end
      for _, l in ipairs(cli.splitLines(s)) do lines[#lines + 1] = l end
    end
    local function key(l)
      if o.n then return tonumber(l:match("^%s*([%-%+]?%d*%.?%d+)")) or 0 end
      return o.f and l:lower() or l
    end
    local keys = {}
    for i, l in ipairs(lines) do keys[i] = { k = key(l), l = l, i = i } end
    table.sort(keys, function(a, b)
      if a.k ~= b.k then if o.r then return a.k > b.k end return a.k < b.k end
      if a.l ~= b.l then if o.r then return a.l > b.l end return a.l < b.l end
      return a.i < b.i
    end)
    local last
    for _, e in ipairs(keys) do
      if not (o.u and last ~= nil and e.k == last) then cli.print(e.l) end
      last = e.k
    end
  end,
}, ...)
