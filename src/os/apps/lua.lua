-- Lua console: the CraftOS Lua REPL in a window (quick peripheral / mod API testing)
return {
  name = "Lua Console", short = "Lua", icon = "Lu", color = colors.lightBlue, order = 2,
  multi = true, w = 46, h = 16,
  main = function()
    local env = setmetatable({ shell = shell, multishell = false }, { __index = _G })
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    os.run(env, "/rom/programs/lua.lua")
  end,
}
