#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"
source_dir="${repo_root}/build/sources"
out_dir="${repo_root}/build/qemu/host"

# tctiSH の build_host_qemu.sh tcti と同じ旗. 組み込む QEMU と同じソースを, Mac 用の実行ファイルにする.
configure_flags=(
  --target-list=x86_64-softmmu
  --disable-hvf --disable-cocoa --disable-coreaudio --disable-sdl --disable-gtk
  --disable-vnc --disable-spice --disable-opengl --disable-dbus-display
  --disable-virglrenderer --enable-capstone --disable-fdt --disable-rust
  --disable-gnutls --disable-gcrypt --disable-nettle --disable-libssh
  --disable-curl --disable-libusb --disable-usb-redir --disable-libiscsi
  --disable-lzo --disable-snappy --disable-zstd --disable-png
  --disable-vde --disable-curses --disable-smartcard
  --disable-docs --disable-werror --disable-tools --disable-guest-agent
  --enable-slirp --disable-slirp-smbd -Dforce_fallback_for=slirp
  -Dslirp:default_library=static
  --with-coroutine=libucontext --enable-ucontext
  --enable-virtfs --disable-download
  --enable-tcg-threaded-interpreter
)
qemu_subprojects=(keycodemapdb berkeley-softfloat-3 berkeley-testfloat-3 slirp libucontext)

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

# nix の shell の中で呼ばれる. 作業用の写しを configure して build し, 成果物を out_dir に置く.
build_in_shell() {
  local work="$1" qemu_src="${1}/qemu" build_dir="${1}/build" stamp="$2"

  (cd "$qemu_src" && meson subprojects download "${qemu_subprojects[@]}")
  mkdir -p -- "$build_dir"
  (cd "$build_dir" && "${qemu_src}/configure" "${configure_flags[@]}")
  # 最後の署名の工程が Xcode の Rez と SetFile を PATH に要る.
  (cd "$build_dir" && PATH="${XCODE_TOOLS_DIR}:${PATH}" nice ninja -j3 qemu-system-x86_64)

  rm -f -- "${out_dir}/qemu-system-x86_64" "${out_dir}/stamp"
  rm -rf -- "${out_dir}/pc-bios"
  cp -RL -- "${qemu_src}/pc-bios" "${out_dir}/pc-bios"
  cp -- "${build_dir}/qemu-system-x86_64" "${out_dir}/qemu-system-x86_64"
  printf '%s\n' "$stamp" > "${out_dir}/stamp"
}

if [[ "${1:-}" == "--in-shell" ]]; then
  build_in_shell "$2" "$3"
  exit 0
fi

os_name="$(uname -s)"
arch_name="$(uname -m)"
[[ "$os_name" == "Darwin" && "$arch_name" == "arm64" ]] || die "this script builds for Apple Silicon Macs only."

nix_bin="$(command -v nix || true)"
if [[ -z "$nix_bin" && -x /nix/var/nix/profiles/default/bin/nix ]]; then
  nix_bin=/nix/var/nix/profiles/default/bin/nix
fi
[[ -n "$nix_bin" ]] || die "nix is required for QEMU's host libraries, but it was not found."

rez_path="$(xcrun --find Rez 2> /dev/null || true)"
setfile_path="$(xcrun --find SetFile 2> /dev/null || true)"
[[ -n "$rez_path" && -n "$setfile_path" ]] || die "Xcode's Rez and SetFile were not found. Install Xcode and run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
[[ "$(dirname -- "$rez_path")" == "$(dirname -- "$setfile_path")" ]] || die "Rez and SetFile are in different directories."
export XCODE_TOOLS_DIR
XCODE_TOOLS_DIR="$(dirname -- "$rez_path")"

"${script_dir}/fetch-qemu.sh" > /dev/null

qemu_commit="$(git -C "${source_dir}/qemu" rev-parse HEAD)"
lock_hash="$(shasum -a 256 "${source_dir}/tctiSH/flake.lock" | cut -d ' ' -f 1)"
stamp="${qemu_commit} ${lock_hash} ${configure_flags[*]}"

if [[ -x "${out_dir}/qemu-system-x86_64" && "$(cat "${out_dir}/stamp" 2> /dev/null || true)" == "$stamp" ]]; then
  printf 'qemu-system-x86_64 is up to date: %s/qemu-system-x86_64\n' "$out_dir"
  exit 0
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/qemu-host.XXXXXXXX")"
trap 'rm -rf -- "$work"' EXIT

# 取得物には書かず, 写しの上で build する. APFS の clone なので速く, 容量も増えない.
cp -Rc -- "${source_dir}/qemu" "${work}/qemu" 2> /dev/null || cp -R -- "${source_dir}/qemu" "${work}/qemu"
mkdir -p -- "${work}/flake" "$out_dir"
cp -- "${source_dir}/tctiSH/flake.nix" "${source_dir}/tctiSH/flake.lock" "${work}/flake/"

# profile を作ると, 実行ファイルが使う /nix/store の library が GC で消えない.
"$nix_bin" --extra-experimental-features 'nix-command flakes' develop \
  --profile "${out_dir}/nix-gc-root" "path:${work}/flake#host-qemu" \
  --command bash "${BASH_SOURCE[0]}" --in-shell "$work" "$stamp"

printf 'built %s/qemu-system-x86_64\n' "$out_dir"
