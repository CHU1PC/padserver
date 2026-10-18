#!/usr/bin/env bash
set -euo pipefail

# usage: upload.sh <bytes> length|chunked
# RELAY_URL と SPIKE_TOKEN を環境変数で渡す. UP_WINDOW と UP_CHUNK (byte) と UPLOAD_PATH で relay の upload の window と chunk を変えられる
bytes="$1"
mode="$2"
extra=()
extra+=(-H "x-spike-up-window: ${UP_WINDOW:-4194304}" -H "x-spike-up-chunk: ${UP_CHUNK:-262144}")
if [ "$mode" = "length" ]; then extra=(-H "Content-Length: $bytes"); fi

out="$(mktemp)"
head -c "$bytes" /dev/zero | curl -sS -o "$out" -T - \
  -X POST "${extra[@]+"${extra[@]}"}" \
  -H "x-spike-token: $SPIKE_TOKEN" \
  -w "UPLOAD($mode) size=$bytes status=%{http_code} seconds=%{time_total} Bps=%{speed_upload} uploaded=%{size_upload}\n" \
  "$RELAY_URL${UPLOAD_PATH:-/upload}" 2>&1 | sed "s#${RELAY_URL#https://}#<relay-host>#g" || true
echo "  body: $(head -c 200 "$out" 2>/dev/null | tr '\n' ' ')"
rm -f "$out"
