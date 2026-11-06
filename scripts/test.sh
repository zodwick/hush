#!/bin/bash
# Runs the HushCore tests. With only the Command Line Tools installed (no
# Xcode), the swift-testing macro plugin lives in a folder the compiler
# doesn't search by default, so point it there.
set -euo pipefail
cd "$(dirname "$0")/.."

PLUGINS="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
if [[ -d "$PLUGINS" ]]; then
    swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
else
    swift test "$@"
fi
