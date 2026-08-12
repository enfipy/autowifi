#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_tmp="${TMPDIR:-/tmp}/autowifi-verify"

cd "$project_root"
PYTHONDONTWRITEBYTECODE=1 python3 tools/generate_constants.py --check
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s linux -p 'test_*.py' -v

CLANG_MODULE_CACHE_PATH="$task_tmp/clang-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$task_tmp/swiftpm-module-cache" \
swift test --package-path ios --scratch-path "$task_tmp/swift-build"

sdk_path="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun swiftc \
    -typecheck \
    -target arm64-apple-ios26.2 \
    -sdk "$sdk_path" \
    -module-cache-path "$task_tmp/ios-module-cache" \
    ios/Sources/AutoWiFiWire/GeneratedConstants.swift \
    ios/Sources/AutoWiFiWire/WireProtocol.swift \
    ios/MinimumTransport.swift
