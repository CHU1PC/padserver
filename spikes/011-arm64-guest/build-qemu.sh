#!/usr/bin/env bash
set -euo pipefail
W=${SPIKE_DIR:?}
cd $W/build-aarch64
$W/qemu-src/configure --target-list=aarch64-softmmu \
 --disable-hvf --disable-cocoa --disable-coreaudio --disable-sdl --disable-gtk \
 --disable-vnc --disable-spice --disable-opengl --disable-dbus-display \
 --disable-virglrenderer --enable-capstone --enable-fdt=system --disable-rust \
 --disable-gnutls --disable-gcrypt --disable-nettle --disable-libssh \
 --disable-curl --disable-libusb --disable-usb-redir --disable-libiscsi \
 --disable-lzo --disable-snappy --disable-zstd --disable-png \
 --disable-vde --disable-curses --disable-smartcard \
 --disable-docs --disable-werror --disable-tools --disable-guest-agent \
 --enable-slirp --disable-slirp-smbd -Dforce_fallback_for=slirp \
 -Dslirp:default_library=static --with-coroutine=libucontext --enable-ucontext \
 --enable-virtfs --disable-download --enable-tcg-threaded-interpreter
nice ninja -j3 qemu-system-aarch64
