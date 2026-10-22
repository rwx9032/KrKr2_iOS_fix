#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${XP3_ENGINE_TEST_BUILD_DIR:-${TMPDIR:-/tmp}/xp3-engine-scheduling-tests}"
mkdir -p "$BUILD_DIR"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
xcrun clang -isysroot "$SDK" -fobjc-arc -fblocks -fobjc-exceptions \
    -Wall -Wextra -Werror=implicit-function-declaration -framework Foundation \
    "$ROOT/tests/NativeEngineSchedulingTests.m" -o "$BUILD_DIR/native-engine-scheduling-tests"
"$BUILD_DIR/native-engine-scheduling-tests"
