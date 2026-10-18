#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

if [[ -n "${RUNNER_TEMP:-}" ]]; then
  work_dir="$RUNNER_TEMP"
else
  work_dir="$(mktemp -d)"
  trap 'rm -rf "$work_dir"' EXIT
fi

cd "$repo_root"
xcodegen generate
rm -rf "$work_dir"/DerivedData/Build/Intermediates.noindex/{PadServer,PadServerCore,PadGuest}.build
xcodebuild -project PadServer.xcodeproj -scheme PadServer \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$work_dir/DerivedData" \
  CODE_SIGNING_ALLOWED=NO build | tee "$work_dir/xcodebuild.log"
xcodebuild -project PadServer.xcodeproj -scheme PadTestSupport \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$work_dir/DerivedData" \
  CODE_SIGNING_ALLOWED=NO build | tee -a "$work_dir/xcodebuild.log"
swiftlint analyze --strict \
  --only-rule unused_declaration \
  --only-rule unused_import \
  --compiler-log-path "$work_dir/xcodebuild.log"
