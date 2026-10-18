#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

cd "$repo_root"
xcodegen generate
derived_data_args=()
if [[ -n "${DERIVED_DATA_PATH:-}" ]]; then
  derived_data_args=(-derivedDataPath "$DERIVED_DATA_PATH")
fi
xcodebuild -project PadServer.xcodeproj -scheme PadServer \
  -destination 'generic/platform=iOS Simulator' \
  ${derived_data_args[@]+"${derived_data_args[@]}"} \
  CODE_SIGNING_ALLOWED=NO build
