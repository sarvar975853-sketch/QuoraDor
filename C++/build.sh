#!/bin/bash
# =========================================================
# QUORADOR — build.sh (run this ON macOS, uses MacPorts)
#
# Produces, from a single source tree:
#   dist/mac/Quorador.app       -- native macOS app bundle
#   dist/windows/Quorador.exe   -- native Windows binary
#                                  (Windows 7 SP1, 8, 10, 11 -- x86_64)
#
# If an "appicon.png" file is found next to this script, it is
# automatically converted into both a macOS .icns and a Windows
# .ico and wired up as the icon for both builds. No appicon.png?
# Both builds proceed with the default OS icon, no error.
#
# Requirements: Xcode command line tools + MacPorts.
# Everything else (SDL2, mingw-w64, the Windows SDL2 dev
# package) is installed / downloaded automatically below.
# =========================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$ROOT_DIR/src"
BUILD_DIR="$ROOT_DIR/build"
DIST_DIR="$ROOT_DIR/dist"
THIRDPARTY_DIR="$ROOT_DIR/thirdparty"
APP_NAME="Quorador"
BUNDLE_ID="com.quorador.game"
SDL2_MINGW_VERSION="2.30.6"
SDL2_MINGW_URL="https://github.com/libsdl-org/SDL/releases/download/release-${SDL2_MINGW_VERSION}/SDL2-devel-${SDL2_MINGW_VERSION}-mingw.tar.gz"

