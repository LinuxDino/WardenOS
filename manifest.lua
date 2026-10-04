-- WardenOS file list, read by install.lua. Paths are relative to src/ and to / on the computer.
-- Add every new OS file here (tests/check.py verifies this list matches src/).
-- Bump version together with src/os/config.lua and src/os/drone/agent.lua.
return {
  version = "1.3.0",
  files = {
    "startup.lua",
    "os/config.lua",
    "os/boot.lua",
    "os/kernel.lua",
    "os/lib/bigfont.lua",
    "os/lib/claude.lua",
    "os/lib/json.lua",
    "os/lib/login.lua",
    "os/lib/screen.lua",
    "os/lib/settings.lua",
    "os/lib/sha256.lua",
    "os/apps/about.lua",
    "os/apps/claude.lua",
    "os/apps/drones.lua",
    "os/apps/edit.lua",
    "os/apps/files.lua",
    "os/apps/lua.lua",
    "os/apps/monitoring.lua",
    "os/apps/peripherals.lua",
    "os/apps/settings.lua",
    "os/apps/terminal.lua",
    "os/drone/agent.lua",
    "os/drone/disk.lua",
    "os/drone/diskstartup.lua",
    "os/drone/startup.lua",
  },
  -- what a turtle gets (os/drone/startup.lua becomes /startup.lua)
  drone = {
    "os/drone/agent.lua",
    "os/drone/startup.lua",
  },
}
