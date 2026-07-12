#!/bin/bash
# Build met2img for 64-bit (native) or 32-bit (cross-compile) targets.
# Usage:
#   ./build.sh           # interactive prompt
#   ./build.sh 64        # build for 64-bit (native)
#   ./build.sh 32        # cross-compile for 32-bit (i386)

TARGET="${1:-}"

if [[ -z "$TARGET" ]]; then
  echo "Build met2img — choose target:"
  echo "  1) 64-bit (native)"
  echo "  2) 32-bit (cross-compile, requires i686 libs)"
  read -p "Selection [1/2]: " choice
  case "$choice" in
    1) TARGET="64" ;;
    2) TARGET="32" ;;
    *) echo "Invalid selection"; exit 1 ;;
  esac
fi

case "$TARGET" in
  64)
    echo "Building 64-bit (native)..."
    nim c -d:danger -d:H5_FUTURE -d:ssl -o:met2img src/met2img.nim
    ;;
  32)
    echo "Building 32-bit (cross-compile)..."
    nim c --cpu:i386 --gcc.options.always:"-m32" --passL:"-m32" \
      -d:danger -d:H5_FUTURE -d:ssl -o:met2img_i386 src/met2img.nim
    ;;
  *)
    echo "Usage: $0 [64|32]"
    exit 1
    ;;
esac
