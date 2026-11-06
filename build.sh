#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BUILD="$ROOT/build"
mkdir -p "$BUILD"

clang -fobjc-arc -fmodules -Wall -Wextra \
  -Wno-unused-parameter -Wno-incompatible-pointer-types \
  -framework Cocoa -framework CoreGraphics -framework CoreAudio \
  "$ROOT/src/main.m" -o "$BUILD/NotchShelf"

if [ "${1:-}" = "--self-test" ]; then
  rm -rf "$BUILD/self-test"
  exec "$BUILD/NotchShelf" --self-test "$BUILD/self-test"
fi

if [ "${1:-}" = "--clipboard-test" ]; then
  rm -rf "$BUILD/clipboard-test"
  exec "$BUILD/NotchShelf" --clipboard-test "$BUILD/clipboard-test"
fi

if [ "${1:-}" = "--uu-test" ]; then
  rm -rf "$BUILD/uu-test"
  exec "$BUILD/NotchShelf" --uu-test "$BUILD/uu-test"
fi

APP="$BUILD/刘海文件托管.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/NotchShelf" "$APP/Contents/MacOS/NotchShelf"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
# Finder may create AppleDouble sidecars on external volumes; they are not app resources.
find "$APP" -name '._*' -type f -delete
codesign --force --sign - "$APP" >/dev/null
printf 'Built %s\n' "$APP"
