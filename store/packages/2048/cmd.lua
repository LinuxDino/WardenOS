-- 2048: run the App Store app "2048" in the terminal (the same program as in its window)
local ok, app = pcall(dofile, "/os/apps/2048.lua")
if not ok or type(app) ~= "table" or type(app.main) ~= "function" then
  printError("2048: the app is missing or broken - reinstall it with: apt install 2048")
  return
end
app.main(...)
