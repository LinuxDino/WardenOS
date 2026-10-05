-- fortune: a random saying
local cli = dofile("/os/lib/cli.lua").init("fortune", shell)
local F = {
  "Creepers don't hate you. They just want a hug.",
  "There's no place like 127.0.0.1. There's no place like your spawn point either.",
  "The Warden can't see you. It can hear you typing, though.",
  "rm -rf is forever. Backups are for people who like their bases.",
  "A turtle with no fuel is just a very expensive block.",
  "Real programmers count from 0. Real miners count to 64.",
  "It works on my computer. Unfortunately, your computer is a turtle.",
  "Diamonds are found at Y=-59. Happiness is found at Y=64 with a view.",
  "Never dig straight down. Never push to main on a Friday.",
  "To understand recursion, first read this fortune.",
  "The cake is not a lie, but the redstone clock is.",
  "In case of fire: git commit, git push, leave the Nether.",
  "Sudo make me a sandwich. Okay.",
  "Your drone is not lost. It is exploring with confidence.",
  "Enderman says: don't look at the logs. Just don't.",
  "There are 10 kinds of players: those who read binary and those who place torches.",
  "Keep calm and Ctrl+T.",
  "The best time to plant a tree farm was 20 days ago. The second best time is now.",
  "A mob in the hand is worth two in the spawner.",
  "Linux is free if your time is worthless. So is mining by hand.",
  "Lua tables start at 1. Minecraft inventories start at slot 1. Coincidence?",
  "If at first you don't succeed, respawn.",
  "You will find a stack of iron. Then you will drop it in lava.",
  "Have you tried turning it off and on again? (reboot)",
  "Shhh. The sculk sensors are listening.",
  "One does not simply walk into the Deep Dark.",
  "Fuel is temporary. Coal is forever.",
  "Your next build will be perfectly symmetrical. Almost.",
  "WardenOS: because every base deserves a sysadmin.",
  "The quickest way to find a bug: show it to someone else.",
  "A watched furnace never smelts.",
  "Trust the turtle. The turtle knows the way. The turtle has GPS.",
  "Chests are just directories with hinges.",
  "There is no cloud. There is just someone else's chunk loader.",
  "Today's lucky numbers: 64, 16, 1.",
  "He who builds on sand shall meet gravity.",
  "Every bug is a feature that hasn't found its biome yet.",
  "May your pickaxe be enchanted and your merge conflicts few.",
  "Phantoms appear when you don't sleep. So do bugs.",
  "Write once, rednet everywhere.",
  "When in doubt, man man.",
}
return cli.main({
  usage = "fortune [-c] [-a]",
  about = "Print a random saying about Minecraft, Linux and WardenOS.",
  options = { "-c  have the cow say it (cowsay)", "-a  print all of them" },
  flags = { c = true, a = true, w = true },
  run = function(o)
    if o.a then for _, f in ipairs(F) do cli.print(f) end return end
    local i = math.random(1, #F)
    if o.c then return cli.exec("/os/bin/cowsay.lua", _ENV, F[i]) end
    for _, l in ipairs(cli.wrap(F[i], term.getSize())) do cli.print(l, colors.white) end
  end,
}, ...)
