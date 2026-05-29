#!/bin/bash
# Helper script to update the Flutter SDK SHA256 in the Flatpak manifest.
# Usage: bash linux/flatpak/get-flutter-sha256.sh [FLUTTER_VERSION]
#
# If no version is provided, looks up the latest stable version from the
# Flutter releases API. Downloads the tarball, computes SHA256, and updates
# the manifest in-place.

set -e

MANIFEST="linux/flatpak/com.neogamelab.neostation.yml"

# Get Flutter version
if [ -n "$1" ]; then
  FLUTTER_VERSION="$1"
else
  echo "Looking up latest Flutter stable version..."
  RELEASES_JSON=$(curl -s https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json)

  # current_release.stable now returns a commit hash, not a version string.
  # Find the release entry with that hash to extract the actual version.
  STABLE_HASH=$(echo "$RELEASES_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['current_release']['stable'])")
  FLUTTER_VERSION=$(echo "$RELEASES_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
target_hash = '$STABLE_HASH'
for rel in d['releases']:
    if rel.get('hash') == target_hash and rel.get('channel') == 'stable':
        print(rel['version'])
        break
")
  echo "Latest stable: $FLUTTER_VERSION (hash: $STABLE_HASH)"
fi

FLUTTER_URL="https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"

echo "Downloading: $FLUTTER_URL"
TMP_FILE=$(mktemp)
curl -L --progress-bar -o "$TMP_FILE" "$FLUTTER_URL"

echo "Computing SHA256..."
SHA256=$(sha256sum "$TMP_FILE" | awk '{print $1}')
echo "SHA256: $SHA256"

if [ -f "$MANIFEST" ]; then
  sed -i "s|url: https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_.*-stable.tar.xz|url: $FLUTTER_URL|" "$MANIFEST"
  sed -i "s|sha256: .*|sha256: $SHA256|" "$MANIFEST"
  echo "Updated $MANIFEST"
  echo "  Flutter version: $FLUTTER_VERSION"
  echo "  SHA256: $SHA256"
else
  echo "Manifest not found at $MANIFEST"
  echo "Flutter URL: $FLUTTER_URL"
  echo "Flutter SHA256: $SHA256"
fi

rm -f "$TMP_FILE"
