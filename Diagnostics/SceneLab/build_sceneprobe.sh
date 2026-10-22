#!/bin/bash
# Build the EXPERIMENTAL XP3Compat SceneProbe for arm64 iOS Simulator only.
# Output is confined to Diagnostics/SceneLab/build; the shipped XP3Compat.dylib
# and Sources/XP3Compat.m are never touched.
set -euo pipefail

LAB="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$LAB/../.." && pwd)"
SOURCE="$LAB/CombinedSceneProbe.m"
BUILD="$LAB/build"
OUT="$BUILD/XP3Compat-SceneProbe-simulator-arm64.dylib"
PRODUCTION_DYLIB="$ROOT/XP3Compat.dylib"
MIN_IOS="14.0"
SDK_VERSION="27.1"
INSTALL_NAME="@executable_path/Frameworks/XP3Compat.dylib"

if [ ! -f "$SOURCE" ]; then
    printf 'Source is missing: %s\n' "$SOURCE" >&2
    exit 1
fi
if [ ! -f "$LAB/XP3SceneAdapter.m" ]; then
    printf 'Scene adapter is missing: %s\n' "$LAB/XP3SceneAdapter.m" >&2
    exit 1
fi
if [ ! -f "$LAB/../DisplayLab/DisplayProbe.m" ]; then
    printf 'DisplayProbe is missing: %s\n' "$LAB/../DisplayLab/DisplayProbe.m" >&2
    exit 1
fi
if [ ! -f "$ROOT/Sources/XP3Compat.m" ]; then
    printf 'Production source is missing: %s\n' "$ROOT/Sources/XP3Compat.m" >&2
    exit 1
fi

case "$OUT" in
    "$BUILD"/*) ;;
    *) printf 'Refusing output outside %s\n' "$BUILD" >&2; exit 1 ;;
esac
if [ "$OUT" = "$PRODUCTION_DYLIB" ]; then
    printf 'Refusing to overwrite the shipped dylib\n' >&2
    exit 1
fi

SDK="$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null || true)"
if [ -z "$SDK" ]; then
    printf 'iPhoneSimulator SDK is unavailable.\n' >&2
    exit 1
fi
ACTUAL_SDK_VERSION="$(xcrun --sdk iphonesimulator --show-sdk-version)"
if [ "$ACTUAL_SDK_VERSION" != "$SDK_VERSION" ]; then
    printf 'Expected simulator SDK %s, got %s\n' "$SDK_VERSION" "$ACTUAL_SDK_VERSION" >&2
    exit 1
fi

mkdir -p "$BUILD"
CLANG="$(xcrun --find clang)"
COMMON=(
    -target "arm64-apple-ios${MIN_IOS}-simulator"
    -isysroot "$SDK"
    -fobjc-arc -fblocks -fobjc-exceptions -fexceptions
    -O2 -Wall -Wextra -Wno-deprecated-declarations
    -Werror=implicit-function-declaration
    -Wl,-install_name,"$INSTALL_NAME"
    -framework Foundation -framework UIKit
    -framework QuartzCore -framework CoreGraphics
)

printf 'Building experimental SceneProbe (arm64 simulator, min iOS %s, SDK %s)\n' \
    "$MIN_IOS" "$ACTUAL_SDK_VERSION"
"$CLANG" "${COMMON[@]}" -dynamiclib "$SOURCE" -o "$OUT"

codesign --force --sign - "$OUT" >/dev/null
codesign --verify --strict "$OUT" >/dev/null

MANIFEST="$BUILD/SCENE-BUILD-MANIFEST.txt"
{
    printf 'XP3Compat SceneProbe build (EXPERIMENTAL, NOT SHIPPED)\n'
    printf 'utc: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'source: Diagnostics/SceneLab/CombinedSceneProbe.m\n'
    printf 'source_sha256: %s\n' "$(shasum -a 256 "$SOURCE" | awk '{print $1}')"
    printf 'scene_adapter: Diagnostics/SceneLab/XP3SceneAdapter.m\n'
    printf 'scene_adapter_sha256: %s\n' "$(shasum -a 256 "$LAB/XP3SceneAdapter.m" | awk '{print $1}')"
    printf 'production_source: Sources/XP3Compat.m\n'
    printf 'production_source_sha256: %s\n' "$(shasum -a 256 "$ROOT/Sources/XP3Compat.m" | awk '{print $1}')"
    printf 'display_probe: Diagnostics/DisplayLab/DisplayProbe.m\n'
    printf 'display_probe_sha256: %s\n' "$(shasum -a 256 "$LAB/../DisplayLab/DisplayProbe.m" | awk '{print $1}')"
    printf 'simulator_sdk: %s\n' "$SDK"
    printf 'simulator_sdk_version: %s\n' "$ACTUAL_SDK_VERSION"
    printf 'minimum_ios: %s\n' "$MIN_IOS"
    printf 'install_name: %s\n' "$INSTALL_NAME"
    printf 'artifact: %s\n' "$(basename "$OUT")"
    printf 'artifact_sha256: %s\n' "$(shasum -a 256 "$OUT" | awk '{print $1}')"
    printf 'artifact_minos: %s\n' "$(otool -l "$OUT" | awk '/LC_BUILD_VERSION/{found=1} found && /minos/{print $2; exit}')"
    printf 'artifact_sdk: %s\n' "$(otool -l "$OUT" | awk '/LC_BUILD_VERSION/{found=1} found && /sdk/{print $2; exit}')"
} > "$MANIFEST"

file "$OUT"
printf '  install name: '
otool -D "$OUT" | tail -n 1
printf '  platform: '
otool -l "$OUT" | awk '/LC_BUILD_VERSION/{found=1} found && /platform/{print $2; exit}'
printf '  minos: '
otool -l "$OUT" | awk '/LC_BUILD_VERSION/{found=1} found && /minos/{print $2; exit}'
printf '  sdk: '
otool -l "$OUT" | awk '/LC_BUILD_VERSION/{found=1} found && /sdk/{print $2; exit}'
printf '  sha256: '
shasum -a 256 "$OUT" | awk '{print $1}'
codesign --verify --strict --verbose=1 "$OUT"
printf 'Diagnostic artifact: %s\n' "$OUT"
printf 'Build manifest: %s\n' "$MANIFEST"
printf 'Shipped dylib was not touched: %s\n' "$PRODUCTION_DYLIB"
