-- pwd: print the working directory
local cli = dofile("/os/lib/cli.lua").init("pwd", shell)
return cli.main({
  usage = "pwd",
  about = "Print the shell's current directory.",
  run = function()
    local d = shell and shell.dir and shell.dir() or ""
    cli.print("/" .. fs.combine(d, ""))
  end,
}, ...)
