# 第三者のコードとライセンス

PadServer が取得して使う, 第三者のコードとライセンスの一覧です.
PadServer 自身のコードは MIT です ([LICENSE](LICENSE)).

## 方針

- QEMU は GPLv2 です. このリポジトリは QEMU を同梱しません. 取得と build の script だけを置きます ([docs/decisions.md](docs/decisions.md) の項目 47 と 56).
- 使う人は, 自分の環境で script を実行して QEMU を build し, 自分のアプリに組み込みます. ビルド済みのアプリや, ビルド済みの QEMU は配りません.
- guest の Linux kernel (GPLv2) と, guest の root filesystem に入る package も, 同じ扱いです. script が取得して build します. 成果物 (`bzImage` と `initrd.img`) は, リポジトリに入れません.
- 組み込んだアプリを他の人へ配る場合は, GPLv2 の義務 (対応するソースコードの提供, ライセンス文の添付など) を, 配る人が自分で確かめます. この文書は, その確認の代わりにはなりません.
- ライセンスの欄は, 取得元の LICENSE などの文面か, 各 package の索引の表記を, 実際に読んで書いています. 読んで確かめられなかったものは「要確認」と書きます.
- 開発に使う道具 (`Brewfile` の lint など) は, 成果物に入らないので, この文書の対象にしません.

## 1. QEMU と build に使うコード

取得元と commit は, [scripts/fetch-qemu.sh](scripts/fetch-qemu.sh) が固定しています. 取得した後, `scripts/patches/` の patch を当てます.

| 名前 | 用途 | ライセンス | 取得元と version |
| --- | --- | --- | --- |
| tctiSH | iOS 用に QEMU を build する仕組みと, guest の土台 (overlay と script). patch を当てて使う | MIT (LICENSE) | `https://github.com/tctiSH/tctiSH.git` の commit `76b6f6081fc328c05c4e0fc1d770aec7f1cdcbc4` |
| QEMU (tctiSH の fork) | x86_64 の guest を動かす. iOS では library として組み込む | GPLv2 (COPYING). 一部のファイルは別の, GPLv2 と両立するライセンス (LICENSE) | `https://github.com/tctiSH/qemu.git` の commit `ded0cff5a2a6d3b0a5261ab570518719b42ae2e6` (QEMU 11.1.2) |
| keycodemapdb | QEMU の meson subproject | BSD 系 (LICENSE.BSD) | `https://gitlab.com/qemu-project/keycodemapdb.git` の commit `f5772a62ec52591ff6870b7e8ef32482371f22c6` |
| berkeley-softfloat-3 | QEMU の meson subproject. 浮動小数点の計算 | BSD-3-Clause 系 (COPYING.txt) | `https://gitlab.com/qemu-project/berkeley-softfloat-3.git` の commit `b64af41c3276f97f0e181920400ee056b9c88037` |
| berkeley-testfloat-3 | QEMU の meson subproject | 要確認 | QEMU の `subprojects/berkeley-testfloat-3.wrap` |
| libslirp | QEMU の meson subproject. guest のユーザーモードのネットワーク | BSD-3-Clause (COPYRIGHT) | `https://gitlab.freedesktop.org/slirp/libslirp.git` の commit `9c744e1e52aa0d9646ed91d789d588696292c21e` |
| libucontext | QEMU の meson subproject. coroutine の実装 | ISC 形式 (LICENSE の文面) | `https://github.com/utmapp/libucontext.git` の commit `9b1d8f01a6e99166f9808c79966abe10786de8b6` |
| libffi | iOS 用の QEMU が使う library. tctiSH の script が build する | MIT (LICENSE) | 3.5.0 (`https://github.com/libffi/libffi/releases/download/v3.5.0/libffi-3.5.0.tar.gz`) |
| libiconv | 同上 | LGPL (library 部分. COPYING.LIB). 付属の program は GPLv3 | 1.16 (`https://ftp.gnu.org/gnu/libiconv/libiconv-1.16.tar.gz`) |
| gettext (gettext-runtime) | 同上 | LGPL と GPL の混在 (gettext-runtime の COPYING). library の `libintl` は LGPL (intl/COPYING.LIB) | 0.22.5 (`https://ftp.gnu.org/gnu/gettext/gettext-0.22.5.tar.gz`) |
| GLib | 同上 | LGPL-2.1 (COPYING) | 2.83.0 (`https://download.gnome.org/sources/glib/2.83/glib-2.83.0.tar.xz`) |
| PCRE2 | GLib が使う regular expression の library | BSD-3-Clause WITH PCRE2-exception (LICENCE.md) | 10.44 (`https://github.com/mesonbuild/wrapdb/releases/download/pcre2_10.44-2/pcre2-10.44.tar.bz2`) |
| pixman | 同上 | MIT (COPYING) | 0.38.0 (`https://www.cairographics.org/releases/pixman-0.38.0.tar.gz`) |
| pkg-config | iOS 用の build の道具. 成果物には入らない | GPLv2 (COPYING) | 0.29.2 (`https://pkgconfig.freedesktop.org/releases/pkg-config-0.29.2.tar.gz`) |

