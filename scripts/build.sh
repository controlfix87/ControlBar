#!/bin/bash
# Builds ControlBar and packages it as build/ControlBar.app.
#
#   scripts/build.sh              # release build for this Mac's architecture
#   UNIVERSAL=1 scripts/build.sh  # arm64 + x86_64
#   CONFIG=debug scripts/build.sh
#
# Signs with the "Perch Local Signing" identity when present (see make-signing-cert.sh) so
# macOS keeps permission grants across rebuilds; otherwise falls back to ad-hoc signing.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

APP="build/ControlBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ControlBar" "$APP/Contents/MacOS/ControlBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

IDENTITY="${PERCH_SIGN_IDENTITY:-Perch Local Signing}"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  SIGN="$IDENTITY"
else
  SIGN="-"
  echo "note: '$IDENTITY' not found, signing ad-hoc (permissions will reset on every rebuild;"
  echo "      run scripts/make-signing-cert.sh once to fix that)"
fi
codesign --force --options runtime --timestamp=none --sign "$SIGN" "$APP"
echo "Built $APP (signed with: $SIGN)"
