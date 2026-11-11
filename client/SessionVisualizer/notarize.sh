#!/bin/sh
# Builds SessionVisualizer.app signed with a Developer ID, has Apple notarise
# it, staples the ticket to it, checks it the way another Mac will, and leaves
# a zip to hand out.
#
#   client/SessionVisualizer/notarize.sh [output directory]
#
# Default output: client/SessionVisualizer/.build/notarized. Environment:
#   SIGN_IDENTITY   the signing identity. Default: the one "Developer ID
#                   Application" identity in the keychain.
#   NOTARY_PROFILE  the notarytool keychain profile (default skit-notary). It is
#                   made once, by the person whose Apple account it is:
#                     xcrun notarytool store-credentials skit-notary --apple-id … --team-id …
#                   Its password is never an argument or a variable of this script.
#   APP_VERSION     the marketing version. Default: the tag the checkout is on
#                   (v0.2.0 gives 0.2.0), so that the tag, the app and the zip
#                   cannot disagree. Off a tag it has to be given.
#   ALLOW_DIRTY=1   notarise a checkout with uncommitted changes (a trial, not a release).
#
# The everyday build (build.sh without SIGN_IDENTITY, `just client-app-install`)
# stays ad hoc and needs none of this.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
out=${1:-$here/.build/notarized}
profile=${NOTARY_PROFILE:-skit-notary}
app="$out/SessionVisualizer.app"

# What is handed out has to be what a commit says it is.
commit=$(git -C "$repo" describe --tags --always --dirty 2>/dev/null || echo dev)
case "$commit" in
*-dirty | dev)
    if [ "${ALLOW_DIRTY:-}" != 1 ]; then
        echo "notarize.sh: the checkout has uncommitted changes ($commit). Commit them, or set ALLOW_DIRTY=1 for a trial." >&2
        exit 1
    fi
    ;;
esac

version=${APP_VERSION:-}
if [ -z "$version" ]; then
    tag=$(git -C "$repo" describe --tags --exact-match 2>/dev/null || true)
    case "$tag" in
    v[0-9]*) version=${tag#v} ;;
    *)
        echo "notarize.sh: the checkout is not on a release tag (vX.Y.Z). Tag it, or name the version with APP_VERSION." >&2
        exit 1
        ;;
    esac
fi
echo "SessionVisualizer $version, from $commit"

identity=${SIGN_IDENTITY:-}
if [ -z "$identity" ]; then
    found=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p')
    case $(printf '%s\n' "$found" | grep -c .) in
    1) identity=$found ;;
    0)
        echo "notarize.sh: no valid \"Developer ID Application\" identity in the keychain." >&2
        echo "If the certificate is installed and still not valid, Apple's intermediate is missing:" >&2
        echo "  https://www.apple.com/certificateauthority/ (Developer ID - G2), added to the login keychain." >&2
        exit 1
        ;;
    *)
        echo "notarize.sh: more than one Developer ID identity; name one with SIGN_IDENTITY:" >&2
        printf '  %s\n' "$found" >&2
        exit 1
        ;;
    esac
fi
# Asked before the build: a profile that does not answer is found out in a second, not after it.
if ! xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1; then
    echo "notarize.sh: the notarytool profile \"$profile\" does not answer (see the top of this script)." >&2
    exit 1
fi

SIGN_IDENTITY="$identity" APP_VERSION="$version" "$here/build.sh" "$out"
codesign --verify --deep --strict "$app"

upload="$out/upload.zip"
rm -f "$upload"
ditto -c -k --keepParent "$app" "$upload"
echo "sending to Apple (profile $profile); this takes a few minutes"
result=$(xcrun notarytool submit "$upload" --keychain-profile "$profile" --wait --output-format json) || true
rm -f "$upload"
id=$(printf '%s' "$result" | sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p')
status=$(printf '%s' "$result" | sed -n 's/.*"status" *: *"\([^"]*\)".*/\1/p')
if [ "$status" != "Accepted" ]; then
    echo "notarize.sh: Apple answered \"${status:-nothing}\" for submission ${id:-unknown}:" >&2
    [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$profile" >&2 || printf '%s\n' "$result" >&2
    exit 1
fi
echo "accepted: submission $id"

# The ticket goes into the bundle, so the first launch needs no network to be believed.
xcrun stapler staple "$app" >/dev/null
xcrun stapler validate "$app" >/dev/null

# As another Mac's Gatekeeper will judge it.
verdict=$(spctl --assess --type execute -vv "$app" 2>&1) || true
case "$verdict" in
*accepted*"Notarized Developer ID"*) echo "Gatekeeper: accepted, Notarized Developer ID" ;;
*)
    echo "notarize.sh: Gatekeeper does not accept the stapled app:" >&2
    printf '%s\n' "$verdict" >&2
    exit 1
    ;;
esac

zip="$out/SessionVisualizer-$version.zip"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
echo "$zip"
echo "sha256 $(shasum -a 256 "$zip" | cut -d' ' -f1)"
