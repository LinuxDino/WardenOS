-- Lua console: the CraftOS Lua REPL in a window (quick peripheral / mod API testing)
return {
  name = "Lua Console", short = "Lua", icon = "Lu", color = colors.lightBlue, order = 2,
  multi = true, w = 46, h = 16,
  art = { { "Lua ", "0000", "bbbb" }, { "    ", "0000", "bbbb" } },   -- 4x2 icon (blit; bg 7 = panel)
  main = function()
    local env = setmetatable({ shell = shell, multishell = false }, { __index = _G })
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    os.run(env, "/rom/programs/lua.lua")
  end,
}
