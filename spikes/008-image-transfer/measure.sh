#!/bin/bash
# usage: measure.sh <work dir> <size in MB> <guest ssh command...>
# 乱数のファイルを載せた linux/amd64 の image をビルドし, 書き出しと guest への読み込みの時間を測る.
set -euo pipefail

WORK=$1
SIZE_MB=$2
shift 2
TAG="spike-transfer:${SIZE_MB}mb"

mkdir -p "$WORK/ctx-$SIZE_MB"
dd if=/dev/urandom of="$WORK/ctx-$SIZE_MB/payload.bin" bs=1048576 count="$SIZE_MB" 2>/dev/null
printf 'FROM alpine:3.20\nCOPY payload.bin /payload.bin\n' > "$WORK/ctx-$SIZE_MB/Dockerfile"

echo "== build"
docker build --platform linux/amd64 -t "$TAG" "$WORK/ctx-$SIZE_MB" 2>&1 | tail -2
docker image inspect "$TAG" --format 'arch={{.Architecture}} size={{.Size}}'

echo "== save"
time docker save "$TAG" -o "$WORK/image-$SIZE_MB.tar"
ls -l "$WORK/image-$SIZE_MB.tar" | awk '{print "tar bytes: " $5}'

echo "== load into the guest over ssh"
time "$@" docker load < "$WORK/image-$SIZE_MB.tar"
"$@" "docker image inspect $TAG --format 'arch={{.Architecture}} size={{.Size}}'"
