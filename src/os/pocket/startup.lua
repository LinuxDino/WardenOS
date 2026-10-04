-- WardenOS Pocket: starts the pocket UI (this file is /startup.lua on a pocket computer)
rawset(_G, "shell", shell)

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
