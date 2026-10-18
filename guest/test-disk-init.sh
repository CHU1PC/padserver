#!/bin/sh
# shellcheck disable=SC2310,SC2311,SC2312
set -eu

usage() {
  echo "Usage: guest/test-disk-init.sh KERNEL INITRD PLACEHOLDER_KEY [WORK_DIR]" >&2
  echo "Boots the guest with QEMU (KVM) and checks how guest/init treats the raw disk," >&2
  echo "that the public placeholder ssh key is refused, and that the Docker API needs a client certificate." >&2
  echo "PLACEHOLDER_KEY is the private half of tctiSH's public placeholder key. Needs qemu, ssh, openssl, curl, GNU cpio." >&2
  exit 2
}

[ $# -ge 3 ] || usage
kernel=$1
initrd=$2
placeholder_key=$3
work=${4:-$(mktemp -d)}
port=10022
docker_port=12376
disk="$work/guest.raw"
pid_file="$work/qemu.pid"
key="$work/id_test"
creds="$work/creds"
cred_disk="$work/creds.tar"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

guest() {
  ssh -i "$key" -p "$port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR -o ConnectTimeout=3 root@127.0.0.1 "$@"
}

# 試験用の鍵と, host が guest に渡す鍵 (CA, server) を作る. client の鍵は guest に渡さない.
prepare() {
  mkdir -p "$creds" "$work/root/.ssh"
  chmod 700 "$work/root" "$work/root/.ssh"
  ssh-keygen -q -t ed25519 -N "" -f "$key"
  cp "$key.pub" "$work/root/.ssh/authorized_keys"
  chmod 600 "$work/root/.ssh/authorized_keys"
  (cd "$work" && find root | cpio -o -H newc -R 0:0 --quiet) | gzip -9n > "$work/ssh-key.cpio.gz"
  cat "$initrd" "$work/ssh-key.cpio.gz" > "$work/initrd-test.img"

  (
    cd "$creds"
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=test-ca" -keyout ca-key.pem -out ca.pem 2> /dev/null
    printf 'basicConstraints=CA:FALSE\nsubjectAltName=DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth\n' > server-ext.cnf
    printf 'basicConstraints=CA:FALSE\nextendedKeyUsage=clientAuth\n' > client-ext.cnf
    for name in server client; do
      openssl req -newkey rsa:2048 -nodes -subj "/CN=test-$name" -keyout "$name-key.pem" -out "$name.csr" 2> /dev/null
      openssl x509 -req -in "$name.csr" -CA ca.pem -CAkey ca-key.pem -CAcreateserial -days 2 \
        -extfile "$name-ext.cnf" -out "$name.pem" 2> /dev/null
    done
    tar -cf "$cred_disk" ca.pem server.pem server-key.pem
  )
}

docker_ping() {
  curl -sS --max-time 5 --cacert "$creds/ca.pem" "$@" "https://127.0.0.1:$docker_port/_ping"
}

boot() {
  rm -f "$work/$1.log"
  cred_args=
  if [ "${2:-creds}" = creds ]; then
    cred_args="-drive file=$cred_disk,id=d2,if=none,format=raw,readonly=on -device virtio-blk-pci,drive=d2"
  fi
  # shellcheck disable=SC2086 # cred_args は空白で分けて渡す.
  qemu-system-x86_64 -M pc -m 1G -smp 2 -accel kvm -cpu host \
    -kernel "$kernel" -initrd "$work/initrd-test.img" -append "tcti_disk=file console=ttyS0" \
    -device virtio-net-pci,netdev=net0 \
    -netdev "user,id=net0,net=192.168.100.0/24,dhcpstart=192.168.100.100,hostfwd=tcp:127.0.0.1:$port-:22,hostfwd=tcp:127.0.0.1:$docker_port-:2376" \
    -device virtio-rng-pci -device virtio-blk-pci,drive=d1 \
    -drive "file=$disk,id=d1,if=none,format=raw" \
    $cred_args \
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

prepare
if gzip -dc "$initrd" | cpio -it 2> /dev/null | grep -q placeholder_key; then fail "the initrd still holds the placeholder key."; fi

echo "== first boot: empty raw disk becomes ext4"
truncate -s 1G "$disk"
boot first
grep -q "Creating one" "$work/first.log" || fail "mkfs did not run on the empty disk."
id_first=$(guest blkid /dev/vda)
[ -n "$id_first" ] || fail "no ext4 filesystem was found on the disk."
guest mount | grep "^/dev/vda on /var/lib/docker type ext4" || fail "/var/lib/docker is not on the disk."
guest "echo kept > /var/lib/docker/marker"

echo "== ssh: the public placeholder key and passwords are refused"
ssh_denied=$(ssh -i "$placeholder_key" -p "$port" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=3 root@127.0.0.1 true 2>&1 || true)
case "$ssh_denied" in
  *"Permission denied (publickey)."*) ;;
  *) fail "ssh did not end with a publickey-only refusal: $ssh_denied" ;;
esac

echo "== docker api: a client certificate is required"
n=0
until docker_ping --cert "$creds/client.pem" --key "$creds/client-key.pem" > /dev/null 2>&1; do
  n=$((n + 1))
  [ "$n" -lt 40 ] || fail "the docker api did not answer with a client certificate."
  sleep 3
done
[ "$(docker_ping --cert "$creds/client.pem" --key "$creds/client-key.pem")" = OK ] || fail "_ping did not return OK."
if docker_ping > /dev/null 2>&1; then fail "the docker api answered without a client certificate."; fi
[ "$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$docker_port/_ping")" != 200 ] || fail "the docker api answered over plain http."

echo "== keys: the client key is not in the guest, the server key only lives in tmpfs"
guest "test ! -e /var/lib/padserver/tls" || fail "the old tls directory remains on the disk."
guest mount | grep "^none on /run/padserver/tls type tmpfs" || fail "/run/padserver/tls is not tmpfs."
keys_in_guest=$(guest "grep -rIl 'PRIVATE KEY' /root /var /etc /run 2> /dev/null | sort")
[ "$keys_in_guest" = /run/padserver/tls/server-key.pem ] || fail "private keys found in the guest: $keys_in_guest"
client_key_line=$(sed -n 2p "$creds/client-key.pem")
halt_guest
if grep -qaF "$client_key_line" "$disk"; then fail "the client key was found on the guest disk."; fi

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

echo "== fourth boot: without the credentials disk, the docker api stays closed"
boot fourth none
if guest "ps -o comm | grep -x dockerd" > /dev/null; then fail "dockerd started without credentials."; fi
if docker_ping --cert "$creds/client.pem" --key "$creds/client-key.pem" > /dev/null 2>&1; then fail "the docker api answered without credentials."; fi
grep -q "credentials disk" "$work/fourth.log" || fail "start-dockerd did not report the missing credentials disk."
halt_guest

echo "PASS: $id_first"
