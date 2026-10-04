-- Terminal: a full CraftOS shell in a window
return {
  name = "Terminal", short = "Term", icon = ">_", color = colors.cyan, order = 1,
  multi = true, w = 46, h = 16,
  main = function()
    local env = setmetatable({ shell = shell, multishell = false }, { __index = _G })
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(WardenOS.theme.accent)
    print(WardenOS.name .. " terminal  (" .. os.version() .. ")")
    term.setTextColor(colors.white)
    os.run(env, "/rom/programs/shell.lua")
  end,
}
