#!/usr/bin/env bash
# Launches pi in an isolated container.
#   - run from inside an allowed folder (pi.conf) → confined to that folder only
#   - run from anywhere else → asks to whitelist the folder, else mounts all allowed
set -euo pipefail

LAUNCH_DIR="$(pwd)"

# Resolve script dir, symlink-aware (pi in /usr/local/bin is a symlink)
SCRIPT="${BASH_SOURCE[0]:-$0}"
while [ -L "$SCRIPT" ]; do
  TARGET="$(readlink "$SCRIPT")"
  case "$TARGET" in
    /*) SCRIPT="$TARGET" ;;
    *) SCRIPT="$(dirname "$SCRIPT")/$TARGET" ;;
  esac
done
cd "$(dirname "$SCRIPT")"
SCRIPT="$(pwd)/$(basename "$SCRIPT")"

# ====== Usage log (host errors only) ======
mkdir -p logs
find logs -name '*.log' -mtime +30 -delete
log_error() {
  echo "[$(date '+%F %T')] $*" >> "logs/usage-$(date +%F).log"
}

# pi.conf is gitignored (it holds your personal paths); auto-create it from the
# example on first run so `source` below never fails on a fresh clone.
[ -f ./pi.conf ] || { cp ./pi.conf.example ./pi.conf; echo "✓ pi.conf created from pi.conf.example — edit it to set your folders"; }
source ./pi.conf

# Are we inside an allowed folder? If so, confine to it.
START_DIR=""
START_REL=""
for dir in ${ALLOWED[@]+"${ALLOWED[@]}"}; do
  dir="${dir%/}"   # a trailing slash would make the pattern `…/proj//*` never match
  case "$LAUNCH_DIR" in
    "$dir"|"$dir"/*)
      START_DIR="$dir"
      START_REL="${LAUNCH_DIR#$dir/}"
      [ "$START_REL" = "$LAUNCH_DIR" ] && START_REL=""
      break
      ;;
  esac
done

# API keys / env vars to forward. Source of truth: the macOS Keychain
# (service "pi-sandbox", account = variable name). A variable already set in the
# shell wins, so you can still override one key for a single launch.
KEYCHAIN_SERVICE="pi-sandbox"
ENV_ARGS=()
for k in ${API_KEYS[@]+"${API_KEYS[@]}"}; do
  v="${!k:-}"
  if [ -z "$v" ] && command -v security >/dev/null 2>&1; then
    v="$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$k" -w 2>/dev/null)" || v=""
  fi
  # export + -e NAME (not NAME=value) keeps the secret out of docker's argv / `ps`
  [ -n "$v" ] && export "$k=$v" && ENV_ARGS+=(-e "$k")
done

# Models live in ~/.pi/agent/models.json (user-level, pi reads nothing else),
# so the repo's config/models.json is bind-mounted over the volume at launch:
# edit it and relaunch — no reinstall, no drift between repo and volume.
MODELS_ARGS=()
MODELS_FILE="$(dirname "$SCRIPT")/config/models.json"
[ -f "$MODELS_FILE" ] && MODELS_ARGS=(-v "$MODELS_FILE:/root/.pi/agent/models.json")

if [ -n "$START_DIR" ]; then
  echo "→ Confined to: $START_DIR"
  # Mount at the folder's real host path so pi's footer shows the actual
  # location (e.g. ~/My_workspace/My_projects/pi-sandbox (main)), not a generic /workspace.
  ARGS=(-v "$START_DIR:$START_DIR")
  [ -n "$START_REL" ] && WORKDIR_ARGS=(-w "$START_DIR/$START_REL") \
                     || WORKDIR_ARGS=(-w "$START_DIR")
else
  echo "⚠ $LAUNCH_DIR is not in ALLOWED (pi.conf)"
  printf "Add this folder to ALLOWED and launch confined to it? [y/N] "
  read -r answer || true
  case "$answer" in
    y|Y|yes|YES)
      # Shared paren-aware parser: a one-line list has no line starting with
      # ")", which the old `^\)` match missed (folder looked added but wasn't).
      awk -v array=ALLOWED -v entry="\"$LAUNCH_DIR\"" \
        -f append-array-entry.awk pi.conf > pi.conf.tmp && mv pi.conf.tmp pi.conf
      echo "✓ Added to ALLOWED (pi.conf), relaunching…"
      cd "$LAUNCH_DIR"
      exec "$SCRIPT"
      ;;
  esac
  echo "→ Mounting all allowed folders (add the folder to ALLOWED in pi.conf to confine)"
  ARGS=(); USED_NAMES=()
  for dir in ${ALLOWED[@]+"${ALLOWED[@]}"}; do
    [ -d "$dir" ] || { log_error "folder not found: $dir"; echo "⚠ folder not found: $dir"; continue; }
    # two allowed folders can share a basename: Docker would silently keep only
    # one mount, so later ones get a suffix (api, api-2) and both stay visible
    name="$(basename "$dir")"; n=1
    while printf '%s\n' ${USED_NAMES[@]+"${USED_NAMES[@]}"} | grep -qxF "$name"; do
      n=$((n + 1)); name="$(basename "$dir")-$n"
    done
    USED_NAMES+=("$name")
    ARGS+=(-v "$dir:${WORKSPACE}/$name")
  done
  WORKDIR_ARGS=(-w "$WORKSPACE")
fi

# Make sure Docker is up (start OrbStack if needed)
if ! docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
  echo "→ Docker is not responding, starting OrbStack / Docker Desktop…"
  open -a OrbStack 2>/dev/null || open -a "Docker Desktop" 2>/dev/null || true
  for _ in {1..10}; do
    sleep 2
    docker version --format '{{.Server.Version}}' >/dev/null 2>&1 && break
  done
fi
docker version --format '{{.Server.Version}}' >/dev/null 2>&1 \
  || { log_error "Docker is not responding"; echo "❌ Docker is not responding. Open OrbStack then retry."; exit 1; }

# Auto-update: rebuild the image in background if a newer pi or rtk release exists.
# The container is ephemeral (docker run --rm), so the update must happen here.
UPDATER="$(dirname "$SCRIPT")/update-pi-sandbox.sh"
if docker image inspect "${IMAGE}" >/dev/null 2>&1; then
  STATUS="$("$UPDATER" --status 2>/dev/null)" || STATUS="up-to-date"
  case "$STATUS" in
    stale:*)
      echo "→ Update available (${STATUS#stale:}) — fetching in the background, restart pi to use it."
      nohup "$UPDATER" >> "logs/update-$(date +%F).log" 2>&1 &
      ;;
  esac
else
  echo "→ Image ${IMAGE} absente, construction…"
  "$UPDATER" || true
fi

code=0
# Tool caches stay in the volume: the container is ephemeral, so without this
# anything cached would be re-downloaded on every launch.
docker run --rm -it \
  ${ENV_ARGS[@]+"${ENV_ARGS[@]}"} \
  -v "${VOLUME}:/root/.pi/agent" \
  -e XDG_CACHE_HOME=/root/.pi/agent/cache \
  ${MODELS_ARGS[@]+"${MODELS_ARGS[@]}"} \
  -v "${RTK_VOLUME}:/root/.local/share/rtk" \
  ${ARGS[@]+"${ARGS[@]}"} \
  "${WORKDIR_ARGS[@]}" \
  ${DOCKER_ARGS[@]+"${DOCKER_ARGS[@]}"} \
  "${IMAGE}" || code=$?
[ "$code" -ne 0 ] && log_error "pi session exited with error (code $code)" || true
exit "$code"
