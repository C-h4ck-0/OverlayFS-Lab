#!/usr/bin/env bash
set -euo pipefail

CONTAINER="overlay-lab"
IMAGE="ubuntu:22.04"

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[-] Missing required command: $cmd"
    exit 1
  fi
}

get_overlay_line() {
  local pid="$1"
  sudo cat "/proc/$pid/mountinfo" | grep ' - overlay overlay ' || true
}

extract_mount_opt() {
  local line="$1"
  local key="$2"
  echo "$line" | sed -n "s/.*${key}=\([^,]*\).*/\1/p"
}

container_realpath() {
  local container="$1"
  local path="$2"

  docker exec "$container" bash -c "readlink -f '$path'"
}

upper_path_for_container_path() {
  local upper="$1"
  local container_path="$2"

  # container_path is expected to be absolute, for example /usr/lib/os-release.
  echo "$upper$container_path"
}

print_section() {
  echo
  echo "============================================================"
  echo "$1"
  echo "============================================================"
}

require_cmd docker
require_cmd sudo
require_cmd sed
require_cmd grep

print_section "[*] Recreating $CONTAINER from $IMAGE"

docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -dit --name "$CONTAINER" "$IMAGE" bash >/dev/null

PID=$(docker inspect "$CONTAINER" --format '{{.State.Pid}}')

if [ -z "$PID" ] || [ "$PID" = "0" ]; then
  echo "[-] Container is not running or PID is invalid"
  exit 1
fi

OVERLAY_LINE=$(get_overlay_line "$PID")

if [ -z "$OVERLAY_LINE" ]; then
  echo "[-] Could not find an OverlayFS mount for PID $PID"
  echo
  echo "Debug:"
  sudo cat "/proc/$PID/mountinfo" || true
  exit 1
fi

LOWER=$(extract_mount_opt "$OVERLAY_LINE" "lowerdir")
UPPER=$(extract_mount_opt "$OVERLAY_LINE" "upperdir")
WORK=$(extract_mount_opt "$OVERLAY_LINE" "workdir")
MERGED="/proc/$PID/root"

if [ -z "$LOWER" ] || [ -z "$UPPER" ] || [ -z "$WORK" ]; then
  echo "[-] Failed to extract lowerdir/upperdir/workdir from mountinfo"
  echo "$OVERLAY_LINE"
  exit 1
fi

IFS=':' read -ra LOWERDIRS <<< "$LOWER"

print_section "[*] OverlayFS paths"

echo "CONTAINER=$CONTAINER"
echo "PID=$PID"
echo "MERGED=$MERGED"
echo "LOWER=$LOWER"
echo "UPPER=$UPPER"
echo "WORK=$WORK"

for i in "${!LOWERDIRS[@]}"; do
  echo "LOWER[$i]=${LOWERDIRS[$i]}"
done

print_section "[*] Prove merged is the container root"

docker exec "$CONTAINER" bash -c 'echo "hello from container rootfs" > /root/created.txt'

echo "Container reads:"
docker exec "$CONTAINER" cat /root/created.txt

echo
echo "Host reads through merged:"
sudo cat "$MERGED/root/created.txt"

echo
echo "Host reads through upperdir:"
sudo cat "$UPPER/root/created.txt"

print_section "[*] Find a lower-layer file and handle symlinks correctly"

OS_RELEASE_CONTAINER_PATH="/etc/os-release"
OS_RELEASE_REAL_PATH=$(container_realpath "$CONTAINER" "$OS_RELEASE_CONTAINER_PATH")
OS_RELEASE_UPPER_PATH=$(upper_path_for_container_path "$UPPER" "$OS_RELEASE_REAL_PATH")

echo "$OS_RELEASE_CONTAINER_PATH resolves inside the container to:"
echo "  $OS_RELEASE_REAL_PATH"
echo
echo "So the expected copied-up upperdir path is:"
echo "  $OS_RELEASE_UPPER_PATH"

echo
echo "Searching lowerdirs for both the symlink path and resolved path:"
for d in "${LOWERDIRS[@]}"; do
  for p in "$OS_RELEASE_CONTAINER_PATH" "$OS_RELEASE_REAL_PATH"; do
    if sudo test -e "$d$p" || sudo test -L "$d$p"; then
      echo "FOUND: $d$p"
      sudo ls -l "$d$p"
      if sudo test -f "$d$p"; then
        sudo head -5 "$d$p"
      fi
      echo
    fi
  done
