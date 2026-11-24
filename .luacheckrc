std = "luajit"
globals = {
  "vim",
}
files["tests/**/*.lua"] = {
  globals = {
    "vim",
    "T",
    "_G",
  },
}
max_line_length = 140
unused_args = false
