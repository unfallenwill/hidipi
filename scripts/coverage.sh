#!/bin/zsh
# Measures line coverage across all test bundles.
# SwiftPM's JSON export skips modules linked into test bundles from executable targets,
# so this drives llvm-profdata/llvm-cov directly over every .xctest binary.
# Usage: scripts/coverage.sh
set -euo pipefail
cd "${0:A:h}/.."

# The local 6.4-dev CLT occasionally needs the Testing macros plugin path (see README).
PLUGINS=()
if [[ -d /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing ]]; then
  PLUGINS=(-Xswiftc=-external-plugin-path
    -Xswiftc='/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing#/Library/Developer/CommandLineTools/usr/bin/swift-plugin-server')
fi

swift test --enable-code-coverage "${PLUGINS[@]}"

CODECOV=.build/debug/codecov
PROFDATA="$CODECOV/all.profdata"
xcrun llvm-profdata merge -sparse "$CODECOV"/*.profraw -o "$PROFDATA"

setopt null_glob
ARGS=()
# Only regular files: bundle MacOS directories can also hold .dSYM bundles on CI.
for binary in .build/debug/*.xctest/Contents/MacOS/*(N-.); do
  ARGS+=(-object "$binary")
done

xcrun llvm-cov report -instr-profile="$PROFDATA" "${ARGS[@]}" | grep -E 'Sources/|TOTAL'
