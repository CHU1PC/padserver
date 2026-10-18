#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

for package in PadServerCore PadGuest; do
  (
    cd "${repo_root}/Packages/${package}"
    swift build
    swift test
  )
done
