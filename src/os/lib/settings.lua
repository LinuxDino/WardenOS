-- Shared settings, used by the kernel and the Settings app.
--   /os/settings.lua  desktop settings      /os/boot.cfg  boot menu settings
local M = {}

local DEFAULTS = {
  theme   = "dark",
  display = "auto",     -- auto | monitor | mirror | computer
  scale   = 0.5,        -- monitor text scale
  dock    = { "terminal", "files", "peripherals", "settings" },
}
M.DISPLAYS = { "auto", "monitor", "mirror", "computer" }
M.SCALES   = { 0.5, 1, 1.5, 2 }

local function read(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  if not f then return nil end
  local d = textutils.unserialize(f.readAll())
  f.close()
  return type(d) == "table" and d or nil
end

local function write(path, data)
  local f = fs.open(path, "w")
  if not f then return false end
  f.write(textutils.serialize(data))
  f.close()
  return true
end

local function copy(v)
  if type(v) ~= "table" then return v end
  local t = {}
  for k, x in pairs(v) do t[k] = copy(x) end
  return t
end

function M.load()
  local s = copy(DEFAULTS)
  local d = read("/os/settings.lua")
  if d then
    for k, v in pairs(d) do
      if DEFAULTS[k] ~= nil and type(v) == type(DEFAULTS[k]) then s[k] = copy(v) end
    end
  end
  local okDisplay = false
  for _, m in ipairs(M.DISPLAYS) do if s.display == m then okDisplay = true end end
  if not okDisplay then s.display = DEFAULTS.display end
  local okScale = false
  for _, v in ipairs(M.SCALES) do if s.scale == v then okScale = true end end
  if not okScale then s.scale = DEFAULTS.scale end
  return s
end

function M.save(s)
  return write("/os/settings.lua", s)
end

function M.loadBoot()
  local b = { default = "wardenos", timeout = 2 }
  local d = read("/os/boot.cfg")
  if d then
    if d.default == "wardenos" or d.default == "craftos" then b.default = d.default end
    if tonumber(d.timeout) then b.timeout = tonumber(d.timeout) end
  end
  return b
end

function M.saveBoot(b)
  return write("/os/boot.cfg", { default = b.default, timeout = b.timeout })
end

-- "1.10.0" > "1.9.2"
function M.newer(a, b)
  local function parts(v)
    local t = {}
    for n in tostring(v):gmatch("%d+") do t[#t + 1] = tonumber(n) end
    return t
  end
  local x, y = parts(a), parts(b)
  for i = 1, math.max(#x, #y) do
    local p, q = x[i] or 0, y[i] or 0
    if p ~= q then return p > q end
  end
  return false
end

return M
