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
    libicu-dev libsrtp2-dev libopus-dev libopusfile-dev libvorbis-dev libspeex-dev \
    libspeexdsp-dev libgsm1-dev portaudio19-dev \
    unixodbc unixodbc-dev odbcinst libltdl-dev libsystemd-dev \
    libasound2-dev libjwt-dev liburiparser-dev liblua5.4-dev \
    python3 python3-dev python-is-python3 procps ca-certificates gnupg

# --- 3. DOWNLOAD ---
if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    echo "Usage: $0 [ASTERISK_VERSION]"
    echo ""
    echo "Arguments:"
    echo "  ASTERISK_VERSION  Asterisk version to build (default: 22-current)"
    echo "                    Examples: 22-current, 22.9.0, 21-current"
    exit 0
fi

ASTERISK_VER="$1"
[ -z "$ASTERISK_VER" ] && ASTERISK_VER="22-current"
BUILD_DIR="/usr/src/asterisk_build"

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo ">>> [BUILDER] Downloading Asterisk $ASTERISK_VER..."
ASTERISK_BASE_URL="https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-${ASTERISK_VER}.tar.gz"
wget -qO asterisk.tar.gz "${ASTERISK_BASE_URL}"
wget -qO asterisk.tar.gz.sha256 "${ASTERISK_BASE_URL}.sha256"

echo ">>> [BUILDER] Verifying Asterisk tarball SHA256..."
EXPECTED_SHA=$(awk '{print $1}' asterisk.tar.gz.sha256)
ACTUAL_SHA=$(sha256sum asterisk.tar.gz | awk '{print $1}')
if [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then
    echo ">>> [BUILDER] ERROR: SHA256 checksum mismatch!"
    echo ">>>   Expected: $EXPECTED_SHA"
    echo ">>>   Got:      $ACTUAL_SHA"
    exit 1
fi
echo ">>> [BUILDER] SHA256 verified: OK"
rm asterisk.tar.gz.sha256

tar -xzf asterisk.tar.gz --strip-components=1
rm asterisk.tar.gz

echo ">>> [BUILDER] Downloading MP3 sources..."
contrib/scripts/get_mp3_source.sh

# --- 3b. OPUS OPEN SOURCE CODEC ---
# The official Digium codec_opus binary is x86-only. On ARM64, we inject
# the open-source transcoding module from traud/asterisk-opus instead.
# This enables full Opus encode/decode natively on any architecture.
echo ">>> [BUILDER] Patching in open-source Opus codec for ARM64..."
# Pinned to an IMMUTABLE commit SHA (not a mutable branch): a force-push or
# account compromise of this third-party repo must not be able to silently
# alter the C source that gets compiled into the binary we ship to every user.
# To upgrade, review upstream and bump OPUS_COMMIT deliberately.
# Pin tracks branch asterisk-13.7 as of 2026-05-30.
OPUS_REPO="https://github.com/traud/asterisk-opus"
OPUS_COMMIT="a959f072d3f364be983dd27e6e250b038aaef747"
wget -qO /tmp/opus-patch.tar.gz "${OPUS_REPO}/archive/${OPUS_COMMIT}.tar.gz"
tar -xzf /tmp/opus-patch.tar.gz -C /tmp/
cp -v /tmp/asterisk-opus-${OPUS_COMMIT}/include/asterisk/* ./include/asterisk/
cp -v /tmp/asterisk-opus-${OPUS_COMMIT}/codecs/*              ./codecs/
cp -v /tmp/asterisk-opus-${OPUS_COMMIT}/res/*                 ./res/
rm -rf /tmp/opus-patch.tar.gz /tmp/asterisk-opus-${OPUS_COMMIT}
echo ">>> [BUILDER] Opus open-source codec patched successfully (commit ${OPUS_COMMIT})."

# --- 4. CONFIGURE ---
echo ">>> [BUILDER] Configuring..."
./configure --libdir=/usr/lib \
    --with-pjproject-bundled \
    --with-jansson-bundled \
    --without-x11 \
    --without-gtk2

# Extract actual Asterisk version
# Priority: .version file (most reliable, contains full semver like 22.9.0)
#         → include/asterisk/version.h (generated after configure)
#         → config.log PACKAGE_VERSION (may only contain major version)
if [ -f ".version" ]; then
    REAL_VERSION=$(cat .version | tr -d '[:space:]')
    echo ">>> [BUILDER] Version from .version file: $REAL_VERSION"
elif [ -f "include/asterisk/version.h" ]; then
    REAL_VERSION=$(grep 'ASTERISK_VERSION' include/asterisk/version.h | grep -oP '"[^"]*"' | tr -d '"' | head -n1)
    echo ">>> [BUILDER] Version from version.h: $REAL_VERSION"
else
    REAL_VERSION=$(grep "^PACKAGE_VERSION='" config.log | head -n1 | cut -d"'" -f2 || echo "")
    echo ">>> [BUILDER] Version from config.log: $REAL_VERSION"
fi
[ -z "$REAL_VERSION" ] && REAL_VERSION="unknown"
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
# Enable the open-source Opus transcoding module we patched in earlier
menuselect/menuselect --enable codec_opus_open_source menuselect.makeopts

# --- 6. COMPILE ---
echo ">>> [BUILDER] Checking available disk space before compilation..."
_avail_kb=$(df -k /usr/src 2>/dev/null | awk 'NR==2 {print $4}')
if [ -n "$_avail_kb" ] && [ "$_avail_kb" -lt $(( 6 * 1024 * 1024 )) ]; then
    echo ">>> [BUILDER] ERROR: Insufficient disk space at /usr/src: need 6GB, have $(( _avail_kb / 1024 / 1024 ))GB free"
    exit 1
fi
unset _avail_kb

echo ">>> [BUILDER] Compiling (Native Speed)..."
make -j"$(nproc)"

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
