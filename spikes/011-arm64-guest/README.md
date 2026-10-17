# arm64 の guest の検証 (V22)

Issue #32 では、tctiSH の QEMU で arm64 の guest が JIT 無しで動くかを確かめ、動いたので、arm64 と x86_64 の guest の速さを Mac の上で比べました. iPad の実機では何も動かしていません. 結果はすべて Mac の上の値です.

## 結果

| 確かめたこと | 結果 |
| --- | --- |
| tctiSH の QEMU の source で、arm64 の guest 用の QEMU (`aarch64-softmmu`) を、TCTI (JIT 無しの interpreter) でビルドできる | できた. tctiSH が x86_64 用に使う configure の旗をそのまま使い、`--target-list` だけを `aarch64-softmmu` に変えた. 変えた旗はもう1つあり、`--disable-fdt` を `--enable-fdt=system` にした (aarch64 の machine は fdt を要る) |
| その QEMU で arm64 の Alpine が起動する | 起動した. `Linux version 6.18.52-0-virt`、`on aarch64` の login まで約40秒だった |
| arm64 の Alpine に Docker を入れて、container を動かせる | 動いた. `docker version` は `OS/Arch: linux/arm64` で、`python:3-alpine` (arm64) を pull して、`docker run` で Python が動いた |
| x86_64 の guest と速さを比べる | 下の表. 計算の速さは、測った3つの負荷で、ほぼ同じだった |

TCTI を使ったことは、ビルドした tree に TCTI の gadget の object が36個あることで確かめました. `-accel tcg` で起動し、HVF は無効にしています.

## 速さの比

同じ Mac の上で、同じ source から作った QEMU (TCTI) の2つを使い、同じ Alpine 3.24.2 の netboot (`virt` kernel 6.18.52)、同じ `python:3-alpine` の image、同じ負荷で測りました. 各負荷は5回ずつ、guest の中の `time.perf_counter` で測っています. 表は中央値 (秒) で、比は arm64 を x86_64 で割った値です. 1より小さければ arm64 が速いです.

| 場所 | 負荷 | arm64 | x86_64 | 比 | 5回の範囲 (arm64 / x86_64) |
| --- | --- | --- | --- | --- | --- |
| guest の上 | Python の 200万回の整数の loop | 6.384 | 5.853 | 1.09 | 6.171 から 6.650 / 5.741 から 6.134 |
| guest の上 | md5 を 8 MiB | 0.086 | 0.086 | 1.00 | 0.080 から 0.122 / 0.085 から 0.089 |
| guest の上 | zlib の圧縮と展開を 4 MiB で4回 | 0.542 | 0.555 | 0.98 | 0.520 から 0.558 / 0.527 から 0.590 |
| container の中 | Python の 200万回の整数の loop | 7.510 | 7.418 | 1.01 | 6.752 から 8.218 / 6.630 から 7.528 |
| container の中 | md5 を 8 MiB | 0.079 | 0.085 | 0.93 | 0.079 から 0.086 / 0.084 から 0.087 |
| container の中 | zlib の圧縮と展開を 4 MiB で4回 | 0.486 | 0.504 | 0.96 | 0.485 から 0.565 / 0.499 から 0.508 |

| 手順 | arm64 | x86_64 |
| --- | --- | --- |
| kernel の起動から login まで (guest 側の modloop の取得を含む) | 40秒 | 60秒 |
| `apk add python3 docker` | 32秒 | 36秒 |
| Docker daemon の起動 | 13秒 | 15秒 |
| `docker pull python:3-alpine` | 26秒 | 29秒 |

起動と apk と pull は、それぞれ1回の測定です. 回数を重ねていないので、差は誤差の範囲かもしれません.

## この検証で確かめていないこと

- iPad の実機では動かしていません. 実機の app が持つ QEMU は x86_64 用 (`build_dependencies.sh` の `--target-list=x86_64-softmmu`) なので、arm64 の guest を実機で動かすには、app の側の build の変更が要ります. それがうまく行くかは分かりません.
- 比べた x86_64 の guest は、tctiSH の自前の kernel (007) ではなく、Alpine の `virt` kernel です. CPU は、arm64 が `cortex-a72`、x86_64 が `qemu64` です. どちらも 4 CPU、メモリ 2 GiB です.
- rootfs は RAM の上で、disk の I/O は比べていません.
- Docker の既定のネットワーク (bridge) は使っていません. container は `--network none` で動かしました.
- 負荷は Python の計算と、md5 と zlib だけです. 実際のアプリ (Kikitoru など) の負荷は試していません.
- `md5` と `zlib` の秒数は、どちらの guest でも、計算の量に対して短いので、負荷の大きさを見直す余地があります.
- sha256 は、arm64 では CPU の拡張命令を使い、x86_64 の `qemu64` では使わないので、速さを比べる負荷から外しました.

## 再現の手順

作業の場所は repo の外に作ります (`SPIKE_DIR`). QEMU の source は tctiSH の fork (`ded0cff5a2a6d3b0a5261ab570518719b42ae2e6`) で、007 と同じです. host の library は、tctiSH の flake (`76b6f6081fc328c05c4e0fc1d770aec7f1cdcbc4`) の `host-qemu` shell から取ります.

```sh
export SPIKE_DIR=<repo の外の作業用ディレクトリ>
# 1. QEMU の source を $SPIKE_DIR/qemu-src に置き、flake.nix と flake.lock を $SPIKE_DIR/flake に置く
mkdir -p "$SPIKE_DIR/build-aarch64"
nix develop "path:$SPIKE_DIR/flake#host-qemu" --command ./build-qemu.sh
# 最後の署名の工程は Xcode の Rez と SetFile を PATH に足して完了させる
# 2. Alpine 3.24.2 の netboot (aarch64 と x86_64) を $SPIKE_DIR/img/a64 と $SPIKE_DIR/img/x64 に展開する
#    bench.py と guest.sh は $SPIKE_DIR/img に置き、$SPIKE_DIR/img で `python3 -m http.server 18080 --bind 127.0.0.1` を動かす
# 3. 起動と測定. ssh と monitor の port は 15022 と 15045 に固定している
./run.exp a64 "$SPIKE_DIR/a64.log"
./run.exp x64 "$SPIKE_DIR/x64.log"
```

`run.exp` の x86_64 の側は、tctiSH の x86_64 用の QEMU (007 と同じ build) を `$SPIKE_DIR/qemu-system-x86_64-tcti` に置いて使います. その QEMU は BIOS を source の `pc-bios` から読みます.
