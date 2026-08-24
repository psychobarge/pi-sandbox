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

# ====== Usage log (erreurs hôte uniquement) ======
mkdir -p logs
find logs -name '*.log' -mtime +30 -delete
log_error() {
  echo "[$(date '+%F %T')] $*" >> "logs/usage-$(date +%F).log"
}

source ./pi.conf

# Are we inside an allowed folder? If so, confine to it.
START_DIR=""
START_REL=""
for dir in "${ALLOWED[@]}"; do
  case "$LAUNCH_DIR" in
    "$dir"|"$dir"/*)
      START_DIR="$dir"
      START_REL="${LAUNCH_DIR#$dir/}"
      [ "$START_REL" = "$LAUNCH_DIR" ] && START_REL=""
      break
      ;;
  esac
done

# API keys / env vars to forward (only those defined in your shell)
ENV_ARGS=()
for k in "${API_KEYS[@]}"; do
  [ -n "${!k:-}" ] && ENV_ARGS+=(-e "$k")
done

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
      awk -v dir="$LAUNCH_DIR" '
        /^ALLOWED=\(/ { in_block=1 }
        in_block && /^\)/ { printf "  \"%s\"\n", dir; in_block=0 }
        { print }
      ' pi.conf > pi.conf.tmp && mv pi.conf.tmp pi.conf
      echo "✓ Added to ALLOWED (pi.conf), relaunching…"
      cd "$LAUNCH_DIR"
      exec "$SCRIPT"
      ;;
  esac
  echo "→ Mounting all allowed folders (add the folder to ALLOWED in pi.conf to confine)"
  ARGS=()
  for dir in "${ALLOWED[@]}"; do
    [ -d "$dir" ] || { log_error "folder not found: $dir"; echo "⚠ folder not found: $dir"; exit 1; }
    ARGS+=(-v "$dir:${WORKSPACE}/$(basename "$dir")")
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

# Auto-update: rebuild the image in background if a newer pi release exists.
# The container is ephemeral (docker run --rm), so the update must happen here.
UPDATER="$(dirname "$SCRIPT")/update-pi-sandbox.sh"
if docker image inspect "${IMAGE}" >/dev/null 2>&1; then
  STATUS="$("$UPDATER" --status 2>/dev/null)" || STATUS="up-to-date"
  case "$STATUS" in
    stale:*)
      LATEST="${STATUS#stale:}"
      echo "→ Nouvelle version de pi (v${LATEST}) disponible — mise à jour en arrière-plan, redémarre pi pour l'utiliser."
      nohup "$UPDATER" >> "logs/update-$(date +%F).log" 2>&1 &
      ;;
  esac
else
  echo "→ Image ${IMAGE} absente, construction…"
  "$UPDATER" || true
fi

code=0
docker run --rm -it \
  ${ENV_ARGS[@]+"${ENV_ARGS[@]}"} \
  -v "${VOLUME}:/root/.pi/agent" \
  -v "${RTK_VOLUME}:/root/.local/share/rtk" \
  "${ARGS[@]}" \
  "${WORKDIR_ARGS[@]}" \
  ${DOCKER_ARGS[@]+"${DOCKER_ARGS[@]}"} \
  "${IMAGE}" || code=$?
[ "$code" -ne 0 ] && log_error "session pi terminée en erreur (code $code)" || true
exit "$code"