- 上の表の libffi から pkg-config までは, tctiSH の `third-party/dependencies/sources` に書かれた取得元と version です. [scripts/build-qemu.sh](scripts/build-qemu.sh) が, tctiSH の `make deps` を通して build します.
- Mac 用の QEMU は, [scripts/build-qemu-host.sh](scripts/build-qemu-host.sh) が, 同じ QEMU のソースから build します. nix が用意する library の一覧とライセンスは, tctiSH の `flake.nix` と `flake.lock` が決めます. 読んで確かめていないので, 要確認です.
- QEMU の `pc-bios` に入る firmware のライセンスは, ファイルごとに違います. 読んで確かめていないので, 要確認です.
- 取り込んだ patch は, 次の3つです. patch のライセンスは, 当てる先のファイルと同じです (tctiSH は MIT).

| patch | 内容 |
| --- | --- |
| `tctiSH-0001-free-apple-id-entitlements.patch` | 無料の Apple ID で署名できるよう, entitlements を減らす |
| `tctiSH-0002-drop-app-icon.patch` | アプリのアイコンを build から外す |
| `tctiSH-0003-stikjit-interface-types.patch` | `build_stikjit.sh` の xcodebuild に Swift の旗を足す |

## 2. guest の Linux kernel

[guest/build-kernel.sh](guest/build-kernel.sh) が, tctiSH の commit `76b6f6081fc328c05c4e0fc1d770aec7f1cdcbc4` を取得し, [guest/kernel.config](guest/kernel.config) を足して build します.

| 名前 | 用途 | ライセンス | 取得元と version |
| --- | --- | --- | --- |
| Linux kernel | guest の kernel (`bzImage`) | GPLv2 | 6.18.53 (tctiSH の `assets/build_kernel.sh` が `https://cdn.kernel.org/pub/linux/kernel/v6.x` から取得) |
| nixos/nix (Docker image) | kernel を build する container. 成果物には入らない | 要確認 | `nixos/nix@sha256:7a007c766426c1877758ddc5cb87a965ac131fc78c582ce0083d922d51ae945c` |

## 3. guest の root filesystem

[guest/build-rootfs.sh](guest/build-rootfs.sh) が, Alpine Linux 3.24 の minirootfs (3.24.2) に, 次の package を固定の version で入れます. tctiSH の `overlay` と `scripts` (MIT) も入ります.

- ライセンスは, `https://pkgs.alpinelinux.org/package/v3.24/` の索引の表記です. 索引の表記は package の version が新しくなると変わることがあります. zlib の索引は 1.3.2-r1 で, 固定している版は 1.3.2-r0 です.
- Docker に関わる package (docker, containerd, runc など) は, 固定した版を Alpine の community repository から入れます.
- 配る前に, 実際に入った版のライセンス文を, 配る人が確かめてください.

| package | version | ライセンス |
| --- | --- | --- |
| alpine-baselayout | 3.7.2-r1 | GPL-2.0-only |
| alpine-baselayout-data | 3.7.2-r1 | GPL-2.0-only |
| alpine-keys | 2.6-r0 | MIT |
| alpine-release | 3.24.2-r0 | MIT |
| apk-tools | 3.0.8-r0 | GPL-2.0-only |
| bash | 5.3.9-r1 | GPL-3.0-or-later |
| busybox | 1.37.0-r31 | GPL-2.0-only |
| busybox-binsh | 1.37.0-r31 | GPL-2.0-only |
| ca-certificates | 20260909-r0 | MPL-2.0 AND MIT |
| ca-certificates-bundle | 20260909-r0 | MPL-2.0 AND MIT |
| containerd | 2.3.7-r0 | Apache-2.0 |
| docker | 29.8.2-r1 | Apache-2.0 |
| docker-cli | 29.8.2-r1 | Apache-2.0 |
| docker-cli-buildx | 0.34.1-r2 | Apache-2.0 |
| docker-cli-compose | 5.1.4-r2 | Apache-2.0 |
| docker-engine | 29.8.2-r1 | Apache-2.0 |
| dropbear | 2026.91-r0 | MIT |
| e2fsprogs | 1.47.4-r0 | GPL-2.0-or-later AND LGPL-2.0-or-later AND BSD-3-Clause AND MIT |
| e2fsprogs-libs | 1.47.4-r0 | GPL-2.0-or-later AND LGPL-2.0-or-later AND BSD-3-Clause AND MIT |
| iptables | 1.8.13-r0 | GPL-2.0-or-later |
| libapk | 3.0.8-r0 | GPL-2.0-only |
| libblkid | 2.42.3-r1 | LGPL-2.1-or-later |
| libbsd | 0.12.2-r0 | BSD-3-Clause |
| libcom_err | 1.47.4-r0 | GPL-2.0-or-later AND LGPL-2.0-or-later AND BSD-3-Clause AND MIT |
| libcrypto3 | 3.5.9-r0 | Apache-2.0 |
| libeconf | 0.8.3-r0 | MIT |
| libmd | 1.2.0-r0 | BSD-3-Clause AND BSD-2-Clause AND ISC AND Beerware AND Public Domain |
| libmnl | 1.0.5-r2 | LGPL-2.1-or-later |
| libncursesw | 6.6_p20260516-r0 | X11 |
| libnftnl | 1.3.1-r0 | GPL-2.0-or-later |
| libseccomp | 2.6.1-r0 | LGPL-2.1-or-later |
| libssl3 | 3.5.9-r0 | Apache-2.0 |
| libuuid | 2.42.3-r1 | BSD-3-Clause |
| libxtables | 1.8.13-r0 | GPL-2.0-or-later |
| musl | 1.2.6-r2 | MIT |
| musl-utils | 1.2.6-r2 | MIT AND BSD-2-Clause AND GPL-2.0-or-later |
| ncurses-terminfo-base | 6.6_p20260516-r0 | X11 |
| netcat-openbsd | 1.234.1-r0 | BSD-3-Clause |
| openssl | 3.5.9-r0 | Apache-2.0 |
| readline | 8.3.3-r1 | GPL-3.0-or-later |
| runc | 1.4.3-r2 | Apache-2.0 |
| scanelf | 1.3.9-r1 | GPL-2.0-only |
| skalibs-libs | 2.15.0.0-r0 | ISC |
| ssl_client | 1.37.0-r31 | GPL-2.0-only |
| tini-static | 0.19.0-r3 | MIT |
| utmps-libs | 0.1.3.3-r0 | ISC |
| zlib | 1.3.2-r0 | Zlib |

