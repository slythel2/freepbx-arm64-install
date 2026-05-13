#!/bin/bash

# ============================================================================
# AUTOMATED BUILD SCRIPT Native ARM64
# TARGET: Asterisk 22 LTS for Debian 12 (Bookworm)
# ============================================================================

# Stop execution on any error
set -e

# --- 1. BOOTSTRAP ---
echo ">>> [BUILDER] Starting NATIVE build process..."
export DEBIAN_FRONTEND=noninteractive

# Determine Output Directory based on environment
if [ -n "$GITHUB_WORKSPACE" ]; then
    OUTPUT_DIR="$GITHUB_WORKSPACE"
    echo ">>> [BUILDER] Detected GitHub Actions Native Environment. Output to: $OUTPUT_DIR"
else
    OUTPUT_DIR="/workspace"
    echo ">>> [BUILDER] Defaulting output to: $OUTPUT_DIR"
fi

mkdir -p "$OUTPUT_DIR"

# --- 2. DEPENDENCIES ---
echo ">>> [BUILDER] Installing dependencies..."
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    build-essential libc6-dev linux-libc-dev gcc g++ \
    git curl wget subversion pkg-config \
    autoconf automake libtool binutils \
    bison flex xmlstarlet libxml2-utils \
    libncurses5-dev libncursesw5-dev libxml2-dev libsqlite3-dev sqlite3 \
    libssl-dev uuid-dev libjansson-dev libedit-dev libxslt1-dev \
    libicu-dev libsrtp2-dev libopus-dev libvorbis-dev libspeex-dev \
    libspeexdsp-dev libgsm1-dev portaudio19-dev \
    unixodbc unixodbc-dev odbcinst libltdl-dev libsystemd-dev \
    libasound2-dev libjwt-dev liburiparser-dev liblua5.4-dev \
    python3 python3-dev python-is-python3 procps ca-certificates gnupg

# --- 3. DOWNLOAD ---
ASTERISK_VER="$1"
[ -z "$ASTERISK_VER" ] && ASTERISK_VER="22-current"
BUILD_DIR="/usr/src/asterisk_build"

mkdir -p $BUILD_DIR
cd $BUILD_DIR

echo ">>> [BUILDER] Downloading Asterisk $ASTERISK_VER..."
wget -qO asterisk.tar.gz "https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-${ASTERISK_VER}.tar.gz"
tar -xzf asterisk.tar.gz --strip-components=1
rm asterisk.tar.gz

echo ">>> [BUILDER] Downloading MP3 sources..."
contrib/scripts/get_mp3_source.sh

# --- 4. CONFIGURE ---
echo ">>> [BUILDER] Configuring..."
./configure --libdir=/usr/lib \
    --with-pjproject-bundled \
    --with-jansson-bundled \
    --without-x11 \
    --without-gtk2

# Extract actual Asterisk version from configure output
REAL_VERSION=$(grep 'PACKAGE_VERSION' config.log | head -n1 | cut -d"'" -f2 || echo "unknown")
echo ">>> [BUILDER] Detected Asterisk version: $REAL_VERSION"
echo "$REAL_VERSION" > /tmp/asterisk_version.txt

# --- 4b. PATCH: Fix pjproject for GCC 12+ on aarch64 ---
# Asterisk's bundled pjproject may fail because config_site.h includes system
# headers (via asterisk_malloc_debug.h) before PJ_DECL is defined in config.h.
# This prepends forward macro definitions. Safe & idempotent.
PJCFG="$BUILD_DIR/third-party/pjproject/source/pjlib/include/pj/config_site.h"
if [ -f "$PJCFG" ]; then
    if ! grep -q "PJ_DECL_COMPAT_FWD" "$PJCFG"; then
        echo ">>> [BUILDER] Patching pjproject config_site.h for GCC 12+ compatibility..."
        TMPFILE=$(mktemp)
        cat > "$TMPFILE" << 'PATCHEOF'
/* PJ_DECL_COMPAT_FWD: Forward-declare pjproject macros for GCC 12+.
 * Prevents cascading errors when config_site.h includes system headers
 * before these macros are defined later in config.h.
 * Identical to upstream defaults — safe even after upstream fixes this. */
#ifndef PJ_DECL
#define PJ_DECL(type)       extern type
#endif
#ifndef PJ_DECL_DATA
#define PJ_DECL_DATA(type)  extern type
#endif
#ifndef PJ_DEF
#define PJ_DEF(type)        type
#endif
#ifndef PJ_INLINE
#define PJ_INLINE(type)     static __inline__ type
#endif

PATCHEOF
        cat "$PJCFG" >> "$TMPFILE"
        mv "$TMPFILE" "$PJCFG"
        echo ">>> [BUILDER] Patch applied successfully."
    else
        echo ">>> [BUILDER] pjproject patch already applied, skipping."
    fi
else
    echo ">>> [BUILDER] WARNING: pjproject config_site.h not found at expected path."
fi

# --- 5. CLEAN & SELECT ---
make -C third-party/pjproject clean || true

make menuselect.makeopts
menuselect/menuselect --enable format_mp3 menuselect.makeopts
menuselect/menuselect --enable CORE-SOUNDS-EN-WAV menuselect.makeopts
menuselect/menuselect --enable CORE-SOUNDS-EN-ULAW menuselect.makeopts
menuselect/menuselect --enable CORE-SOUNDS-EN-ALAW menuselect.makeopts
menuselect/menuselect --enable CORE-SOUNDS-EN-GSM menuselect.makeopts
# BUILD_NATIVE is disabled to avoid optimizing for the specific CPU used by Github Workflows.
menuselect/menuselect --disable BUILD_NATIVE menuselect.makeopts

# --- 6. COMPILE ---
echo ">>> [BUILDER] Compiling (Native Speed)..."
make -j$(nproc)

# --- 7. INSTALL & PACKAGE ---
echo ">>> [BUILDER] Packaging..."
make install DESTDIR=$BUILD_DIR/staging
make samples DESTDIR=$BUILD_DIR/staging

mkdir -p "$BUILD_DIR/staging/etc/init.d"
mkdir -p "$BUILD_DIR/staging/etc/default"
mkdir -p "$BUILD_DIR/staging/usr/lib/systemd/system"

make config DESTDIR=$BUILD_DIR/staging

# Include version file in the tarball
if [ -f /tmp/asterisk_version.txt ]; then
    cp /tmp/asterisk_version.txt $BUILD_DIR/staging/VERSION.txt
fi

cd $BUILD_DIR/staging
TAR_NAME="asterisk-${ASTERISK_VER}-arm64-debian12.tar.gz"
echo ">>> [BUILDER] Creating archive at $OUTPUT_DIR/$TAR_NAME..."
tar -czvf "$OUTPUT_DIR/$TAR_NAME" .

echo ">>> [BUILDER] SUCCESS! Artifact ready: $TAR_NAME"
