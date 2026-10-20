#!/bin/zsh
# Builds dist/Nestcast-<version>.pkg: the Nestcast app, the "Nest Hub (Cast)"
# audio driver, the speaker chooser, and install/uninstall scripts.
# Prerequisite: the self-contained binary from scripts/build.sh
# (<openscreen>/out/Dist/nestcast).
set -euo pipefail
VERSION=${VERSION:-0.1.2}
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
codesign --force --sign - --options runtime --entitlements $REPO/app/entitlements.plist --identifier local.nestcast.core $APP/Contents/MacOS/nestcast-core
codesign --force --sign - --options runtime --entitlements $REPO/app/entitlements.plist --identifier local.nestcast $APP

# Menu bar app (remote control; quitting it does not stop the engine).
MENU="$ROOT/Applications/Nestcast Menu.app"
mkdir -p "$MENU/Contents/MacOS"
sed "s|<string>0.1</string>|<string>$VERSION</string>|" $REPO/menu/Info.plist \
  > "$MENU/Contents/Info.plist"
swiftc -O -target arm64-apple-macos26.0 $REPO/menu/NestcastMenu.swift \
  -o "$MENU/Contents/MacOS/NestcastMenu"
codesign --force --sign - --options runtime --identifier local.nestcast.menu "$MENU"

# Audio driver.
$REPO/driver/build_driver.sh $ROOT/Library/Audio/Plug-Ins/HAL/NestHubCast.driver >/dev/null

chmod +x $REPO/pkg/scripts/*
xattr -cr $ROOT 2>/dev/null || true  # (com.apple.provenance stays; Installer folds ._* back into xattrs)
# Never "relocate" the apps: by default Installer updates an existing bundle
# with the same identifier wherever it lives (e.g. a development copy) instead
# of installing into /Applications.
COPYFILE_DISABLE=1 pkgbuild --root $ROOT --component-plist $REPO/pkg/components.plist \
  --scripts $REPO/pkg/scripts --identifier local.nestcast.pkg \
  --version $VERSION --install-location / --ownership recommended \
  $OUT/Nestcast-$VERSION.pkg
cp $REPO/pkg/resources/uninstall.command "$OUT/Nestcast-Uninstall.command"
chmod +x "$OUT/Nestcast-Uninstall.command"
rm -rf $WORK
ls -la $OUT
