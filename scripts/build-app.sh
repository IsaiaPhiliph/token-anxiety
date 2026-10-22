#!/bin/zsh
# Builds "build/Token Anxiety.app", signed ad hoc for this Mac.
#
#   scripts/build-app.sh                       release build
#   scripts/build-app.sh --open [args…]        build, then (re)launch it; args go to the app
#                                              (--demo for sample data, --open-panel, --open-settings)
#   scripts/build-app.sh --install             build and copy it to /Applications
#   CONFIG=debug scripts/build-app.sh …        faster debug build while iterating
set -euo pipefail
cd "${0:A:h}/.."

CONFIG="${CONFIG:-release}"
APP="build/Token Anxiety.app"

swift build -c "$CONFIG" --product TokenAnxiety
BIN="$(swift build -c "$CONFIG" --show-bin-path)/TokenAnxiety"

[[ -f Resources/AppIcon.icns ]] || swift scripts/make-icon.swift Resources

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TokenAnxiety"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --timestamp=none "$APP" >/dev/null
echo "✓ $APP ($CONFIG)"

case "${1:-}" in
  --open)
    shift
    pkill -x TokenAnxiety 2>/dev/null && sleep 0.5 || true
    open "$APP" --args "$@"
    ;;
  --install)
    pkill -x TokenAnxiety 2>/dev/null && sleep 0.5 || true
    rm -rf "/Applications/Token Anxiety.app"
    cp -R "$APP" "/Applications/Token Anxiety.app"
    echo "✓ instalada en /Applications"
    open "/Applications/Token Anxiety.app"
    ;;
esac
