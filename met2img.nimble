# Package
version = "0.1.0"
author = "DAHLS"
description = "Render DMI radar composite + wind on a satellite map (Nim rewrite)"
license = "GPL-3.0"
srcDir = "src"
bin = @["met2img"]

requires "nim >= 2.2.0"
requires "nimhdf5 >= 0.6.3"
requires "arraymancer >= 0.7.33"
requires "pixie >= 6.1.0"

task test, "Run the unit-test suite":
  exec "bash tests/run.sh"
