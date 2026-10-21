#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${XP3_TEST_BUILD_DIR:-$ROOT/.test-build}"
mkdir -p "$BUILD_DIR"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
xcrun clang -isysroot "$SDK" -fobjc-arc -fblocks -fobjc-exceptions \
    -DXP3COMPAT_TESTING=1 -Wall -Wextra -Werror=implicit-function-declaration \
    -framework Foundation \
    "$ROOT/Sources/XP3Compat.m" "$ROOT/tests/FakeUIKit.m" \
    "$ROOT/tests/NativeTests.m" -o "$BUILD_DIR/native-tests"
"$BUILD_DIR/native-tests"

# Also compile the shipping SDK-less declarations against the actual macOS
# Objective-C runtime. The normal fake-UIKit build alone cannot catch incorrect
# superclass instance layout in XP3ABI.h.
xcrun clang -isysroot "$SDK" -fobjc-arc -fblocks -fobjc-exceptions \
    -fno-objc-msgsend-selector-stubs -DXP3_MINIMAL_SDK=1 \
    -Wall -Wextra -Werror=implicit-function-declaration -framework Foundation \
    "$ROOT/Sources/XP3Compat.m" "$ROOT/tests/FakeUIKit.m" \
    "$ROOT/tests/NativeTests.m" -o "$BUILD_DIR/native-minimal-abi-tests"
"$BUILD_DIR/native-minimal-abi-tests"

xcrun clang -isysroot "$SDK" -fobjc-arc -fblocks -Wall -Wextra \
    -Werror=implicit-function-declaration -framework Foundation \
    "$ROOT/tests/NativeInputTests.m" -o "$BUILD_DIR/native-input-tests"
"$BUILD_DIR/native-input-tests"