log()  { printf '\033[1;36m==> %s\033[0m\n' "$1"; }
warn() { printf '\033[1;33m!! %s\033[0m\n' "$1"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$1"; exit 1; }

if [[ "$(uname -s)" != "Darwin" ]]; then
    die "build.sh is meant to be run on macOS (it cross-compiles the Windows build from here)."
fi

mkdir -p "$BUILD_DIR" "$DIST_DIR" "$THIRDPARTY_DIR"

# ---------------------------------------------------------
# 0. MacPorts + dependencies
# ---------------------------------------------------------
if ! command -v port >/dev/null 2>&1; then
    die "MacPorts not found. Install it from https://www.macports.org/install.php and re-run build.sh."
fi

# MacPorts installs to a prefix (almost always /opt/local); make sure its
# bin/sbin are on PATH for this script even if the current shell doesn't
# already have them (e.g. a fresh Terminal profile).
MACPORTS_PREFIX="$(dirname "$(dirname "$(command -v port)")")"
export PATH="$MACPORTS_PREFIX/bin:$MACPORTS_PREFIX/sbin:$PATH"

log "Checking dependencies (libsdl2, mingw-w64, pkgconfig)..."
PORT_PKGS=(libsdl2 mingw-w64 pkgconfig)
MISSING_PKGS=()
for pkg in "${PORT_PKGS[@]}"; do
    if ! port installed "$pkg" 2>/dev/null | grep -q "(active)"; then
        MISSING_PKGS+=("$pkg")
    fi
done
if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
    log "Installing missing ports (this may ask for your password): ${MISSING_PKGS[*]}"
    sudo port install "${MISSING_PKGS[@]}"
fi

export PKG_CONFIG_PATH="$MACPORTS_PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

# =========================================================
# 0.5. App icon (optional): appicon.png -> AppIcon.icns + AppIcon.ico
# =========================================================
ICON_SRC=""
if [[ -f "$ROOT_DIR/appicon.png" ]]; then
    ICON_SRC="$ROOT_DIR/appicon.png"
elif [[ -f "$(pwd)/appicon.png" ]]; then
    ICON_SRC="$(pwd)/appicon.png"
fi

ICNS_PATH=""
ICO_PATH=""
ICON_BUILD="$BUILD_DIR/icon"

if [[ -n "$ICON_SRC" ]]; then
    log "Found appicon.png ($ICON_SRC) -- generating .icns and .ico from it..."
    rm -rf "$ICON_BUILD"
    mkdir -p "$ICON_BUILD"

    SRC_DIMS="$(sips -g pixelWidth -g pixelHeight "$ICON_SRC" 2>/dev/null | awk '/pixelWidth|pixelHeight/{print $2}')"
    SRC_W="$(echo "$SRC_DIMS" | sed -n '1p')"
    SRC_H="$(echo "$SRC_DIMS" | sed -n '2p')"
    if [[ -n "$SRC_W" && -n "$SRC_H" && "$SRC_W" != "$SRC_H" ]]; then
        warn "appicon.png is ${SRC_W}x${SRC_H} (not square) -- it will be stretched when resized. A square source image is recommended."
    fi

    # ---- macOS .icns via the built-in sips + iconutil ----
    ICONSET="$ICON_BUILD/AppIcon.iconset"
    mkdir -p "$ICONSET"
    # size:filename pairs required by iconutil for a complete iconset
    declare -a ICNS_SIZES=(16 32 32 64 128 256 256 512 512 1024)
    declare -a ICNS_NAMES=(
        "icon_16x16.png" "icon_16x16@2x.png"
        "icon_32x32.png" "icon_32x32@2x.png"
        "icon_128x128.png" "icon_128x128@2x.png"
        "icon_256x256.png" "icon_256x256@2x.png"
        "icon_512x512.png" "icon_512x512@2x.png"
    )
    for i in "${!ICNS_SIZES[@]}"; do
        sz="${ICNS_SIZES[$i]}"
        name="${ICNS_NAMES[$i]}"
        sips -z "$sz" "$sz" "$ICON_SRC" --out "$ICONSET/$name" >/dev/null 2>&1
    done
    if iconutil -c icns "$ICONSET" -o "$ICON_BUILD/AppIcon.icns" >/dev/null 2>&1; then
        ICNS_PATH="$ICON_BUILD/AppIcon.icns"
        log "  built AppIcon.icns"
    else
        warn "iconutil failed to build AppIcon.icns -- continuing with the default app icon."
    fi

    # ---- Windows .ico, hand-built (PNG-in-ICO, valid on Vista+/Win7+) ----
    ICO_SIZES=(16 32 48 256)
    ICO_PNGS=()
    for sz in "${ICO_SIZES[@]}"; do
        out="$ICON_BUILD/ico_${sz}.png"
        sips -z "$sz" "$sz" "$ICON_SRC" --out "$out" >/dev/null 2>&1
        ICO_PNGS+=("$out")
    done

    cat > "$ICON_BUILD/make_ico.py" << 'PYEOF'
# Packs a set of same-format PNGs into a valid .ico container.
# Modern Windows (Vista+) accepts PNG-compressed frames directly inside
# ICO files, so no bitmap re-encoding is needed -- just PNG bytes plus
# a small ICONDIR/ICONDIRENTRY header, per the ICO file format spec.
import struct, sys

def build_ico(png_paths, out_path):
    images = []
    for p in png_paths:
        with open(p, 'rb') as f:
            data = f.read()
        if data[:8] != b'\x89PNG\r\n\x1a\n':
            raise ValueError(f"{p} is not a valid PNG")
        w = struct.unpack('>I', data[16:20])[0]
        h = struct.unpack('>I', data[20:24])[0]
        images.append((w, h, data))
    n = len(images)
    header = struct.pack('<HHH', 0, 1, n)
    entries = b''
    offset = 6 + 16 * n
    payload = b''
    for (w, h, data) in images:
        bw = w if w < 256 else 0
        bh = h if h < 256 else 0
        entries += struct.pack('<BBBBHHII', bw, bh, 0, 0, 1, 32, len(data), offset)
        payload += data
        offset += len(data)
    with open(out_path, 'wb') as f:
        f.write(header)
        f.write(entries)
        f.write(payload)

if __name__ == '__main__':
    build_ico(sys.argv[2:], sys.argv[1])
PYEOF

    PYTHON_BIN="$(command -v python3 || true)"
    if [[ -n "$PYTHON_BIN" ]]; then
        if "$PYTHON_BIN" "$ICON_BUILD/make_ico.py" "$ICON_BUILD/AppIcon.ico" "${ICO_PNGS[@]}"; then
            ICO_PATH="$ICON_BUILD/AppIcon.ico"
            log "  built AppIcon.ico"
        else
            warn "Failed to build AppIcon.ico -- continuing with the default exe icon."
        fi
    else
        warn "python3 not found -- can't build AppIcon.ico, continuing with the default exe icon."
    fi
else
    log "No appicon.png found next to build.sh -- both builds will use the default OS icon."
    log "  (drop a square PNG named 'appicon.png' next to build.sh to give Quorador a custom icon)"
fi

# =========================================================
# 1. macOS native build
# =========================================================
log "Building native macOS binary..."

MAC_BUILD="$BUILD_DIR/mac"
mkdir -p "$MAC_BUILD"

if command -v sdl2-config >/dev/null 2>&1; then
    SDL2_CFLAGS="$(sdl2-config --cflags)"
    SDL2_LIBS="$(sdl2-config --libs)"
else
    SDL2_CFLAGS="$(pkg-config --cflags sdl2)"
    SDL2_LIBS="$(pkg-config --libs sdl2)"
fi

clang++ -std=c++17 -O2 -Wall -Wextra -Wno-unused-parameter \
    $SDL2_CFLAGS \
    "$SRC_DIR/main.cpp" \
    -o "$MAC_BUILD/$APP_NAME" \
    $SDL2_LIBS \
    -framework CoreAudio -framework AudioToolbox -framework CoreVideo \
    -framework Cocoa -framework IOKit -framework ForceFeedback \
    -framework Carbon -framework Metal -framework QuartzCore -framework GameController \
    -lpthread

log "Native binary built: $MAC_BUILD/$APP_NAME"

# ---- assemble the .app bundle ----
log "Assembling $APP_NAME.app ..."

APP_BUNDLE="$DIST_DIR/mac/$APP_NAME.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$APP_BUNDLE/Contents/Frameworks"

cp "$MAC_BUILD/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

ICON_PLIST_ENTRY=""
if [[ -n "$ICNS_PATH" ]]; then
    cp "$ICNS_PATH" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    ICON_PLIST_ENTRY="    <key>CFBundleIconFile</key><string>AppIcon</string>"
fi

cat > "$APP_BUNDLE/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>10.13</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Quorador</string>
${ICON_PLIST_ENTRY}
</dict>
</plist>
PLIST

# Bundle SDL2's dylib into the app so it runs on machines without MacPorts'
# SDL2 installed, and repoint the binary + dylib to load it via @rpath.
SDL2_DYLIB_PATH="$(otool -L "$APP_BUNDLE/Contents/MacOS/$APP_NAME" | grep -i 'libSDL2' | awk '{print $1}' | head -n1 || true)"
if [[ -n "$SDL2_DYLIB_PATH" ]]; then
    SDL2_DYLIB_REAL="$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$SDL2_DYLIB_PATH" 2>/dev/null || echo "$SDL2_DYLIB_PATH")"
    cp -L "$SDL2_DYLIB_REAL" "$APP_BUNDLE/Contents/Frameworks/libSDL2.dylib"
    chmod +w "$APP_BUNDLE/Contents/Frameworks/libSDL2.dylib"
    install_name_tool -id "@rpath/libSDL2.dylib" "$APP_BUNDLE/Contents/Frameworks/libSDL2.dylib"
    install_name_tool -change "$SDL2_DYLIB_PATH" "@rpath/libSDL2.dylib" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true
    log "Bundled libSDL2.dylib into the .app (no MacPorts SDL2 required to run it)."
