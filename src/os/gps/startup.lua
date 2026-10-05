-- Warden GPS host startup. The installer ("GPS host") copies this file to /startup.lua.
-- Runs /os/gps/host.lua and restarts it if it ever crashes; Ctrl+T stops it (reboot starts it again).
while true do
  local ok, err = pcall(dofile, "/os/gps/host.lua")
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
  if ok then return end
  if tostring(err):find("Terminated") then
    print("Warden GPS host stopped. Type 'reboot' to start it again.")
    return
  end
  printError("Warden GPS host crashed: " .. tostring(err))
  print("Restarting in 5 seconds (Ctrl+T to stop)...")
  local okS = pcall(sleep, 5)
  if not okS then return end
end
