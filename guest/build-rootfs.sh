#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "${BASH_SOURCE[0]%/*}" && pwd)"
repo_dir="$(cd -- "${script_dir}/.." && pwd)"

# 固定する入力. 動かすときは, 理由を決めて全部を一緒に更新する.
tctish_url="https://github.com/tctiSH/tctiSH.git"
tctish_commit="76b6f6081fc328c05c4e0fc1d770aec7f1cdcbc4"
builder_image="alpine@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6"
alpine_mirror="https://dl-cdn.alpinelinux.org/alpine/v3.24"
minirootfs_version="3.24.2"
minirootfs_sha256="c5ca053cfe1d85c5b96dff8b9bc57045f7f184a30ffb6b65776409ca90388677"

# rootfs に入れる package の全部. 依存で入るものも含めて固定し, 入った一覧と食い違えば止まる.
rootfs_packages=(
  alpine-baselayout=3.7.2-r1
  alpine-baselayout-data=3.7.2-r1
  alpine-keys=2.6-r0
  alpine-release=3.24.2-r0
  apk-tools=3.0.8-r0
  bash=5.3.9-r1
  busybox=1.37.0-r31
  busybox-binsh=1.37.0-r31
  ca-certificates=20260909-r0
  ca-certificates-bundle=20260909-r0
  containerd=2.3.7-r0
  docker=29.8.2-r1
  docker-cli=29.8.2-r1
  docker-cli-buildx=0.34.1-r2
  docker-cli-compose=5.1.4-r2
  docker-engine=29.8.2-r1
  dropbear=2026.91-r0
  e2fsprogs=1.47.4-r0
  e2fsprogs-libs=1.47.4-r0
  iptables=1.8.13-r0
  libapk=3.0.8-r0
  libblkid=2.42.3-r1
  libbsd=0.12.2-r0
  libcom_err=1.47.4-r0
  libcrypto3=3.5.9-r0
  libeconf=0.8.3-r0
  libmd=1.2.0-r0
  libmnl=1.0.5-r2
  libncursesw=6.6_p20260516-r0
  libnftnl=1.3.1-r0
  libseccomp=2.6.1-r0
  libssl3=3.5.9-r0
  libuuid=2.42.3-r1
  libxtables=1.8.13-r0
  musl=1.2.6-r2
  musl-utils=1.2.6-r2
  ncurses-terminfo-base=6.6_p20260516-r0
  netcat-openbsd=1.234.1-r0
  openssl=3.5.9-r0
  readline=8.3.3-r1
  runc=1.4.3-r2
  scanelf=1.3.9-r1
  skalibs-libs=2.15.0.0-r0
  ssl_client=1.37.0-r31
  tini-static=0.19.0-r3
  utmps-libs=0.1.3.3-r0
  zlib=1.3.2-r0
)

# 組み立てに使う道具. rootfs には入らない.
builder_packages=(cpio=2.15-r0 gzip=1.14-r3)

output="${repo_dir}/build/guest/initrd.img"
container_name="padserver-rootfs-build"