else
    warn "Could not detect the SDL2 dylib path via otool -- the .app will require SDL2 to be installed on the target Mac."
fi

# Touch the bundle so Finder/LaunchServices notices the (possibly new) icon,
# then ad-hoc codesign it.
touch -c "$APP_BUNDLE"
codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1 || warn "Ad-hoc codesign failed (app will still run, just may warn on first launch)."

log "macOS app ready: $APP_BUNDLE"

# =========================================================
# 2. Windows cross-build (via mingw-w64)
# =========================================================
log "Preparing Windows cross-build toolchain..."

MINGW_CXX="x86_64-w64-mingw32-g++"
MINGW_WINDRES="x86_64-w64-mingw32-windres"
if ! command -v "$MINGW_CXX" >/dev/null 2>&1; then
    die "mingw-w64 not found on PATH even after 'port install mingw-w64'. Try 'sudo port install mingw-w64' manually and check $MACPORTS_PREFIX/bin is on PATH."
fi

# mingw-w64 must be the posix-threads variant for std::thread/std::mutex to
# work. MacPorts' mingw-w64 port provides this by default. If your toolchain
# was built with the win32-threads variant instead, this compile will fail
# with errors mentioning '__gthread_cond_t' -- see README.md for the fix.
SDL2_MINGW_ROOT="$THIRDPARTY_DIR/SDL2-${SDL2_MINGW_VERSION}"
if [[ ! -d "$SDL2_MINGW_ROOT/x86_64-w64-mingw32" ]]; then
    log "Downloading SDL2 ${SDL2_MINGW_VERSION} mingw devel package..."
    curl -fL -o "$THIRDPARTY_DIR/sdl2-mingw.tar.gz" "$SDL2_MINGW_URL"
    tar xzf "$THIRDPARTY_DIR/sdl2-mingw.tar.gz" -C "$THIRDPARTY_DIR"
