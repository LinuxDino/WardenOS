-- nano: opens the CraftOS editor
local cli = dofile("/os/lib/cli.lua").init("nano", shell)
return cli.main({
  usage = "nano <file>",
  about = "Edit a file. GNU nano isn't installed, so this opens the CraftOS editor (edit): press Ctrl "
    .. "for its menu (Save, Exit, ...).",
  run = function(_, args)
    if not args[1] then cli.fail("usage: nano <file>") end
    return cli.run("edit", args[1])
  end,
}, ...)
