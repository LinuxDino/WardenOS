-- Makes a WardenOS drone install disk in the first disk drive that holds a floppy.
-- Used by the Drones app: dofile("/os/drone/disk.lua")(ownerComputerId) -> ok, message
return function(owner)
  local mount
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "drive" and disk.isPresent(name) and disk.hasData(name) then
      mount = disk.getMountPath(name)
      if mount then
        pcall(disk.setLabel, name, "WardenOS Drone Installer")
        break
      end
    end
  end
  if not mount then return false, "Put a floppy disk in a disk drive" end

  local function copy(from, to)
    local f = fs.open(from, "r")
    if not f then error("missing " .. from, 0) end
    local data = f.readAll()
    f.close()
    fs.makeDir(fs.getDir(to))
    local o = fs.open(to, "w")
    if not o then error("disk is full or read-only", 0) end
    o.write(data)
    o.close()
  end
  local ok, err = pcall(function()
    copy("/os/drone/diskstartup.lua", fs.combine(mount, "startup.lua"))
    copy("/os/drone/agent.lua", fs.combine(mount, "wardenos/agent.lua"))
    copy("/os/drone/startup.lua", fs.combine(mount, "wardenos/startup.lua"))
    local f = fs.open(fs.combine(mount, "wardenos/config"), "w")
    f.write(textutils.serialize({ owner = owner }))
    f.close()
  end)
  if not ok then return false, tostring(err) end
  return true, "Disk ready: place a turtle next to the drive and turn it on"
end
