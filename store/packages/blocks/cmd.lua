-- blocks: run the App Store app "blocks" in the terminal (the same program as in its window)
local ok, app = pcall(dofile, "/os/apps/blocks.lua")
if not ok or type(app) ~= "table" or type(app.main) ~= "function" then
  printError("blocks: the app is missing or broken - reinstall it with: apt install blocks")
  return
end
app.main(...)
