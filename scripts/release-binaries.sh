#!/bin/zsh
# Release-compile the app and stage everything tray/build.sh takes from the
# build into <out-dir>. CI runs this as the release gate and hands the result
# to publish, which ships these bytes instead of compiling again.
set -euo pipefail
out=${1:?usage: release-binaries.sh <out-dir>}
out=${out:A}
cd "${0:A:h}/.."

swift build -c release --product N2AgentsTray
swift build -c release --product n2-loop
bin=$(swift build -c release --show-bin-path)
sparkle=$(find .build -type d -name Sparkle.framework -print -quit)
[[ -n $sparkle ]] || { echo "✗ Sparkle.framework was not produced" >&2; exit 1 }

rm -rf "$out"; mkdir -p "$out"
cp "$bin/N2AgentsTray" "$bin/n2-loop" "$out/"
ditto "$bin/SwiftTerm_SwiftTerm.bundle" "$out/SwiftTerm_SwiftTerm.bundle"
ditto "$sparkle" "$out/Sparkle.framework"