done

if sudo test -e "$OS_RELEASE_UPPER_PATH"; then
  echo "[!] $OS_RELEASE_REAL_PATH already exists in upperdir before modification:"
  sudo ls -l "$OS_RELEASE_UPPER_PATH"
else
  echo "[+] $OS_RELEASE_REAL_PATH is not yet in upperdir"
fi

print_section "[*] Modify /etc/os-release to trigger copy-up"

docker exec "$CONTAINER" bash -c 'echo "# changed by overlayfs lab" >> /etc/os-release'

echo "Container now sees the change:"
docker exec "$CONTAINER" bash -c 'tail -5 /etc/os-release'

echo
echo "Checking the resolved copied-up file in upperdir:"
if sudo test -e "$OS_RELEASE_UPPER_PATH"; then
  sudo ls -l "$OS_RELEASE_UPPER_PATH"
  sudo tail -5 "$OS_RELEASE_UPPER_PATH"
else
  echo "[-] Expected copied-up file was not found:"
  echo "    $OS_RELEASE_UPPER_PATH"
  echo
  echo "Debug: nearby upperdir files:"
  sudo find "$UPPER" -xdev -path '*/os-release' -ls 2>/dev/null || true
  exit 1
fi

echo
echo "Checking lowerdirs remain unchanged:"
for d in "${LOWERDIRS[@]}"; do
  if sudo test -f "$d$OS_RELEASE_REAL_PATH"; then
    echo "=== $d$OS_RELEASE_REAL_PATH ==="
    sudo tail -5 "$d$OS_RELEASE_REAL_PATH"
    echo
  fi
done

print_section "[*] Create, modify, delete: observe upperdir delta"

docker exec "$CONTAINER" bash -c '
echo "brand new file" > /tmp/new-file.txt
echo "modified passwd" >> /etc/passwd
rm -f /usr/bin/yes
'

echo "Created file in upperdir:"
sudo cat "$UPPER/tmp/new-file.txt"

echo
echo "Modified /etc/passwd copied up into upperdir:"
if sudo test -e "$UPPER/etc/passwd"; then
  sudo tail -3 "$UPPER/etc/passwd"
else
  echo "[-] Expected $UPPER/etc/passwd to exist, but it does not"
fi

echo
echo "Deleted /usr/bin/yes from merged/container view:"
sudo ls -l "$MERGED/usr/bin/yes" 2>/dev/null || echo "/usr/bin/yes is hidden from merged"

echo
echo "But lowerdirs may still contain /usr/bin/yes:"
for d in "${LOWERDIRS[@]}"; do
  sudo find "$d" -path '*/usr/bin/yes' -ls 2>/dev/null || true
done

echo
echo "Upperdir evidence for delete/whiteout behavior:"
sudo find "$UPPER/usr/bin" -maxdepth 1 -name '*yes*' -ls 2>/dev/null || true
sudo ls -la "$UPPER/usr/bin" 2>/dev/null | grep yes || true

print_section "[*] Forensic view: what did this container actually change?"

sudo find "$UPPER" -xdev -printf '%p\n' | sed "s|$UPPER||" | sort | head -200

print_section "[*] Final mental model"

cat <<EOF
merged:
  $MERGED
  The unified filesystem view. This is what the container sees as /.

upperdir:
  $UPPER
  The writable layer. New files and copied-up modified files land here.

lowerdir:
  $LOWER
  One or more read-only layers. In containerd-backed Docker, this often includes:
    lower[0] = per-container init layer
    lower[1] = shared image/base layer

workdir:
  $WORK
  OverlayFS internal workspace.

Key lesson:
  Creating a new file writes to upperdir.
  Modifying a lowerdir file copies it up into upperdir.
  Deleting a lowerdir file records deletion/whiteout behavior in upperdir.
  Symlinks matter: modifying /etc/os-release may copy up /usr/lib/os-release.
EOF

echo
echo "Cleanup:"
echo "  docker rm -f $CONTAINER"
