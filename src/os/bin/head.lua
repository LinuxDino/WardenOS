-- head: first lines of files
local cli = dofile("/os/lib/cli.lua").init("head", shell)
return cli.main({
  usage = "head [-n N] <file>...",
  about = "Print the first 10 lines of each file (or N lines).",
  options = { "-n N  print the first N lines (also: -N)" },
  flags = { n = "num" }, long = { lines = "n" }, digits = "n",
  run = function(o, args)
    if #args == 0 then cli.fail("missing file operand (try: head -n 5 <file>)") end
    local count = math.max(0, math.floor(o.n or 10))
    for i, a in ipairs(args) do
      local s, err = cli.readFile(a)
      if not s then cli.print("head: " .. err, colors.red)
      else
        if #args > 1 then cli.print((i > 1 and "\n" or "") .. "==> " .. a .. " <==", colors.cyan) end
        local lines = cli.splitLines(s)
        for k = 1, math.min(count, #lines) do cli.print(lines[k], colors.white) end
      end
    end
  end,
}, ...)