fi
SDL2_WIN_DIR="$SDL2_MINGW_ROOT/x86_64-w64-mingw32"

# ---- Windows icon resource (optional) ----
WIN_ICON_OBJS=()
if [[ -n "$ICO_PATH" ]]; then
    if command -v "$MINGW_WINDRES" >/dev/null 2>&1; then
        log "Embedding AppIcon.ico into the Windows build..."
        cat > "$ICON_BUILD/appicon.rc" << RC
IDI_ICON1 ICON "${ICO_PATH}"
RC
        if "$MINGW_WINDRES" "$ICON_BUILD/appicon.rc" -O coff -o "$ICON_BUILD/appicon_res.o"; then
            WIN_ICON_OBJS+=("$ICON_BUILD/appicon_res.o")
        else
            warn "windres failed to compile the icon resource -- Quorador.exe will use the default exe icon."
        fi
    else
        warn "$MINGW_WINDRES not found -- Quorador.exe will use the default exe icon."
    fi
fi

log "Cross-compiling Quorador.exe for Windows (x86_64, static, Win7 SP1+)..."

WIN_BUILD="$BUILD_DIR/windows"
mkdir -p "$WIN_BUILD"

"$MINGW_CXX" -std=c++17 -O2 -Wall -Wextra -Wno-unused-parameter \
    -I"$SDL2_WIN_DIR/include/SDL2" \
    "$SRC_DIR/main.cpp" \
    "${WIN_ICON_OBJS[@]}" \
    -o "$WIN_BUILD/$APP_NAME.exe" \
    -L"$SDL2_WIN_DIR/lib" \
    -static -static-libgcc -static-libstdc++ \
    -lmingw32 -lSDL2main -lSDL2 -lwinmm -limm32 -lversion -lsetupapi -lole32 -loleaut32 -luuid \
    -mwindows

mkdir -p "$DIST_DIR/windows"
cp "$WIN_BUILD/$APP_NAME.exe" "$DIST_DIR/windows/$APP_NAME.exe"

log "Windows binary ready: $DIST_DIR/windows/$APP_NAME.exe"
log "  (statically linked -- no SDL2.dll or MinGW runtime DLLs needed on the target PC)"

# =========================================================
# Done
# =========================================================
echo
log "Build complete."
echo "  macOS app  : $DIST_DIR/mac/$APP_NAME.app"
echo "  Windows exe: $DIST_DIR/windows/$APP_NAME.exe"
if [[ -n "$ICNS_PATH" || -n "$ICO_PATH" ]]; then
    echo "  Custom icon: applied from appicon.png"
else
    echo "  Custom icon: none (add appicon.png next to build.sh and re-run to set one)"
fi
echo
echo "To test the Windows build on your Mac, you can use Wine:"
echo "  sudo port install wine-devel"
echo "  wine \"$DIST_DIR/windows/$APP_NAME.exe\""
