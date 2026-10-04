-- Mirrored display helper for the boot menu and installer: the same picture on the
-- computer screen and, centered, on the monitor. Text on the monitor is never scaled
-- above 1x, so it stays crisp and nothing gets cropped.
local both = {
  write = 1, blit = 1, clear = 1, clearLine = 1, scroll = 1,
  setCursorPos = 1, setCursorBlink = 1,
  setTextColor = 1, setTextColour = 1, setBackgroundColor = 1, setBackgroundColour = 1,
}

local M = {}

-- minW/minH: smallest monitor worth mirroring on. side: preferred monitor side.
function M.open(minW, minH, side)
  local scr = term.current()
  local tw, th = scr.getSize()
  local mon
  if side and peripheral.getType(side) == "monitor" then
    mon = peripheral.wrap(side)
  else
    mon = peripheral.find("monitor")
  end

  local W, H = tw, th
  local mwin
  if mon then
    mon.setTextScale(0.5)
    local mw, mh = mon.getSize()
    if mw >= minW and mh >= minH then
      W, H = math.min(tw, mw), math.min(th, mh)
      mon.setTextScale(1)                         -- 1x if the picture fits, else 0.5x
      mw, mh = mon.getSize()
      if mw < W or mh < H then
        mon.setTextScale(0.5)
        mw, mh = mon.getSize()
      end
      mon.setBackgroundColor(colors.black)
      mon.clear()
      mwin = window.create(mon, math.floor((mw - W) / 2) + 1, math.floor((mh - H) / 2) + 1, W, H, true)
    else
      mon = nil                                   -- monitor too small: computer only
    end
  end

  local ui = scr
  if mwin then
    ui = setmetatable({}, { __index = function(_, k)
      local f = scr[k]
      if type(f) ~= "function" then return f end
      local g = mwin[k]
      if both[k] and g then return function(...) g(...) return f(...) end end
      return f
    end })
  end
  ui.setBackgroundColor(colors.black)
  ui.clear()

  local win = window.create(ui, 1, 1, W, H, true)
  term.redirect(win)

  local S = { W = W, H = H, mon = mon, scr = scr, ui = ui, win = win }
  function S.close()
    term.redirect(scr)
    scr.setBackgroundColor(colors.black)
    scr.setTextColor(colors.white)
    scr.clear()
    scr.setCursorPos(1, 1)
    if mon then
      mon.setBackgroundColor(colors.black)
      mon.clear()
    end
  end
  return S
end

return M
