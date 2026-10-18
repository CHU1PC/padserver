# guest の起動から Docker の応答までの時間 (Mac)

Issue #376 では、Mac の上で guest を起動してから、Docker の API が応答するまでの時間を測りました. iPad の実機では何も動かしていません. 結果はすべて Mac の上の値です.

## 結果

| 確かめたこと | 結果 |
| --- | --- |
| Mac 用の QEMU の library (`libqemu-x86_64.dylib`) で、Docker を含む guest が起動する | 起動した. `QEMURunner` が dlopen して、kernel が起動し、init が `dockerd` を起動した |
| `DockerClient` が、本物の `dockerd` と相互 TLS で繋がる | 繋がった. 成功した9回すべてで、`PortForwarder` で転送した port 経由の `ping()` が成功し、`version()` は `Version` が 29.8.2、`ApiVersion` が 1.56 を返した |
| 起動から Docker の API が応答するまでの時間 | disk が空の初回で、中央値 31.67 秒 (6回, 31.20 から 34.03 秒). 作った disk を使い回した2回目以降は、中央値 31.20 秒 (3回, 31.19 から 31.47 秒) |

disk を ext4 にする初回の `mkfs` による差は、測定のばらつきの内に収まりました.

## 測り方

T0 は `QEMUGuestController.start()` を呼ぶ直前で、T1 は `start()` が戻った時刻です. `start()` は disk の確保、鍵の生成、credential の tar の書き出し、QEMU の起動、`GuestDockerReadiness` の ping の成功までを含みます. controller は 1 秒おきに ping するので、T1 には最大で約 1 秒の粒度があります.

測定用の executable は repo に入れず、使い捨てにしました. `PadGuest` の `QEMUMonitor` の port は、公開の `init()` では 10045 に固定されています. 同時に別の guest が動いていたので、`PadGuest` の写しの上で 27045 に変えて測りました. `PadGuest` の他の部分は変えていません.

1回ごとに、新しいプロセスで QEMU を起動しました. 鍵 (`GuestCredentialsProvider`) は1回ごとに新しく作り、保存先は一時ファイルの `CredentialStore` にしました.

| 項目 | 値 |
| --- | --- |
| Mac | Apple Silicon, macOS 26.5 |
| guest のメモリ | 2 GiB (`-m 2G`) |
| guest の CPU | 4 個 (`-smp cpus=4,maxcpus=4`), `-cpu Haswell-v4,-pcid,-tsc-deadline,-invpcid,-spec-ctrl` |
| 実行方式 | `-M pc -accel tcg` (QEMU の TCTI. HVF は使わない) |
| disk | raw, 4 GiB (sparse), virtio-blk |
| 通信 | `-netdev user`, ssh の hostfwd は 27022. Docker の API は `PortForwarder` が monitor 経由で 127.0.0.1 の空き port へ転送 |
| kernel の引数 | `tcti_disk=file console=ttyS0` |
| 追加の引数 | `-device virtio-rng-pci -display none -no-reboot -serial file:<log> -monitor tcp:127.0.0.1:27045,server,nowait` |

`QEMUArguments` には kernel の引数 (`-append`) と `-M` と `-serial` が含まれないので、これらは `additionalArguments` で渡しました.

## 使った成果物

| 成果物 | SHA-256 | 大きさ |
| --- | --- | --- |
| `bzImage` | `42f36070d9045be2131f9e0c1e42656ee8f048f6878eafdbdf0402131602b87f` | 9,868,288 byte |
| `initrd.img` | `d644a5026d991159e6937fb6ca68ce61c42ce9395f3305c37813c19849d7a0ff` | 106,783,393 byte |
| `libqemu-x86_64.dylib` | `2c77f8e05cbbb7c088e935827a7148e373b1884d1bd8f455ce397c1a47d95520` | 419,046,824 byte |

- `bzImage` は、Issue #21 でビルドしたもの ([NETWORK.md](../007-guest-rebuild/NETWORK.md)) で、SHA-256 が一致するものを使いました.
- `initrd.img` は、WSL の Docker の中で `guest/build-rootfs.sh` を実行して作りました. Docker 29.8.2 を含みます.
- `libqemu-x86_64.dylib` は、`scripts/build-qemu-host.sh` で作りました. QEMU の fork は `ded0cff5a2a6d3b0a5261ab570518719b42ae2e6` です.

