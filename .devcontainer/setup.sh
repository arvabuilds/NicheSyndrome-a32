#!/bin/bash
set -e  # Exit immediately on any error

echo "============================================"
echo "  A32 Kernel Builder — Environment Setup"
echo "============================================"

CACHE_DIR="/workspace-cache"
TOOLCHAIN_DIR="$CACHE_DIR/toolchains"
CCACHE_DIR="$CACHE_DIR/ccache"

# Create directory structure
mkdir -p "$TOOLCHAIN_DIR/neutron-clang"
mkdir -p "$TOOLCHAIN_DIR/gcc-aarch64"
mkdir -p "$TOOLCHAIN_DIR/gcc-arm32"
mkdir -p "$CCACHE_DIR"

# ----------------------------------------------------------------
# Neutron Clang
# Check if already downloaded (cache hit from previous Codespace)
# ----------------------------------------------------------------
if [ ! -f "$TOOLCHAIN_DIR/neutron-clang/bin/clang" ]; then
    echo ""
    echo "→ Downloading Neutron Clang (latest)..."

    RELEASE_URL=$(curl -s \
        "https://api.github.com/repos/Neutron-Toolchains/clang-build-catalogue/releases/latest" \
        | python3 -c "
import sys, json
data = json.load(sys.stdin)
assets = [a for a in data['assets'] if a['name'].endswith('.tar.zst')]
print(assets[0]['browser_download_url'] if assets else '')
")

    if [ -z "$RELEASE_URL" ]; then
        echo "ERROR: Could not get Neutron Clang release URL"
        echo "Check: https://github.com/Neutron-Toolchains/clang-build-catalogue/releases"
        exit 1
    fi

    echo "  URL: $RELEASE_URL"
    curl -Lo /tmp/neutron-clang.tar.zst "$RELEASE_URL"
    tar -I zstd -xf /tmp/neutron-clang.tar.zst -C "$TOOLCHAIN_DIR/neutron-clang"
    rm /tmp/neutron-clang.tar.zst

    echo "  Clang version: $($TOOLCHAIN_DIR/neutron-clang/bin/clang --version | head -1)"
else
    echo "→ Neutron Clang already cached, skipping download"
    echo "  Version: $($TOOLCHAIN_DIR/neutron-clang/bin/clang --version | head -1)"
fi

# ----------------------------------------------------------------
# GCC aarch64 (64-bit cross compiler)
# ----------------------------------------------------------------
if [ ! -f "$TOOLCHAIN_DIR/gcc-aarch64/bin/aarch64-linux-android-gcc" ]; then
    echo ""
    echo "→ Downloading GCC aarch64..."
    git clone --depth=1 \
        https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9 \
        "$TOOLCHAIN_DIR/gcc-aarch64"
    echo "  Done"
else
    echo "→ GCC aarch64 already cached, skipping download"
fi

# ----------------------------------------------------------------
# GCC arm32 (32-bit compat layer)
# ----------------------------------------------------------------
if [ ! -f "$TOOLCHAIN_DIR/gcc-arm32/bin/arm-linux-androideabi-gcc" ]; then
    echo ""
    echo "→ Downloading GCC arm32..."
    git clone --depth=1 \
        https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.9 \
        "$TOOLCHAIN_DIR/gcc-arm32"
    echo "  Done"
else
    echo "→ GCC arm32 already cached, skipping download"
fi

# ----------------------------------------------------------------
# Configure ccache
# ----------------------------------------------------------------
echo ""
echo "→ Configuring ccache..."
"$TOOLCHAIN_DIR/neutron-clang/bin/clang" --version  # warm up ccache path detection
ccache --max-size=5G
ccache --zero-stats  # reset stats for clean reporting
echo "  Cache size limit: 5 GB"
echo "  Cache location: $CCACHE_DIR"

# ----------------------------------------------------------------
# Create build helper scripts in PATH
# ----------------------------------------------------------------
echo ""
echo "→ Installing build helper scripts..."

# Main build script — so you can just type 'kbuild' from anywhere
cat > /usr/local/bin/kbuild << 'KBUILD_EOF'
#!/bin/bash
# Quick kernel build wrapper
# Usage: kbuild [defconfig] [extra make args]
#
# Examples:
#   kbuild                         — build with current .config
#   kbuild a32_vigus_defconfig     — configure then build
#   kbuild a32_docker_defconfig    — configure then build
#   kbuild "" -j4                  — build with 4 jobs (override auto)

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "/workspaces/$(ls /workspaces | head -1)")
cd "$REPO_ROOT"

DEFCONFIG="${1:-}"
shift 2>/dev/null || true  # shift off defconfig arg if present

CLANG_DIR="/workspace-cache/toolchains/neutron-clang/bin"
GCC64_DIR="/workspace-cache/toolchains/gcc-aarch64/bin"
GCC32_DIR="/workspace-cache/toolchains/gcc-arm32/bin"

