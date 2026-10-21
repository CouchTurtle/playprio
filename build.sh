#!/usr/bin/env bash
#
#   ./build.sh            build build/PlayPrio.app
#   ./build.sh install    build, copy to ~/Applications and (re)start it
#   ./build.sh release    build for Apple silicon and Intel, zipped: build/PlayPrio.zip
#
# Signing: without a certificate the app is signed ad hoc. macOS ties the
# Accessibility grant to the signature, so after every rebuild you have to
# remove PlayPrio from System Settings → Privacy & Security → Accessibility and
# add it again. Run scripts/create-signing-identity.sh once and every build is
# signed with the same local certificate, so the grant survives rebuilds.
# Any other identity: PLAYPRIO_SIGN_ID="<name>" ./build.sh install
set -euo pipefail
cd "$(dirname "$0")"

# Plain swiftc instead of `swift build`: works with just the Command Line Tools,
# whose SwiftPM can be out of step with the compiler after macOS updates.
SWIFTC_FLAGS=()

# Some Command Line Tools installs keep a stale usr/include/swift/module.modulemap
# from an older version next to the new bridging.modulemap. Both define
# SwiftBridging and every import fails ("redefinition of module"). Hide the stale
# one through a VFS overlay instead of deleting a system file.
SWIFT_INCLUDE="$(dirname "$(xcrun -f swiftc)")/../include/swift"
if [ -f "$SWIFT_INCLUDE/module.modulemap" ] && [ -f "$SWIFT_INCLUDE/bridging.modulemap" ]; then
  OVERLAY_DIR="$(mktemp -d)"
  trap 'rm -rf "$OVERLAY_DIR"' EXIT
  : > "$OVERLAY_DIR/empty.modulemap"
  INCLUDE_DIR="$(cd "$SWIFT_INCLUDE" && pwd -P)"
  cat > "$OVERLAY_DIR/overlay.yaml" <<EOF
{ "version": 0, "case-sensitive": "false", "roots": [ { "type": "directory", "name": "$INCLUDE_DIR",
  "contents": [ { "type": "file", "name": "module.modulemap", "external-contents": "$OVERLAY_DIR/empty.modulemap" } ] } ] }
EOF
  SWIFTC_FLAGS+=(-vfsoverlay "$OVERLAY_DIR/overlay.yaml")
fi

APP=build/PlayPrio.app
ARCHS="$(uname -m)"
if [ "${1:-}" = "release" ]; then ARCHS="arm64 x86_64"; fi
rm -rf "$APP" build/PlayPrio.zip
mkdir -p "$APP/Contents/MacOS" build/arch
for ARCH in $ARCHS; do
  swiftc -O -swift-version 5 \
    -target "$ARCH-apple-macos14.0" -sdk "$(xcrun --show-sdk-path)" \
    ${SWIFTC_FLAGS[@]+"${SWIFTC_FLAGS[@]}"} \
    Sources/PlayPrio/*.swift -o "build/arch/PlayPrio-$ARCH"
done
lipo -create build/arch/PlayPrio-* -output "$APP/Contents/MacOS/PlayPrio"
rm -rf build/arch
cp Resources/Info.plist "$APP/Contents/Info.plist"
# The icons come from scripts/make-icon.swift (WebIcon.png is the iPhone remote's).
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns Resources/WebIcon.png "$APP/Contents/Resources/"
# Prefer the local identity from scripts/create-signing-identity.sh; ad hoc otherwise.
SIGN_ID="${PLAYPRIO_SIGN_ID:-}"
if [ -z "$SIGN_ID" ] && security find-certificate -c "PlayPrio Local Signing" >/dev/null 2>&1; then
  SIGN_ID="PlayPrio Local Signing"
fi
codesign --force --sign "${SIGN_ID:--}" --identifier local.PlayPrio "$APP"
echo "==> signed with: ${SIGN_ID:-ad hoc (Accessibility must be re-granted after each build)}"
echo "==> $APP"

if [ "${1:-}" = "release" ]; then
  ditto -c -k --norsrc --noextattr --noacl --keepParent "$APP" build/PlayPrio.zip
  echo "==> build/PlayPrio.zip ($(lipo -archs "$APP/Contents/MacOS/PlayPrio"))"
fi

if [ "${1:-}" = "install" ]; then
  pkill -x PlayPrio 2>/dev/null || true
  # Wait for the old instance to exit, or `open` may land on it while it's quitting.
  for _ in $(seq 50); do pgrep -x PlayPrio >/dev/null || break; sleep 0.1; done
  rm -rf "$HOME/Applications/PlayPrio.app"
  cp -R "$APP" "$HOME/Applications/"
  open "$HOME/Applications/PlayPrio.app"
  echo "==> installed and started: ~/Applications/PlayPrio.app"
fi
