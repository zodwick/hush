#!/bin/bash
# Builds Hush.app and the hushctl debug CLI from source into ./build.
# Usage: scripts/build-app.sh [--open] [--debug] [--install]
#   --open     relaunch the app after building
#   --debug    relaunch with debug control on, so hushctl can talk to it
#   --install  copy to ~/Applications (so Spotlight finds "Hush") and launch
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release --product Hush
swift build -c release --product hushctl

# Spotlight skips folders ending in .noindex, so this staging copy doesn't
# show up next to the installed app when searching "Hush".
APP=build/app.noindex/Hush.app
rm -rf "$APP" build/Hush.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Hush" "$APP/Contents/MacOS/Hush"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$(swift build -c release --show-bin-path)/hushctl" build/hushctl

# Ad-hoc signature: enough for macOS to run it locally and ask for Bluetooth
# permission. Not notarized, so it is only meant for this Mac.
codesign --force --sign - "$APP"

echo "Built $APP"

OPEN=0; DEBUG=0; INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --open) OPEN=1 ;;
        --debug) OPEN=1; DEBUG=1 ;;
        --install) INSTALL=1 ;;
    esac
done

if [[ $INSTALL == 1 ]]; then
    pkill -x Hush 2>/dev/null || true
    sleep 0.5
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/Hush.app"
    cp -R "$APP" "$HOME/Applications/Hush.app"
    mdimport "$HOME/Applications/Hush.app" 2>/dev/null || true
    open "$HOME/Applications/Hush.app"
    echo "Installed to ~/Applications/Hush.app. Launch it from Spotlight: Hush"
    exit 0
fi

if [[ $OPEN == 1 ]]; then
    pkill -x Hush 2>/dev/null || true
    sleep 0.5
    if [[ $DEBUG == 1 ]]; then
        open "$APP" --args -DebugControl YES
        echo "Launched with debug control. Try: build/hushctl status"
    else
        open "$APP"
    fi
fi
