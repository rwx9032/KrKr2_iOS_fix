#!/bin/bash
# Reproducible build for the OfflineContinuation-20261021 diagnostic dylibs.
#
# NOTE: this build is NOT byte-reproducible: the read-only Display/Engine probes
# embed __DATE__/__TIME__, and the linker assigns a random LC_UUID. The SHA-256 in
# BUILD-MANIFEST.txt identifies the artifact produced by this run only; always keep
# the dylib together with the manifest that was generated with it.
#
# Diagnostic only: this script never writes outside its own directory, never
# touches production Sources/, the shipped XP3Compat.dylib, the GitHub work
# tree, or any simulator/device.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LAB="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$LAB/../.." && pwd)"       # outputs/XP3Compat
SRC="$LAB/src/CombinedOfflineProbe.m"
INSTALL_NAME="@executable_path/Frameworks/XP3Compat.dylib"
MIN_IOS="14.0"
SIM_OUT="$HERE/XP3Compat-OfflineProbe-simulator-arm64.dylib"
DEV_OUT="$HERE/XP3Compat-OfflineProbe-device-arm64.dylib"
MANIFEST="$HERE/BUILD-MANIFEST.txt"

for path in "$SRC" "$ROOT/Sources/XP3Compat.m" \
            "$ROOT/Diagnostics/DisplayLab/DisplayProbe.m" \
            "$ROOT/Diagnostics/DisplayLab/EngineFrameProbe.m" \
            "$ROOT/Diagnostics/SceneLab/EngineActivityProbe.m"; do
    [ -f "$path" ] || { printf 'Missing input: %s\n' "$path" >&2; exit 1; }
done

case "$SIM_OUT$DEV_OUT" in
    "$HERE"/*) ;;
    *) printf 'Refusing output outside %s\n' "$HERE" >&2; exit 1 ;;
esac

FLAGS=(
    -fobjc-arc -fblocks -fobjc-exceptions -fexceptions -O2
    -Wall -Wextra -Wno-deprecated-declarations
    -Werror=implicit-function-declaration
    -Wl,-install_name,"$INSTALL_NAME"
    -framework Foundation -framework UIKit
    -framework QuartzCore -framework CoreGraphics
)

SIM_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
SIM_VER="$(xcrun --sdk iphonesimulator --show-sdk-version)"
DEV_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
DEV_VER="$(xcrun --sdk iphoneos --show-sdk-version)"

printf 'Building simulator (arm64, iOS %s, SDK %s)\n' "$MIN_IOS" "$SIM_VER"
xcrun clang -target "arm64-apple-ios${MIN_IOS}-simulator" -isysroot "$SIM_SDK" \
    "${FLAGS[@]}" -dynamiclib "$SRC" -o "$SIM_OUT"
codesign --force --sign - "$SIM_OUT" >/dev/null
codesign --verify --strict "$SIM_OUT"

printf 'Building device (arm64, iOS %s, SDK %s)\n' "$MIN_IOS" "$DEV_VER"
xcrun clang -target "arm64-apple-ios${MIN_IOS}" -isysroot "$DEV_SDK" \
    "${FLAGS[@]}" -dynamiclib "$SRC" -o "$DEV_OUT"
codesign --force --sign - "$DEV_OUT" >/dev/null
codesign --verify --strict "$DEV_OUT"

{
    printf 'OfflineContinuation-20261021 candidate build (DIAGNOSTIC ONLY)\n'
    printf 'utc: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    for f in "$LAB/src/CombinedOfflineProbe.m" \
             "$LAB/src/XP3SceneContextAdapter.m" \
             "$LAB/src/XP3AdaptiveGeometryKeepDesign.m" \
             "$ROOT/Sources/XP3Compat.m" \
             "$ROOT/Diagnostics/DisplayLab/DisplayProbe.m" \
             "$ROOT/Diagnostics/DisplayLab/EngineFrameProbe.m" \
             "$ROOT/Diagnostics/SceneLab/EngineActivityProbe.m"; do
        rel="${f#"$ROOT"/}"
        printf 'input: %s  %s\n' "$rel" "$(shasum -a 256 "$f" | awk '{print $1}')"
    done
    printf 'simulator_sdk: %s (%s)\n' "$SIM_SDK" "$SIM_VER"
    printf 'device_sdk: %s (%s)\n' "$DEV_SDK" "$DEV_VER"
    printf 'minimum_ios: %s\n' "$MIN_IOS"
    printf 'install_name: %s\n' "$INSTALL_NAME"
    for out in "$SIM_OUT" "$DEV_OUT"; do
        printf 'artifact: %s\n' "$(basename "$out")"
        printf '  sha256: %s\n' "$(shasum -a 256 "$out" | awk '{print $1}')"
        printf '  platform: %s\n' "$(xcrun vtool -show-build "$out" | awk '/platform/{print $2; exit}')"
        printf '  minos: %s\n' "$(xcrun vtool -show-build "$out" | awk '/minos/{print $2; exit}')"
        printf '  sdk: %s\n' "$(xcrun vtool -show-build "$out" | awk '/sdk/{print $2; exit}')"
    done
} > "$MANIFEST"

file "$SIM_OUT" "$DEV_OUT"
cat "$MANIFEST"
printf 'Done. Nothing outside %s was written.\n' "$HERE"
