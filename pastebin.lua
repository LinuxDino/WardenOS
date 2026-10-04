-- WardenOS loader (this is what lives on Pastebin: CeQfPV78).
-- It never needs updating: it always downloads and runs the newest installer from GitHub.
--   pastebin get CeQfPV78 install
--   install            install WardenOS (on a turtle: the drone agent)
--   install update     update, keeps accounts, settings and files
local URL = "https://raw.githubusercontent.com/LinuxDino/WardenOS/main/install.lua"

if not http then
  printError("The http API is disabled.")
  print("Enable http in the CC: Tweaked config (server owner), then try again.")
  return
end
print("Getting the WardenOS installer from GitHub...")
local h, err = http.get(URL .. "?t=" .. os.epoch("utc"))
if not h then
  printError("Download failed: " .. tostring(err))
  print("Nothing was changed. Check your connection and try again.")
  return
end
local src = h.readAll()
h.close()
local fn, lerr = load(src, "=install.lua", "t", setmetatable({ shell = shell }, { __index = _G }))
if not fn then
  printError("The downloaded installer is broken: " .. tostring(lerr))
  return
end
fn(...)
