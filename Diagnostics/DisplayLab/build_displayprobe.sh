#!/bin/bash
# Build the read-only XP3Compat DisplayProbe for arm64 iOS Simulator and,
# optionally, arm64 iOS devices.  Outputs are confined to
# Diagnostics/DisplayLab/build and never replace the shipped XP3Compat.dylib.
set -euo pipefail

LAB="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$LAB/../.." && pwd)"
SOURCE="$LAB/DisplayProbe.m"
BUILD="$LAB/build"
PRODUCTION_DYLIB="$ROOT/XP3Compat.dylib"
MIN_IOS="${XP3_DISPLAY_MIN_IOS:-12.0}"
SIM_MIN_IOS="${XP3_DISPLAY_SIM_MIN_IOS:-14.0}"
INSTALL_NAME="${XP3_DISPLAY_INSTALL_NAME:-@executable_path/Frameworks/XP3Compat.dylib}"
MODE="both"

usage() {
    cat <<'EOF'
Usage: build_displayprobe.sh [--simulator-only|--device-only|--both]

Environment:
  XP3_DISPLAY_MIN_IOS        device deployment target (default 12.0)
  XP3_DISPLAY_SIM_MIN_IOS    simulator deployment target (default 14.0)
  XP3_DISPLAY_INSTALL_NAME   dylib install name
                             (default @executable_path/Frameworks/XP3Compat.dylib)
EOF
}

for arg in "$@"; do
    case "$arg" in
        --simulator-only) MODE="simulator" ;;
        --device-only) MODE="device" ;;
        --both) MODE="both" ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Unknown argument: %s\n' "$arg" >&2; usage >&2; exit 2 ;;
    esac
done

if [ ! -f "$SOURCE" ]; then
    printf 'Source is missing: %s\n' "$SOURCE" >&2
    exit 1
fi
if [ ! -d "$BUILD" ]; then
    mkdir -p "$BUILD"
fi

# Refuse any output that is not inside this diagnostic build directory.
assert_build_path() {
    case "$1" in
        "$BUILD"/*) ;;
        *) printf 'Refusing output outside %s: %s\n' "$BUILD" "$1" >&2; exit 1 ;;
    esac
    if [ "$1" = "$PRODUCTION_DYLIB" ]; then
        printf 'Refusing to overwrite the shipped dylib\n' >&2
        exit 1
    fi
}
assert_build_path "$BUILD/DisplayProbe-simulator-arm64.dylib"
assert_build_path "$BUILD/DisplayProbe-device-arm64.dylib"

CLANG="$(xcrun --find clang)"
COMMON=(
    -fobjc-arc -fblocks -fobjc-exceptions -fexceptions
    -O2 -Wall -Wextra -Wno-deprecated-declarations
    -Werror=implicit-function-declaration
    -Wl,-install_name,"$INSTALL_NAME"
    -framework Foundation -framework UIKit -framework CoreGraphics -framework QuartzCore
)

SIM_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null || true)"
DEV_SDK="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)"
SIM_OUT="$BUILD/DisplayProbe-simulator-arm64.dylib"
DEV_OUT="$BUILD/DisplayProbe-device-arm64.dylib"
BUILT=()

sign_and_inspect() {
    local output="$1"
    local platform="$2"
    codesign --force --sign - "$output" >/dev/null
    codesign --verify --strict "$output" >/dev/null
    file "$output"
    printf '  install name: '
    otool -D "$output" | tail -n 1
    printf '  platform: '
    otool -l "$output" | awk '/LC_BUILD_VERSION/{found=1} found && /platform/{print $2; exit}'
    printf '  LC_BUILD_VERSION minos: '
    otool -l "$output" | awk '/LC_BUILD_VERSION/{found=1} found && /minos/{print $2; exit}'
    printf '  sha256: '
    shasum -a 256 "$output" | awk '{print $1}'
    printf '  signed: yes\n'
    printf '  diagnostic platform tag: %s\n' "$platform"
}

if [ "$MODE" = "both" ] || [ "$MODE" = "simulator" ]; then
    if [ -z "$SIM_SDK" ]; then
        printf 'iPhoneSimulator SDK is unavailable.\n' >&2
        exit 1
    fi
    printf 'Building simulator arm64 (min iOS %s)\n' "$SIM_MIN_IOS"
    "$CLANG" -target "arm64-apple-ios${SIM_MIN_IOS}-simulator" -isysroot "$SIM_SDK" \
        "${COMMON[@]}" -dynamiclib "$SOURCE" -o "$SIM_OUT"
    sign_and_inspect "$SIM_OUT" "SIMULATOR"
    BUILT+=("$SIM_OUT")
fi

if [ "$MODE" = "both" ] || [ "$MODE" = "device" ]; then
    if [ -z "$DEV_SDK" ]; then
        if [ "$MODE" = "device" ]; then
            printf 'iPhoneOS SDK is unavailable; cannot build the optional device dylib.\n' >&2
            exit 1
        fi
        printf 'iPhoneOS SDK unavailable; skipping optional device build.\n'
    else
        printf 'Building device arm64 (min iOS %s)\n' "$MIN_IOS"
        "$CLANG" -target "arm64-apple-ios${MIN_IOS}" -isysroot "$DEV_SDK" \
            "${COMMON[@]}" -dynamiclib "$SOURCE" -o "$DEV_OUT"
        sign_and_inspect "$DEV_OUT" "DEVICE"
        BUILT+=("$DEV_OUT")
    fi
fi

if [ "${#BUILT[@]}" -eq 0 ]; then
    printf 'No artifact was built.\n' >&2
    exit 1
fi

MANIFEST="$BUILD/BUILD-MANIFEST.txt"
{
    printf 'XP3Compat DisplayProbe build\n'
    printf 'utc: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'source: Diagnostics/DisplayLab/DisplayProbe.m\n'
    printf 'source_sha256: %s\n' "$(shasum -a 256 "$SOURCE" | awk '{print $1}')"
    printf 'device_min_ios: %s\n' "$MIN_IOS"
    printf 'simulator_min_ios: %s\n' "$SIM_MIN_IOS"
    printf 'install_name: %s\n' "$INSTALL_NAME"
    printf 'simulator_sdk: %s\n' "${SIM_SDK:-unavailable}"
    printf 'device_sdk: %s\n' "${DEV_SDK:-unavailable}"
    for output in "${BUILT[@]}"; do
        printf 'artifact: %s\n' "$(basename "$output")"
        printf 'artifact_sha256: %s\n' "$(shasum -a 256 "$output" | awk '{print $1}')"
        printf 'artifact_minos: %s\n' "$(otool -l "$output" | awk '/LC_BUILD_VERSION/{found=1} found && /minos/{print $2; exit}')"
    done
} > "$MANIFEST"

printf '\nArtifacts (diagnostic only):\n'
for output in "${BUILT[@]}"; do
    printf '  %s\n' "$output"
done
printf '  %s\n' "$MANIFEST"
printf 'Shipped dylib was not touched: %s\n' "$PRODUCTION_DYLIB"
