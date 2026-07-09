std = "luajit"
globals = { "vim" }
max_line_length = false
files["tests"] = {
  ignore = { "631" }, -- long lines in fixtures
}
