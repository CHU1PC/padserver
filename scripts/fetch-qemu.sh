#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source_dir="${script_dir}/../build/sources"
patch_dir="${script_dir}/patches"

# tctiSH のこの commit が参照する QEMU submodule の commit を固定する。
tctish_commit="76b6f6081fc328c05c4e0fc1d770aec7f1cdcbc4"
qemu_commit="ded0cff5a2a6d3b0a5261ab570518719b42ae2e6"

fetch_source() {
  local name="$1" url="$2" commit="$3"
  local destination="${source_dir}/${name}"
  local temporary actual_origin actual_commit

  if [[ -e "$destination" || -L "$destination" ]]; then
    if [[ ! -d "$destination/.git" ]]; then
      printf 'Error: %s already exists and is not a Git checkout.\n' "$destination" >&2
      return 1
    fi
    actual_origin="$(git -C "$destination" remote get-url origin)"
    if [[ "$actual_origin" != "$url" ]]; then
      printf 'Error: %s has a different origin.\n' "$destination" >&2
      return 1
    fi
    actual_commit="$(git -C "$destination" rev-parse HEAD)"
    if [[ "$actual_commit" != "$commit" ]]; then
      printf 'Error: %s is at a different commit.\n' "$destination" >&2
      return 1
    fi
    printf '%s %s\n' "$name" "$commit"
    return
  fi

  temporary="$(mktemp -d "${source_dir}/.${name}.XXXXXXXX")"
  if ! (
    trap 'rm -rf -- "$temporary"' EXIT
    git -C "$temporary" init -q
    git -C "$temporary" remote add origin "$url"
    git -C "$temporary" -c protocol.version=2 fetch --quiet --filter=blob:none --depth=1 origin "$commit"
    git -C "$temporary" checkout --quiet --detach FETCH_HEAD
    actual_commit="$(git -C "$temporary" rev-parse HEAD)"
    [[ "$actual_commit" == "$commit" ]]
    mv -- "$temporary" "$destination"
  ); then
    printf 'Error: could not fetch %s at %s.\n' "$name" "$commit" >&2
    return 1
  fi
  printf '%s %s\n' "$name" "$commit"
}

apply_patches() {
  local name="$1" patch
  for patch in "${patch_dir}/${name}"-*.patch; do
    [[ -e "$patch" ]] || continue
    if git -C "${source_dir}/${name}" apply --reverse --check "$patch" 2> /dev/null; then
      continue
    fi
    if ! git -C "${source_dir}/${name}" apply "$patch"; then
      printf 'Error: could not apply %s.\n' "$patch" >&2
      return 1
    fi
    printf 'applied %s\n' "$(basename -- "$patch")"
  done
}

mkdir -p -- "$source_dir"
export GIT_TERMINAL_PROMPT=0
fetch_source tctiSH https://github.com/tctiSH/tctiSH.git "$tctish_commit"
fetch_source qemu https://github.com/tctiSH/qemu.git "$qemu_commit"
apply_patches tctiSH
apply_patches qemu
