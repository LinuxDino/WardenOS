-- WardenOS Drone install disk. A turtle next to this disk drive becomes a WardenOS drone.
local dir = fs.getDir(shell.getRunningProgram())          -- "disk", "disk2", ...

if not turtle then
  -- a computer booting with this disk inserted: start its own system as usual
  if fs.exists("/startup.lua") then shell.run("/startup.lua") end
  return
end

local function copy(from, to)
  local f = fs.open(from, "r")
  if not f then return false end
  local data = f.readAll()
  f.close()
  local old = fs.open(to, "r")
  if old then
    local same = old.readAll() == data
    old.close()
    if same then return true end
  end
  fs.makeDir(fs.getDir(to))
  local o = fs.open(to, "w")
  o.write(data)
  o.close()
  return true
end

local first = not fs.exists("/os/drone/agent.lua")
if fs.exists("/startup.lua") and not fs.exists("/os/drone/agent.lua") and not fs.exists("/startup.old.lua") then
  fs.copy("/startup.lua", "/startup.old.lua")             -- keep the turtle's old startup
end
assert(copy(fs.combine(dir, "wardenos/agent.lua"), "/os/drone/agent.lua"), "disk is missing the agent")
assert(copy(fs.combine(dir, "wardenos/startup.lua"), "/startup.lua"), "disk is missing startup.lua")
if not fs.exists("/os/drone/config") and fs.exists(fs.combine(dir, "wardenos/config")) then
  copy(fs.combine(dir, "wardenos/config"), "/os/drone/config")   -- owner = the computer that made the disk
end
if not os.getComputerLabel() then os.setComputerLabel("drone-" .. os.getComputerID()) end

if first then
  print("WardenOS drone installed. You can move the turtle away from the disk drive now.")
  sleep(2)
end
shell.run("/os/drone/agent.lua")
