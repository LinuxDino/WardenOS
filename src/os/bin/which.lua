-- which: where a command comes from
local cli = dofile("/os/lib/cli.lua").init("which", shell)
return cli.main({
  usage = "which [-a] <command>...",
  about = "Print the program file a command runs, following shell aliases (e.g. ls -> list).",
  options = { "-a  also show the alias it goes through" },
  flags = { a = true }, long = { all = "a" },
  run = function(o, args)
    if #args == 0 then cli.fail("missing command name") end
    if not (shell and shell.resolveProgram) then cli.fail("needs the CraftOS shell") end
    local aliases = shell.aliases and shell.aliases() or {}
    local missing = false
    for _, name in ipairs(args) do
      local target = aliases[name]
      local path = shell.resolveProgram(target or name) or (target and shell.resolveProgram(name))
      if path then
        if o.a and target then cli.print(name .. ": aliased to " .. target, colors.lightGray) end
        cli.print("/" .. fs.combine(path, ""), colors.white)
      else
        missing = true
        cli.print("which: no " .. name .. " in (" .. (shell.path and shell.path() or "") .. ")", colors.red)
      end
    end
    return not missing
  end,
}, ...)
