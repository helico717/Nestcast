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

# Nestcast.app: the app the user opens (settings window, optional menu bar
# icon). The streaming engine lives inside it as a helper app, started by
# launchd; closing or quitting the app does not stop it.
APP=$ROOT/Applications/Nestcast.app
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources $APP/Contents/Helpers
sed "s|<string>0.1</string>|<string>$VERSION</string>|" $REPO/ui/Info.plist > $APP/Contents/Info.plist
swiftc -O -target arm64-apple-macos26.0 $REPO/ui/Nestcast.swift -o $APP/Contents/MacOS/Nestcast

# Engine helper: stable launcher (owns the privacy permissions) + engine.
ENGINE="$APP/Contents/Helpers/Nestcast Engine.app"
mkdir -p "$ENGINE/Contents/MacOS"
sed -e 's|<string>nestcast</string>|<string>Nestcast</string>|' \
    -e "s|<string>0.1</string>|<string>$VERSION</string>|" \
    $REPO/app/Info.plist > "$ENGINE/Contents/Info.plist"
clang -O2 -arch arm64 -mmacosx-version-min=26.0 -o "$ENGINE/Contents/MacOS/Nestcast" $REPO/app/launcher.c
cp $CORE "$ENGINE/Contents/MacOS/nestcast-core"
cp $REPO/pkg/resources/uninstall.command $APP/Contents/Resources/
chmod +x $APP/Contents/Resources/uninstall.command
codesign --force --sign - --options runtime --entitlements $REPO/app/entitlements.plist \
  --identifier local.nestcast.engine.core "$ENGINE/Contents/MacOS/nestcast-core"
codesign --force --sign - --options runtime --entitlements $REPO/app/entitlements.plist \
  --identifier local.nestcast.engine "$ENGINE"
codesign --force --sign - --options runtime --entitlements $REPO/app/entitlements.plist \
  --identifier local.nestcast $APP

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
