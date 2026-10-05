-- snake: run the App Store app "snake" in the terminal (the same program as in its window)
local ok, app = pcall(dofile, "/os/apps/snake.lua")
if not ok or type(app) ~= "table" or type(app.main) ~= "function" then
  printError("snake: the app is missing or broken - reinstall it with: apt install snake")
  return
end
app.main(...)
