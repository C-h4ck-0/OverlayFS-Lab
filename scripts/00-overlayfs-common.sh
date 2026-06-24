#!/usr/bin/env bash

set -euo pipefail

get_pid() {
  local container="$1"
  docker inspect "$container" --format '{{.State.Pid}}'
}

get_overlay_line() {
  local container="$1"
  local pid
  pid=$(get_pid "$container")

  if [ "$pid" = "0" ] || [ -z "$pid" ]; then
    echo "Container is not running: $container" >&2
    return 1
  fi

  sudo cat "/proc/$pid/mountinfo" | grep ' - overlay overlay '
}

get_lower() {
  get_overlay_line "$1" | sed -n 's/.*lowerdir=\([^,]*\).*/\1/p'
}

get_upper() {
  get_overlay_line "$1" | sed -n 's/.*upperdir=\([^,]*\).*/\1/p'
}

get_work() {
  get_overlay_line "$1" | sed -n 's/.*workdir=\([^,]*\).*/\1/p'
}

print_overlay_paths() {
  local container="$1"
  local pid lower upper work merged

  pid=$(get_pid "$container")
  lower=$(get_lower "$container")
  upper=$(get_upper "$container")
  work=$(get_work "$container")
  merged="/proc/$pid/root"

  echo "CONTAINER=$container"
  echo "PID=$pid"
  echo "MERGED=$merged"
  echo "LOWER=$lower"
  echo "UPPER=$upper"
  echo "WORK=$work"

  IFS=':' read -ra lowerdirs <<< "$lower"
  for i in "${!lowerdirs[@]}"; do
    echo "LOWER[$i]=${lowerdirs[$i]}"
  done
}
