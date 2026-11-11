#!/bin/sh
# Builds SessionVisualizer.app: the Swift client, with the skit engine of this
# checkout inside it as Contents/Helpers/skit, signed.
#
#   client/SessionVisualizer/build.sh [output directory]
#
# Default output: client/SessionVisualizer/.build/app. Environment:
#   SIGN_IDENTITY  a code-signing identity ("Developer ID Application: …").
#                  Unset, the app is signed ad hoc: it runs on the Mac that
#                  built it, and Gatekeeper refuses it on any other.
#   APP_VERSION    the marketing version (default 0.1.0).
#
# The app registers the skit-visualizer:// scheme (Copy Link). On first launch
# it installs the background agent for the skit inside it, unless an agent is
# already serving.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
out=${1:-$here/.build/app}
app="$out/SessionVisualizer.app"
identity=${SIGN_IDENTITY:--}
version=${APP_VERSION:-0.1.0}
commit=$(git -C "$repo" describe --tags --always --dirty 2>/dev/null || echo dev)
build=$(git -C "$repo" rev-list --count HEAD 2>/dev/null || echo 1)

echo "building the client (release)"
(cd "$here" && swift build -c release --product SessionVisualizer)
bin=$(cd "$here" && swift build -c release --show-bin-path)

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers"
cp "$bin/SessionVisualizer" "$app/Contents/MacOS/SessionVisualizer"

echo "building skit $commit"
# -trimpath: the helper is shipped, and without it holds the builder's home and checkout paths.
(cd "$repo" && CGO_ENABLED=0 go build -trimpath -ldflags "-X main.version=$commit" -o "$app/Contents/Helpers/skit" ./cmd/skit)

# The icon: every size the Dock, the Finder and Spotlight ask for, from the one drawing
# (Resources/AppIcon.png, made from the logo by Scripts/make-icon.swift).
mkdir -p "$app/Contents/Resources"
iconset=$(mktemp -d)/AppIcon.iconset
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -z $size $size "$here/Resources/AppIcon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$here/Resources/AppIcon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$iconset")"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>SessionVisualizer</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>dev.sessionkit.SessionVisualizer</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>SessionVisualizer</string>
	<key>CFBundleDisplayName</key>
	<string>SessionVisualizer</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$version</string>
	<key>CFBundleVersion</key>
	<string>$build</string>
	<key>SkitCommit</key>
	<string>$commit</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.developer-tools</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLName</key>
			<string>dev.sessionkit.SessionVisualizer.link</string>
			<key>CFBundleTypeRole</key>
			<string>Viewer</string>
			<key>CFBundleURLSchemes</key>
			<array>
				<string>skit-visualizer</string>
			</array>
		</dict>
	</array>
</dict>
</plist>
PLIST
plutil -lint "$app/Contents/Info.plist" >/dev/null

# Inside out: the helper first, then the bundle that seals it. The hardened
# runtime is what notarization asks for; an ad hoc signature gains nothing from it.
if [ "$identity" = "-" ]; then
    echo "signing ad hoc (set SIGN_IDENTITY for a signature other Macs accept)"
    codesign --force --sign - "$app/Contents/Helpers/skit"
    codesign --force --sign - "$app"
else
    echo "signing as $identity"
    codesign --force --options runtime --timestamp --sign "$identity" "$app/Contents/Helpers/skit"
    codesign --force --options runtime --timestamp --sign "$identity" "$app"
fi
codesign --verify --strict "$app"
echo "$app"
