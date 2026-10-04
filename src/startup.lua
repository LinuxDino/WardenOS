-- WardenOS boot: boot menu -> WardenOS or plain CraftOS
rawset(_G, "shell", shell)

-- WardenOS terminal commands (btop, neofetch, ...) live in /os/bin
if shell.setPath and not (":" .. shell.path() .. ":"):find(":/os/bin:", 1, true) then
  shell.setPath(shell.path() .. ":/os/bin")
end

local ok, choice = pcall(dofile, "/os/boot.lua")
term.redirect(term.native())
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)

if not ok then
  term.setTextColor(colors.red)
  print("Boot menu error: " .. tostring(choice))
  term.setTextColor(colors.white)
  print("Starting CraftOS.")
  return
end

if choice == "wardenos" then
  print("WardenOS booting...")
  local ok2, err = pcall(dofile, "/os/kernel.lua")
  if not ok2 then
    term.redirect(term.native())
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.red)
    print("Kernel error: " .. tostring(err))
    term.setTextColor(colors.white)
    print("Dropped to CraftOS.")
  end
else
  print("CraftOS")
end
