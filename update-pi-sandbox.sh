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
LOCK="${PI_UPDATE_LOCK:-/tmp/pi-sandbox-update.lock}"

pi_latest_version() {
  curl -fsS --max-time 5 "$PI_LATEST_URL" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p'
}

# Latest stable rtk tag without the leading "v". /releases/latest skips
# pre-releases. Empty on any failure (offline, GitHub rate limit) → the callers
# treat that as "up-to-date" and never block a launch.
# (GitHub's JSON is pretty-printed, hence the [:space:]* after the colon.)
# NOTE: \{0,1\}, not \? — macOS ships BSD sed, where \? is a literal '?'.
rtk_latest_version() {
  curl -fsS --max-time 5 "$RTK_LATEST_URL" | sed -n 's/.*"tag_name":[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p'
}

# Versions actually baked into the image (not the pins) — source of truth.
# Both probes in one container start: each `docker run` costs ~0.3-1 s.
image_versions() {
  docker run --rm --entrypoint bash pi-sandbox -c 'pi --version; rtk --version' 2>/dev/null || true
}

# pi prints a bare "1.2.0" (line 1); rtk prints "rtk x.y.z" (line 2).
image_pi_version()  { printf '%s\n' "$1" | sed -n '1p'; }
image_rtk_version() { printf '%s\n' "$1" | sed -n '2p' | awk '{print $NF}'; }

docker_ok() {
  docker version --format '{{.Server.Version}}' >/dev/null 2>&1
}

# A lock is live only if its PID is still running and really is the updater.
# An EXIT trap does not run on SIGKILL or reboot, so a leftover lock is
# reclaimed instead of disabling auto-update forever.
lock_is_live() {
  local pid
  [ -f "$LOCK/pid" ] || return 1
  pid="$(cat "$LOCK/pid" 2>/dev/null)" || return 1
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  ps -p "$pid" -o command= 2>/dev/null | grep -q 'update-pi-sandbox' || return 1
}

# "pi v1.2.3 + rtk v1.0.0" for whatever is stale, or empty when all is current.
stale_label() {
  local label="" lp lr ip ir versions
  lp="$(pi_latest_version || true)"; lr="$(rtk_latest_version || true)"
  versions="$(image_versions)"
  ip="$(image_pi_version "$versions")"; ir="$(image_rtk_version "$versions")"
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

  local lp lr ip ir changed="" rtk_changed="" old_image="" versions
  lp="$(pi_latest_version || true)"; lr="$(rtk_latest_version || true)"
  versions="$(image_versions)"
  ip="$(image_pi_version "$versions")"; ir="$(image_rtk_version "$versions")"

  # lock: one rebuild at a time (macOS has no flock by default)
  if lock_is_live; then
    echo "[$(date '+%F %T')] rebuild already running (pid $(cat "$LOCK/pid")), skip" >> "$LOG"
    exit 0
  fi
  if [ -d "$LOCK" ]; then
    rm -f "$LOCK/pid"
    rmdir "$LOCK" 2>/dev/null || true
    echo "[$(date '+%F %T')] removed stale update lock" >> "$LOG"
  fi
  mkdir "$LOCK" 2>/dev/null || { echo "[$(date '+%F %T')] lock $LOCK not acquired, skip" >> "$LOG"; exit 0; }
  echo $$ > "$LOCK/pid"
  trap 'rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null || true' EXIT

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

  # The build retags pi-sandbox, leaving the previous image untagged for good.
  # Remember its exact ID (never a global prune: other projects' images and
  # containers must not be touched) and drop it once the new build exists.
  old_image="$(docker image inspect --format '{{.Id}}' pi-sandbox 2>/dev/null || true)"

  if docker build -t pi-sandbox -f Dockerfile.pi . >> "$LOG" 2>&1; then
    echo "[$(date '+%F %T')] rebuilt pi-sandbox → $changed" >> "$LOG"
    if [ -n "$old_image" ] && [ "$old_image" != "$(docker image inspect --format '{{.Id}}' pi-sandbox 2>/dev/null || true)" ]; then
      # Fails, harmlessly, while a session still runs on it → removed next rebuild.
      if docker image rm "$old_image" >> "$LOG" 2>&1; then
        echo "[$(date '+%F %T')] removed previous image ${old_image#sha256:}" >> "$LOG"
      else
        echo "[$(date '+%F %T')] previous image in use, kept ${old_image#sha256:}" >> "$LOG"
      fi
    fi
    # The pi hook is an rtk-generated template (it changes between releases):
    # refresh it so it matches the new binary. --auto-patch: this run has no TTY.
    if [ -n "$rtk_changed" ]; then
      docker run --rm -e RTK_TELEMETRY_DISABLED=1 -v pi-agent-home:/root/.pi/agent \
        --entrypoint bash pi-sandbox -c 'rtk init -g --agent pi --auto-patch' >> "$LOG" 2>&1 \
        || echo "[$(date '+%F %T')] rtk hook refresh failed" >> "$LOG"
    fi
    if [ "$(uname -s)" = "Darwin" ]; then
      osascript -e "display notification \"pi-sandbox updated ($changed) — restart pi to use it\" with title \"pi-sandbox update\"" 2>/dev/null || true
    fi
  else
    echo "[$(date '+%F %T')] build FAILED (pi=$ip→$lp, rtk=$ir→$lr) — retry next launch" >> "$LOG"
  fi
}

case "${1:-}" in
  --status) status ;;
  *) rebuild ;;
esac
