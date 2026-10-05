-- echo: print text, with optional color tags
local cli = dofile("/os/lib/cli.lua").init("echo", shell)
return cli.main({
  usage = "echo [-n] [-e] [text...]",
  about = "Print the text. Color tags like {red}, {green}, {cyan}, {yellow} change the color and "
    .. "{reset} goes back to white. With -e, \\n and \\t are turned into a new line and a tab.",
  options = { "-n  no newline at the end", "-e  interpret \\n and \\t", "e.g. echo {red}hot {blue}cold" },
  flags = { n = true, e = true, E = true }, stop = true, lenient = true,
  run = function(o, args)
    local s = table.concat(args, " ")
    if o.e then s = s:gsub("\\n", "\n"):gsub("\\t", "  "):gsub("\\\\", "\\") end
    cli.tagged(s)
    if not o.n then cli.print("") end
  end,
}, ...)
