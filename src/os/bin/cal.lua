-- cal: a month calendar with today highlighted
local cli = dofile("/os/lib/cli.lua").init("cal", shell)
local MONTHS = { "January", "February", "March", "April", "May", "June", "July", "August", "September",
                 "October", "November", "December" }
local function weekday(y, m, d)                  -- 0 = Sunday (Sakamoto)
  local t = { 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 }
  if m < 3 then y = y - 1 end
  return (y + math.floor(y / 4) - math.floor(y / 100) + math.floor(y / 400) + t[m] + d) % 7
end
local function days(y, m)
  if m == 2 then return (y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0)) and 29 or 28 end
  return ({ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 })[m]
end
return cli.main({
  usage = "cal [-m] [[month] year]",
  about = "Show a calendar for this month (today highlighted), or for the given month and year. "
    .. "Weeks start on Sunday; -m starts them on Monday.",
  options = { "-m  weeks start on Monday", "e.g. cal 2 2024" },
  flags = { m = true }, long = { monday = "m" },
  run = function(o, args)
    local now = os.date("*t")
    local m, y = now.month, now.year
    if #args == 1 then
      y = tonumber(args[1])
      if not y then cli.fail("not a year: " .. args[1]) end
      m = (y == now.year) and now.month or 1
    elseif #args >= 2 then
      m, y = tonumber(args[1]), tonumber(args[2])
      if not m or m < 1 or m > 12 then cli.fail("month must be 1-12") end
      if not y then cli.fail("not a year: " .. args[2]) end
    end
    if y < 1 or y > 9999 then cli.fail("year must be 1-9999") end
    m, y = math.floor(m), math.floor(y)
    local title = MONTHS[m] .. " " .. y
    cli.print(string.rep(" ", math.floor((20 - #title) / 2)) .. title, colors.cyan)
    cli.print(o.m and "Mo Tu We Th Fr Sa Su" or "Su Mo Tu We Th Fr Sa", colors.yellow)
    local first = weekday(y, m, 1)
    if o.m then first = (first + 6) % 7 end
    local col = first
    cli.write(string.rep("   ", col))
    for d = 1, days(y, m) do
      local today = y == now.year and m == now.month and d == now.day
      local s = ("%2d"):format(d)
      if today then
        if cli.color then cli.bg(colors.white) cli.fg(colors.black) cli.write(s) cli.bg(colors.black)
        else cli.write(s:sub(1, 1) == " " and "*" .. s:sub(2) or s) end
      else
        local wkend = (o.m and col >= 5) or (not o.m and (col == 0 or col == 6))
        cli.write(s, wkend and colors.lightGray or colors.white)
      end
      col = col + 1
      if col == 7 then cli.print("") col = 0 elseif d < days(y, m) then cli.write(" ") end
    end
    if col ~= 0 then cli.print("") end
  end,
}, ...)
