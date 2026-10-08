-- WardenOS Recovery: shown by /startup.lua when WardenOS can't start (or picked in the boot menu).
-- Plain CC APIs only (no WardenOS libraries), so it still works when other files are damaged.
--
--   R.run(info)        the recovery screen; info = { stage, err, trace } (all optional). Returns "safe" (start
--                      WardenOS in safe mode), "craftos" or "boot" (start normally); Repair and Restart reboot.
--   R.report(info)     write /os/crash.txt (also done by R.run), returns its text
--   R.hint(err, trace) a plain-language explanation of an error message
--   R.check()          damaged or missing WardenOS files: { { path, why }, ... }
--   R.critical()       the same for the files needed to boot (fast; /startup.lua runs it on every boot)
local R = {}
local CRASH = "/os/crash.txt"
local LIST = "/os/files.dat"
local CRITICAL = { "/os/boot.lua", "/os/kernel.lua", "/os/config.lua", "/os/lib/screen.lua", "/os/lib/bigfont.lua",
                   "/os/lib/login.lua", "/os/lib/settings.lua", "/os/lib/sha256.lua" }

local function readTable(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  if not f then return nil end
  local d = textutils.unserialize(f.readAll() or "")
  f.close()
  return type(d) == "table" and d or nil
end

local function config()
  local ok, c = pcall(dofile, "/os/config.lua")
  if ok and type(c) == "table" then return c end
  return {}
end

---------------------------------------------------------------- checks
local function checkFile(path)
  if not fs.exists(path) then return "missing" end
  if fs.isDir(path) then return "is a folder" end
  if path:sub(-4) == ".lua" then
    local f = fs.open(path, "r")
    if not f then return "can't be read" end
    local src = f.readAll() or ""
    f.close()
    local fn, err = load(src, "=" .. path, "t", {})   -- compile only, nothing runs
    if not fn then return "damaged: " .. tostring(err) end
  end
  return nil
end

function R.critical()
  local bad = {}
  for _, p in ipairs(CRITICAL) do
    local why = checkFile(p)
    if why then bad[#bad + 1] = { p, why } end
  end
  return bad
end

function R.check()
  local list = readTable(LIST)
  local files = list and type(list.files) == "table" and list.files or CRITICAL
  local bad, n = {}, 0
  for _, p in ipairs(files) do
    if type(p) == "string" and p ~= "/startup.lua" then
      local why = checkFile(p)
      if why then bad[#bad + 1] = { p, why } end
    end
    n = n + 1
    if n % 20 == 0 then                           -- many files: don't run too long without yielding
      os.queueEvent("recovery_yield")
      os.pullEvent("recovery_yield")
    end
  end
  return bad
end

---------------------------------------------------------------- explanation
function R.hint(err, trace)
  local e = (tostring(err or "") .. "\n" .. tostring(trace or "")):lower()
  local free = fs.getFreeSpace and fs.getFreeSpace("/") or math.huge
  if e:find("out of space") or free < 2000 then
    return "The computer's disk is (almost) full. Delete big files (Files app or CraftOS 'delete'), " ..
           "e.g. old maps in /os/map or /os/tradeview/cache, then Restart."
  end
  if e:find("too long without yielding") then
    return "Something ran too long and the game stopped it. Often a huge map or a slow peripheral. " ..
           "Try Safe mode; if that works, the problem is a monitor, drones or another background part."
  end
  if e:find("monitor") or e:find("settextscale") or e:find("getsize") then
    return "The monitor is not working as expected (a mod update can change it). Try Reset display " ..
           "settings or Safe mode, or check the monitor blocks."
  end
  if e:find("missing") or e:find("no such file") or e:find("not found") or e:find("cannot open") then
    return "A WardenOS file is missing. Repair downloads it again; accounts, settings and your files stay."
  end
  if e:find("unexpected symbol") or e:find("expected") or e:find("unfinished") or e:find("damaged")
      or e:find("malformed") then
    return "A WardenOS file is damaged (cut off or changed). Repair downloads it again; accounts, " ..
           "settings and your files stay."
  end
  if e:find("http") then
    return "The internet (http API) is disabled or blocked. Ask the server owner to enable http in the " ..
           "CC: Tweaked config. WardenOS itself still starts without it."
  end
  if e:find("attempt to") or e:find("nil value") then
    return "WardenOS got a value it did not expect. Usually a damaged file or a block/peripheral that " ..
           "changed after a mod update. Try Safe mode, then Repair."
  end
  return "Try Restart first. If it happens again: Safe mode, then Repair (keeps accounts and your files)."
end

---------------------------------------------------------------- crash report
function R.report(info)
  info = info or {}
  local c = config()
  local lines = {
    "WardenOS crash report",
    "time: " .. (os.date and os.date("%Y-%m-%d %H:%M:%S") or tostring(os.epoch("utc"))) ..
      "   game day " .. tostring(os.day()) .. " " .. textutils.formatTime(os.time(), true),
    "WardenOS: " .. tostring(c.version or "?") .. "   computer #" .. os.getComputerID() ..
      (os.getComputerLabel() and (" (" .. os.getComputerLabel() .. ")") or ""),
    "CC: " .. tostring(_HOST or "?"),
    "stage: " .. tostring(info.stage or "?"),
    "",
    "error:",
    tostring(info.err or "(none)"),
  }
  if info.trace and tostring(info.trace) ~= "" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "traceback:"
    lines[#lines + 1] = tostring(info.trace)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "peripherals:"
  for _, n in ipairs(peripheral.getNames()) do
    lines[#lines + 1] = "  " .. n .. ": " .. table.concat({ peripheral.getType(n) }, ", ")
  end
  local free = fs.getFreeSpace and fs.getFreeSpace("/")
  lines[#lines + 1] = "free disk: " .. tostring(free)
  local text = table.concat(lines, "\n")
  pcall(function()
    if not fs.isDir("/os") then fs.makeDir("/os") end
    local f = fs.open(CRASH, "w")
    if f then f.write(text .. "\n") f.close() end
  end)
  return text
end

---------------------------------------------------------------- screen helpers
local t = term.native()
local W, H = t.getSize()
local colour = t.isColour()
local function col(c, plain) return colour and c or (plain or colors.white) end

local function wrap(s, width)
  local out = {}
  for para in (tostring(s) .. "\n"):gmatch("(.-)\n") do
    if para == "" then out[#out + 1] = "" end
    while #para > 0 do
      if #para <= width then out[#out + 1] = para break end
      local cut = para:sub(1, width):match("^.*()%s") or (width + 1)
      if cut <= 1 then cut = width + 1 end
      out[#out + 1] = para:sub(1, cut - 1)
      para = para:sub(cut):gsub("^%s+", "")
    end
  end
  return out
end

local function put(x, y, s, fg, bg)
  if y < 1 or y > H then return end
  t.setCursorPos(x, y)
  t.setTextColor(fg or colors.white)
  t.setBackgroundColor(bg or colors.black)
  t.write(tostring(s):sub(1, math.max(0, W - x + 1)))
end

local function header(title)
  t.setBackgroundColor(colors.black)
  t.clear()
  t.setCursorPos(1, 1)
  t.setBackgroundColor(col(colors.red, colors.white))
  t.clearLine()
  put(2, 1, title, col(colors.white, colors.black), col(colors.red, colors.white))
end

-- the monitor (if any) says where to look
local function noteMonitors()
  for _, n in ipairs(peripheral.getNames()) do
    pcall(function()
      if peripheral.getType(n) == "monitor" then
        local m = peripheral.wrap(n)
        m.setTextScale(1)
        m.setBackgroundColor(colors.black)
        m.clear()
        m.setCursorPos(2, 2)
        m.setTextColor(colors.red)
        m.write("WardenOS Recovery")
        m.setCursorPos(2, 3)
        m.setTextColor(colors.white)
        m.write("Look at the computer screen")
      end
    end)
  end
end

-- a scrollable text page; any key but up/down/page keys goes back
local function viewText(title, text)
  local lines = wrap(text, W - 1)
  local top = 1
  while true do
    header(title)
    for i = 1, H - 2 do put(1, i + 1, lines[top + i - 1] or "", colors.white) end
    put(1, H, ("UP/DOWN scroll  other key: back"):sub(1, W), col(colors.lightGray))
    local e, k = os.pullEvent()
    if e == "key" then
      if k == keys.up then top = math.max(1, top - 1)
      elseif k == keys.down then top = math.min(math.max(1, #lines - (H - 3)), top + 1)
      elseif k == keys.pageUp then top = math.max(1, top - (H - 3))
      elseif k == keys.pageDown then top = math.min(math.max(1, #lines - (H - 3)), top + (H - 3))
      else return end
    elseif e == "mouse_scroll" then
      top = math.max(1, math.min(math.max(1, #lines - (H - 3)), top + k))
    elseif e == "mouse_click" then
      return
    end
  end
end

local function message(title, text, fg)
  header(title)
  local y = 3
  for _, l in ipairs(wrap(text, W - 2)) do put(2, y, l, fg or colors.white) y = y + 1 end
  put(2, H, "Press any key", col(colors.lightGray))
  os.pullEvent("key")
end

---------------------------------------------------------------- actions
local function repair()
  header("Repair WardenOS")
  t.setCursorPos(1, 3)
  t.setTextColor(colors.white)
  t.setBackgroundColor(colors.black)
  if not http then
    message("Repair WardenOS", "The http API is disabled, so WardenOS can't be downloaded. Ask the server owner " ..
      "to enable http in the CC: Tweaked config.", col(colors.red))
    return
  end
  local c = config()
  local repo = type(c.repo) == "string" and c.repo or "LinuxDino/WardenOS"
  local branch = type(c.branch) == "string" and c.branch or "main"
  print("Downloading the WardenOS installer from GitHub...")
  local h, err = http.get(("https://raw.githubusercontent.com/%s/%s/install.lua?t=%d"):format(repo, branch,
    os.epoch("utc")))
  if not h then
    message("Repair WardenOS", "Download failed: " .. tostring(err) .. "\n\nCheck the internet and try again.",
      col(colors.red))
    return
  end
  local src = h.readAll()
  h.close()
  local fn, lerr = load(src or "", "=install.lua", "t", setmetatable({ shell = shell }, { __index = _G }))
  if not fn then
    message("Repair WardenOS", "The downloaded installer is broken: " .. tostring(lerr), col(colors.red))
    return
  end
  local ok, e = pcall(fn, "update", branch, "-y")   -- reinstalls every file, keeps accounts and settings; reboots
  message("Repair WardenOS", ok and "The installer finished. Press a key to restart." or
    ("Repair failed: " .. tostring(e)), ok and col(colors.lime) or col(colors.red))
  os.reboot()
end

local function resetDisplay()
  local moved = {}
  if fs.exists("/os/settings.lua") then
    local f = fs.open("/os/settings.lua", "r")
    local data = f and f.readAll() or ""
    if f then f.close() end
    local g = fs.open("/os/settings.bak", "w")
    if g then g.write(data) g.close() end
    fs.delete("/os/settings.lua")
    moved[#moved + 1] = "desktop settings (saved as /os/settings.bak)"
  end
  if fs.exists("/os/boot.cfg") then fs.delete("/os/boot.cfg") moved[#moved + 1] = "boot menu settings" end
  message("Reset display settings", #moved > 0 and ("Reset: " .. table.concat(moved, ", ") ..
    ". Accounts and your files are not touched. Restart to try again.") or "There was nothing to reset.")
end

local function checkFiles()
  header("Check files")
  put(2, 3, "Checking...", colors.white)
  local bad = R.check()
  if #bad == 0 then
    message("Check files", "All WardenOS files are there and readable.", col(colors.lime))
    return false
  end
  local lines = { #bad .. " file(s) missing or damaged:" }
  for i, b in ipairs(bad) do
    if i > 12 then lines[#lines + 1] = "... and " .. (#bad - 12) .. " more" break end
    lines[#lines + 1] = b[1] .. " - " .. b[2]
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Repair downloads them again (accounts, settings and your files stay)."
  viewText("Check files", table.concat(lines, "\n"))
  return true
end

---------------------------------------------------------------- the menu
function R.run(info)
  info = info or {}
  local report
  if info.err then
    report = R.report(info)
  else                                            -- opened from the boot menu: show the last report, if any
    local f = fs.exists(CRASH) and fs.open(CRASH, "r")
    report = f and f.readAll() or "No error has been recorded."
    if f then f.close() end
  end
  noteMonitors()
  local items = {
    { "Restart", "try again" },
    { "Repair", "download WardenOS again" },
    { "Safe mode", "no monitor, no extras" },
    { "Check files" },
    { "Reset display settings" },
    { "Show full error" },
    { "CraftOS shell" },
  }
  if info.stage == "menu" then table.insert(items, 1, { "Start WardenOS", "normal start" }) end
  local sel = 1
  while true do
    header("WardenOS Recovery")
    local y = 3
    if info.err then
      put(2, y, info.stage == "loop" and "WardenOS keeps failing to start." or "WardenOS could not start.",
        col(colors.yellow)) y = y + 1
      local errLines = wrap(tostring(info.err), W - 2)
      for i = 1, math.min(#errLines, H >= 19 and 3 or 2) do put(2, y, errLines[i], col(colors.red)) y = y + 1 end
      local hint = wrap(R.hint(info.err, info.trace), W - 2)
      local room = math.max(1, H - y - #items - 2)
      for i = 1, math.min(#hint, room) do put(2, y, hint[i], col(colors.lightGray)) y = y + 1 end
    else
      put(2, y, "Pick what to do.", col(colors.lightGray)) y = y + 1
    end
    y = math.min(y + 1, math.max(3, H - #items - 1))
    local zones = {}
    for i, it in ipairs(items) do
      local on = i == sel
      local label = (" " .. i .. " " .. it[1])
      if it[2] and #label + #it[2] + 4 <= W - 2 then label = label .. "  (" .. it[2] .. ")" end
      label = (label .. string.rep(" ", W)):sub(1, W - 2)
      put(2, y, label, on and col(colors.black) or colors.white, on and col(colors.cyan, colors.white) or colors.black)
      zones[i] = y
      y = y + 1
    end
    put(2, H, ("Report: " .. CRASH):sub(1, W - 2), col(colors.gray, colors.white))

    local choice
    local e, a, b, c = os.pullEvent()
    if e == "key" then
      if a == keys.up then sel = (sel - 2) % #items + 1
      elseif a == keys.down then sel = sel % #items + 1
      elseif a == keys.enter then choice = items[sel][1] end
    elseif e == "char" and tonumber(a) and items[tonumber(a)] then
      choice = items[tonumber(a)][1]
    elseif e == "mouse_click" then
      for i, zy in pairs(zones) do if c == zy then choice = items[i][1] end end
    end

    if choice == "Start WardenOS" then return "boot"
    elseif choice == "Restart" then os.reboot()
    elseif choice == "Safe mode" then return "safe"
    elseif choice == "CraftOS shell" then return "craftos"
    elseif choice then
      local ok, e = pcall(function()                -- an action that fails shows why, the menu stays
        if choice == "Repair" then repair()
        elseif choice == "Check files" then
          if checkFiles() then
            for i, it in ipairs(items) do if it[1] == "Repair" then sel = i end end
          end
        elseif choice == "Reset display settings" then resetDisplay()
        elseif choice == "Show full error" then viewText("Error report", report) end
      end)
      if not ok then
        if e == "Terminated" then error(e, 0) end
        message(choice, "That did not work: " .. tostring(e), col(colors.red))
      end
    end
  end
end

return R
