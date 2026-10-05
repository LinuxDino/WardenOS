-- vim / vi: a joke, then the CraftOS editor
local cli = dofile("/os/lib/cli.lua").init("vim", shell)
local JOKES = {
  "vim isn't installed. Relax: here you can always get out.",
  "Starting vim... just kidding. You'd never get out.",
  "No vim here, so you won't need :q! today.",
  "Warning: vim not found. Your escape key has been spared.",
}
return cli.main({
  usage = "vim <file>",
  about = "Prints a joke, then edits the file with the CraftOS editor (edit). Press Ctrl for the menu; "
    .. "no :q needed.",
  run = function(_, args)
    local a = args[1]
    if a == ":q" or a == ":q!" or a == ":wq" or a == ":x" or a == "ZZ" then
      cli.print("E37: No write since last change (add ! to override)", colors.red)
      cli.print("...just kidding. You are not in vim. You are free.", colors.lightGray)
      return
    end
    local i = (os.getComputerID() + math.floor(os.clock())) % #JOKES + 1
    cli.print(JOKES[i], colors.green)
    if not a then
      cli.print("How do I exit vim? Asked on the internet 3 million times.", colors.lightGray)
      cli.print("usage: vim <file>", colors.white)
      return
    end
    return cli.run("edit", a)
  end,
}, ...)
