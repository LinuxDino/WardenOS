-- WardenOS installer for CC: Tweaked (https://tweaked.cc)
-- Downloads WardenOS from GitHub, then runs the setup wizard.
--
--   install            clean install (wizard: terms, account, full erase)
--   install update     update to the latest version, keeps accounts, settings and your files
--   install <branch>   use another branch of the repository (works with "update" too)
--   install update -y  update without asking (used by Settings > Update now)
--   install gps        set this computer up as a Warden GPS host (also: G on the welcome screen)
--   install screen     set this computer up as a Warden Screen: one page of your main WardenOS computer, live on
--                      a monitor (also: S on the welcome screen)
--   install desktop    the WardenOS desktop setup, also on a computer that is a GPS host or screen now
--
-- On a turtle it installs the WardenOS drone agent instead (no erase, no desktop).
-- On an Advanced Pocket Computer it installs WardenOS Pocket (no erase, no desktop).
-- On a standard (non-Advanced) computer it offers the Warden GPS host (no erase, no desktop); `install screen`
-- makes it a Warden Screen instead.

local REPO, BRANCH = "LinuxDino/WardenOS", "main"
local TOS_VERSION, STEPS = "1.0", 5
local ABORT = {}
local erased = false

local mode, branch, yes = "install", BRANCH, false
local gpsArg, desktopArg, screenArg = false, false, false
for _, a in ipairs({ ... }) do
  if a == "update" then mode = "update"
  elseif a == "-y" then yes = true
  elseif a == "gps" then gpsArg = true
  elseif a == "desktop" then desktopArg = true
  elseif a == "screen" then screenArg = true
  elseif a ~= "" then branch = a end
end
local RAW = "https://raw.githubusercontent.com/" .. REPO .. "/" .. branch .. "/"

---------------------------------------------------------------- checks
if not http then
  printError("The http API is disabled.")
  print("Enable http in the CC: Tweaked config (server owner), then try again.")
  return
end
local isTurtle = turtle ~= nil
local isPocket = pocket ~= nil and not isTurtle
local isColour = term.isColour()
-- Warden GPS host: a standard computer can only be one; a dedicated host stays one unless "install desktop"
local GPS_CFG = "/os/gps/host.cfg"
local function readGpsCfg()
  if not fs.exists(GPS_CFG) then return nil end
  local f = fs.open(GPS_CFG, "r")
  if not f then return nil end
  local d = textutils.unserialize(f.readAll() or "")
  f.close()
  if type(d) == "table" and tonumber(d.x) and tonumber(d.y) and tonumber(d.z) then return d end
  return nil
end
local gpsCfg = readGpsCfg()
local gpsDedicated = gpsCfg ~= nil and gpsCfg.mode ~= "desktop" and not fs.exists("/os/kernel.lua")
-- Warden Screen: a dedicated screen stays one (re-running the installer updates it) unless "install desktop" / "gps"
local SCREEN_CFG = "/os/screen/screen.cfg"
local function readScreenCfg()
  if not fs.exists(SCREEN_CFG) then return nil end
  local f = fs.open(SCREEN_CFG, "r")
  if not f then return nil end
  local d = textutils.unserialize(f.readAll() or "")
  f.close()
  if type(d) == "table" and type(d.page) == "string" then return d end
  return nil
end
local screenCfg = readScreenCfg()
local screenDedicated = screenCfg ~= nil and not fs.exists("/os/kernel.lua")
local screenOnly = not isTurtle and not isPocket
  and (screenArg or (screenDedicated and not desktopArg and not gpsArg))
-- pockets install even without colour/touch (the pocket UI also works with the keyboard)
local gpsOnly = not isTurtle and not isPocket and not screenOnly
  and (gpsArg or not isColour or (gpsDedicated and not desktopArg))
if gpsOnly and not isColour and desktopArg then
  printError("The WardenOS desktop needs an Advanced Computer (gold).")
  print("This computer can be a Warden GPS host (run the installer without 'desktop') or a Warden Screen ('install screen').")
  return
end

---------------------------------------------------------------- download (nothing is changed before this succeeds)
local FILES, MANIFEST = {}, nil

local function fetch(path)
  local url = RAW .. path .. "?t=" .. os.epoch("utc")
  local last
  for try = 1, 3 do
    local h, err, resp = http.get(url, nil, true)
    if h then
      local code = h.getResponseCode()
      local body = h.readAll()
      h.close()
      if code == 200 and body then return body end
      last = "HTTP " .. tostring(code)
    else
      if resp then
        last = "HTTP " .. tostring(resp.getResponseCode())
        resp.close()
      else
        last = tostring(err or "request failed")
      end
    end
    if try < 3 then sleep(try) end
  end
  error(("could not download %s (%s)"):format(path, last), 0)
end

local function download()
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  term.setTextColor(colors.cyan)
  print(isTurtle and "WardenOS drone installer" or (isPocket and "WardenOS Pocket installer"
    or (gpsOnly and "Warden GPS installer" or (screenOnly and "Warden Screen installer" or "WardenOS installer"))))
  term.setTextColor(colors.lightGray)
  print(REPO .. " @ " .. branch)
  print()

  local fn, err = load(fetch("manifest.lua"), "=manifest.lua", "t", {})
  if not fn then error("broken manifest: " .. tostring(err), 0) end
  local ok, m = pcall(fn)
  local list = ok and type(m) == "table" and (isTurtle and m.drone or (isPocket and m.pocket
    or (gpsOnly and m.gps or (screenOnly and m.screen or m.files))))
  if type(list) ~= "table" or #list == 0 then
    error("broken manifest", 0)
  end

  local _, y = term.getCursorPos()
  local w = term.getSize()
  for i, path in ipairs(list) do
    if type(path) ~= "string" or path:find("%.%.") or not path:match("^[%w_%-%./]+$") then
      error("bad path in manifest: " .. tostring(path), 0)
    end
    term.setCursorPos(1, y)
    term.clearLine()
    term.setTextColor(colors.white)
    term.write((("[%d/%d] %s"):format(i, #list, path)):sub(1, w))
    local body = fetch("src/" .. path)
    if path:sub(-4) == ".lua" then
      local f, lerr = load(body, "=" .. path, "t", {})      -- syntax check only, nothing runs
      if not f then error("downloaded file is broken: " .. tostring(lerr), 0) end
    end
    FILES["/" .. path] = body
  end
  term.setCursorPos(1, y)
  term.clearLine()
  term.setTextColor(colors.green)
  print(("Downloaded %d files (v%s)"):format(#list, tostring(m.version)))
  term.setTextColor(colors.white)
  MANIFEST = m
end

local okd, derr = pcall(download)
if not okd then
  term.setTextColor(colors.white)
  print()
  if tostring(derr):find("Terminated") then
    print("Cancelled. Nothing was changed.")
  else
    printError("Download failed: " .. tostring(derr))
    print("Nothing was changed. Check your connection and try again.")
  end
  return
end
local OS_VERSION = tostring(MANIFEST.version)

---------------------------------------------------------------- turtle: drone agent
if isTurtle then
  local function droneInstall()
    local owner
    local hadDesktop = fs.exists("/os/kernel.lua")    -- an old installer put the full desktop on this turtle
    if mode ~= "update" and not yes then
      print()
      if hadDesktop then
        print("This turtle has the WardenOS desktop. It is removed and the drone agent is installed instead. Other files stay.")
      else
        print("This turtle becomes a WardenOS drone. Its startup.lua is replaced (the old one is kept as startup.old.lua). Other files stay.")
      end
      print()
      print("Owner = the computer that controls it.")
      print("Press Enter to claim it later in the Drones app.")
      write("Owner computer ID: ")
      local id = read()
      owner = tonumber(id)
      if id ~= "" and not owner then print("Not a number, claim it later in the Drones app.") end
      write("Install? (y/n) ")
      if read():lower() ~= "y" then
        print("Cancelled. Nothing was changed.")
        return
      end
    end
    if hadDesktop then
      -- remove only WardenOS desktop files (they can't run on a turtle); the agent is written below
      for _, p in ipairs(MANIFEST.files) do
        local path = "/" .. p
        if path ~= "/startup.lua" and not FILES[path] and fs.exists(path) and not fs.isDir(path) then fs.delete(path) end
      end
      for _, p in ipairs({ "/os/users.dat", "/os/settings.lua", "/os/boot.cfg", "/os/files.dat" }) do
        if fs.exists(p) then fs.delete(p) end
      end
      for _, d in ipairs({ "/os/apps", "/os/lib", "/os/pocket", "/os/bin", "/os/man", "/os/gps", "/os/screen" }) do
        if fs.isDir(d) and #fs.list(d) == 0 then fs.delete(d) end
      end
    elseif fs.exists("/startup.lua") and not fs.exists("/os/drone/agent.lua") and not fs.exists("/startup.old.lua") then
      fs.copy("/startup.lua", "/startup.old.lua")
    end
    local function put(path, data)
      local dir = fs.getDir(path)
      if dir ~= "" then fs.makeDir(dir) end
      local f = assert(fs.open(path, "w"))
      f.write(data)
      f.close()
    end
    for path, data in pairs(FILES) do
      put(path == "/os/drone/startup.lua" and "/startup.lua" or path, data)
    end
    if owner and not fs.exists("/os/drone/config") then
      put("/os/drone/config", textutils.serialize({ owner = owner }))
    end
    if not os.getComputerLabel() then os.setComputerLabel("drone-" .. os.getComputerID()) end
    print("WardenOS drone " .. OS_VERSION .. " installed. Rebooting...")
    sleep(1)
    os.reboot()
  end
  local ok, err = pcall(droneInstall)
  if not ok then
    if tostring(err):find("Terminated") then print("Cancelled.") else printError("Install failed: " .. tostring(err)) end
  end
  return
end

---------------------------------------------------------------- pocket computer: WardenOS Pocket
if isPocket then
  local function pocketInstall()
    local hadDesktop = fs.exists("/os/kernel.lua")    -- an old installer put the full desktop on this pocket
    if mode ~= "update" and not yes then
      print()
      if hadDesktop then
        print("This pocket computer has the WardenOS desktop. It is replaced by WardenOS Pocket. Other files stay.")
      else
        print("This pocket computer gets WardenOS Pocket. Its startup.lua is replaced (the old one is kept as startup.old.lua). Other files stay.")
      end
      print()
      write("Install? (y/n) ")
      if read():lower() ~= "y" then
        print("Cancelled. Nothing was changed.")
        return
      end
    end
    if hadDesktop then
      -- remove only WardenOS desktop files (the pocket UI replaces them); pocket files are written below
      for _, p in ipairs(MANIFEST.files) do
        local path = "/" .. p
        if path ~= "/startup.lua" and not FILES[path] and fs.exists(path) and not fs.isDir(path) then fs.delete(path) end
      end
      for _, p in ipairs({ "/os/users.dat", "/os/settings.lua", "/os/boot.cfg", "/os/files.dat" }) do
        if fs.exists(p) then fs.delete(p) end
      end
      for _, d in ipairs({ "/os/apps", "/os/lib", "/os/drone", "/os/bin", "/os/gps", "/os/screen" }) do
        if fs.isDir(d) and #fs.list(d) == 0 then fs.delete(d) end
      end
    elseif fs.exists("/startup.lua") and not fs.exists("/os/pocket/main.lua") and not fs.exists("/startup.old.lua") then
      fs.copy("/startup.lua", "/startup.old.lua")
    end
    local function put(path, data)
      local dir = fs.getDir(path)
      if dir ~= "" then fs.makeDir(dir) end
      local f = assert(fs.open(path, "w"))
      f.write(data)
      f.close()
    end
    for path, data in pairs(FILES) do
      put(path == "/os/pocket/startup.lua" and "/startup.lua" or path, data)
    end
    if fs.exists("/os/pocket/startup.lua") then fs.delete("/os/pocket/startup.lua") end   -- left by a desktop install
    if not os.getComputerLabel() then os.setComputerLabel("pocket-" .. os.getComputerID()) end
    print("WardenOS Pocket " .. OS_VERSION .. " installed. Rebooting...")
    sleep(1)
    os.reboot()
  end
  local ok, err = pcall(pocketInstall)
  if not ok then
    if tostring(err):find("Terminated") then print("Cancelled.") else printError("Install failed: " .. tostring(err)) end
  end
  return
end

---------------------------------------------------------------- Warden GPS host (any computer with a wireless modem)
-- plain print/read, so it works on a standard computer too; also reached from the desktop welcome screen (G)
local function gpsInstall()
  local hasDesktop = fs.exists("/os/kernel.lua")
  local function say(s, c)
    term.setTextColor(isColour and c or colors.white)
    print(s)
    term.setTextColor(colors.white)
  end
  local function ask(q)
    term.setTextColor(colors.white)
    write(q)
    return read()
  end
  local function yesNo(q, default)
    say(q .. (default and " (Y/n)" or " (y/n)"), colors.white)
    while true do
      local a = ask("> "):lower()
      if a == "" and default ~= nil then return default end
      if a == "y" or a == "yes" then return true end
      if a == "n" or a == "no" then return false end
    end
  end
  local function cancel()
    say("Cancelled. Nothing was changed.", colors.lightGray)
    error(ABORT, 0)
  end
  local function wirelessModems()
    local out = {}
    for _, n in ipairs(peripheral.getNames()) do
      if peripheral.getType(n) == "modem" then
        local ok, w = pcall(peripheral.call, n, "isWireless")
        if ok and w then out[#out + 1] = n end
      end
    end
    return out
  end

  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  say("Warden GPS host setup", colors.cyan)
  say("A GPS host tells turtles, pockets and computers where they are. You need 4 or more hosts, not all in one flat plane.",
      colors.lightGray)
  if not isColour and not gpsArg then
    say("(The WardenOS desktop needs an Advanced Computer; this computer can be a GPS host. For a Warden Screen run: install screen)", colors.lightGray)
  end
  print()

  local cfg
  local old = gpsCfg
  if old and (yes or mode == "update") then
    cfg = { x = math.floor(old.x), y = math.floor(old.y), z = math.floor(old.z), mode = old.mode == "desktop" and "desktop" or "dedicated" }
  elseif old then
    say(("This computer is a Warden GPS host at %d %d %d (%s)."):format(old.x, old.y, old.z,
        old.mode == "desktop" and "with the desktop" or "dedicated"), colors.yellow)
    if yesNo("Keep this position and update?", true) then
      cfg = { x = math.floor(old.x), y = math.floor(old.y), z = math.floor(old.z), mode = old.mode == "desktop" and "desktop" or "dedicated" }
    end
  end

  if not cfg then
    cfg = { mode = "dedicated" }
    if hasDesktop then
      say("WardenOS desktop is installed here.", colors.yellow)
      say(" B  background: keep the desktop, it also answers GPS", colors.white)
      say(" D  dedicated: remove the desktop (accounts, settings), run only the GPS host", colors.white)
      say(" Q  cancel", colors.white)
      while true do
        local a = ask("B/D/Q> "):lower()
        if a == "b" then cfg.mode = "desktop" break end
        if a == "d" then cfg.mode = "dedicated" break end
        if a == "q" then cancel() end
      end
    end

    local modems = wirelessModems()
    if #modems == 0 then
      say("No wireless or ender modem found. Attach one (ender modems reach everywhere); the host waits for it.",
          colors.red)
    end

    -- the position: from other hosts, from an old `gps host` startup, or typed in
    local guess
    if #modems > 0 and FILES["/os/lib/gpsx.lua"] then
      if yesNo("Detect this position from GPS hosts that already run?", true) then
        say("Locating...", colors.lightGray)
        local okg, gx = pcall(function() return assert(load(FILES["/os/lib/gpsx.lua"], "=gpsx.lua", "t", _G))() end)
        local r, why
        if okg and type(gx) == "table" then r, why = gx.locate({ samples = 3, timeout = 2 }) else why = tostring(gx) end
        if r and r.quality ~= "noisy" then
          guess = { r.x, r.y, r.z, ("found with %d hosts, %s fix"):format(r.hosts, r.quality) }
        else
          say("No reliable fix: " .. tostring(r and "the hosts disagree" or why), colors.yellow)
        end
      end
    end
    if not guess and fs.exists("/startup.lua") then
      local f = fs.open("/startup.lua", "r")
      local src = f and f.readAll() or ""
      if f then f.close() end
      local x, y, z = src:match("[\"']gps[\"']%s*,%s*[\"']host[\"']%s*,%s*[\"']?(%-?%d+)[\"']?%s*,%s*[\"']?(%-?%d+)[\"']?%s*,%s*[\"']?(%-?%d+)")
      if x then guess = { tonumber(x), tonumber(y), tonumber(z), "from the old gps host startup" } end
    end
    if guess and not yesNo(("Use %d %d %d (%s)?"):format(guess[1], guess[2], guess[3], guess[4]), true) then
      guess = nil
    end
    if guess then
      cfg.x, cfg.y, cfg.z = guess[1], guess[2], guess[3]
    else
      say("Type the position of THIS COMPUTER's block: look at it, press F3, read 'Targeted Block'.", colors.lightGray)
      while true do
        local a = ask("x y z> "):gsub(",", " ")
        if a:lower() == "q" then cancel() end
        local x, y, z = a:match("^%s*(%-?%d+)%s+(%-?%d+)%s+(%-?%d+)%s*$")
        if x then
          cfg.x, cfg.y, cfg.z = tonumber(x), tonumber(y), tonumber(z)
          break
        end
        say("Three whole numbers, like: 120 200 -45  (Q cancels)", colors.red)
      end
    end
    if cfg.y < -64 or cfg.y > 320 then say("Note: y = " .. cfg.y .. " is outside the usual world height.", colors.yellow) end
    if cfg.y < 64 then say("Tip: GPS hosts work best high up (y 128+); wireless range grows with height.", colors.lightGray) end
    print()
    say(("GPS host at %d %d %d, %s."):format(cfg.x, cfg.y, cfg.z,
        cfg.mode == "desktop" and "runs in the background of the desktop" or "dedicated (starts on boot)"), colors.white)
    if cfg.mode == "dedicated" and hasDesktop then
      say("The WardenOS desktop, its accounts and settings are removed. Your own files stay.", colors.red)
    end
    if not yesNo("Install?", nil) then cancel() end
  end

  -- write
  local gpsFiles = {}
  for _, p in ipairs(MANIFEST.gps or {}) do gpsFiles["/" .. p] = true end
  local function put(path, data)
    local dir = fs.getDir(path)
    if dir ~= "" then fs.makeDir(dir) end
    local f = assert(fs.open(path, "w"))
    f.write(data)
    f.close()
  end
  if cfg.mode == "dedicated" then
    if hasDesktop then
      for _, p in ipairs(MANIFEST.files) do
        local path = "/" .. p
        if path ~= "/startup.lua" and not gpsFiles[path] and fs.exists(path) and not fs.isDir(path) then fs.delete(path) end
      end
      for _, p in ipairs({ "/os/users.dat", "/os/settings.lua", "/os/boot.cfg", "/os/files.dat" }) do
        if fs.exists(p) then fs.delete(p) end
      end
      for _, d in ipairs({ "/os/apps", "/os/lib", "/os/drone", "/os/pocket", "/os/bin", "/os/man", "/os/screen" }) do
        if fs.isDir(d) and #fs.list(d) == 0 then fs.delete(d) end
      end
    elseif fs.exists("/startup.lua") and not fs.exists("/os/gps/host.lua") and not fs.exists("/startup.old.lua") then
      fs.copy("/startup.lua", "/startup.old.lua")
    end
  end
  for path in pairs(gpsFiles) do
    if FILES[path] then
      if path == "/os/gps/startup.lua" then
        if cfg.mode == "dedicated" then put("/startup.lua", FILES[path]) end
        if hasDesktop and cfg.mode == "desktop" then put(path, FILES[path]) end
      elseif not (path == "/os/config.lua" and cfg.mode == "desktop") then   -- the desktop keeps its own config
        put(path, FILES[path])
      end
    end
  end
  if cfg.mode == "dedicated" and fs.exists("/os/gps/startup.lua") then fs.delete("/os/gps/startup.lua") end
  if cfg.mode == "dedicated" and not hasDesktop and fs.isDir("/os/screen") then fs.delete("/os/screen") end  -- was a screen
  put(GPS_CFG, textutils.serialize({ x = cfg.x, y = cfg.y, z = cfg.z, mode = cfg.mode }))
  if not os.getComputerLabel() then os.setComputerLabel("gps-" .. os.getComputerID()) end
  say(("Warden GPS host %s at %d %d %d. Rebooting..."):format(OS_VERSION, cfg.x, cfg.y, cfg.z), colors.green)
  sleep(1)
  os.reboot()
end

---------------------------------------------------------------- Warden Screen (one page of the brain on a monitor)
-- plain print/read, so it works on a standard computer too; also reached from the desktop welcome screen (S)
local function screenInstall()
  local hasDesktop = fs.exists("/os/kernel.lua")
  local function say(s, c)
    term.setTextColor(isColour and c or colors.white)
    print(s)
    term.setTextColor(colors.white)
  end
  local function ask(q)
    term.setTextColor(colors.white)
    write(q)
    return read()
  end
  local function yesNo(q, default)
    say(q .. (default and " (Y/n)" or " (y/n)"), colors.white)
    while true do
      local a = ask("> "):lower()
      if a == "" and default ~= nil then return default end
      if a == "y" or a == "yes" then return true end
      if a == "n" or a == "no" then return false end
    end
  end
  local function cancel()
    say("Cancelled. Nothing was changed.", colors.lightGray)
    error(ABORT, 0)
  end
  local core = assert(load(FILES["/os/screen/core.lua"], "=core.lua", "t", _G))()

  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  say("Warden Screen setup", colors.cyan)
  say("A Warden Screen shows ONE page of your main WardenOS computer (the brain) live on a monitor. No desktop, no login.",
      colors.lightGray)
  print()

  local cfg
  local old = screenCfg and core.read() or nil
  if old and (yes or mode == "update") then
    cfg = old
  elseif old then
    local pg = core.page(old.page)
    say(("This computer is a Warden Screen: %s, brain %s."):format(pg and pg.name or old.page,
        old.brain and ("#" .. old.brain) or "auto"), colors.yellow)
    if yesNo("Keep these settings and update?", true) then cfg = old end
  end

  if not cfg then
    cfg = { interval = 2, touch = true }
    if hasDesktop then
      say("WardenOS desktop is installed here.", colors.yellow)
      say(" D  dedicated: remove the desktop (accounts, settings), run only the screen", colors.white)
      say(" Q  cancel", colors.white)
      while true do
        local a = ask("D/Q> "):lower()
        if a == "d" then break end
        if a == "q" then cancel() end
      end
    end

    -- 1. the page
    say("Which page should it show? (Enter = 1)", colors.white)
    for i, p in ipairs(core.PAGES) do say((" %d  %s - %s"):format(i, p.name, p.about), colors.lightGray) end
    while true do
      local a = ask(("Page (1-%d)> "):format(#core.PAGES))
      if a:lower() == "q" then cancel() end
      local n = a == "" and 1 or tonumber(a)
      if n and core.PAGES[n] then cfg.page = core.PAGES[n].id break end
      say("Type a number from the list (Q cancels).", colors.red)
    end

    -- 2. the monitor
    local mons = core.monitors()
    if #mons == 0 then
      say("No monitor found: the page is shown on this computer's screen. Attach a monitor any time, the biggest one is used.",
          colors.yellow)
      cfg.monitor = nil
    else
      for i, m in ipairs(mons) do
        say((" %d  %s  %dx%d%s"):format(i, m.name, m.w, m.h, m.colour and "" or " (black and white)"), colors.lightGray)
      end
      say(" 0  this computer's own screen", colors.lightGray)
      say("Which monitor? (Enter = 1, the biggest)", colors.white)
      while true do
        local a = ask(("Monitor (0-%d)> "):format(#mons))
        if a:lower() == "q" then cancel() end
        local n = a == "" and 1 or tonumber(a)
        if n == 0 then cfg.monitor = "term" break end
        if n and mons[n] then cfg.monitor = mons[n].name break end
        say("Type a number from the list (Q cancels).", colors.red)
      end
    end

    -- 3. the brain
    local nm = core.openModems()
    local found = {}
    if nm == 0 then
      say("No modem found. Attach a wireless or ender modem (or a wired one on the brain's network); the screen waits for it.",
          colors.red)
    else
      say("Looking for WardenOS computers...", colors.lightGray)
      found = core.discover(2)
    end
    if #found > 0 then
      for i, b in ipairs(found) do
        say((" %d  #%d %s  v%s%s"):format(i, b.id, b.label or "", b.version,
            b.drones and (", " .. b.drones .. " drones") or ""), colors.lightGray)
      end
      say("Which one is the brain? A number from the list or # and an ID like #5 (Enter = 1)", colors.white)
      while true do
        local a = ask(("Brain (1-%d)> "):format(#found))
        if a:lower() == "q" then cancel() end
        local id = tonumber((a:match("^%s*#%s*(%d+)%s*$")))
        local n = a == "" and 1 or tonumber(a)
        if id then cfg.brain = id break end
        if n and found[n] then cfg.brain = found[n].id break end
        say("A number from the list, or # and a computer ID like #5 (Q cancels).", colors.red)
      end
    else
      if nm > 0 then
        say("No WardenOS computer answered (it must run WardenOS " .. OS_VERSION .. "+, logged in, with a modem).",
            colors.yellow)
      end
      say("Type the brain's computer ID (Enter = find it automatically)", colors.white)
      while true do
        local a = ask("Brain ID> ")
        if a:lower() == "q" then cancel() end
        if a == "" then cfg.brain = nil break end
        local id = tonumber((a:gsub("#", "")))
        if id and id >= 0 then cfg.brain = math.floor(id) break end
        say("A computer ID is a number, like 5 (Q cancels).", colors.red)
      end
    end
    print()
    local pg = core.page(cfg.page)
    say(("Warden Screen: %s on %s, brain %s."):format(pg.name,
        cfg.monitor == "term" and "this computer" or (cfg.monitor or "the biggest monitor"),
        cfg.brain and ("#" .. cfg.brain) or "auto"), colors.white)
    if hasDesktop then
      say("The WardenOS desktop, its accounts and settings are removed. Your own files stay.", colors.red)
    end
    if not yesNo("Install?", nil) then cancel() end
  end

  -- write
  local mine = {}
  for _, p in ipairs(MANIFEST.screen or {}) do mine["/" .. p] = true end
  local function put(path, data)
    local dir = fs.getDir(path)
    if dir ~= "" then fs.makeDir(dir) end
    local f = assert(fs.open(path, "w"))
    f.write(data)
    f.close()
  end
  if hasDesktop then
    for _, p in ipairs(MANIFEST.files) do
      local path = "/" .. p
      if path ~= "/startup.lua" and not mine[path] and fs.exists(path) and not fs.isDir(path) then fs.delete(path) end
    end
    for _, p in ipairs({ "/os/users.dat", "/os/settings.lua", "/os/boot.cfg", "/os/files.dat" }) do
      if fs.exists(p) then fs.delete(p) end
    end
    for _, d in ipairs({ "/os/apps", "/os/lib", "/os/drone", "/os/pocket", "/os/bin", "/os/man", "/os/gps" }) do
      if fs.isDir(d) and #fs.list(d) == 0 then fs.delete(d) end
    end
  elseif fs.exists("/startup.lua") and not fs.exists("/os/screen/client.lua") and not fs.exists("/os/gps/host.lua")
         and not fs.exists("/startup.old.lua") then
    fs.copy("/startup.lua", "/startup.old.lua")
  end
  if gpsDedicated and fs.isDir("/os/gps") then fs.delete("/os/gps") end   -- was a dedicated GPS host
  for path in pairs(mine) do
    if FILES[path] then put(path == "/os/screen/startup.lua" and "/startup.lua" or path, FILES[path]) end
  end
  if fs.exists("/os/screen/startup.lua") then fs.delete("/os/screen/startup.lua") end
  core.write(cfg, SCREEN_CFG)
  if not os.getComputerLabel() then os.setComputerLabel("screen-" .. os.getComputerID()) end
  say(("Warden Screen %s installed. Rebooting..."):format(OS_VERSION), colors.green)
  sleep(1)
  os.reboot()
end

if screenOnly then
  local ok, err = pcall(screenInstall)
  if not ok and err ~= ABORT then
    if tostring(err):find("Terminated") then print("Cancelled.") else printError("Install failed: " .. tostring(err)) end
  end
  return
end

if gpsOnly then
  local ok, err = pcall(gpsInstall)
  if not ok and err ~= ABORT then
    if tostring(err):find("Terminated") then print("Cancelled.") else printError("Install failed: " .. tostring(err)) end
  end
  return
end

math.randomseed(os.epoch("utc") % 2147483647 + math.floor(os.clock() * 1000))

---------------------------------------------------------------- helpers
local function use(path)
  return assert(load(FILES[path], "=" .. path, "t", _G))()
end
local font   = use("/os/lib/bigfont.lua")
local sha    = use("/os/lib/sha256.lua")
local screen = use("/os/lib/screen.lua")

local art                                       -- Warden pixel art (optional: a manifest without it still works)
if FILES["/os/lib/art.lua"] then
  local oka, m = pcall(use, "/os/lib/art.lua")
  if oka and type(m) == "table" then art = m end
end

-- common-size mirrored display (computer + monitor), nothing gets cropped
local S = screen.open(29, 13, "right")
local W, H = S.W, S.H
do                                              -- the dark WardenOS palette (undone by S.close)
  local okc, c = pcall(use, "/os/config.lua")
  if okc and type(c) == "table" and type(c.themes) == "table" and c.themes.dark and S.palette then
    S.palette(c.themes.dark.palette)
  end
end

local function at(x, y, s, fg, bg)
  term.setCursorPos(x, y)
  term.setTextColor(fg or colors.white)
  term.setBackgroundColor(bg or colors.black)
  term.write(s)
end
local function clr()
  term.setBackgroundColor(colors.black)
  term.clear()
end
local function center(y, s, fg)
  at(math.floor((W - #s) / 2) + 1, y, s, fg)
end
local function abort() error(ABORT, 0) end

local function wrap(str, width)
  local lines = {}
  for para in (str .. "\n"):gmatch("(.-)\n") do
    if para == "" then
      lines[#lines + 1] = ""
    else
      local indent = para:match("^%s*")
      local line = indent
      for word in para:gmatch("%S+") do
        if #line + #word + 1 > width and line:match("%S") then
          lines[#lines + 1] = line
          line = indent .. word
        else
          line = (line:match("%S") and (line .. " ") or line) .. word
        end
      end
      lines[#lines + 1] = line
    end
  end
  return lines
end

-- write wrapped text starting at row y, returns the next free row
local function say(y, str, fg, centered)
  for _, l in ipairs(wrap(str, W - 2)) do
    if centered then center(y, l, fg) else at(2, y, l, fg) end
    y = y + 1
  end
  return y
end

local function header(step, title)
  clr()
  at(1, 1, string.rep(" ", W), colors.white, colors.gray)
  at(2, 1, "\4", colors.cyan, colors.gray)
  at(4, 1, "WardenOS Setup", colors.white, colors.gray)
  local s = ("step %d/%d"):format(step, STEPS)
  at(W - #s, 1, s, colors.lightGray, colors.gray)
  local bw = math.floor(W * step / STEPS)           -- progress line under the bar
  at(1, 2, string.rep(" ", W), colors.white, colors.black)
  at(2, 3, title:sub(1, W - 2), colors.cyan)
  if bw > 0 then at(1, 2, string.rep("_", bw), colors.cyan, colors.black) end
end
local function footer(s)
  at(1, H, string.rep(" ", W), colors.lightGray, colors.black)
  at(2, H, s:sub(1, W - 2), colors.lightGray)
end

local function logo(y)
  if art and W >= 41 and H >= 18 then              -- the Warden next to the WARDEN wordmark
    local a = art.get("warden", "medium")
    local x = math.floor((W - (a.w + 3 + font.width("WARDEN"))) / 2) + 1
    art.draw(term, "warden", "medium", x, y)
    font.draw(term, "WARDEN", x + a.w + 3, y + math.floor((a.h - 5) / 2), colors.cyan)
    return y + a.h + 1
  end
  if art and H >= 16 then                           -- the Warden alone
    local a = art.get("warden", "small")
    art.draw(term, "warden", "small", math.floor((W - a.w) / 2) + 1, y)
    return y + a.h + 1
  end
  if H >= 16 then
    font.draw(term, "WARDEN", math.floor((W - font.width("WARDEN")) / 2) + 1, y, colors.cyan)
    return y + 7
  end
  center(y, "W A R D E N", colors.cyan)
  return y + 2
end

local function bar(y, frac, label)
  local w = W - 4
  at(2, y, (label .. string.rep(" ", w)):sub(1, w), colors.white)
  at(2, y + 1, string.rep(" ", w), colors.white, colors.gray)
  at(2, y + 1, string.rep(" ", math.floor(w * frac + 0.5)), colors.white, colors.cyan)
  at(2, y + 2, ("%d%%"):format(math.floor(frac * 100)), colors.lightGray)
end

---------------------------------------------------------------- terms text
local TOS = [[
WARDENOS TERMS OF SERVICE  (v]] .. TOS_VERSION .. [[)

1. What this is
WardenOS is a hobby operating system for the CC: Tweaked Minecraft mod, made for modded worlds. It is provided for fun, as-is.

2. Clean install
Setup erases EVERYTHING stored on this computer, and the contents of inserted disks only if you explicitly choose that. Erased data cannot be recovered. Back up anything you care about before you continue.

3. Accounts
The account you create is stored locally on this computer. Your password is saved as a salted hash, never as plain text. This is game-level protection only: anyone who can open the computer's files or the world save can still read or change them. Do not reuse a real-life password.

4. Network
WardenOS only connects to GitHub, to download and update itself. It does not send any of your data anywhere. The version of these terms you accepted is stored with your account.

5. No warranty
There is no warranty of any kind. The authors are not liable for lost builds, lost code, lost chests or lost sanity.

6. Changes
These terms may change in future versions. Setup will ask you again when they do.

By typing AGREE you confirm that you have read and accepted these terms and that you want to erase this computer.]]

---------------------------------------------------------------- screens
local function welcome()
  clr()
  local y = logo(2)
  center(y, "WardenOS Setup " .. OS_VERSION, colors.white)
  y = say(y + 2, "Clean install: terms, account, then a full disk erase.", colors.lightGray, true)
  local installed = fs.exists("/os/kernel.lua")
  if installed then
    y = say(y + 1, "WardenOS is already installed. Press U to update and keep your accounts.", colors.yellow, true)
  end
  local gy = y + (installed and 0 or 1)
  if gy <= H - 1 then say(gy, "G GPS host, S Warden Screen", colors.lightGray, true) end
  footer(installed and "ENTER new U upd G GPS S scr" or "ENTER begin G GPS S screen")
  while true do
    local _, k = os.pullEvent("key")
    if k == keys.enter then return "install" end
    if k == keys.u and installed then return "update" end
    if k == keys.g then return "gps" end
    if k == keys.s then return "screen" end
    if k == keys.q then abort() end
  end
end

local function terms()
  local lines = wrap(TOS, W - 4)
  local view = H - 6
  local maxTop = math.max(1, #lines - view + 1)
  local top, note = 1, ""
  while true do
    header(2, "Terms of Service")
    for i = 0, view - 1 do
      local l = lines[top + i]
      if l then at(3, 4 + i, l, colors.white) end
    end
    local last = top >= maxTop
    local pos = ("%d/%d"):format(math.min(#lines, top + view - 1), #lines)
    at(W - #pos, 3, pos, colors.lightGray)
    footer(last and "ENTER continue  UP/DOWN" or "UP/DOWN: read to the end")
    if note ~= "" then at(2, H - 1, note, colors.red) end
    local e, k = os.pullEvent()
    note = ""
    if e == "key" then
      if k == keys.up then top = math.max(1, top - 1)
      elseif k == keys.down then top = math.min(maxTop, top + 1)
      elseif k == keys.pageUp then top = math.max(1, top - view)
      elseif k == keys.pageDown then top = math.min(maxTop, top + view)
      elseif k == keys.enter then
        if last then break else note = "Scroll to the end first." end
      end
    elseif e == "mouse_scroll" then
      top = math.max(1, math.min(maxTop, top + k))
    end
  end

  local err = ""
  while true do
    header(2, "Terms of Service")
    local y = say(5, "Do you accept the Terms of Service?", colors.white) + 1
    y = say(y, "Type AGREE to accept, or DECLINE to quit without changes.", colors.lightGray) + 1
    if err ~= "" then at(2, math.min(H, y + 1), err:sub(1, W - 2), colors.red) end
    at(2, y, "> ", colors.green)
    term.setTextColor(colors.white)
    local a = read():upper():gsub("%s", "")
    if a == "AGREE" then return end
    if a == "DECLINE" then abort() end
    err = "Type AGREE or DECLINE."
  end
end

-- one question per screen, so it fits any size
local function ask(title, label, mask, validate, err)
  err = err or ""
  while true do
    header(3, title)
    local y = say(5, label, colors.lightGray) + 1
    if err ~= "" then say(y + 2, err, colors.red) end
    at(2, y, "> ", colors.green)
    term.setTextColor(colors.white)
    local ok, res = validate(read(mask))
    if ok then return res end
    err = res
  end
end

local function account()
  local defName = "warden-" .. os.getComputerID()
  local host = ask("Computer name", "Name for this computer (ENTER = " .. defName .. "):", nil, function(v)
    if v == "" then return true, defName end
    if #v > 32 then return false, "At most 32 characters." end
    return true, v
  end)
  local user = ask("Username", "Choose a username (3-16 characters: a-z 0-9 _ -):", nil, function(v)
    v = v:lower()
    if #v < 3 or #v > 16 or not v:match("^[a-z0-9_%-]+$") then
      return false, "Use 3-16 characters: a-z, 0-9, _ or -"
    end
    return true, v
  end)
  local pass, perr
  while true do
    pass = ask("Password", "Choose a password (at least 4 characters):", "*", function(v)
      if #v < 4 then return false, "Too short." end
      return true, v
    end, perr)
    local again = ask("Password", "Repeat the password:", "*", function(v) return true, v end)
    if again == pass then break end
    perr = "Passwords did not match. Try again."
  end
  return { host = host, user = user, pass = pass }
end

local function rootTargets()
  local t = {}
  for _, n in ipairs(fs.list("/")) do
    if fs.getDrive("/" .. n) == "hdd" then t[#t + 1] = n end
  end
  return t
end

local function size(p)
  if fs.isDir(p) then
    local s = 0
    for _, n in ipairs(fs.list(p)) do s = s + size(fs.combine(p, n)) end
    return s
  end
  return fs.getSize(p)
end

local function diskStep()
  local targets = rootTargets()
  local kb = 0
  for _, n in ipairs(targets) do kb = kb + size("/" .. n) end
  kb = math.floor(kb / 1024)

  local disks = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "drive" and disk.isPresent(name) and disk.hasData(name) then
      disks[#disks + 1] = { side = name, path = disk.getMountPath(name) }
    end
  end

  -- A: what gets erased
  header(4, "Erase this computer")
  local y = say(5, "EVERYTHING on this computer will be deleted:", colors.red)
  y = say(y, ("%d items, ~%d KB. The read-only ROM is kept."):format(#targets, kb), colors.lightGray) + 1
  local room = math.max(0, H - y - 1)
  local show = math.min(#targets, room)
  if #targets > room and room > 0 then show = room - 1 end
  for i = 1, show do at(4, y + i - 1, "/" .. targets[i]:sub(1, W - 5), colors.white) end
  if show < #targets and room > 0 then
    at(4, y + show, ("... and %d more"):format(#targets - show), colors.lightGray)
  end
  footer("ENTER continue    Q cancel")
  while true do
    local _, k = os.pullEvent("key")
    if k == keys.enter then break end
    if k == keys.q then abort() end
  end

  -- B: inserted disks
  local wipeDisks = false
  if #disks > 0 then
    header(4, "Inserted disks")
    say(5, ("%d inserted disk(s) found. Erase them too?"):format(#disks), colors.yellow)
    footer("Y = erase them   N = keep")
    while true do
      local _, k = os.pullEvent("key")
      if k == keys.y then wipeDisks = true break end
      if k == keys.n or k == keys.enter then break end
    end
  end

  -- C: final confirmation
  header(4, "Final confirmation")
  local msg = ("This erases %d items%s."):format(#targets, wipeDisks and " AND the inserted disks" or "")
  y = say(5, msg, colors.red) + 1
  y = say(y, "Type ERASE to wipe and install. Anything else cancels.", colors.yellow) + 1
  at(2, y, "> ", colors.green)
  term.setTextColor(colors.white)
  if read() ~= "ERASE" then abort() end
  return { targets = targets, disks = disks, wipeDisks = wipeDisks }
end

local function randomHex(n)
  local t = {}
  for i = 1, n do t[i] = string.format("%x", math.random(0, 15)) end
  return table.concat(t)
end

local LIST = "/os/files.dat"

local function sortedPaths()
  local paths = {}
  for p in pairs(FILES) do paths[#paths + 1] = p end
  table.sort(paths)
  return paths
end

local function writeFile(p)
  local dir = fs.getDir(p)
  if dir ~= "" then fs.makeDir(dir) end
  local f = assert(fs.open(p, "w"))
  f.write(FILES[p])
  f.close()
end

local function saveFileList()
  local f = assert(fs.open(LIST, "w"))
  f.write(textutils.serialize({ version = OS_VERSION, branch = branch, files = sortedPaths() }))
  f.close()
end

local function readFileList()
  if not fs.exists(LIST) then return {} end
  local f = fs.open(LIST, "r")
  local d = textutils.unserialize(f.readAll())
  f.close()
  if type(d) == "table" and type(d.files) == "table" then return d.files end
  return {}
end

local function install(acct, plan)
  header(5, "Installing")
  local jobs = {}
  local function job(label, fn) jobs[#jobs + 1] = { label, fn } end

  for _, n in ipairs(plan.targets) do
    job("Erasing /" .. n, function() erased = true fs.delete("/" .. n) end)
  end
  if plan.wipeDisks then
    for _, d in ipairs(plan.disks) do
      if d.path then
        for _, n in ipairs(fs.list(d.path)) do
          job("Erasing disk " .. d.side .. ": " .. n, function() erased = true fs.delete(fs.combine(d.path, n)) end)
        end
      end
    end
  end

  for _, p in ipairs(sortedPaths()) do
    job("Writing " .. p, function() writeFile(p) end)
  end

  job("Creating account " .. acct.user, function()
    local salt = randomHex(16)
    local data = {
      version = 1,
      host = acct.host,
      last = acct.user,
      tos = { version = TOS_VERSION, accepted = true, day = os.day() },
      users = { { name = acct.user, admin = true, salt = salt, hash = sha.hashPassword(acct.pass, salt) } },
    }
    local f = assert(fs.open("/os/users.dat", "w"))
    f.write(textutils.serialize(data))
    f.close()
  end)
  job("Naming computer " .. acct.host, function() os.setComputerLabel(acct.host) end)
  job("Saving file list", saveFileList)

  for i, j in ipairs(jobs) do
    bar(6, (i - 1) / #jobs, j[1])
    local ok, err = pcall(j[2])
    if not ok then error("Install failed at '" .. j[1] .. "': " .. tostring(err), 0) end
    sleep(0)
  end
  bar(6, 1, "Done")
end

local function finish(acct)
  clr()
  local y = logo(2)
  center(y, "WardenOS is installed.", colors.white)
  center(y + 2, ("Account: " .. acct.user):sub(1, W - 2), colors.lightGray)
  center(y + 3, ("Computer: " .. acct.host):sub(1, W - 2), colors.lightGray)
  footer("Press any key to reboot")
  os.pullEvent("key")
  os.reboot()
end

---------------------------------------------------------------- update (keeps accounts, settings, user files)
local function update()
  if not fs.exists("/os/kernel.lua") then
    clr()
    local y = say(2, "WardenOS is not installed on this computer.", colors.red)
    say(y + 1, "Run the installer without 'update' for a clean install.", colors.lightGray)
    footer("Press any key")
    os.pullEvent("key")
    abort()
  end
  if not yes then
    clr()
    local y = logo(2)
    center(y, "Update WardenOS to " .. OS_VERSION, colors.white)
    say(y + 2, "Accounts, settings and your own files are kept.", colors.lightGray, true)
    footer("ENTER update    Q cancel")
    while true do
      local _, k = os.pullEvent("key")
      if k == keys.enter then break end
      if k == keys.q then abort() end
    end
  end

  clr()
  at(1, 1, string.rep(" ", W), colors.white, colors.gray)
  at(2, 1, "WardenOS Update", colors.white, colors.gray)
  local jobs = {}
  local function job(label, fn) jobs[#jobs + 1] = { label, fn } end

  -- remove files a previous version installed that no longer exist
  local old = readFileList()
  for _, p in ipairs(old) do
    if not FILES[p] and fs.exists(p) and not fs.isDir(p) then
      job("Removing " .. p, function() fs.delete(p) end)
    end
  end
  for _, p in ipairs(sortedPaths()) do
    job("Writing " .. p, function() writeFile(p) end)
  end
  job("Saving file list", saveFileList)

  for i, j in ipairs(jobs) do
    bar(3, (i - 1) / #jobs, j[1])
    local ok, err = pcall(j[2])
    if not ok then error("Update failed at '" .. j[1] .. "': " .. tostring(err), 0) end
  end
  bar(3, 1, "Done")
  if yes then
    footer("Updated to " .. OS_VERSION .. ". Rebooting...")
    sleep(1)
  else
    footer("Updated. Press any key to reboot")
    os.pullEvent("key")
  end
  os.reboot()
end

---------------------------------------------------------------- run
local function main()
  if mode == "update" then return update() end
  local choice = welcome()
  if choice == "update" then return update() end
  if choice == "gps" or choice == "screen" then return choice end
  terms()
  local acct = account()
  local plan = diskStep()
  install(acct, plan)
  finish(acct)
end

local ok, err = pcall(main)
S.close()
if ok and err == "gps" then                     -- G on the welcome screen: the plain-text GPS host setup
  local okg, gerr = pcall(gpsInstall)
  if not okg and gerr ~= ABORT then
    if tostring(gerr):find("Terminated") then print("Cancelled.") else printError("Install failed: " .. tostring(gerr)) end
  end
  return
end
if ok and err == "screen" then                  -- S on the welcome screen: the plain-text Warden Screen setup
  local oks, serr = pcall(screenInstall)
  if not oks and serr ~= ABORT then
    if tostring(serr):find("Terminated") then print("Cancelled.") else printError("Install failed: " .. tostring(serr)) end
  end
  return
end
if not ok then
  if err == ABORT or tostring(err):find("Terminated") then
    print(erased and "Setup interrupted AFTER erasing started. Run it again." or "Setup cancelled. Nothing was changed.")
  else
    printError("Setup failed: " .. tostring(err))
  end
end
