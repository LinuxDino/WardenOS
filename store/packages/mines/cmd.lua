-- mines: run the App Store app "mines" in the terminal (the same program as in its window)
local ok, app = pcall(dofile, "/os/apps/mines.lua")
if not ok or type(app) ~= "table" or type(app.main) ~= "function" then
  printError("mines: the app is missing or broken - reinstall it with: apt install mines")
  return
end
app.main(...)
