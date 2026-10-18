#!/bin/sh
# shellcheck disable=SC2310,SC2311,SC2312
set -eu

usage() {
  echo "Usage: guest/test-disk-init.sh KERNEL INITRD SSH_KEY [WORK_DIR]" >&2
  echo "Boots the guest with QEMU (KVM) and checks how guest/init treats the raw disk." >&2
  exit 2
}

[ $# -ge 3 ] || usage
kernel=$1
initrd=$2
key=$3
work=${4:-$(mktemp -d)}
port=10022
disk="$work/guest.raw"
pid_file="$work/qemu.pid"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

guest() {
  ssh -i "$key" -p "$port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR -o ConnectTimeout=3 root@127.0.0.1 "$@"
}

boot() {
  rm -f "$work/$1.log"
  qemu-system-x86_64 -M pc -m 1G -smp 2 -accel kvm -cpu host \
    -kernel "$kernel" -initrd "$initrd" -append "tcti_disk=file console=ttyS0" \
    -device virtio-net-pci,netdev=net0 \
    -netdev "user,id=net0,net=192.168.100.0/24,dhcpstart=192.168.100.100,hostfwd=tcp:127.0.0.1:$port-:22" \
    -device virtio-rng-pci -device virtio-blk-pci,drive=d1 \
    -drive "file=$disk,id=d1,if=none,format=raw" \
    -display none -no-reboot -serial "file:$work/$1.log" -daemonize -pidfile "$pid_file"
  n=0
  until guest true 2> /dev/null; do
    n=$((n + 1))
    [ "$n" -lt 60 ] || fail "the guest did not accept ssh ($1)."
    sleep 3
  done
}

halt_guest() {
  pid=$(cat "$pid_file")
  guest sync
  guest poweroff || true
  n=0
  while kill -0 "$pid" 2> /dev/null; do
    n=$((n + 1))
    [ "$n" -lt 30 ] || fail "the guest did not power off."
    sleep 1
  done
}

echo "== first boot: empty raw disk becomes ext4"
truncate -s 1G "$disk"
boot first
grep -q "Creating one" "$work/first.log" || fail "mkfs did not run on the empty disk."
id_first=$(guest blkid /dev/vda)
[ -n "$id_first" ] || fail "no ext4 filesystem was found on the disk."
guest mount | grep "^/dev/vda on /var/lib/docker type ext4" || fail "/var/lib/docker is not on the disk."
guest "echo kept > /var/lib/docker/marker"
halt_guest

echo "== second boot: the filesystem and the saved data stay"
boot second
if grep -q "Creating one" "$work/second.log"; then fail "mkfs ran on a disk with a filesystem."; fi
[ "$(guest blkid /dev/vda)" = "$id_first" ] || fail "the filesystem UUID changed."
[ "$(guest cat /var/lib/docker/marker)" = kept ] || fail "the saved data is gone."
halt_guest

echo "== third boot: a disk with unknown data is never formatted"
rm -f "$disk"
truncate -s 1G "$disk"
printf 'JUNK' | dd of="$disk" bs=1 seek=512 conv=notrunc 2> /dev/null
boot third
grep -q "Refusing to reformat" "$work/third.log" || fail "the disk with unknown data was not refused."
if grep -q "Creating one" "$work/third.log"; then fail "mkfs ran on a disk with unknown data."; fi
halt_guest
[ "$(dd if="$disk" bs=1 skip=512 count=4 2> /dev/null)" = JUNK ] || fail "the unknown data was overwritten."

echo "PASS: $id_first"