## 実測の出力

出力は、測定用の executable が書いたものです. 秒は T0 からの経過です.

disk が空の初回 (6回. `mkfs.ext4` が走る).

```text
RESULT fresh1 T0_to_T1_seconds=33.590
RESULT fresh3 T0_to_T1_seconds=31.205
RESULT warm0  T0_to_T1_seconds=31.349
RESULT fresh4 T0_to_T1_seconds=31.802
RESULT fresh5 T0_to_T1_seconds=34.026
RESULT fresh6 T0_to_T1_seconds=31.544
```

作った disk を使い回した2回目以降 (3回).

```text
RESULT warm1 T0_to_T1_seconds=31.467
RESULT warm2 T0_to_T1_seconds=31.189
RESULT warm3 T0_to_T1_seconds=31.197
VERSION warm3 docker=29.8.2 api=1.56
```

## 起動の各段

serial の log (`console=ttyS0`) を 50 ミリ秒おきに読み、目印の文字列が最初に現れた時刻を記録しました. 値は T0 からの秒数です. 目印の時刻は、log を書いた時刻ではなく、読めた時刻なので、数十ミリ秒の誤差があります.

| 段 | 目印 | 初回 (fresh3) | 初回 (warm0) | 2回目以降 (warm1) | 2回目以降 (warm3) |
| --- | --- | --- | --- | --- | --- |
| QEMU と BIOS から kernel の起動 | `Linux version` | 1.53 | 1.67 | 1.42 | 1.42 |
| initramfs の展開 (106 MB) から init の開始 | `Run /init` | 20.04 | 19.86 | 19.57 | 19.38 |
| 初回の disk の ext4 化 | `Creating one` | 20.50 | 20.25 | (出ない) | (出ない) |
| `dockerd` の起動の開始 | `Docker` | 25.64 | 25.32 | 25.27 | 24.90 |
| `dockerd` の準備完了 | `API listen` | 30.31 | 29.09 | 28.46 | 28.20 |
| `DockerClient.ping` の成功 (T1) | | 31.205 | 31.349 | 31.467 | 31.197 |

最初の1回 (fresh1) だけは、`Linux version` が 4.44 秒で、library を初めて読み込むため遅くなったと考えられます. この値は未確認です.

時間の大半は、次の2つです.

- kernel が initramfs を展開して `/init` を始めるまでの約 18 秒 (T0 から 1.5 秒の後から約 20 秒まで).
- `/init` の開始から `Docker` の目印までの約 5.5 秒と、そこから `dockerd` の準備完了までの約 3 から 4 秒.

`dockerd` の準備完了から T1 までは、約 1 秒です (controller の ping の間隔と TLS の握手).

## 測定中に見つけたこと

実装の修正は別の Issue のため、ここでは直していません.

- **終了時に固まる**: `controller.stop()` で `quit` を送った後、`exit(0)` を呼ぶと、`qemu_run_exit_notifiers` の mutex の待ちでプロセスが戻らなかった (`sample` で確認). 測定用の executable は、`_exit(0)` を使って回避した. app が QEMU の停止後にプロセスを終わらせる場合に、同じことが起きうる.
- **異常終了が1回**: 全10回の起動のうち1回 (`fresh2`) で、起動の約23秒の `mkfs.ext4` の最中に、プロセスが何も出力せずに消えた. 原因は調べていない. その後の8回の起動では、再現しなかった.
- **monitor の port の固定**: `QEMUMonitor` の公開の `init()` は 10045 に固定される. 他の guest と同時に動かす場合は、port を渡せない.

## 再現の手順

1. WSL の Docker の中で、`guest/build-rootfs.sh` を実行して `initrd.img` を作る. kernel は上の SHA-256 の `bzImage` を使う.
2. `scripts/build-qemu-host.sh` を実行して、`build/qemu/host/` に dylib と `pc-bios` を作る (約 6 分).
3. `PadGuest` を使う executable で、`QEMUGuestController` を上の引数で作り、`start()` の前後の時刻を測る.
