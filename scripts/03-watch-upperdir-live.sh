#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/00-overlayfs-common.sh"

CONTAINER="${1:-overlay-lab}"

if ! command -v inotifywait >/dev/null 2>&1; then
  echo "inotifywait not found. Install with: sudo apt install -y inotify-tools" >&2
  exit 1
fi

UPPER=$(get_upper "$CONTAINER")

echo "Watching upperdir for $CONTAINER:"
echo "$UPPER"
echo
echo "In another terminal, try:"
echo "  docker exec $CONTAINER bash -c 'echo live > /tmp/live.txt; echo x >> /etc/group; rm -f /usr/bin/whoami'"
echo

sudo inotifywait -m -r "$UPPER"
