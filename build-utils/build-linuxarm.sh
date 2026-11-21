#!/bin/bash
set -e

# Build Flutter Linux app natively (ARM64 / aarch64)
# Usage: ENV_FILE=.env ./build-utils/build-linuxarm.sh
#
# System dependencies (Ubuntu/Debian):
#   sudo apt-get install -y curl git unzip xz-utils zip libglu1-mesa clang cmake \
#     ninja-build pkg-config libgtk-3-dev liblzma-dev libstdc++-12-dev \
#     libsqlite3-dev libsecret-1-dev libjsoncpp-dev libasound2-dev libpulse-dev \
#     libopus-dev libvorbis-dev libflac-dev libogg-dev python3 imagemagick \
#     patchelf dos2unix desktop-file-utils libgdk-pixbuf2.0-dev fakeroot file \
#     libfuse2 squashfs-tools wget lld

echo "Building Flutter Linux app (ARM64)..."

# Verify Linux
if [ "$(uname -s)" != "Linux" ]; then
    echo "Error: This script must run on Linux."
    exit 1
fi

# Verify architecture
ARCH=$(uname -m)
if [ "$ARCH" != "aarch64" ]; then
    echo "Error: This script is for ARM64 (aarch64). Detected: $ARCH"
    echo "Use build-linux.sh for x86_64 builds."
    exit 1
fi

# Verify Flutter
if ! command -v flutter &> /dev/null; then
    echo "Error: Flutter not found. Please install Flutter first."
    echo "  https://docs.flutter.dev/get-started/install/linux"
    exit 1
fi

# Project root
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

# Environment file
ENV_FILE="${ENV_FILE:-.env}"
ENV_ARG=""
if [ -f "$ENV_FILE" ]; then
    echo "Loading environment from $ENV_FILE..."
    ENV_ARG="--dart-define-from-file=$ENV_FILE"
else
    echo "Env file not found: $ENV_FILE"
fi

# Build cache directory for tools
CACHE_DIR="$PROJECT_ROOT/.cache/build-tools"
mkdir -p "$CACHE_DIR"

# Download and extract linuxdeploy if not present
LINUXDEPLOY_ARCH="aarch64"
LINUXDEPLOY_URL="https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-${LINUXDEPLOY_ARCH}.AppImage"
LINUXDEPLOY_DIR="$CACHE_DIR/linuxdeploy"

if [ ! -d "$LINUXDEPLOY_DIR" ]; then
    echo "Downloading linuxdeploy (${LINUXDEPLOY_ARCH})..."
    wget -q --show-progress "$LINUXDEPLOY_URL" -O "$CACHE_DIR/linuxdeploy.AppImage"
    chmod +x "$CACHE_DIR/linuxdeploy.AppImage"
    cd "$CACHE_DIR"
    ./linuxdeploy.AppImage --appimage-extract >/dev/null 2>&1 || {
        echo "FUSE not available, extracting manually..."
        python3 -c "import sys; d=open('linuxdeploy.AppImage','rb').read(); o=d.find(b'hsqs'); exit(1) if o<0 else open('sqfs','wb').write(d[o:])"
        unsquashfs -d squashfs-root sqfs >/dev/null 2>&1
        rm -f sqfs
    }
    mv squashfs-root linuxdeploy
    rm -f linuxdeploy.AppImage
fi

# Download and extract linuxdeploy-plugin-appimage if not present
PLUGIN_URL="https://github.com/linuxdeploy/linuxdeploy-plugin-appimage/releases/download/continuous/linuxdeploy-plugin-appimage-${LINUXDEPLOY_ARCH}.AppImage"
PLUGIN_DIR="$CACHE_DIR/linuxdeploy-plugin-appimage"

