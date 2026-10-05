-- notes: run the App Store app "notes" in the terminal (the same program as in its window)
local ok, app = pcall(dofile, "/os/apps/notes.lua")
if not ok or type(app) ~= "table" or type(app.main) ~= "function" then
  printError("notes: the app is missing or broken - reinstall it with: apt install notes")
  return
end
app.main(...)
