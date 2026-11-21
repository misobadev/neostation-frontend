#!/bin/bash

# Build Flutter macOS app
# Usage: ENV_FILE=.env ./build-utils/build-macos.sh

echo "Building Flutter macOS app..."

# Get project root (parent of deploy directory)
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Clean previous build
echo "Cleaning previous build..."
rm -rf "$PROJECT_ROOT/build/macos/Build/Products/Release"
cd "$PROJECT_ROOT"
flutter clean

# Build release
echo "Building macOS release..."
ENV_FILE="${ENV_FILE:-.env}"
ENV_ARG=""
if [ -f "$ENV_FILE" ]; then
    echo "Loading environment from $ENV_FILE..."
    ENV_ARG="--dart-define-from-file=$ENV_FILE"
else
    echo "Env file not found: $ENV_FILE"
fi

flutter build macos --release $ENV_ARG

# Verify Architectures
APP_BUNDLE="$PROJECT_ROOT/build/macos/Build/Products/Release/NeoStation.app"
if [ ! -d "$APP_BUNDLE" ]; then
    APP_BUNDLE="$PROJECT_ROOT/build/macos/Build/Products/Release/Runner.app"
fi

if [ -d "$APP_BUNDLE" ]; then
    BINARY_NAME=$(defaults read "$APP_BUNDLE/Contents/Info.plist" CFBundleExecutable)
    BINARY_PATH="$APP_BUNDLE/Contents/MacOS/$BINARY_NAME"
    echo "Verifying architectures for: $BINARY_NAME"
    lipo -info "$BINARY_PATH"
fi

# Get version from pubspec.yaml
VERSION=$(grep 'version:' pubspec.yaml | sed 's/version: //' | tr -d '\r')

# Create output directory
echo "Creating output directory..."
mkdir -p "$PROJECT_ROOT/release"

# Copy bundle
echo "Copying bundle..."
# Check for NeoStation.app or Runner.app
if [ -d "$PROJECT_ROOT/build/macos/Build/Products/Release/NeoStation.app" ]; then
    APP_PATH="$PROJECT_ROOT/build/macos/Build/Products/Release/NeoStation.app"
elif [ -d "$PROJECT_ROOT/build/macos/Build/Products/Release/Runner.app" ]; then
    APP_PATH="$PROJECT_ROOT/build/macos/Build/Products/Release/Runner.app"
else
    echo "App bundle not found!"
    exit 1
fi

ENTITLEMENTS="$PROJECT_ROOT/macos/Runner/Distribution.entitlements"

# Signing identity: MACOS_SIGNING_IDENTITY when given, otherwise the first
# "Developer ID Application" identity in the keychain (CI imports one), and
# ad-hoc ("-") when there is none, as for pull requests and forks.
IDENTITY="${MACOS_SIGNING_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')
fi

if [ -n "$IDENTITY" ]; then
    echo "Signing with: $IDENTITY"
    # Inside out, as Apple requires: every nested library and framework
    # first, then the app with the hardened runtime and its entitlements.
    find "$APP_PATH/Contents" \( -name "*.dylib" -o -name "*.so" \) -type f -print0 \
        | while IFS= read -r -d '' lib; do
            codesign --force --timestamp --options runtime --sign "$IDENTITY" "$lib"
        done
    find "$APP_PATH/Contents/Frameworks" -maxdepth 1 -name "*.framework" -print0 2>/dev/null \
        | while IFS= read -r -d '' fw; do
            codesign --force --timestamp --options runtime --sign "$IDENTITY" "$fw"
        done
    codesign --force --timestamp --options runtime \
        --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP_PATH"
else
    echo "No Developer ID identity: signing ad-hoc (the app will need to be"
    echo "opened with right-click > Open)."
    codesign --force --deep --sign - --entitlements "$ENTITLEMENTS" "$APP_PATH"
fi

