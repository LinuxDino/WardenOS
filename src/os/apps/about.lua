-- About: system info, refreshes every second
return {
  name = "About", short = "About", icon = "i", color = colors.orange, order = 9,
  w = 36, h = 13,
  main = function()
    local T = WardenOS.theme
    while true do
      term.setBackgroundColor(T.bg)
      term.setTextColor(T.text)
      term.clear()
      local w = term.getSize()
      term.setCursorPos(2, 2)
      term.setTextColor(T.accent)
      print(WardenOS.name .. " " .. WardenOS.version)
      term.setTextColor(T.text)
      local function row(s) local _, y = term.getCursorPos() term.setCursorPos(2, y) print(s) end
      row("")
      row("Computer #" .. os.getComputerID() .. " " .. (os.getComputerLabel() or ""))
      row("User: " .. (WardenOS.user or "-"))
      row(os.version())
      row("Uptime " .. math.floor(os.clock()) .. "s   Free " .. math.floor(fs.getFreeSpace("/") / 1024) .. " KB")
      row("")
      term.setTextColor(T.dim)
      row("Peripherals")
      term.setTextColor(T.text)
      for _, n in ipairs(peripheral.getNames()) do
        row((n .. " (" .. tostring(peripheral.getType(n)) .. ")"):sub(1, w - 2))
      end
      local t = os.startTimer(1)
      repeat local e, id = os.pullEvent() until (e == "timer" and id == t) or e == "theme_changed"
    end
  end,
}
