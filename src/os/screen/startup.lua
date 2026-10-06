-- Warden Screen startup. The installer ("install screen") copies this file to /startup.lua.
-- Runs /os/screen/client.lua and restarts it if it ever crashes; Ctrl+T stops it (reboot starts it again).
while true do
  local ok, err = pcall(dofile, "/os/screen/client.lua")
  if ok then return end                         -- not set up: the client printed why
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
  if tostring(err):find("Terminated") then
    print("Warden Screen stopped. Type 'reboot' to start it again.")
    return
  end
  printError("Warden Screen crashed: " .. tostring(err))
  print("Restarting in 5 seconds (Ctrl+T to stop)...")
  local okS = pcall(sleep, 5)
  if not okS then return end
end
