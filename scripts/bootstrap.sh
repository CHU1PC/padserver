#!/usr/bin/env bash
set -euo pipefail

os_name="$(uname -s)"
if [[ "$os_name" != "Darwin" ]]; then
  printf 'Error: bootstrap.sh requires macOS.\n' >&2
  exit 1
fi

if ! command -v brew > /dev/null 2>&1; then
  printf 'Error: Homebrew is required. Install it from https://brew.sh/.\n' >&2
  exit 1
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
brewfile="${script_dir}/../Brewfile"
HOMEBREW_BUNDLE_NO_LOCK=1 brew bundle install --file="$brewfile" --no-upgrade

failed=0
while IFS=' ' read -r tool executable version_arg; do
  [[ -n "$tool" ]] || continue
  if ! command -v "$executable" > /dev/null 2>&1; then
    printf 'Error: %s is missing from PATH after Homebrew setup.\n' "$tool" >&2
    failed=1
    continue
  fi

  if [[ "$tool" == "shellcheck" ]]; then
    if version_output=$("$executable" "$version_arg" | sed -n '2s/^version: //p'); then
      if [[ -z "$version_output" ]]; then
        printf 'Error: could not read the %s version.\n' "$tool" >&2
        failed=1
      else
        printf '%s %s\n' "$tool" "$version_output"
      fi
    else
      printf 'Error: could not read the %s version.\n' "$tool" >&2
      failed=1
    fi
  elif version_output=$("$executable" "$version_arg" | grep -Eo '[0-9]+([.][0-9.]+)+' | head -n 1); then
    if [[ -z "$version_output" ]]; then
      printf 'Error: could not read the %s version.\n' "$tool" >&2
      failed=1
    else
      printf '%s %s\n' "$tool" "$version_output"
    fi
  else
    printf 'Error: could not read the %s version.\n' "$tool" >&2
    failed=1
  fi
done << 'TOOLS'
actionlint actionlint -version
gitleaks gitleaks version
markdownlint-cli2 markdownlint-cli2 --version
pre-commit pre-commit --version
shellcheck shellcheck --version
shfmt shfmt --version
swift-format swift-format --version
swiftlint swiftlint version
typos-cli typos --version
xcodegen xcodegen --version
yamllint yamllint --version
zizmor zizmor --version
TOOLS

exit "$failed"