if [ ! -d "$PLUGIN_DIR" ]; then
    echo "Downloading linuxdeploy-plugin-appimage (${LINUXDEPLOY_ARCH})..."
    wget -q --show-progress "$PLUGIN_URL" -O "$CACHE_DIR/plugin.AppImage"
    chmod +x "$CACHE_DIR/plugin.AppImage"
    cd "$CACHE_DIR"
    ./plugin.AppImage --appimage-extract >/dev/null 2>&1 || {
        echo "FUSE not available, extracting manually..."
        python3 -c "import sys; d=open('plugin.AppImage','rb').read(); o=d.find(b'hsqs'); exit(1) if o<0 else open('sqfs','wb').write(d[o:])"
        unsquashfs -d squashfs-root sqfs >/dev/null 2>&1
        rm -f sqfs
    }
    mv squashfs-root linuxdeploy-plugin-appimage
    rm -f plugin.AppImage
fi

cd "$PROJECT_ROOT"

# Clean previous build
echo "Cleaning previous build..."
rm -rf "$PROJECT_ROOT/build/linux"
flutter clean

# Get dependencies
echo "Getting Flutter dependencies..."
flutter pub get

# WORKAROUND: Download and extract mdk-sdk manually to avoid LZMA error in CMake
# The error "Lzma library error: No progress is possible" occurs when cmake extracts inside Docker
# For native builds this may not be needed, but we include it for safety
MDK_SDK_URL="https://sourceforge.net/projects/mdk-sdk/files/nightly/mdk-sdk-linux.tar.xz"
MDK_FILE="$CACHE_DIR/mdk-sdk-linux.tar.xz"

FVP_LINUX_DIR="$PROJECT_ROOT/linux/flutter/ephemeral/.plugin_symlinks/fvp/linux"
if [ -d "$FVP_LINUX_DIR" ]; then
    if [ ! -f "$MDK_FILE" ]; then
        echo "Downloading mdk-sdk..."
        wget -q --show-progress "$MDK_SDK_URL" -O "$MDK_FILE" || { echo "Download failed"; exit 1; }
    else
        echo "Using cached mdk-sdk"
    fi

    echo "Extracting mdk-sdk into fvp plugin..."
    tar -xf "$MDK_FILE" -C "$FVP_LINUX_DIR"

    if [ -d "$FVP_LINUX_DIR/mdk-sdk-linux" ]; then
        echo "Adjusting mdk-sdk structure..."
        mv "$FVP_LINUX_DIR/mdk-sdk-linux/"* "$FVP_LINUX_DIR/"
        rmdir "$FVP_LINUX_DIR/mdk-sdk-linux"
    fi
fi

# Build release
echo "Building Linux release..."

# flutter_soloud bundles precompiled x86_64 ogg/opus/vorbis/flac libs.
# On ARM64 those are not available, so force linking against the system
# libraries installed above.
export TRY_SYSTEM_LIBS_FIRST=1

flutter build linux --release $ENV_ARG

# Get version
VERSION=$(grep 'version:' pubspec.yaml | head -1 | awk '{print $2}' | tr -d '\r')
echo "Version: $VERSION"

# Create release directory
mkdir -p "$PROJECT_ROOT/release"

# Build AppImage
echo "Building AppImage..."
APPDIR="$PROJECT_ROOT/build-utils/appimage/AppDir"
rm -rf "$APPDIR" "$PROJECT_ROOT/build-utils/appimage/"*.AppImage 2>/dev/null || true

mkdir -p "$APPDIR/usr/bin"
mkdir -p "$APPDIR/usr/lib"
mkdir -p "$APPDIR/usr/share"

cp -r "$PROJECT_ROOT/build/linux/arm64/release/bundle/"* "$APPDIR/usr/bin/"

# Verify data directory exists
if [ ! -d "$APPDIR/usr/bin/data" ]; then
    echo "ERROR: data/ directory not found in bundle!"
    exit 1
fi

# Library search paths for ARM64 across Debian/Ubuntu and Fedora/RHEL/Asahi Linux
LIB_SEARCH_PATHS=(
  "/usr/lib/aarch64-linux-gnu"
  "/usr/lib64"
  "/usr/lib"
  "/lib/aarch64-linux-gnu"
  "/lib64"
)

