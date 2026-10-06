std = "luajit"
max_line_length = false -- stylua owns line width
self = false
read_globals = { "G_reader_settings" } -- provided by KOReader
ignore = { "213/_.*" } -- unused loop variables named _something
exclude_files = { "plugin/kindlestories.koplugin/macui.lua", "plugin/kindlestories.koplugin/markdown.lua" } -- vendored kit
