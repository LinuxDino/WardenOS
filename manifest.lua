-- WardenOS file list, read by install.lua. Paths are relative to src/ and to / on the computer.
-- Add every new OS file here (tests/check.py verifies this list matches src/).
return {
  version = "1.1.0",
  files = {
    "startup.lua",
    "os/config.lua",
    "os/boot.lua",
    "os/kernel.lua",
    "os/lib/bigfont.lua",
    "os/lib/login.lua",
    "os/lib/screen.lua",
    "os/lib/settings.lua",
    "os/lib/sha256.lua",
    "os/apps/about.lua",
    "os/apps/edit.lua",
    "os/apps/files.lua",
    "os/apps/lua.lua",
    "os/apps/monitoring.lua",
    "os/apps/peripherals.lua",
    "os/apps/settings.lua",
    "os/apps/terminal.lua",
  },
}
