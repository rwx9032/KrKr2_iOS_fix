#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${XP3_BUILD_DIR:-$ROOT/.build}"
OUTPUT="${XP3_OUTPUT:-$ROOT/XP3Compat.dylib}"
MODE="${XP3_BUILD_MODE:-auto}"
MIN_IOS="${XP3_MIN_IOS:-12.0}"
CLANG="${CC:-$(xcrun --find clang)}"
PYTHON="${PYTHON:-python3}"
SOURCE="$ROOT/Sources/XP3Compat.m"

mkdir -p "$BUILD_DIR" "$(dirname "$OUTPUT")"
if [ ! -f "$SOURCE" ]; then
    printf 'Source is missing: %s\n' "$SOURCE" >&2
    exit 1
fi
SDK=""
if [ "$MODE" != "minimal" ]; then
    SDK="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)"
fi
if [ "$MODE" = "sdk" ] && [ -z "$SDK" ]; then
    printf 'XP3_BUILD_MODE=sdk requires an installed iPhoneOS SDK.\n' >&2
    exit 1
fi
if [ "$MODE" != "auto" ] && [ "$MODE" != "sdk" ] && [ "$MODE" != "minimal" ]; then
    printf 'Unknown XP3_BUILD_MODE: %s (use auto, sdk or minimal).\n' "$MODE" >&2
    exit 1
fi

COMMON=( -target "arm64-apple-ios$MIN_IOS" -fobjc-arc -fblocks
    -fno-objc-msgsend-selector-stubs
    -fobjc-exceptions -fexceptions -fvisibility=hidden -O2
    -Wall -Wextra -Werror=implicit-function-declaration
    -I "$ROOT/Sources" )
INSTALL_NAME="@executable_path/Frameworks/XP3Compat.dylib"
if [ -n "$SDK" ]; then
    printf 'Building with iPhoneOS SDK: %s\n' "$SDK"
    "$CLANG" "${COMMON[@]}" -isysroot "$SDK" -dynamiclib "$SOURCE" \
        -framework Foundation -framework UIKit -framework CoreFoundation \
        -framework CoreGraphics -lobjc \
        -Wl,-install_name,"$INSTALL_NAME" -o "$OUTPUT"
else
    printf 'iPhoneOS SDK unavailable; using project ABI declarations and explicit system link stubs.\n'
    "$CLANG" "${COMMON[@]}" -isysroot / -Wno-incompatible-sysroot \
        -DXP3_MINIMAL_SDK=1 -c "$SOURCE" -o "$BUILD_DIR/XP3Compat.o"
    "$PYTHON" "$ROOT/tools/make_link_stubs.py" \
        "$BUILD_DIR/XP3Compat.o" "$BUILD_DIR/link-stubs"
    STUBS=( "$BUILD_DIR/link-stubs/System.tbd" "$BUILD_DIR/link-stubs/objc.tbd"
        "$BUILD_DIR/link-stubs/CoreFoundation.tbd" "$BUILD_DIR/link-stubs/Foundation.tbd"
        "$BUILD_DIR/link-stubs/CoreGraphics.tbd" "$BUILD_DIR/link-stubs/UIKit.tbd" )
    "$CLANG" -target "arm64-apple-ios$MIN_IOS" -isysroot / \
        -Wno-incompatible-sysroot -dynamiclib -nostdlib \
        "$BUILD_DIR/XP3Compat.o" "${STUBS[@]}" \
        -Wl,-install_name,"$INSTALL_NAME" -o "$OUTPUT"
fi

# Ad-hoc signing makes local integrity verification possible. Installation on
# ordinary iOS still requires signing the complete app with a valid profile.
codesign --force --sign - "$OUTPUT"
codesign --verify --strict "$OUTPUT"
file "$OUTPUT"
printf 'Built: %s\n' "$OUTPUT"
