#!/bin/bash
# Fails unless the selected Xcode's macOS SDK has FoundationModels. Without it,
# `#if canImport(FoundationModels)` is false and the Apple Intelligence engine silently compiles
# out, so every Mac would be told it's unsupported. Run by ci.yml and release.yml before building.
set -euo pipefail
xcodebuild -version
echo "SDK: $(xcrun --sdk macosx --show-sdk-version)"
src="${RUNNER_TEMP:-/tmp}/check-foundationmodels.swift"
printf 'import FoundationModels\n' > "$src"
if ! xcrun --sdk macosx swiftc -typecheck "$src"; then
  echo "error: this SDK has no FoundationModels; select Xcode 26 or later" >&2
  exit 1
fi
echo "FoundationModels: available"
