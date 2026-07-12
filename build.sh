#!/bin/bash
nim c --run -d:danger -o:max -d:H5_FUTURE -d:ssl -o:met2img src/met2img.nim
