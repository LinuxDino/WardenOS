-- rev: reverse each line of files (or the given text)
local cli = dofile("/os/lib/cli.lua").init("rev", shell)
return cli.main({
  usage = "rev <file...|text>",
  about = "Print every line with its characters reversed. If the arguments are not files, the text "
    .. "itself is reversed.",
  stop = true,
  run = function(_, args)
    local files, text = cli.filesOrText(args)
    if not files and not text then cli.fail("usage: rev <file...|text>") end
    if text then cli.print(text:reverse()) return end
    for _, f in ipairs(files) do
      for _, l in ipairs(cli.splitLines(cli.readFile(f))) do cli.print(l:reverse()) end
    end
  end,
}, ...)
