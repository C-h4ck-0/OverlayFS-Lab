#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/00-overlayfs-common.sh"

CONTAINER="overlay-lab"
IMAGE="ubuntu:22.04"

echo "[*] Recreating $CONTAINER from $IMAGE"
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -dit --name "$CONTAINER" "$IMAGE" bash >/dev/null

PID=$(get_pid "$CONTAINER")
LOWER=$(get_lower "$CONTAINER")
UPPER=$(get_upper "$CONTAINER")
WORK=$(get_work "$CONTAINER")
MERGED="/proc/$PID/root"
IFS=':' read -ra LOWERDIRS <<< "$LOWER"

echo
echo "[*] OverlayFS paths"
print_overlay_paths "$CONTAINER"

echo
echo "[*] Prove merged is the container root"
docker exec "$CONTAINER" bash -c 'echo "hello from container rootfs" > /root/created.txt'
echo "Container reads:"
docker exec "$CONTAINER" cat /root/created.txt
echo "Host reads through merged:"
sudo cat "$MERGED/root/created.txt"
echo "Host reads through upperdir:"
sudo cat "$UPPER/root/created.txt"

echo
echo "[*] Find /etc/os-release in lowerdirs before modification"
for d in "${LOWERDIRS[@]}"; do
  if sudo test -e "$d/etc/os-release"; then
    echo "FOUND in: $d"
    sudo head -5 "$d/etc/os-release"
    echo
  fi
done

if sudo test -e "$UPPER/etc/os-release"; then
  echo "[!] /etc/os-release already exists in upperdir"
else
  echo "[+] /etc/os-release is not yet in upperdir"
fi

echo
echo "[*] Modify /etc/os-release to trigger copy-up"
docker exec "$CONTAINER" bash -c 'echo "# changed by overlayfs lab" >> /etc/os-release'

echo "Upperdir version now contains:"
sudo tail -5 "$UPPER/etc/os-release"

echo
echo "Lowerdirs should remain unchanged:"
for d in "${LOWERDIRS[@]}"; do
  if sudo test -e "$d/etc/os-release"; then
    echo "=== $d/etc/os-release ==="
    sudo tail -5 "$d/etc/os-release"
    echo
  fi
done

echo
echo "[*] Delete a lower-layer file and observe whiteout behavior"
docker exec "$CONTAINER" bash -c 'rm -f /usr/bin/yes'

echo "Container merged view:"
docker exec "$CONTAINER" bash -c 'ls -l /usr/bin/yes 2>/dev/null || echo "hidden from container"'

echo
echo "Lowerdirs may still contain /usr/bin/yes:"
for d in "${LOWERDIRS[@]}"; do
  sudo find "$d" -path '*/usr/bin/yes' -ls 2>/dev/null || true
done

echo
echo "Upperdir changed files so far:"
sudo find "$UPPER" -xdev -printf '%p\n' | sed "s|$UPPER||" | sort

echo
echo "[*] Done. Cleanup with: docker rm -f $CONTAINER"
