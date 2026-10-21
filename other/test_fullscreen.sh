#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p build
xcrun swiftc -O -parse-as-library -D COMPOSITOR_PROBE_MAIN IINATests/CompositorProbe.swift -o build/CompositorProbe
probe_dir=$(mktemp -d /tmp/iina-compositor-probe.XXXXXX)
./build/CompositorProbe "$probe_dir" > build/compositor-probe.log 2>&1 &
probe_pid=$!
cleanup() {
  kill "$probe_pid" 2>/dev/null || true
  rm -r "$probe_dir"
}
trap cleanup EXIT
TEST_RUNNER_IINA_COMPOSITOR_PROBE_DIR="$probe_dir" xcodebuild test \
  -project iina.xcodeproj -scheme iina -configuration Debug -derivedDataPath build \
  -destination 'platform=macOS' ONLY_ACTIVE_ARCH=YES \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= "$@"
