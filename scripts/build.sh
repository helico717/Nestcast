#!/bin/zsh
# Builds nestcast from source on an Apple Silicon Mac (macOS 26+).
# Needs: Xcode Command Line Tools, Homebrew `opus` and `libvpx` (static libs
# are linked in, so the result has no Homebrew runtime dependencies).
# Fetches Chromium depot_tools and Open Screen at pinned revisions next to this
# repository (../openscreen), applies our patches, and builds:
#   ../openscreen/openscreen/out/Dist/nestcast
# Then run pkg/build_pkg.sh to make the installer.
set -euo pipefail
REPO=${0:A:h:h}
WORK=${WORK:-$REPO/..}
OPENSCREEN_REV=978e90d34a539bb6580634e1e67b0d673869f11c
BUILD_REV=9eae7c82c57b9e64a85bcf3a246821dffd9d4d5e

command -v clang >/dev/null || { echo "Install Xcode Command Line Tools: xcode-select --install"; exit 1; }
for f in opus libvpx; do
  [[ -d /opt/homebrew/opt/$f ]] || { echo "Missing Homebrew $f: brew install opus libvpx"; exit 1; }
done

cd $WORK
[[ -d depot_tools ]] || git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git
export PATH=$WORK/depot_tools:$PATH
if [[ ! -d openscreen/openscreen ]]; then
  mkdir -p openscreen && (cd openscreen && fetch --nohooks openscreen)
fi
cd openscreen/openscreen
git checkout -q $OPENSCREEN_REV
gclient sync -D
git -C build checkout -q $BUILD_REV

# Patches: Open Screen sender hooks, and Chromium //build support for building
# with only the Command Line Tools (no Xcode.app).
git checkout -q -- . && git -C build checkout -q -- .
git apply $REPO/patches/openscreen.patch
git -C build apply $REPO/patches/chromium-build-clt.patch
ln -sfn $REPO/src nestcast

C=/opt/homebrew/opt
gn gen out/Dist --args="is_debug=false mac_deployment_target=\"26.0\" have_ffmpeg=false have_libsdl2=false have_libopus=true have_libvpx=true have_libaom=false libopus_include_dirs=[\"$C/opus/include\"] libvpx_include_dirs=[\"$C/libvpx/include\"] nestcast_static_libs=[\"/opt/homebrew/lib/libopus.a\",\"/opt/homebrew/lib/libvpx.a\"]"
autoninja -C out/Dist nestcast
echo "Built: $PWD/out/Dist/nestcast"
