#!/bin/zsh
# Builds the "Nest Hub (Cast)" HAL driver bundle (ad-hoc signed) at $1
# (default: dist/NestHubCast.driver). pkg/build_pkg.sh packages it.
set -e
D=${0:A:h}
OUT=${1:-${0:A:h:h}/dist/NestHubCast.driver}
rm -rf $OUT && mkdir -p $OUT/Contents/MacOS
clang -O2 -arch arm64 -mmacosx-version-min=14.2 -bundle -Wno-deprecated-declarations \
  -o $OUT/Contents/MacOS/NestHubCast $D/NestHubCast.c \
  -framework CoreAudio -framework CoreFoundation -framework Accelerate
cp $D/Info.plist $OUT/Contents/Info.plist
codesign --force --sign - $OUT
codesign -dv $OUT 2>&1 | grep -E "Identifier|Format"
