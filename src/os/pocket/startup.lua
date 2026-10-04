-- WardenOS Pocket: starts the pocket UI (this file is /startup.lua on a pocket computer)
rawset(_G, "shell", shell)

-- WardenOS terminal commands (btop, neofetch, ...) live in /os/bin: on the program path and as aliases,
-- both are copied by every shell started later (Terminal app, pocket terminal, CraftOS after exit)
if shell.setPath and not (":" .. shell.path() .. ":"):find(":/os/bin:", 1, true) then
  shell.setPath(shell.path() .. ":/os/bin")
end
if shell.setAlias and fs.isDir("/os/bin") then
  for _, f in ipairs(fs.list("/os/bin")) do
    if f:sub(-4) == ".lua" then shell.setAlias(f:sub(1, -5), "/os/bin/" .. f) end
  end
end

local ok, err = pcall(dofile, "/os/pocket/main.lua")
term.redirect(term.native())
if not ok then
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.red)
  term.clear()
  term.setCursorPos(1, 1)
  print("WardenOS Pocket error: " .. tostring(err))
  term.setTextColor(colors.white)
  print("Dropped to CraftOS. Reboot to try again.")
end