# Verify signature immediately
echo "Verifying new signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -dvvv --entitlements - "$APP_PATH"

# Notarization credentials, in order of preference:
#   - App Store Connect API key: APPLE_API_KEY_ID, APPLE_API_ISSUER_ID and
#     APPLE_API_KEY_PATH (the .p8 file);
#   - Apple ID: APPLE_ID, APPLE_APP_PASSWORD (an app-specific password) and
#     APPLE_TEAM_ID;
#   - a keychain profile saved with `xcrun notarytool store-credentials`:
#     NOTARY_PROFILE.
NOTARY_ARGS=()
if [ -n "${APPLE_API_KEY_ID:-}" ] && [ -n "${APPLE_API_ISSUER_ID:-}" ] && [ -n "${APPLE_API_KEY_PATH:-}" ]; then
    NOTARY_ARGS=(--key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID")
elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ]; then
    NOTARY_ARGS=(--apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" --team-id "$APPLE_TEAM_ID")
elif [ -n "${NOTARY_PROFILE:-}" ]; then
    NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
fi

notarize() {
    # Submits $1 and waits for Apple's verdict; prints the log on rejection.
    local out
    out=$(xcrun notarytool submit "$1" "${NOTARY_ARGS[@]}" --wait 2>&1)
    echo "$out"
    if ! echo "$out" | grep -q "status: Accepted"; then
        local id
        id=$(echo "$out" | awk '/id:/ {print $2; exit}')
        [ -n "$id" ] && xcrun notarytool log "$id" "${NOTARY_ARGS[@]}" || true
        echo "Notarization failed for $1"
        exit 1
    fi
}

if [ -n "$IDENTITY" ] && [ ${#NOTARY_ARGS[@]} -gt 0 ]; then
    # The app first, so its own ticket is stapled and it opens offline once
    # copied out of the DMG.
    echo "Notarizing the app..."
    APP_ZIP="$PROJECT_ROOT/build/NeoStation-notarize.zip"
    rm -f "$APP_ZIP"
    ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"
    notarize "$APP_ZIP"
    xcrun stapler staple "$APP_PATH"
    rm -f "$APP_ZIP"
elif [ -n "$IDENTITY" ]; then
    echo "Signed but not notarized: no notarization credentials were given."
fi

# Check if create-dmg is installed
if ! command -v create-dmg &> /dev/null; then
    echo "create-dmg not found."
    echo "Please install it with: brew install create-dmg"
    exit 1
fi

echo "Creating DMG..."
OUTPUT_DMG="$PROJECT_ROOT/release/neostation-macos-universal-$VERSION.dmg"

# Remove existing DMG
if [ -f "$OUTPUT_DMG" ]; then
    rm "$OUTPUT_DMG"
fi

# Create DMG
create-dmg \
  --volname "NeoStation Installer" \
  --window-pos 200 120 \
  --window-size 800 400 \
  --icon-size 100 \
  --icon "$(basename "$APP_PATH")" 200 190 \
  --hide-extension "$(basename "$APP_PATH")" \
  --app-drop-link 600 185 \
  "$OUTPUT_DMG" \
  "$APP_PATH"

if [ -f "$OUTPUT_DMG" ] && [ -n "$IDENTITY" ]; then
    codesign --force --timestamp --sign "$IDENTITY" "$OUTPUT_DMG"
    if [ ${#NOTARY_ARGS[@]} -gt 0 ]; then
        echo "Notarizing the DMG..."
        notarize "$OUTPUT_DMG"
        xcrun stapler staple "$OUTPUT_DMG"
        spctl --assess --type open --context context:primary-signature -v "$OUTPUT_DMG" || true
    fi
fi

if [ -f "$OUTPUT_DMG" ]; then
    echo ""
    echo "Build completed!"
    echo "Result in: release/"
    ls -lh "$OUTPUT_DMG"
else
    echo "Error creating DMG file"
    exit 1
fi
