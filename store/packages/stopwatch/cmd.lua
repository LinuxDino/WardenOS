-- stopwatch: run the App Store app "stopwatch" in the terminal (the same program as in its window)
local ok, app = pcall(dofile, "/os/apps/stopwatch.lua")
if not ok or type(app) ~= "table" or type(app.main) ~= "function" then
  printError("stopwatch: the app is missing or broken - reinstall it with: apt install stopwatch")
  return
end
app.main(...)
