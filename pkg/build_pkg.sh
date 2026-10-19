#!/bin/zsh
# Builds dist/Nestcast-<version>.pkg: the Nestcast app, the "Nest Hub (Cast)"
# audio driver, the speaker chooser, and install/uninstall scripts.
# Prerequisite: the self-contained binary from scripts/build.sh
# (<openscreen>/out/Dist/nestcast).
set -euo pipefail
VERSION=${VERSION:-0.1.0}
REPO=${0:A:h:h}
OPENSCREEN=${OPENSCREEN:-$REPO/../openscreen/openscreen}
CORE=${CORE:-$OPENSCREEN/out/Dist/nestcast}
WORK=$REPO/dist/work; ROOT=$WORK/root; OUT=$REPO/dist
rm -rf $WORK && mkdir -p $ROOT/Applications $ROOT/Library/Audio/Plug-Ins/HAL $OUT

# Nestcast.app: stable launcher (owns the privacy permissions) + engine.
APP=$ROOT/Applications/Nestcast.app
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
sed -e 's|<string>nestcast</string>|<string>Nestcast</string>|' \
    -e "s|<string>0.1</string>|<string>$VERSION</string>|" \
    $REPO/app/Info.plist > $APP/Contents/Info.plist
clang -O2 -arch arm64 -mmacosx-version-min=26.0 -o $APP/Contents/MacOS/Nestcast $REPO/app/launcher.c
cp $CORE $APP/Contents/MacOS/nestcast-core
cp $REPO/pkg/resources/uninstall.command $APP/Contents/Resources/
chmod +x $APP/Contents/Resources/uninstall.command
codesign --force --sign - --identifier local.nestcast.core $APP/Contents/MacOS/nestcast-core
codesign --force --sign - --identifier local.nestcast $APP

# Speaker chooser.
osacompile -o "$ROOT/Applications/Nestcast 스피커 선택.app" $REPO/pkg/resources/choose_hub.applescript
codesign --force --sign - "$ROOT/Applications/Nestcast 스피커 선택.app"

# Audio driver.
$REPO/driver/build_driver.sh $ROOT/Library/Audio/Plug-Ins/HAL/NestHubCast.driver >/dev/null

chmod +x $REPO/pkg/scripts/*
xattr -cr $ROOT 2>/dev/null || true  # (com.apple.provenance stays; Installer folds ._* back into xattrs)
COPYFILE_DISABLE=1 pkgbuild --root $ROOT --scripts $REPO/pkg/scripts --identifier local.nestcast.pkg \
  --version $VERSION --install-location / --ownership recommended \
  $OUT/Nestcast-$VERSION.pkg
cp $REPO/pkg/resources/uninstall.command "$OUT/Nestcast 제거.command"
chmod +x "$OUT/Nestcast 제거.command"
rm -rf $WORK
ls -la $OUT
