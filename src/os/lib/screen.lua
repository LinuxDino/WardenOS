-- Mirrored display helper: computer screen + monitor, drawn in a window of the
-- COMMON size so nothing is cropped on either screen.
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
  if mon then
    mon.setTextScale(0.5)
    local mw, mh = mon.getSize()
    if mw >= minW and mh >= minH then
      W, H = math.min(tw, mw), math.min(th, mh)
      for _, s in ipairs({ 5, 4.5, 4, 3.5, 3, 2.5, 2, 1.5, 1, 0.5 }) do   -- biggest text that still fits
        mon.setTextScale(s)
        local a, b = mon.getSize()
        if a >= W and b >= H then break end
      end
      mon.setBackgroundColor(colors.black)
      mon.clear()
    else
      mon = nil                                   -- monitor too small: computer only
    end
  end

  local ui = scr
  if mon then
    ui = setmetatable({}, { __index = function(_, k)
      local f = scr[k]
      if type(f) ~= "function" then return f end
      local g = mon[k]
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
