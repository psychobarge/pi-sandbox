#!/usr/bin/env bash
# Rebuilds the pi-sandbox image when a newer pi or rtk release exists.
# Runs on the host (the container is ephemeral: docker run --rm).
#   --status : fast check, prints "up-to-date" or "stale:<what>"
#   (default): rebuild in background if stale (called nohup'd by pi.sh)
set -euo pipefail

PI_LATEST_URL="https://pi.dev/api/latest-version"
RTK_LATEST_URL="https://api.github.com/repos/rtk-ai/rtk/releases/latest"

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

pi_latest_version() {
  curl -fsS --max-time 5 "$PI_LATEST_URL" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p'
}

# Latest stable rtk tag without the leading "v". /releases/latest skips
# pre-releases. Empty on any failure (offline, GitHub rate limit) → the callers
# treat that as "up-to-date" and never block a launch.
# (GitHub's JSON is pretty-printed, hence the [:space:]* after the colon.)
rtk_latest_version() {
  curl -fsS --max-time 5 "$RTK_LATEST_URL" | sed -n 's/.*"tag_name":[[:space:]]*"v\?\([^"]*\)".*/\1/p'
}

# Versions actually baked into the image (not the pins) — source of truth.
image_pi_version() {
  docker run --rm pi-sandbox --version 2>/dev/null || true
}

image_rtk_version() {
  docker run --rm --entrypoint rtk pi-sandbox --version 2>/dev/null | awk '{print $NF}' || true
}

docker_ok() {
  docker version --format '{{.Server.Version}}' >/dev/null 2>&1
}

# "pi v1.2.3 + rtk v1.0.0" for whatever is stale, or empty when all is current.
stale_label() {
  local label="" lp lr ip ir
  lp="$(pi_latest_version || true)"; ip="$(image_pi_version)"
  lr="$(rtk_latest_version || true)"; ir="$(image_rtk_version)"
  if [ -n "$lp" ] && [ "$lp" != "$ip" ]; then label="pi v$lp"; fi
  if [ -n "$lr" ] && [ "$lr" != "$ir" ]; then label="${label:+$label + }rtk v$lr"; fi
  printf '%s' "$label"
}

status() {
  docker_ok || { echo "up-to-date"; exit 0; }   # can't check → never block launch
  local label
  label="$(stale_label)"
  if [ -n "$label" ]; then echo "stale:$label"; else echo "up-to-date"; fi
}

rebuild() {
  LOG="$DIR/logs/update-$(date +%F).log"
  mkdir -p "$DIR/logs"
  find "$DIR/logs" -name '*.log' -mtime +30 -delete
  docker_ok || { echo "[$(date '+%F %T')] docker down, skip" >> "$LOG"; exit 0; }

  local lp lr ip ir changed="" rtk_changed=""
  lp="$(pi_latest_version || true)"; ip="$(image_pi_version)"
  lr="$(rtk_latest_version || true)"; ir="$(image_rtk_version)"

  # lock: one rebuild at a time (macOS has no flock by default)
  mkdir /tmp/pi-sandbox-update.lock 2>/dev/null || exit 0
  trap 'rmdir /tmp/pi-sandbox-update.lock 2>/dev/null || true' EXIT

  # Bump the pins (busts the docker/npm layer cache) then rebuild.
  # On build failure a pin stays bumped, but next launch compares against the
  # image's real version → still stale → retry. Self-healing.
  if [ -n "$lp" ] && [ "$lp" != "$ip" ]; then
    sed -i '' "s|@earendil-works/pi-coding-agent@[0-9][0-9.]*|@earendil-works/pi-coding-agent@$lp|; s|@earendil-works/pi-coding-agent$|@earendil-works/pi-coding-agent@$lp|" Dockerfile.pi
    changed="pi v$lp"
  fi
  if [ -n "$lr" ] && [ "$lr" != "$ir" ]; then
    sed -i '' "s|^ARG RTK_VERSION=v.*|ARG RTK_VERSION=v$lr|" Dockerfile.pi
    changed="${changed:+$changed + }rtk v$lr"
    rtk_changed=1
  fi
  if [ -z "$changed" ]; then exit 0; fi

  if docker build -t pi-sandbox -f Dockerfile.pi . >> "$LOG" 2>&1; then
    echo "[$(date '+%F %T')] rebuilt pi-sandbox → $changed" >> "$LOG"
    # The pi hook is an rtk-generated template (it changes between releases):
    # refresh it so it matches the new binary. --auto-patch: this run has no TTY.
    if [ -n "$rtk_changed" ]; then
      docker run --rm -e RTK_TELEMETRY_DISABLED=1 -v pi-agent-home:/root/.pi/agent \
        --entrypoint bash pi-sandbox -c 'rtk init -g --agent pi --auto-patch' >> "$LOG" 2>&1 \
        || echo "[$(date '+%F %T')] rtk hook refresh failed" >> "$LOG"
    fi
    if [ "$(uname -s)" = "Darwin" ]; then
      osascript -e "display notification \"pi-sandbox mis à jour ($changed) — redémarre pi pour l'utiliser\" with title \"pi-sandbox update\"" 2>/dev/null || true
    fi
  else
    echo "[$(date '+%F %T')] build FAILED (pi=$ip→$lp, rtk=$ir→$lr) — retry next launch" >> "$LOG"
  fi
}

case "${1:-}" in
  --status) status ;;
  *) rebuild ;;
esac
