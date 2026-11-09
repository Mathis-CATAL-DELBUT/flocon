#!/bin/bash
# Compile Flocon.app dans ./build
#   ./build.sh            → architecture de ce Mac
#   ./build.sh universal  → Apple Silicon + Intel
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Flocon.app"
FLAGS=(-O -swift-version 5 -enforce-exclusivity=unchecked
       -framework AppKit -framework Metal -framework QuartzCore
       -framework IOKit -framework ServiceManagement -framework Carbon)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [[ "${1:-}" == "universal" ]]; then
  swiftc "${FLAGS[@]}" -target arm64-apple-macos14.0  Sources/*.swift -o build/Flocon-arm64
  swiftc "${FLAGS[@]}" -target x86_64-apple-macos14.0 Sources/*.swift -o build/Flocon-x86_64
  lipo -create build/Flocon-arm64 build/Flocon-x86_64 -output "$APP/Contents/MacOS/Flocon"
  rm build/Flocon-arm64 build/Flocon-x86_64
else
  swiftc "${FLAGS[@]}" -target "$(uname -m)-apple-macos14.0" Sources/*.swift -o "$APP/Contents/MacOS/Flocon"
fi

cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null
echo "OK → $APP"
