# tctiSH guest kernel の再ビルド

Issue #20 では、tctiSH の設定を変えずに kernel を Linux 上でビルドし、Mac 上の QEMU で guest が起動するかを確かめました。Docker の動作や rootfs の変更は、後続の Issue で扱います。

## 固定した入力

| 入力 | 値 |
| --- | --- |
| tctiSH | `76b6f6081fc328c05c4e0fc1d770aec7f1cdcbc4` |
| QEMU fork | `ded0cff5a2a6d3b0a5261ab570518719b42ae2e6` |
| Linux | `6.18.53`、tarball の SHA-256 は `4d6fba95c2244b08a7b4144a4d38b9be4fb31abb5e7682ae40bb5cb11374cfe0` |
| kernel の設定 | `assets/kernel/tctish.config` を変更せずに使用 |
| toolchain | `assets/kernel/flake.lock` で固定された Nix 環境 |

`assets/build_kernel.sh` が Linux の取得、設定の展開、`bzImage` のビルドを行います。既存の `assets/bzImage` は、作業用の別 checkout に退避しました。ビルドは Linux x86_64 上の Docker で行い、CPU を8個、メモリを12 GiBに制限しました。

```sh
build_checkout=$(mktemp -d)
empty_docker_config=$(mktemp -d)
git clone https://github.com/tctiSH/tctiSH.git "$build_checkout"
git -C "$build_checkout" checkout --detach 76b6f6081fc328c05c4e0fc1d770aec7f1cdcbc4
mv "$build_checkout/assets/bzImage" "$build_checkout/assets/bzImage.original"
printf '{}\n' > "$empty_docker_config/config.json"

DOCKER_CONFIG="$empty_docker_config" docker run --rm --cpus=8 --memory=12g \
  -v "$build_checkout:/src" -w /src \
  -e 'NIX_CONFIG=experimental-features = nix-command flakes' \
  nixos/nix@sha256:7a007c766426c1877758ddc5cb87a965ac131fc78c582ce0083d922d51ae945c \
  nix develop path:/src/assets/kernel -c env TCTISH_TOOLCHAIN=1 bash /src/assets/build_kernel.sh
```

`$build_checkout` は固定した tctiSH の作業用 checkout です。`$empty_docker_config` には `{}` だけの Docker 設定を書き、既存の認証設定を使わずに実行しました。

```text
Kernel: arch/x86/boot/bzImage is ready  (#1)
==> wrote assets/bzImage (9.0M)
==> kernel release: 6.18.53tctish
87c1742cd9d40508fa351b3a107378a4352f8aa0e8458addd2e0c25e0c407116  assets/bzImage
```

## Mac 上の起動

ビルドした `bzImage` を Mac へコピーし、tctiSH の `initrd.img` と `empty.qcow` と一緒に一時ディレクトリへ置きました。元の tctiSH の `assets/bzImage` は変更していません。QEMU は tctiSH が固定する fork を `build_host_qemu.sh tcti` で Mac 向けにビルドしました。最終工程には Xcode の `Rez` と `SetFile` が必要です。この環境では Nix shell の PATH に無かったため、`xcrun --find Rez` で所在を確認し、両ツールがあるディレクトリを PATH に足して最終工程を完了しました。TCTI backend で guest を起動しました。

```text
$ TCTISH_QEMU=<Mac 向け QEMU の絶対 path> ./assets/boot_guest.sh --backend tcti
==> creating a working disk from empty.qcow
==> console follows; the guest logs in as root automatically

# uname -a
Linux tctiSH 6.18.53tctish #1 SMP Tue Jan  1 00:00:00 UTC 1980 x86_64 Linux

# poweroff
Requesting system poweroff
[   89.180818] reboot: Power down
```

この結果で、設定を変えない kernel の再ビルドと Mac 上の guest 起動を確認しました。Docker の既定のネットワーク、`docker exec`、`docker compose` の動作は、この検証には含めていません。

guest の起動の処理を直す Issue #22 の結果は [BOOT.md](BOOT.md) にあります。

kernel にネットワークの機能を足す検証 (Issue #21) は [NETWORK.md](NETWORK.md) にあります。
