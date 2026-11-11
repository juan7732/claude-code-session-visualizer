#!/bin/sh
# Runs SwiftPM for the client so that every Mac builds the same app.
#
#   Scripts/swiftpm.sh build [arguments]     as `swift build`, `swift test`, …
#
# Two things are settled here, both new with the tools of 27 (Swift 6.4):
#
# 1. The build system. From Swift 6.4 SwiftPM's default is a new one. It stamps
#    the binary as built with the SDK of the deployment target (macOS 14), and
#    macOS then draws the app with that year's controls: another title bar,
#    other buttons. It also puts products elsewhere than .build/debug, where
#    the recipes and scripts here look. The older one ("native") stamps the SDK
#    it used. It is asked for by name for as long as SwiftPM has it.
#
# 2. The SDK, with the Command Line Tools and no Xcode. In the macOS 27 SDK
#    SwiftUI's @State is a macro, and the plugin that expands it ships with
#    Xcode only: with the tools alone every view fails with "plugin for module
#    'SwiftUIMacros' not found". The tools also carry the macOS 26 SDK, where
#    @State needs no plugin, so that is what they build against.
#
# DEVELOPER_DIR chooses the tools, as for any Apple tool, and needs no sudo:
#   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer just client-app-install
#
# REVIEW: (2) was run with Xcode 27.2's Swift 6.4 against the 26.5 SDK, not on
# a Mac that has the Command Line Tools 27 alone.
set -eu
[ $# -gt 0 ] || { echo "usage: swiftpm.sh build|test|… [arguments]" >&2; exit 2; }
command=$1
shift

native=""
if swift build --help 2>/dev/null | grep -qw native; then
    native="--build-system native"
fi

dev=$(xcode-select -p 2>/dev/null || true)
case "$dev" in
*CommandLineTools*)
    sdk=$(xcrun --show-sdk-path 2>/dev/null || true)
    if [ -z "${SDKROOT:-}" ] &&
        grep -qs StateMacro "$sdk"/System/Library/Frameworks/SwiftUICore.framework/Modules/SwiftUICore.swiftmodule/*.swiftinterface &&
        [ -z "$(find "$dev" -name libSwiftUIMacros.dylib -maxdepth 8 2>/dev/null | head -1)" ]; then
        older=""
        for d in "$dev"/SDKs/MacOSX26*.sdk; do
            [ -d "$d" ] && older=$d
        done
        if [ -z "$older" ] || [ -z "$native" ]; then
            echo "swiftpm.sh: these Command Line Tools cannot build a SwiftUI app by themselves: the macOS 27 SDK" >&2
            echo "needs a compiler plugin that only Xcode has, and there is no macOS 26 SDK to build against instead." >&2
            echo "With Xcode installed, point at it for this command (no sudo needed):" >&2
            echo "  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer just client-app-install" >&2
            exit 1
        fi
        echo "swiftpm.sh: Command Line Tools without Xcode, building against $(basename "$older")" >&2
        export SDKROOT="$older"
    fi
    ;;
esac

# shellcheck disable=SC2086  # the flag is two words
exec swift "$command" $native "$@"