copy_lib_to_appdir() {
  local lib_pattern="$1"
  local found=0
  for search_dir in "${LIB_SEARCH_PATHS[@]}"; do
    if [ -d "$search_dir" ]; then
      while IFS= read -r lib_path; do
        if [ -n "$lib_path" ] && [ -f "$lib_path" ]; then
          cp -L "$lib_path" "$APPDIR/usr/lib/" 2>/dev/null || true
          found=1
        fi
      done < <(find "$search_dir" -maxdepth 1 -name "$lib_pattern" 2>/dev/null)
    fi
  done
  return $found
}

# Copy FFmpeg libraries
echo "Copying FFmpeg libraries..."
for lib in libavcodec.so.* libavformat.so.* libavutil.so.* libswscale.so.* libswresample.so.* libavfilter.so.*; do
  copy_lib_to_appdir "$lib" || true
done

# Copy SQLite3
SQLITE3_FOUND=0
for search_dir in "${LIB_SEARCH_PATHS[@]}"; do
  if [ -f "$search_dir/libsqlite3.so.0" ]; then
    cp -L "$search_dir"/libsqlite3.so.* "$APPDIR/usr/lib/" 2>/dev/null || true
    SQLITE3_FOUND=1
    break
  fi
done
if [ "$SQLITE3_FOUND" = "1" ]; then
  cd "$APPDIR/usr/lib/"
  for f in libsqlite3.so.0.*; do
    [ -f "$f" ] && ln -sf "$f" libsqlite3.so.0
    [ -f "$f" ] && ln -sf "$f" libsqlite3.so
  done
  cd "$PROJECT_ROOT"
  echo "SQLite3 copied with symlinks"
fi

# Copy X11 libraries
echo "Copying X11 libraries..."
for xlib in libX11.so.* libXau.so.* libXdmcp.so.* libXext.so.* libXfixes.so.* libXrender.so.* libXrandr.so.* libXi.so.* libXcursor.so.* libXdamage.so.* libXcomposite.so.* libXpresent.so.* libxcb.so.* libxcb-shm.so.* libxcb-render.so.*; do
  copy_lib_to_appdir "$xlib" || true
done

# Copy SoLoud audio dependencies (loaded at runtime via DynamicLibrary.open — not caught by ldd on main binary)
echo "Copying SoLoud audio libraries..."
for audiolib in libFLAC.so.* libFLAC++.so.* libogg.so.* libvorbis.so.* libvorbisenc.so.* libvorbisfile.so.* libopus.so.*; do
  copy_lib_to_appdir "$audiolib" || true
done

# ...and put them where the loader will actually look. usr/lib is NOT on any
# runtime search path: AppRun deliberately leaves LD_LIBRARY_PATH unset (see the
# note there — setting it shadows system GL/EGL and breaks video), so the only
# bundled directory that resolves is usr/bin/lib, via the executable's
# RUNPATH of $ORIGIN/lib. libflutter_soloud_plugin.so is dlopen'd from there and
# needs its FLAC/Xiph deps alongside it, or audio silently fails on any host that
# doesn't happen to ship the same FLAC SONAME as the build machine.
mkdir -p "$APPDIR/usr/bin/lib"
for audiolib in libFLAC.so.* libFLAC++.so.* libogg.so.* libvorbis.so.* libvorbisenc.so.* libvorbisfile.so.* libopus.so.*; do
  for lib_path in "$APPDIR"/usr/lib/$audiolib; do
    [ -f "$lib_path" ] && cp -L "$lib_path" "$APPDIR/usr/bin/lib/" 2>/dev/null || true
  done
done

