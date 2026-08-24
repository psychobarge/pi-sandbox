#!/usr/bin/env bash
# Rebuilds the pi-sandbox image when a newer pi release exists.
# Runs on the host (the container is ephemeral: docker run --rm).
#   --status : fast check, prints "up-to-date" or "stale:<latest>"
#   (default): rebuild in background if stale (called nohup'd by pi.sh)
set -euo pipefail

LATEST_URL="https://pi.dev/api/latest-version"

# Resolve script dir, symlink-aware (same block as pi.sh)
SCRIPT="${BASH_SOURCE[0]:-$0}"
while [ -L "$SCRIPT" ]; do
  TARGET="$(readlink "$SCRIPT")"
  case "$TARGET" in
    /*) SCRIPT="$TARGET" ;;
    *) SCRIPT="$(dirname "$SCRIPT")/$TARGET" ;;
  esac
done
cd "$(dirname "$SCRIPT")"
DIR="$(pwd)"

latest_version() {
  curl -fsS --max-time 5 "$LATEST_URL" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p'
}

# Version actually baked into the image (not the pin) — source of truth.
image_version() {
  docker run --rm pi-sandbox --version 2>/dev/null || true
}

docker_ok() {
  docker version --format '{{.Server.Version}}' >/dev/null 2>&1
}

status() {
  docker_ok || { echo "up-to-date"; exit 0; }   # can't check → never block launch
  local latest installed
  latest="$(latest_version || true)"
  installed="$(image_version)"
  if [ -z "$latest" ] || [ "$latest" = "$installed" ]; then
    echo "up-to-date"
  else
    echo "stale:$latest"
  fi
}

rebuild() {
  LOG="$DIR/logs/update-$(date +%F).log"
  mkdir -p "$DIR/logs"
  find "$DIR/logs" -name '*.log' -mtime +30 -delete
  docker_ok || { echo "[$(date '+%F %T')] docker down, skip" >> "$LOG"; exit 0; }
  local latest installed
  latest="$(latest_version || true)"
  installed="$(image_version)"
  [ -z "$latest" ] && exit 0
  if [ "$latest" = "$installed" ]; then
    exit 0
  fi

  # lock: one rebuild at a time (macOS has no flock by default)
  mkdir /tmp/pi-sandbox-update.lock 2>/dev/null || exit 0
  trap 'rmdir /tmp/pi-sandbox-update.lock 2>/dev/null || true' EXIT

  # Bump the pin (busts the docker/npm layer cache) then rebuild.
  # On build failure the pin stays bumped, but next launch compares against
  # the image's real version → still stale → retry. Self-healing.
  sed -i '' "s|@earendil-works/pi-coding-agent@[0-9][0-9.]*|@earendil-works/pi-coding-agent@$latest|; s|@earendil-works/pi-coding-agent$|@earendil-works/pi-coding-agent@$latest|" Dockerfile.pi
  if docker build -t pi-sandbox -f Dockerfile.pi . >> "$LOG" 2>&1; then
    echo "[$(date '+%F %T')] rebuilt pi-sandbox → $latest" >> "$LOG"
    if [ "$(uname -s)" = "Darwin" ]; then
      osascript -e "display notification \"pi-sandbox mis à jour vers v$latest — redémarre pi pour l'utiliser\" with title \"pi update\"" 2>/dev/null || true
    fi
  else
    echo "[$(date '+%F %T')] build FAILED (image=$installed, target=$latest) — retry next launch" >> "$LOG"
  fi
}

case "${1:-}" in
  --status) status ;;
  *) rebuild ;;
esac
