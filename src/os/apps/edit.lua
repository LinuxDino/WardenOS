-- Editor: CraftOS edit in a window (opened from Files or the dock)
return {
  name = "Editor", short = "Edit", icon = "Ed", color = colors.blue, order = 4,
  multi = true, w = 46, h = 17,
  main = function(path)
    local env = setmetatable({ shell = shell, multishell = false }, { __index = _G })
    os.run(env, "/rom/programs/edit.lua", path or "new.lua")
  end,
}
