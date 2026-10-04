-- WardenOS installer for CC: Tweaked (https://tweaked.cc)
-- Downloads WardenOS from GitHub, then runs the setup wizard.
--
--   install            clean install (wizard: terms, account, full erase)
--   install update     update to the latest version, keeps accounts, settings and your files
--   install <branch>   use another branch of the repository (works with "update" too)
--   install update -y  update without asking (used by Settings > Update now)

local REPO, BRANCH = "LinuxDino/WardenOS", "main"
local TOS_VERSION, STEPS = "1.0", 5
local ABORT = {}
local erased = false

local mode, branch, yes = "install", BRANCH, false
for _, a in ipairs({ ... }) do
  if a == "update" then mode = "update"
  elseif a == "-y" then yes = true
  elseif a ~= "" then branch = a end
end
local RAW = "https://raw.githubusercontent.com/" .. REPO .. "/" .. branch .. "/"

---------------------------------------------------------------- checks
if not http then
  printError("The http API is disabled.")
  print("Enable http in the CC: Tweaked config (server owner), then try again.")
  return
end
if not term.isColour() then
  printError("WardenOS needs an Advanced Computer (gold).")
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
  print("WardenOS installer")
  term.setTextColor(colors.lightGray)
  print(REPO .. " @ " .. branch)
  print()

  local fn, err = load(fetch("manifest.lua"), "=manifest.lua", "t", {})
  if not fn then error("broken manifest: " .. tostring(err), 0) end
  local ok, m = pcall(fn)
  if not ok or type(m) ~= "table" or type(m.files) ~= "table" or #m.files == 0 then
    error("broken manifest", 0)
  end

  local _, y = term.getCursorPos()
  local w = term.getSize()
  for i, path in ipairs(m.files) do
    if type(path) ~= "string" or path:find("%.%.") or not path:match("^[%w_%-%./]+$") then
      error("bad path in manifest: " .. tostring(path), 0)
    end
    term.setCursorPos(1, y)
    term.clearLine()
    term.setTextColor(colors.white)
    term.write((("[%d/%d] %s"):format(i, #m.files, path)):sub(1, w))
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
  print(("Downloaded %d files (v%s)"):format(#m.files, tostring(m.version)))
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

math.randomseed(os.epoch("utc") % 2147483647 + math.floor(os.clock() * 1000))

---------------------------------------------------------------- helpers
local function use(path)
  return assert(load(FILES[path], "=" .. path, "t", _G))()
end
local font   = use("/os/lib/bigfont.lua")
local sha    = use("/os/lib/sha256.lua")
local screen = use("/os/lib/screen.lua")

-- common-size mirrored display (computer + monitor), nothing gets cropped
local S = screen.open(29, 13, "right")
local W, H = S.W, S.H

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
  at(2, 1, "WardenOS Setup", colors.white, colors.gray)
  local s = ("step %d/%d"):format(step, STEPS)
  at(W - #s, 1, s, colors.lightGray, colors.gray)
  at(2, 3, title:sub(1, W - 2), colors.cyan)
end
local function footer(s)
  at(1, H, string.rep(" ", W), colors.lightGray, colors.black)
  at(2, H, s:sub(1, W - 2), colors.lightGray)
end

local function logo(y)
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
    say(y + 1, "WardenOS is already installed. Press U to update and keep your accounts.", colors.yellow, true)
  end
  footer(installed and "ENTER clean   U update   Q quit" or "ENTER begin    Q quit")
  while true do
    local _, k = os.pullEvent("key")
    if k == keys.enter then return "install" end
    if k == keys.u and installed then return "update" end
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
  if welcome() == "update" then return update() end
  terms()
  local acct = account()
  local plan = diskStep()
  install(acct, plan)
  finish(acct)
end

local ok, err = pcall(main)
S.close()
if not ok then
  if err == ABORT or tostring(err):find("Terminated") then
    print(erased and "Setup interrupted AFTER erasing started. Run it again." or "Setup cancelled. Nothing was changed.")
  else
    printError("Setup failed: " .. tostring(err))
  end
end
