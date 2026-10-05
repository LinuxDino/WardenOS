-- less: page through a file
local cli = dofile("/os/lib/cli.lua").init("less", shell)
return cli.main({
  usage = "less [-N] <file>",
  about = "Show a file one screen at a time. Up/down or j/k scroll a line, space/b a page, g/G jump "
    .. "to the start/end, q or Ctrl+T quits. Short files are just printed.",
  options = { "-N  number lines" },
  flags = { N = true, n = true }, long = { ["LINE-NUMBERS"] = "N" },
  run = function(o, args)
    if not args[1] then cli.fail("missing file name (CC has no stdin)") end
    local s, err = cli.readFile(args[1])
    if not s then cli.fail(err) end
    local w, h = term.getSize()
    local lines = {}
    for i, l in ipairs(cli.splitLines(s)) do
      local prefix = o.N and ("%4d "):format(i) or ""
      l = prefix .. l:gsub("\t", "  ")
      repeat
        lines[#lines + 1] = l:sub(1, w)
        l = (o.N and "     " or "") .. l:sub(w + 1)
      until #l <= (o.N and 5 or 0)
    end
    if #lines < h then for _, l in ipairs(lines) do cli.print(l) end return end
    cli.pager(lines, fs.getName(args[1]))
  end,
}, ...)
