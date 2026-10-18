#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd -- "${script_dir}/.." && pwd)"
source_dir="${root_dir}/build/sources"
work_dir="${root_dir}/build/work/qemu-ios"
output_dir="${root_dir}/build/qemu/ios"
stamp_file="${output_dir}/.stamp"
sysroot_name="sysroot-iOS-arm64"

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

for tool in nix xcrun git shasum; do
  command -v "$tool" > /dev/null 2>&1 || fail "${tool} is required but not found in PATH."
done
nix --version > /dev/null 2>&1 || fail "nix does not run."

"${script_dir}/fetch-qemu.sh" || fail "could not fetch the sources."

# 入力 (2 つの commit と patch と、この script) が同じなら作り直さない。
input_stamp="$(
  {
    git -C "${source_dir}/tctiSH" rev-parse HEAD
    git -C "${source_dir}/qemu" rev-parse HEAD
    shasum -a 256 "${script_dir}"/patches/*.patch "${BASH_SOURCE[0]}" | awk '{ print $1 }'
  } | shasum -a 256 | awk '{ print $1 }'
)"
if [[ -f "$stamp_file" && "$(< "$stamp_file")" == "$input_stamp" ]] \
  && [[ -d "${output_dir}/Frameworks/qemu-x86_64-softmmu.framework" ]]; then
  printf 'up to date: %s\n' "$output_dir"
  exit 0
fi

# 途中の状態を引き継がず, いつも空の作業木から作る。
rm -rf -- "$work_dir"
mkdir -p -- "$work_dir"
cp -R -- "${source_dir}/tctiSH" "${work_dir}/tctiSH"
rmdir -- "${work_dir}/tctiSH/third-party/qemu" || fail "third-party/qemu is not an empty directory."
cp -R -- "${source_dir}/qemu" "${work_dir}/tctiSH/third-party/qemu"

# アプリ全体は xcodebuild せず, QEMU の library を作る make deps だけを使う。
(
  cd -- "${work_dir}/tctiSH"
  NCPU="${NCPU:-3}" make deps
) || fail "make deps failed. The work tree is kept at ${work_dir}."

frameworks="${work_dir}/tctiSH/${sysroot_name}/Frameworks"
[[ -d "${frameworks}/qemu-x86_64-softmmu.framework" ]] \
  || fail "qemu-x86_64-softmmu.framework was not produced in ${frameworks}."

rm -rf -- "$output_dir"
mkdir -p -- "$output_dir"
cp -R -- "$frameworks" "${output_dir}/Frameworks"
printf '%s\n' "$input_stamp" > "$stamp_file"
rm -rf -- "$work_dir"
printf 'built: %s\n' "${output_dir}/Frameworks"