MAKE_FLAGS=(
    ARCH=arm64
    SUBARCH=arm64
    CC="$CLANG_DIR/clang"
    CLANG_TRIPLE=aarch64-linux-gnu-
    CROSS_COMPILE="$GCC64_DIR/aarch64-linux-android-"
    CROSS_COMPILE_ARM32="$GCC32_DIR/arm-linux-androideabi-"
    LD="$CLANG_DIR/ld.lld"
    AR="$CLANG_DIR/llvm-ar"
    NM="$CLANG_DIR/llvm-nm"
    OBJCOPY="$CLANG_DIR/llvm-objcopy"
    OBJDUMP="$CLANG_DIR/llvm-objdump"
    STRIP="$CLANG_DIR/llvm-strip"
    LLVM=1
    LLVM_IAS=1
)

# Configure if defconfig was specified
if [ -n "$DEFCONFIG" ]; then
    echo "→ Configuring: $DEFCONFIG"
    make "${MAKE_FLAGS[@]}" "$DEFCONFIG"
fi

# Build
echo "→ Building with $(nproc) jobs..."
START_TIME=$(date +%s)

make -j$(nproc) "${MAKE_FLAGS[@]}" "$@" 2>&1 | tee /tmp/kernel-build.log

EXIT_CODE=${PIPESTATUS[0]}
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

echo ""
echo "================================================"
if [ $EXIT_CODE -eq 0 ]; then
    echo "  BUILD SUCCEEDED in ${ELAPSED}s"
    ls -lh arch/arm64/boot/Image* 2>/dev/null
    ls -lh arch/arm64/boot/*.dtb 2>/dev/null || true
else
    echo "  BUILD FAILED after ${ELAPSED}s"
    echo "  Last errors:"
    grep -E "^.+error:" /tmp/kernel-build.log | tail -20
    echo ""
    echo "  Full log: /tmp/kernel-build.log"
fi
echo "================================================"
exit $EXIT_CODE
KBUILD_EOF
chmod +x /usr/local/bin/kbuild

# Menuconfig wrapper
cat > /usr/local/bin/kmenuconfig << 'MENU_EOF'
#!/bin/bash
# Launch menuconfig with correct cross-compile environment
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "/workspaces/$(ls /workspaces | head -1)")
cd "$REPO_ROOT"
make ARCH=arm64 menuconfig
MENU_EOF
chmod +x /usr/local/bin/kmenuconfig

# ccache stats helper
cat > /usr/local/bin/kstats << 'STATS_EOF'
#!/bin/bash
echo "=== ccache statistics ==="
ccache --show-stats
echo ""
echo "=== Disk usage ==="
du -sh /workspace-cache/toolchains/neutron-clang 2>/dev/null | sed 's/^/  Neutron Clang: /'
du -sh /workspace-cache/toolchains/gcc-aarch64 2>/dev/null   | sed 's/^/  GCC aarch64:   /'
du -sh /workspace-cache/toolchains/gcc-arm32 2>/dev/null     | sed 's/^/  GCC arm32:     /'
du -sh /workspace-cache/ccache 2>/dev/null                   | sed 's/^/  ccache:        /'
df -h /workspaces 2>/dev/null | tail -1 | awk '{print "  Workspace:     " $3 " used / " $2 " total"}'
STATS_EOF
chmod +x /usr/local/bin/kstats

# ----------------------------------------------------------------
# Add toolchain bins to PATH for interactive use
# ----------------------------------------------------------------
PROFILE_ADDITION='
# A32 Kernel Builder — toolchain PATH
export PATH="/workspace-cache/toolchains/neutron-clang/bin:$PATH"
export PATH="/workspace-cache/toolchains/gcc-aarch64/bin:$PATH"
export PATH="/workspace-cache/toolchains/gcc-arm32/bin:$PATH"
export CCACHE_DIR="/workspace-cache/ccache"
export USE_CCACHE=1
'

echo "$PROFILE_ADDITION" >> /root/.bashrc
echo "$PROFILE_ADDITION" >> /root/.profile

# ----------------------------------------------------------------
# Print completion summary
# ----------------------------------------------------------------
echo ""
echo "============================================"
echo "  Setup complete"
echo ""
echo "  Available commands:"
echo "    kbuild [defconfig]   — configure + build"
echo "    kmenuconfig          — interactive Kconfig"
echo "    kstats               — disk and cache usage"
echo ""
echo "  Toolchains:"
$TOOLCHAIN_DIR/neutron-clang/bin/clang --version | head -1 | sed 's/^/    /'
echo "    GCC aarch64: $($TOOLCHAIN_DIR/gcc-aarch64/bin/aarch64-linux-android-gcc --version | head -1)"
echo "    GCC arm32:   $($TOOLCHAIN_DIR/gcc-arm32/bin/arm-linux-androideabi-gcc --version | head -1)"
echo "============================================"
