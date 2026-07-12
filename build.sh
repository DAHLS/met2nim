#!/bin/bash
nim c -d:release -d:H5_FUTURE -d:ssl -o:met2img src/met2img.nim
