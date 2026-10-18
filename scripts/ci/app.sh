#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

cd "$repo_root"
xcodegen generate
xcodebuild -project PadServer.xcodeproj -scheme PadServer \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
