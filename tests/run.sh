#!/usr/bin/env bash
# Run the met2img unit-test suite.
# Usage: bash tests/run.sh
set -e
cd "$(dirname "$0")/.."

nim c -r --path=src tests/test_geo.nim
nim c -r --path=src tests/test_config.nim
nim c -r -d:H5_FUTURE --path=src tests/test_interp.nim
nim c -r --path=src tests/test_wind.nim
nim c -r --path=src tests/test_lightning.nim

echo "All tests passed."
