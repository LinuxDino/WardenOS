-- pacman: you are not on Arch
local cli = dofile("/os/lib/cli.lua").init("pacman", shell)
return cli.main({
  usage = "pacman <anything>",
  about = "The Arch Linux package manager. This is not Arch. (WardenOS apps come from the App Store.)",
  stop = true, lenient = true,
  run = function(_, args)
    cli.write("error: ", colors.red)
    cli.print("you cannot perform this operation unless you are Arch.", colors.white)
    cli.print("I use WardenOS btw.", colors.cyan)
    if args[1] and args[1]:match("^%-S") then
      cli.print("(looking for apps? try the App Store)", colors.lightGray)
    end
  end,
}, ...)
