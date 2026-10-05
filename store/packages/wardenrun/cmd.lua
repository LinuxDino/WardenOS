-- wardenrun: run the App Store app "wardenrun" in the terminal (the same program as in its window)
local ok, app = pcall(dofile, "/os/apps/wardenrun.lua")
if not ok or type(app) ~= "table" or type(app.main) ~= "function" then
  printError("wardenrun: the app is missing or broken - reinstall it with: apt install wardenrun")
  return
end
app.main(...)