# Verify critical audio libraries were bundled. Fedora/Asahi places them under /usr/lib64,
# while Debian/Ubuntu uses /usr/lib/aarch64-linux-gnu. If the build machine lacks the
# -devel/-dev package, CMake may link against a versioned SONAME that we then fail to ship.
# Checked in usr/bin/lib, since a copy anywhere else cannot be loaded, and matched by
# glob rather than by SONAME so the next FLAC bump doesn't silently slip through.
if ! ls "$APPDIR"/usr/bin/lib/libFLAC.so.* >/dev/null 2>&1; then
  echo "ERROR: libFLAC was not bundled. Ensure libflac/libflac-dev is installed and found in one of:"
  printf '  %s\n' "${LIB_SEARCH_PATHS[@]}"
  exit 1
fi

# Copying the libraries next to the plugin is necessary but NOT sufficient: the
# plugin is dlopen'd, and its own DT_NEEDED entries are resolved using ITS RUNPATH,
# not the executable's. CMake bakes in a RUNPATH pointing at the build machine
# (linux/flutter/ephemeral/.plugin_symlinks/...), which exists on no user's system,
# so resolution falls through to the system paths and finds libFLAC only on hosts
# that happen to ship the same SONAME. Point it at its own directory instead.
SOLOUD_PLUGIN="$APPDIR/usr/bin/lib/libflutter_soloud_plugin.so"
if [ -f "$SOLOUD_PLUGIN" ]; then
  if ! command -v patchelf >/dev/null 2>&1; then
    echo "ERROR: patchelf is required to fix the SoLoud plugin's RUNPATH (see the dependency list at the top of this script)."
    exit 1
  fi
  patchelf --set-rpath '$ORIGIN' "$SOLOUD_PLUGIN"
  echo "Set RUNPATH=\$ORIGIN on libflutter_soloud_plugin.so"
fi

# Belt and braces: the plugin is dlopen'd, so a dependency it cannot find surfaces
# only as a silent "no audio" on the user's machine. Assert every Xiph/FLAC library
# it declares is actually sitting next to it. This reads DT_NEEDED rather than using
# ldd on purpose — ldd resolves against the BUILD HOST's /usr/lib and would pass
# happily while shipping an AppImage that loads nowhere else.
if command -v objdump >/dev/null 2>&1 && [ -f "$SOLOUD_PLUGIN" ]; then
  MISSING_AUDIO_DEPS=""
  for dep in $(objdump -p "$SOLOUD_PLUGIN" 2>/dev/null | awk '/NEEDED/{print $2}' | grep -E '^lib(FLAC|ogg|vorbis|opus)'); do
    [ -f "$APPDIR/usr/bin/lib/$dep" ] || MISSING_AUDIO_DEPS="$MISSING_AUDIO_DEPS $dep"
  done
  if [ -n "$MISSING_AUDIO_DEPS" ]; then
    echo "ERROR: libflutter_soloud_plugin.so needs these libraries, which are not in usr/bin/lib:$MISSING_AUDIO_DEPS"
    echo "       Only usr/bin/lib is on the runtime search path (RUNPATH \$ORIGIN/lib);"
    echo "       a copy in usr/lib cannot be loaded."
    exit 1
  fi
fi

# Analyze and copy additional binary dependencies
# Run ldd on main binary AND all bundled .so plugins to catch transitive/runtime-loaded deps
echo "Analyzing binary dependencies..."
SYSTEM_LIB_EXCLUDE='^(libc\.so|libm\.so|libdl\.so|libpthread\.so|librt\.so|ld-linux|libGL|libEGL|libGLX|libdrm|libnvidia|libvulkan|libgtk|libgdk|libgio|libglib|libgobject|libpango|libcairo|libgvfs|libpixbuf|librsvg|libharfbuzz|libfontconfig|libfreetype|libwayland|libmount|libblkid|libpipewire|libspa|libjack|libasound|libpulse)'

copy_ldd_deps() {
  local binary="$1"
  ldd "$binary" 2>/dev/null | grep "=> /" | awk '{print $3}' | while read lib; do
    if [ -f "$lib" ]; then
      libname=$(basename "$lib")
      if [[ ! "$libname" =~ $SYSTEM_LIB_EXCLUDE ]]; then
        if [ ! -f "$APPDIR/usr/lib/$libname" ]; then
          cp -L "$lib" "$APPDIR/usr/lib/" 2>/dev/null || true
        fi
      fi
    fi
  done
}

