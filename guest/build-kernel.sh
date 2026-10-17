#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "${BASH_SOURCE[0]%/*}" && pwd)"
repo_dir="$(cd -- "${script_dir}/.." && pwd)"

# 固定する入力. 動かすときは, 理由を決めて全部を一緒に更新する.
tctish_url="https://github.com/tctiSH/tctiSH.git"
tctish_commit="76b6f6081fc328c05c4e0fc1d770aec7f1cdcbc4"
tctish_config_sha256="ccfa317d39d3d3fe9f745c8d36ee5379b8a462aab0f5da5310dabbefccc1debf"
builder_image="nixos/nix@sha256:7a007c766426c1877758ddc5cb87a965ac131fc78c582ce0083d922d51ae945c"

# カーネルのビルドはメモリを多く使う. 共用の機械で他の処理を止めないための上限.
build_cpus="8"
build_memory="12g"
build_pids="4096"

output="${repo_dir}/build/guest/bzImage"
container_name="padserver-kernel-build"

usage() {
  cat << 'USAGE'
Usage: guest/build-kernel.sh [--output PATH] [--container-name NAME]

Build the guest kernel (bzImage) from the pinned tctiSH checkout and
guest/kernel.config. Needs Linux x86_64 and Docker.
USAGE
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || die "--output needs a path."
      output="$2"
      shift 2
      ;;
    --container-name)
      [[ $# -ge 2 ]] || die "--container-name needs a name."
      container_name="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown option: $1"
      ;;
  esac
done

os_name="$(uname -s)"
machine="$(uname -m)"
[[ "$os_name" == "Linux" && "$machine" == "x86_64" ]] \
  || die "this script needs Linux x86_64."
command -v docker > /dev/null 2>&1 || die "docker is missing from PATH."
command -v git > /dev/null 2>&1 || die "git is missing from PATH."
[[ -f "${script_dir}/kernel.config" ]] || die "guest/kernel.config is missing."

if docker container inspect "$container_name" > /dev/null 2>&1; then
  die "a container named ${container_name} already exists."
fi

work_dir="${repo_dir}/build/guest/kernel-work"
docker_config="$(mktemp -d)"
cleanup() {
  docker rm -f "$container_name" > /dev/null 2>&1 || true
  rm -rf -- "$docker_config"
}
trap cleanup EXIT

# 前回の作業ツリーは捨てる. ビルドの入力は, 毎回この commit から作る.
rm -rf -- "$work_dir"
mkdir -p -- "$work_dir" "$(dirname -- "$output")"

export GIT_TERMINAL_PROMPT=0
git -C "$work_dir" init -q
git -C "$work_dir" remote add origin "$tctish_url"
git -C "$work_dir" -c protocol.version=2 fetch --quiet --filter=blob:none --depth=1 origin "$tctish_commit"
git -C "$work_dir" checkout --quiet --detach FETCH_HEAD
actual_commit="$(git -C "$work_dir" rev-parse HEAD)"
[[ "$actual_commit" == "$tctish_commit" ]] \
  || die "tctiSH is not at ${tctish_commit}."

base_config="${work_dir}/assets/kernel/tctish.config"
actual_sha256="$(sha256sum "$base_config" | cut -d' ' -f1)"
[[ "$actual_sha256" == "$tctish_config_sha256" ]] \
  || die "tctish.config differs from the pinned one (${actual_sha256})."

cat "${script_dir}/kernel.config" >> "$base_config"
rm -f -- "${work_dir}/assets/bzImage"

host_uid="$(id -u)"
host_gid="$(id -g)"

# 空の Docker 設定を使い, 手元の認証の設定に頼らない.
printf '{}\n' > "${docker_config}/config.json"

# build_kernel.sh が, 設定の全 symbol が解決後の .config に入ったかを検証する.
# root で作られたファイルを, 呼び出した user が消せるように最後に所有者を戻す.
DOCKER_CONFIG="$docker_config" docker run --name "$container_name" \
  --cpus="$build_cpus" --memory="$build_memory" --pids-limit="$build_pids" \
  -v "${work_dir}:/src" -w /src \
  -e 'NIX_CONFIG=experimental-features = nix-command flakes' \
  "$builder_image" \
  sh -c 'nix develop path:/src/assets/kernel -c env TCTISH_TOOLCHAIN=1 bash /src/assets/build_kernel.sh
status=$?
chown -R "$1:$2" /src
exit "$status"' sh "$host_uid" "$host_gid"

built="${work_dir}/assets/bzImage"
[[ -s "$built" ]] || die "the build produced no bzImage."
cp -- "$built" "$output"
sha256sum -- "$output"
