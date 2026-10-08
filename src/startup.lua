-- WardenOS boot: boot menu -> WardenOS or plain CraftOS
rawset(_G, "shell", shell)

-- WardenOS terminal commands (btop, neofetch, ...) live in /os/bin: on the program path and as aliases,
-- both are copied by every shell started later (Terminal app, pocket terminal, CraftOS after exit)
if shell.setPath and not (":" .. shell.path() .. ":"):find(":/os/bin:", 1, true) then
  shell.setPath(shell.path() .. ":/os/bin")
end
if shell.setAlias and fs.isDir("/os/bin") then
  for _, f in ipairs(fs.list("/os/bin")) do
    if f:sub(-4) == ".lua" then shell.setAlias(f:sub(1, -5), "/os/bin/" .. f) end
  end
end

-- Recovery (/os/recovery.lua): a clear error screen with Restart, Repair, Safe mode, ... instead of a red line.
-- If even that file is broken, a plain message says how to repair from CraftOS.
local function recover(stage, err, trace)
  term.redirect(term.native())
  local okr, R = pcall(dofile, "/os/recovery.lua")
  if okr and type(R) == "table" and R.run then
    local ok3, res = pcall(R.run, { stage = stage, err = err, trace = trace })
    if ok3 then return res end
    err = tostring(err) .. "\n(the recovery screen failed too: " .. tostring(res) .. ")"
  end
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  if term.isColour() then term.setTextColor(colors.red) end
  print((stage == "kernel" and "Kernel error: " or "WardenOS error: ") .. tostring(err))
  term.setTextColor(colors.white)
  print("Dropped to CraftOS. To repair (keeps accounts and files):")
  print("  pastebin run CeQfPV78 update")
  return "craftos"
end

-- boot failure counter: +1 before the desktop starts, back to 0 once it is running (kernel.lua)
local STATE = "/os/boot.state"
local function fails(n)
  if n == nil then
    local f = fs.exists(STATE) and fs.open(STATE, "r")
    local d = f and textutils.unserialize(f.readAll() or "")
    if f then f.close() end
    return type(d) == "table" and tonumber(d.fails) or 0
  end
  pcall(function()
    local f = fs.open(STATE, "w")
    if f then f.write(textutils.serialize({ fails = n })) f.close() end
  end)
end

local choice
local okR, R = pcall(dofile, "/os/recovery.lua")
local bad = okR and type(R) == "table" and R.critical and R.critical() or {}
if #bad > 0 then                                -- a file needed to boot is missing or damaged
  local names = {}
  for i, b in ipairs(bad) do if i <= 4 then names[#names + 1] = b[1] .. " (" .. b[2] .. ")" end end
  choice = recover("files", "WardenOS files are missing or damaged: " .. table.concat(names, ", "))
else
  local ok
  ok, choice = pcall(dofile, "/os/boot.lua")
  if not ok then choice = recover("boot menu", choice) end
end
term.redirect(term.native())
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)

if choice == "recovery" then choice = recover("menu") end
if choice == "boot" then choice = "wardenos" end
if choice == "wardenos" and fails() >= 3 then
  choice = recover("loop", "WardenOS failed to start " .. fails() .. " times in a row.")
  if choice == "boot" then choice = "wardenos" end
end

while choice == "wardenos" or choice == "safe" do
  rawset(_G, "WARDEN_SAFE", choice == "safe" or nil)
  print(choice == "safe" and "WardenOS booting (safe mode)..." or "WardenOS booting...")
  fails(fails() + 1)
  local trace
  local ok2, err = xpcall(function() dofile("/os/kernel.lua") end, function(e)
    trace = debug and debug.traceback and debug.traceback() or nil
    return e
  end)
  rawset(_G, "WARDEN_SAFE", nil)
  if ok2 then
    choice = nil
  else
    term.redirect(term.native())
    choice = recover("kernel", err, trace)
    if choice == "boot" then choice = "wardenos" end
  end
end
if choice == "craftos" then
  term.redirect(term.native())
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
  print("CraftOS")
end
