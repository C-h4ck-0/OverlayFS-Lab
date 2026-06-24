#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/00-overlayfs-common.sh"

IMAGE="ubuntu:22.04"
A="overlay-a"
B="overlay-b"

echo "[*] Recreating containers from $IMAGE"
docker rm -f "$A" "$B" >/dev/null 2>&1 || true
docker run -dit --name "$A" "$IMAGE" bash >/dev/null
docker run -dit --name "$B" "$IMAGE" bash >/dev/null

PID_A=$(get_pid "$A")
PID_B=$(get_pid "$B")

LOWER_A=$(get_lower "$A")
LOWER_B=$(get_lower "$B")
UPPER_A=$(get_upper "$A")
UPPER_B=$(get_upper "$B")
WORK_A=$(get_work "$A")
WORK_B=$(get_work "$B")
MERGED_A="/proc/$PID_A/root"
MERGED_B="/proc/$PID_B/root"

IFS=':' read -ra A_LOWERDIRS <<< "$LOWER_A"
IFS=':' read -ra B_LOWERDIRS <<< "$LOWER_B"

echo
echo "=============================="
echo "Container A"
echo "=============================="
echo "name:   $A"
echo "pid:    $PID_A"
echo "merged: $MERGED_A"
echo "upper:  $UPPER_A"
echo "work:   $WORK_A"
for i in "${!A_LOWERDIRS[@]}"; do
  echo "lower[$i]: ${A_LOWERDIRS[$i]}"
done

echo
echo "=============================="
echo "Container B"
echo "=============================="
echo "name:   $B"
echo "pid:    $PID_B"
echo "merged: $MERGED_B"
echo "upper:  $UPPER_B"
echo "work:   $WORK_B"
for i in "${!B_LOWERDIRS[@]}"; do
  echo "lower[$i]: ${B_LOWERDIRS[$i]}"
done

echo
echo "=============================="
echo "Compare lower stacks"
echo "=============================="

if [ "$LOWER_A" = "$LOWER_B" ]; then
  echo "[+] Full lowerdir stack is identical"
else
  echo "[*] Full lowerdir stack is different"
fi

printf '%s\n' "${A_LOWERDIRS[@]}" | sort > /tmp/overlay-a-lowers.txt
printf '%s\n' "${B_LOWERDIRS[@]}" | sort > /tmp/overlay-b-lowers.txt

echo
echo "Shared lowerdirs:"
comm -12 /tmp/overlay-a-lowers.txt /tmp/overlay-b-lowers.txt || true

echo
echo "Unique to A:"
comm -23 /tmp/overlay-a-lowers.txt /tmp/overlay-b-lowers.txt || true

echo
echo "Unique to B:"
comm -13 /tmp/overlay-a-lowers.txt /tmp/overlay-b-lowers.txt || true

echo
echo "=============================="
echo "Compare upperdirs"
echo "=============================="

if [ "$UPPER_A" != "$UPPER_B" ]; then
  echo "[+] Different upperdirs, as expected"
else
  echo "[-] Same upperdir, unexpected"
fi

echo
echo "=============================="
echo "Inspect likely init layers"
echo "=============================="

A_INIT="${A_LOWERDIRS[0]}"
B_INIT="${B_LOWERDIRS[0]}"

echo "A likely init layer: $A_INIT"
echo "B likely init layer: $B_INIT"

for f in /etc/hostname /etc/hosts /etc/resolv.conf; do
  echo
  echo "----- $f -----"

  echo "[A init layer]"
  sudo cat "$A_INIT$f" 2>/dev/null || echo "not found"

  echo
  echo "[B init layer]"
  sudo cat "$B_INIT$f" 2>/dev/null || echo "not found"
done

echo
echo "=============================="
echo "Write isolation test"
echo "=============================="

docker exec "$A" bash -c 'echo "created only in overlay-a" > /root/only-a.txt'

echo "[A reads]"
docker exec "$A" cat /root/only-a.txt

echo "[B reads]"
docker exec "$B" bash -c 'cat /root/only-a.txt 2>/dev/null || echo "not visible in overlay-b"'

echo
echo "Upperdir evidence:"
echo "[A upperdir]"
sudo find "$UPPER_A" -path '*/root/only-a.txt' -ls 2>/dev/null || true

echo "[B upperdir]"
sudo find "$UPPER_B" -path '*/root/only-a.txt' -ls 2>/dev/null || true

echo
echo "=============================="
echo "Copy-up isolation test"
echo "=============================="

docker exec "$A" bash -c 'echo "# changed only in overlay-a" >> /etc/os-release'

echo "[A /etc/os-release tail]"
docker exec "$A" tail -3 /etc/os-release

echo
echo "[B /etc/os-release tail]"
docker exec "$B" tail -3 /etc/os-release

echo
echo "Copy-up evidence:"
sudo test -e "$UPPER_A/etc/os-release" && echo "[+] A copied up /etc/os-release"
sudo test -e "$UPPER_B/etc/os-release" && echo "[!] B copied up /etc/os-release" || echo "[+] B did not copy it up"

echo
echo "=============================="
echo "Final conclusion"
echo "=============================="
echo "Both containers came from: $IMAGE"
echo "They share at least one image/base lowerdir when the image layer is reused."
echo "They may have unique init lower layers."
echo "They have unique writable upperdirs."
echo
echo "Cleanup: docker rm -f $A $B"
