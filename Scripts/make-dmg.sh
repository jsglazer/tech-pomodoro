#!/bin/bash
#
# make-dmg.sh — build TechPomodoro.app from the XcodeGen project, sign it, and package a
# drag-to-Applications DMG. One command; no third-party tools beyond xcodegen (xcodebuild,
# codesign, hdiutil and xcrun all ship with macOS + Xcode).
#
# The app must be a real, signed bundle for two reasons beyond distribution: NSStatusItem needs a
# bundle, and SMAppService (launch at login) only registers for an app running from one — from
# /Applications, not from a build directory.
#
# The signing tier adapts to what's in your keychain:
#   • "Developer ID Application" identity present  -> hardened-runtime signed
#       + a notarytool profile present             -> notarized & stapled (best)
#   • neither                                      -> ad-hoc signed (local use)
#
# Override detection:
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"   pin the identity
#   NOTARY_PROFILE="tech-pomodoro-notary"                     notarytool profile to use
#   SKIP_NOTARIZE=1                                           sign but don't submit to Apple
#   SKIP_SIGN=1                                               ad-hoc only (local use)
#
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

APP_NAME="TechPomodoro"
SCHEME="TechPomodoro"
PROJECT="$APP_NAME.xcodeproj"
VERSION="$(awk '/MARKETING_VERSION/ {gsub(/[":]/, "", $2); print $2; exit}' project.yml)"

DIST="$ROOT/dist"
DERIVED="$ROOT/.build/xcode"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/${APP_NAME}-${VERSION}.dmg"
mkdir -p "$DIST"

echo "==> tech-pomodoro packager (version $VERSION)"

# 1. Regenerate the Xcode project from its spec, so the DMG can never be built from a stale one.
if command -v xcodegen >/dev/null 2>&1; then
    echo "==> xcodegen generate"
    xcodegen generate >/dev/null
else
    echo "==> xcodegen not installed; using the committed $PROJECT as-is"
fi

# 2. Build Release. CODE_SIGNING_ALLOWED=NO: this script signs the bundle itself in step 4, so the
#    build should not stamp a development signature that step 4 would only have to replace.
echo "==> xcodebuild -scheme $SCHEME -configuration Release"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO \
    build >/dev/null

BUILT="$DERIVED/Build/Products/Release/$APP_NAME.app"
[ -d "$BUILT" ] || { echo "no app bundle at $BUILT" >&2; exit 1; }

# 3. Stage the bundle in dist/ so the signed artifact and the DMG live together.
echo "==> staging $APP"
rm -rf "$APP"
cp -R "$BUILT" "$APP"

# 4. Resolve a signing identity (auto-detect a Developer ID unless pinned or disabled).
if [ -n "${SKIP_SIGN:-}" ]; then
    echo "==> SKIP_SIGN set — ad-hoc only, no notarization (local use)"
    SIGN_IDENTITY=""
elif [ -z "${SIGN_IDENTITY:-}" ]; then
    # `|| true`: grep/head exiting non-zero must not trip `set -o pipefail` and abort the run.
    SIGN_IDENTITY="$(security find-identity -v -p codesigning \
        | grep 'Developer ID Application' | head -1 \
        | sed -E 's/.*"(.*)".*/\1/' || true)"
fi

if [ -n "${SIGN_IDENTITY:-}" ]; then
    echo "==> signing (hardened runtime): $SIGN_IDENTITY"
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
    SIGNED_REAL=1
else
    echo "==> no Developer ID identity; ad-hoc signing (local use only)"
    codesign --force --sign - "$APP"
    SIGNED_REAL=0
fi
codesign --verify --strict --verbose=2 "$APP"

# 5. Notarize — only when Developer-ID-signed and a notary profile exists.
#    Probe the profile with notarytool itself: recent Xcode stores the credential where
#    `security find-generic-password` cannot reliably see it.
NOTARIZED=0
have_profile() {
    xcrun notarytool history --keychain-profile "$1" >/dev/null 2>&1
}
if [ "$SIGNED_REAL" = 1 ] && [ -z "${SKIP_NOTARIZE:-}" ]; then
    for candidate in "${NOTARY_PROFILE:-tech-pomodoro-notary}" "app-router-notary"; do
        if have_profile "$candidate"; then
            NOTARY_PROFILE="$candidate"
            break
        fi
    done
fi
if [ "$SIGNED_REAL" = 1 ] && [ -z "${SKIP_NOTARIZE:-}" ] \
   && [ -n "${NOTARY_PROFILE:-}" ] && have_profile "$NOTARY_PROFILE"; then
    echo "==> notarizing the app via profile '$NOTARY_PROFILE' (submits to Apple, waits)"
    ZIP="$DIST/$APP_NAME-notarize.zip"
    /usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    NOTARIZED=1
elif [ "$SIGNED_REAL" = 1 ]; then
    echo "==> skipping notarization (SKIP_NOTARIZE set, or no notarytool profile found)"
fi

# 6. Build the drag-to-Applications DMG.
echo "==> building DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME $VERSION" \
    -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
[ -f "$DMG" ] || { echo "hdiutil produced no DMG at $DMG" >&2; exit 1; }

# 6b. Sign the disk image itself. hdiutil emits an *unsigned* image, so without this the app inside
#     assesses fine but the container reads as "no usable signature". Sign before notarizing: a new
#     signature invalidates a stapled ticket.
if [ "$SIGNED_REAL" = 1 ]; then
    echo "==> signing the DMG: $SIGN_IDENTITY"
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
    codesign --verify --strict --verbose=2 "$DMG"
fi

# 7. Notarize + staple the DMG itself. A DMG needs its own ticket; it is not covered by the app's.
if [ "$NOTARIZED" = 1 ]; then
    echo "==> notarizing the DMG (submits to Apple, waits)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

# 8. Gatekeeper assessment — what another Mac will actually do with these artifacts.
echo
echo "==> Gatekeeper assessment"
spctl -a -vvv -t exec "$APP" 2>&1 | sed 's/^/    app  /' || true
spctl -a -vvv -t open --context context:primary-signature "$DMG" 2>&1 | sed 's/^/    dmg  /' || true

echo
echo "==> DONE"
echo "    App: $APP"
echo "    DMG: $DMG"
if [ "$NOTARIZED" = 1 ]; then
    echo "    Signing: Developer ID + notarized + stapled (clean double-click install)"
elif [ "$SIGNED_REAL" = 1 ]; then
    echo "    Signing: Developer ID, NOT notarized (Gatekeeper still warns off-machine)"
else
    echo "    Signing: ad-hoc (first launch on another Mac: right-click ▸ Open)"
fi
