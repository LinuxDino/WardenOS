-- Terminal: a full CraftOS shell in a window
return {
  name = "Terminal", short = "Term", icon = ">_", color = colors.cyan, order = 1,
  multi = true, w = 46, h = 16,
  art = { { ">_  ", "9000", "ffff" }, { "    ", "0000", "8888" } },   -- 4x2 icon (blit; bg 7 = panel)
  main = function()
    local env = setmetatable({ shell = shell, multishell = false }, { __index = _G })
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(WardenOS.theme.accent)
    print(WardenOS.name .. " terminal  (" .. os.version() .. ")")
    term.setTextColor(colors.lightGray)
    print("try: neofetch, btop, cowsay, apt list, man -k <word>")
    term.setTextColor(colors.white)
    if shell and shell.setPath and not (":" .. shell.path() .. ":"):find(":/os/bin:", 1, true) then
      shell.setPath(shell.path() .. ":/os/bin")      -- the new shell copies this path
    end
    os.run(env, "/rom/programs/shell.lua")
  end,
}