usage() {
  cat << 'USAGE'
Usage: guest/build-rootfs.sh [--output PATH] [--container-name NAME]

Build the guest rootfs (initrd.img) from a pinned Alpine Linux, with Docker
and the compose plugin, the tctiSH overlay, and guest/init. Needs Linux x86_64
and Docker.
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
[[ -f "${script_dir}/init" ]] || die "guest/init is missing."

if docker container inspect "$container_name" > /dev/null 2>&1; then
  die "a container named ${container_name} already exists."
fi

work_dir="${repo_dir}/build/guest/rootfs-work"
docker_config="$(mktemp -d)"
cleanup() {
  docker rm -f "$container_name" > /dev/null 2>&1 || true
  rm -rf -- "$docker_config"
}
trap cleanup EXIT

# 前回の作業ツリーは捨てる. ビルドの入力は, 毎回この commit から作る.
rm -rf -- "$work_dir"
mkdir -p -- "$work_dir/out" "$(dirname -- "$output")"

export GIT_TERMINAL_PROMPT=0
tctish_dir="${work_dir}/tctish"
mkdir -p -- "$tctish_dir"
git -C "$tctish_dir" init -q
git -C "$tctish_dir" remote add origin "$tctish_url"
git -C "$tctish_dir" -c protocol.version=2 fetch --quiet --filter=blob:none --depth=1 origin "$tctish_commit"
git -C "$tctish_dir" checkout --quiet --detach FETCH_HEAD
actual_commit="$(git -C "$tctish_dir" rev-parse HEAD)"
[[ "$actual_commit" == "$tctish_commit" ]] \
  || die "tctiSH is not at ${tctish_commit}."

host_uid="$(id -u)"
host_gid="$(id -g)"

# 空の Docker 設定を使い, 手元の認証の設定に頼らない.
printf '{}\n' > "${docker_config}/config.json"

# container の中の手順. 入った package が固定した一覧と食い違えば止まる.
# 時刻は 0 に揃え, 同じ入力から同じ bytes が出るようにする.
# root で作られたファイルを, 呼び出した user が消せるように最後に所有者を戻す.
# shellcheck disable=SC2016
inner_script='
set -eu
set -o pipefail
host_uid="$1"
host_gid="$2"

apk add --no-cache $BUILDER_PACKAGES > /dev/null

wget -q -O /minirootfs.tar.gz "${ALPINE_MIRROR}/releases/x86_64/alpine-minirootfs-${MINIROOTFS_VERSION}-x86_64.tar.gz"
echo "${MINIROOTFS_SHA256}  /minirootfs.tar.gz" | sha256sum -c -
mkdir /rootfs
tar xzf /minirootfs.tar.gz -C /rootfs

apk --root /rootfs --no-cache -X "${ALPINE_MIRROR}/main" -X "${ALPINE_MIRROR}/community" \
	add --no-interactive $ROOTFS_PACKAGES > /dev/null
apk --root /rootfs list -I | sed "s/ .*//" | sort > /installed.txt
printf "%s\n" $ROOTFS_PACKAGES | sed "s/=/-/" | sort > /pinned.txt
diff /pinned.txt /installed.txt || { echo "installed packages differ from the pinned list" >&2; exit 1; }

printf "%s\n%s\n" "${ALPINE_MIRROR}/main" "${ALPINE_MIRROR}/community" > /rootfs/etc/apk/repositories

tctish=/tctish/assets
cp -a "${tctish}/overlay/." /rootfs/
install -m 0755 /guest/init /rootfs/init
install -d -m 0755 /rootfs/usr/bin
install -m 0755 "${tctish}"/scripts/* /rootfs/usr/bin/
ln -sf ../usr/bin/mount.ios /rootfs/sbin/mount.ios
install -d -m 0755 /rootfs/etc/dropbear /rootfs/ios_host /rootfs/private /rootfs/etc/padserver
install -m 0755 /guest/rootfs/etc/padserver/start-dockerd /rootfs/etc/padserver/
cat /guest/rootfs/etc/padserver/inittab.docker >> /rootfs/etc/inittab
sed -i "s|/usr/sbin/dropbear -RF\$|/usr/sbin/dropbear -RFs|" /rootfs/etc/inittab
grep -q "dropbear -RFs\$" /rootfs/etc/inittab

# app が使う root の password は tctiSH の build_rootfs.sh の値をそのまま使う. repo には書かない.
password_hash="$(sed -n "s/^ROOT_PASSWORD_HASH=.\(.*\).\$/\1/p" "${tctish}/build_rootfs.sh")"
password_lastchg="$(sed -n "s/^ROOT_PASSWORD_LASTCHG=\"\(.*\)\"\$/\1/p" "${tctish}/build_rootfs.sh")"
[ -n "$password_hash" ] && [ -n "$password_lastchg" ]
awk -F: -v OFS=: -v h="$password_hash" -v l="$password_lastchg" "\$1 == \"root\" { \$2 = h; \$3 = l } { print }" /rootfs/etc/shadow > /shadow.new
cat /shadow.new > /rootfs/etc/shadow
grep -q "^root:\\\$6\\\$" /rootfs/etc/shadow

rm -rf /rootfs/var/cache/apk /rootfs/var/log/apk.log
install -d -m 0755 /rootfs/var/cache/apk
find /rootfs -depth -exec touch -h -d @0 {} +

(cd /rootfs && find . | LC_ALL=C sort | cpio -o -H newc --reproducible --quiet) | gzip -9 -n > /out/initrd.img
chown "$host_uid:$host_gid" /out/initrd.img
'

DOCKER_CONFIG="$docker_config" docker run --name "$container_name" \
  -v "${tctish_dir}:/tctish:ro" -v "${script_dir}:/guest:ro" -v "${work_dir}/out:/out" \
  -e "ALPINE_MIRROR=${alpine_mirror}" \
  -e "MINIROOTFS_VERSION=${minirootfs_version}" \
  -e "MINIROOTFS_SHA256=${minirootfs_sha256}" \
  -e "ROOTFS_PACKAGES=${rootfs_packages[*]}" \
  -e "BUILDER_PACKAGES=${builder_packages[*]}" \
  "$builder_image" \
  sh -c "$inner_script" sh "$host_uid" "$host_gid"

built="${work_dir}/out/initrd.img"
[[ -s "$built" ]] || die "the build produced no initrd.img."
cp -- "$built" "$output"
sha256sum -- "$output"
