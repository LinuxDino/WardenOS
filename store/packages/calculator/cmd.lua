-- calculator: run the App Store app "calculator" in the terminal (the same program as in its window)
local ok, app = pcall(dofile, "/os/apps/calculator.lua")
if not ok or type(app) ~= "table" or type(app.main) ~= "function" then
  printError("calculator: the app is missing or broken - reinstall it with: apt install calculator")
  return
end
app.main(...)
