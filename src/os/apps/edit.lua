-- Editor: CraftOS edit in a window (opened from Files or the dock)
return {
  name = "Editor", short = "Edit", icon = "Ed", color = colors.blue, order = 4,
  multi = true, w = 46, h = 17,
  art = { { " -- ", "7777", "0000" }, { " --/", "777b", "0000" } },   -- 4x2 icon (blit; bg 7 = panel)
  main = function(path)
    local env = setmetatable({ shell = shell, multishell = false }, { __index = _G })
    os.run(env, "/rom/programs/edit.lua", path or "new.lua")
  end,
}
