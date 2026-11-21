#!/bin/bash
# Generate icons for Flatpak from the app logo.
# Requires imagemagick (convert) or python3 with PIL.
#
# Usage: bash linux/flatpak/generate-icons.sh
#
# Outputs icons to linux/flatpak/icons/ suitable for Flatpak.

set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOGO="$PROJECT_ROOT/assets/images/logo.png"
OUT_DIR="$PROJECT_ROOT/linux/flatpak/icons"

if [ ! -f "$LOGO" ]; then
  echo "Logo not found at $LOGO"
  exit 1
fi

mkdir -p "$OUT_DIR"

SIZES=(48 64 128 256 512)

for size in "${SIZES[@]}"; do
  DIR="$OUT_DIR/${size}x${size}"
  mkdir -p "$DIR"
  OUTPUT="$DIR/com.neogamelab.neostation.png"

  if command -v convert &> /dev/null; then
    convert "$LOGO" -resize "${size}x${size}" "$OUTPUT"
    echo "Created $OUTPUT ($(identify -format '%wx%h' "$OUTPUT"))"
  elif python3 -c "from PIL import Image" 2>/dev/null; then
    python3 -c "
from PIL import Image
img = Image.open('$LOGO')
img = img.resize(($size, $size), Image.LANCZOS)
img.save('$OUTPUT')
print(f'Created $OUTPUT ({size}x{size})')
"
  else
    echo "Error: Install imagemagick or python3-pillow to resize icons"
    exit 1
  fi
done

echo ""
echo "Icons generated in $OUT_DIR"
echo "Copy them to the Flatpak build dir or reference in manifest."
