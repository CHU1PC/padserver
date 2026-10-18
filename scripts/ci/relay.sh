#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

if ! command -v bun > /dev/null 2>&1; then
  printf 'Error: bun is required for the relay checks. Install it from https://bun.sh/.\n' >&2
  exit 1
fi

cd "${repo_root}/relay"
bun install --frozen-lockfile
bun run typecheck
bun test
