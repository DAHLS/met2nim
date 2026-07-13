#!/usr/bin/env bash
# Build met2img for 64-bit (native) or 32-bit (cross-compile) targets.
# Usage:
#   ./build.sh           # interactive prompt
#   ./build.sh 64        # build for 64-bit (native)
#   ./build.sh 32        # cross-compile for 32-bit (i386)
set -euo pipefail

TARGET="${1:-}"

if [[ -z "$TARGET" ]]; then
  echo "Build met2img — choose target:"
  echo "  1) 64-bit (native)"
  echo "  2) 32-bit (cross-compile, requires i686 libs)"
  read -rp "Selection [1/2]: " choice
  case "$choice" in
    1) TARGET="64" ;;
    2) TARGET="32" ;;
    *) echo "Invalid selection"; exit 1 ;;
  esac
fi

# -d:release keeps runtime checks (bounds/overflow) — the binary parses
# network data unattended, so a logged IndexDefect beats a silent segfault.
FLAGS=(-d:release -d:H5_FUTURE -d:ssl)

case "$TARGET" in
  64)
    echo "Building 64-bit (native)..."
    nim c "${FLAGS[@]}" --nimcache:nimcache/amd64 -o:met2img src/met2img.nim
    ;;
  32)
    echo "Building 32-bit (cross-compile)..."
    # Nim's Linux config never adds -m32 for --cpu:i386 (unlike its Windows
    # mingw handling), so pass it to both the C compile and link steps.
    # Per-target nimcache avoids mixing 32/64-bit objects between builds.
    nim c --cpu:i386 --passC:"-m32" --passL:"-m32" \
      "${FLAGS[@]}" --nimcache:nimcache/i386 -o:met2img_i386 src/met2img.nim
    ;;
  *)
    echo "Usage: $0 [64|32]"
    exit 1
    ;;
esac
