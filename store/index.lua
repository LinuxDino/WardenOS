-- WardenOS App Store catalog, read by /os/lib/store.lua (the App Store app and `apt`).
-- Every package: id, name, kind ("app" = a window app in /os/apps, "command" = a terminal command in /os/bin),
-- category (game | tool | command), version (bump it to ship an update), author, description, size (bytes),
-- icon + color (text icon), art (4x2 icon: two rows of { text, text colors, background colors } in blit hex),
-- featured, requires (oldest WardenOS version), files = { { from = path in this repo, to = path on the computer } }.
-- Packages may only write /os/apps/*.lua, /os/bin/*.lua and /os/data/<id>/...
return {
  version = 1,
  packages = {
    {
      id = "snake", name = "Snake", kind = "app", category = "game", version = "1.0.0", author = "WardenOS",
      featured = true, requires = "1.6", icon = "~S", color = "lime",
      art = { { " :  ", "0f00", "f55f" }, { "    ", "0000", "fdde" } },
      summary = "The classic: eat apples, grow longer, never bite yourself.",
      description = "The classic: eat apples, grow longer, never bite yourself. Golden apples are worth five, the walls wrap around and it gets faster the longer you get. Arrows or WASD, or tap where to turn. Plays in a window or as the 'snake' command; the best score is kept.",
      size = 7597,
      files = {
        { from = "store/packages/snake/snake.lua", to = "/os/apps/snake.lua" },
        { from = "store/packages/snake/cmd.lua", to = "/os/bin/snake.lua" },
      },
    },
    {
      id = "2048", name = "2048", kind = "app", category = "game", version = "1.0.0", author = "WardenOS",
      requires = "1.6", icon = "2K", color = "orange",
      art = { { "2048", "0000", "1e2a" }, { "    ", "0000", "45d9" } },
      summary = "Slide the tiles, merge equal numbers, reach 2048.",
      description = "Slide the tiles, merge equal numbers, reach 2048. Arrows / WASD, the buttons or tap a side of the board. Keeps your best score. Also the '2048' command.",
      size = 8269,
      files = {
        { from = "store/packages/2048/2048.lua", to = "/os/apps/2048.lua" },
        { from = "store/packages/2048/cmd.lua", to = "/os/bin/2048.lua" },
      },
    },
    {
      id = "mines", name = "Minesweeper", kind = "app", category = "game", version = "1.0.0", author = "WardenOS",
      requires = "1.6", icon = "*F", color = "red",
      art = { { "1F2 ", "be3f", "0880" }, { " *1 ", "f0bf", "8e08" } },
      summary = "Clear the field without digging up a mine.",
      description = "Clear the field without digging up a mine. Three levels, a safe first dig, a flag mode for touch screens and chording on numbers. Best times per level. Also the 'mines' command.",
      size = 9348,
      files = {
        { from = "store/packages/mines/mines.lua", to = "/os/apps/mines.lua" },
        { from = "store/packages/mines/cmd.lua", to = "/os/bin/mines.lua" },
      },
    },
    {
      id = "blocks", name = "Blocks", kind = "app", category = "game", version = "1.0.0", author = "WardenOS",
      featured = true, requires = "1.6", icon = "[]=", color = "purple",
      art = { { "    ", "0000", "a99f" }, { "    ", "0000", "aa4e" } },
      summary = "Falling blocks: fill whole rows to clear them.",
      description = "Falling blocks: fill whole rows to clear them. Ghost piece, next piece, levels that speed up, hard drop and touch buttons. Also the 'blocks' command.",
      size = 10098,
      files = {
        { from = "store/packages/blocks/blocks.lua", to = "/os/apps/blocks.lua" },
        { from = "store/packages/blocks/cmd.lua", to = "/os/bin/blocks.lua" },
      },
    },
    {
      id = "wardenrun", name = "Warden Run", kind = "app", category = "game", version = "1.0.0", author = "WardenOS",
      featured = true, requires = "1.6", icon = "o/", color = "cyan",
      art = { { "99 o", "99f0", "777f" }, { "/\\ \\", "999b", "777f" } },
      summary = "The Warden is right behind you. Run!",
      description = "The Warden is right behind you. Run through the Deep Dark, jump over sculk and grab echo shards. Space, up or a tap jumps. It plays sounds on an attached speaker. Also the 'wardenrun' command.",
      size = 7488,
      files = {
        { from = "store/packages/wardenrun/wardenrun.lua", to = "/os/apps/wardenrun.lua" },
        { from = "store/packages/wardenrun/cmd.lua", to = "/os/bin/wardenrun.lua" },
      },
    },
    {
      id = "calculator", name = "Calculator", kind = "app", category = "tool", version = "1.0.0", author = "WardenOS",
      requires = "1.6", icon = "+-", color = "lightBlue",
      art = { { " 42 ", "0000", "7777" }, { "+-x=", "3339", "8888" } },
      summary = "A touch calculator with brackets, powers and functions.",
      description = "A touch calculator with brackets, powers, sqrt, trig, logs, pi and the last answer. Type or tap; a history appears when the window is wide. Also the 'calculator' command.",
      size = 8503,
      files = {
        { from = "store/packages/calculator/calculator.lua", to = "/os/apps/calculator.lua" },
        { from = "store/packages/calculator/cmd.lua", to = "/os/bin/calculator.lua" },
      },
    },
    {
      id = "stopwatch", name = "Stopwatch", kind = "app", category = "tool", version = "1.0.0", author = "WardenOS",
      featured = true, requires = "1.6", icon = "(:)", color = "yellow",
      art = { { " /\\ ", "0440", "f44f" }, { " \\/ ", "0440", "f44f" } },
      summary = "Stopwatch with laps and a timer with an alarm.",
      description = "Stopwatch with laps and a countdown timer with presets. When the timer runs out it rings an attached speaker (or flashes) and shows a notification. Also the 'stopwatch' command.",
      size = 8949,
      files = {
        { from = "store/packages/stopwatch/stopwatch.lua", to = "/os/apps/stopwatch.lua" },
        { from = "store/packages/stopwatch/cmd.lua", to = "/os/bin/stopwatch.lua" },
      },
    },
    {
      id = "notes", name = "Notes", kind = "app", category = "tool", version = "1.0.0", author = "WardenOS",
      featured = true, requires = "1.6", icon = "=/", color = "yellow",
      art = { { "=== ", "7770", "4444" }, { "== /", "777f", "4444" } },
      summary = "Quick notes: many notes, the first line is the title.",
      description = "Quick notes: keep as many as you like, the first line is the title. A note list beside the editor when the window is wide, autosave, Ctrl+S / Ctrl+Q. Saved in /os/data/notes. Also the 'notes' command.",
      size = 11082,
      files = {
        { from = "store/packages/notes/notes.lua", to = "/os/apps/notes.lua" },
        { from = "store/packages/notes/cmd.lua", to = "/os/bin/notes.lua" },
      },
    },
    {
      id = "paint", name = "Paint", kind = "app", category = "tool", version = "1.0.0", author = "WardenOS",
      featured = true, requires = "1.6", icon = "~/", color = "pink",
      art = { { " ~  ", "0e00", "e14b" }, { "   /", "000c", "5d9f" } },
      summary = "Pixel art with 16 colors, saved as .nfp images.",
      description = "Pixel art with 16 colors: pen, bucket fill and eraser. Pictures are saved as .nfp (the format of CraftOS paint and paintutils) in /os/data/paint, so other programs can load them.",
      size = 8019,
      files = {
        { from = "store/packages/paint/paint.lua", to = "/os/apps/paint.lua" },
      },
    },
    {
      id = "weather", name = "weather", kind = "command", category = "command", version = "1.0.0", author = "WardenOS",
      featured = true, requires = "1.6", icon = "*", color = "yellow",
      art = { { "\\ | ", "4440", "ffff" }, { "-O- ", "4440", "ffff" } },
      summary = "Time of day, sky and moon of your world.",
      description = "Time of day, sky and moon of your world in the terminal: day number, sunrise / nightfall countdown and the moon phase. With an Environment Detector (Advanced Peripherals) attached it also knows about rain, thunder and the biome. 'weather -s' prints one line.",
      size = 4390,
      files = {
        { from = "store/packages/weather/weather.lua", to = "/os/bin/weather.lua" },
      },
    },
    {
      id = "calc", name = "calc", kind = "command", category = "command", version = "1.0.0", author = "WardenOS",
      requires = "1.6", icon = "=", color = "lightBlue",
      art = { { "1+2 ", "0300", "ffff" }, { "=3  ", "5500", "ffff" } },
      summary = "Quick math in the terminal: calc 2+3*4",
      description = "Quick math in the terminal: 'calc 2+3*4', or just 'calc' for an interactive prompt where 'ans' is the last result. Brackets, powers, sqrt, trig, logs, pi and e. Safe: it never runs code.",
      size = 3918,
      files = {
        { from = "store/packages/calc/calc.lua", to = "/os/bin/calc.lua" },
      },
    },
    {
      id = "timer", name = "timer", kind = "command", category = "command", version = "1.0.0", author = "WardenOS",
      requires = "1.6", icon = "5m", color = "orange",
      art = { { "5:00", "0000", "ffff" }, { "    ", "0000", "9977" } },
      summary = "A countdown with a progress bar: timer 5m tea",
      description = "A countdown with a progress bar right in the terminal: 'timer 5m', 'timer 90', 'timer 1h30m bread'. Rings an attached speaker and shows a notification when the time is up; q cancels.",
      size = 2919,
      files = {
        { from = "store/packages/timer/timer.lua", to = "/os/bin/timer.lua" },
      },
    },
  },
}