root filesystem を作る container の image (`alpine@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6`) と, 道具の package (`cpio`, `gzip`) は, 成果物に入りません. ライセンスは読んでいないので, 要確認です.

## 4. Swift の package

`Packages/PadServerCore` と `cli/` が使います. `Packages/PadGuest` は, 他の package に依存しません. アプリ (`project.yml`) は `PadServerCore` だけに依存します.

- version は `Package.resolved` の値です. ライセンスは, その version の commit にある LICENSE の文面を読んで確かめました.
- 直接の依存は, Hummingbird (`PadServerCore` と `cli/`), swift-argument-parser (`cli/`), TOMLDecoder (`cli/`) の3つです. 残りは, これらが使う間接の依存です.
- 取得元は, すべて GitHub の `https://github.com/<組織>/<名前>` です. 組織は表の列にあります.

| 名前 | 組織 | version | ライセンス |
| --- | --- | --- | --- |
| hummingbird | hummingbird-project | 2.28.0 | Apache-2.0 |
| swift-argument-parser | apple | 1.8.2 | Apache-2.0 |
| TOMLDecoder | dduan | 0.4.5 | MIT |
| async-http-client | swift-server | 1.36.2 | Apache-2.0 |
| swift-service-lifecycle | swift-server | 2.12.1 | Apache-2.0 |
| swift-algorithms | apple | 1.2.1 | Apache-2.0 |
| swift-asn1 | apple | 1.7.3 | Apache-2.0 |
| swift-async-algorithms | apple | 1.1.7 | Apache-2.0 |
| swift-atomics | apple | 1.3.1 | Apache-2.0 |
| swift-certificates | apple | 1.21.0 | Apache-2.0 |
| swift-collections | apple | 1.7.3 | Apache-2.0 |
| swift-configuration | apple | 1.2.2 | Apache-2.0 |
| swift-crypto | apple | 5.0.1 | Apache-2.0 |
| swift-distributed-tracing | apple | 1.7.0 | Apache-2.0 |
| swift-http-structured-headers | apple | 1.7.0 | Apache-2.0 |
| swift-http-types | apple | 1.8.0 | Apache-2.0 |
| swift-log | apple | 1.16.1 | Apache-2.0 |
| swift-metrics | apple | 2.12.0 | Apache-2.0 |
| swift-nio | apple | 2.104.0 | Apache-2.0 |
| swift-nio-extras | apple | 1.35.1 | Apache-2.0 |
| swift-nio-http2 | apple | 1.46.0 | Apache-2.0 |
| swift-nio-ssl | apple | 2.37.5 | Apache-2.0 |
| swift-nio-transport-services | apple | 1.28.0 | Apache-2.0 |
| swift-numerics | apple | 1.1.1 | Apache-2.0 |
| swift-service-context | apple | 1.5.0 | Apache-2.0 |
| swift-system | apple | 1.8.1 | Apache-2.0 |

swift-crypto と swift-nio-ssl は, BoringSSL 由来のコードを含むことがあります. その部分のライセンス文は, 読んでいないので, 要確認です.

## 5. relay の依存

`relay/` は, Cloudflare Workers の中継です. `package.json` の依存は, 開発用 (`devDependencies`) の3つだけです. version は `bun.lock` の値です. ライセンスは npm registry の `license` の欄です.

| 名前 | 用途 | ライセンス | version |
| --- | --- | --- | --- |
| wrangler | Workers の開発と配備 | MIT OR Apache-2.0 | 4.151.1 |
| typescript | 型の検査 | Apache-2.0 | 5.9.3 |
| @types/bun | bun の型定義 | MIT | 1.4.3 |

wrangler が使う間接の依存 (miniflare, workerd, esbuild など) は, 一覧にしていません. ライセンスは要確認です.