copy_ldd_deps "$APPDIR/usr/bin/neostation"

# Also analyze all bundled .so files (plugins loaded at runtime)
find "$APPDIR/usr/bin/lib" -name "*.so" -o -name "*.so.*" 2>/dev/null | while read sofile; do
  copy_ldd_deps "$sofile"
done

# Create AppRun
cat > "$APPDIR/AppRun" << 'APPRUN_EOF'
#!/bin/bash
HERE="$(dirname "$(readlink -f "${0}")")"

export XDG_DATA_DIRS="${HERE}/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
# NOTE: Do NOT set LD_LIBRARY_PATH. The binary has RUNPATH:$ORIGIN/lib which
# resolves to usr/bin/lib inside the AppImage, matching the bundle layout.
# Setting LD_LIBRARY_PATH can shadow system GL/EGL libs and break video rendering.
#
# NOTE: Do NOT force GPU selection (e.g. DRI_PRIME, __NV_PRIME_RENDER_OFFLOAD).
# The app and mdk/fvp must use the same GPU. Forcing PRIME offload can cause
# mdk to render on a different GPU than Flutter, resulting in black video.

if [ "$DEBUG_APPIMAGE" = "1" ]; then
  echo "HERE: $HERE"
  echo "LD_LIBRARY_PATH: $LD_LIBRARY_PATH"
  ls -la "${HERE}/usr/bin/data" 2>/dev/null || echo "data dir not found"
  ls "${HERE}/usr/bin/lib" | head -10
fi

cd "${HERE}/usr/bin"
exec ./neostation "$@" 2>&1
APPRUN_EOF
chmod +x "$APPDIR/AppRun"

# Prepare icon and desktop file
echo "Preparing icon and desktop file..."
if [ -f "$PROJECT_ROOT/assets/images/logo.png" ]; then
  convert "$PROJECT_ROOT/assets/images/logo.png" -resize 256x256 "$APPDIR/neostation.png" 2>/dev/null || \
    cp "$PROJECT_ROOT/assets/images/logo.png" "$APPDIR/neostation.png"
elif [ -f "$PROJECT_ROOT/build-utils/appimage/Icon-512.png" ]; then
  convert "$PROJECT_ROOT/build-utils/appimage/Icon-512.png" -resize 256x256 "$APPDIR/neostation.png" 2>/dev/null || \
    cp "$PROJECT_ROOT/build-utils/appimage/Icon-512.png" "$APPDIR/neostation.png"
fi

cp "$PROJECT_ROOT/build-utils/appimage/com.neogamelab.neostation.desktop" "$APPDIR/neostation.desktop" 2>/dev/null || true

if [ -f "$PROJECT_ROOT/linux/packaging/com.neogamelab.neostation.desktop" ]; then
  cp "$PROJECT_ROOT/linux/packaging/com.neogamelab.neostation.desktop" "$APPDIR/neostation.desktop"
fi

# Fix line endings
if [ -f "$APPDIR/neostation.desktop" ]; then
  sed -i 's/\r$//' "$APPDIR/neostation.desktop"
fi

# Create AppImage
echo "Creating AppImage with appimagetool..."
APPIMAGE_OUT="$PROJECT_ROOT/release/neostation-linux-arm64-${VERSION}.AppImage"
mkdir -p "$PROJECT_ROOT/release"
ARCH=aarch64 "$PLUGIN_DIR/usr/bin/appimagetool" "$APPDIR" "$APPIMAGE_OUT"

# Verify output
if [ -f "$APPIMAGE_OUT" ]; then
    chmod 777 "$APPIMAGE_OUT"
    echo ""
    echo "Build completed!"
    echo "Result in: release/"
    ls -lh "$APPIMAGE_OUT"
else
    echo "AppImage creation failed!"
    exit 1
fi
