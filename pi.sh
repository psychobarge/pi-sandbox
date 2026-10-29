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

# Never mount the repo or a folder containing it: the agent could rewrite
# pi.conf / pi.sh here and get them executed on the host at the next launch.
# A folder inside the repo is refused too (its .git hooks run on the host).
# Symlinks are resolved and case is ignored: APFS treats ~/workspace as ~/Workspace.
REPO="$(pwd -P)"
holds_repo() {
  local d
  d="$(cd "$1" 2>/dev/null && pwd -P)" || d="$1"
  ( shopt -s nocasematch
    case "$REPO/" in "$d"/*) exit 0 ;; esac
    case "$d/" in "$REPO"/*) exit 0 ;; esac
    exit 1 )
}

# Are we inside an allowed folder? If so, confine to it.
START_DIR=""
for dir in ${ALLOWED[@]+"${ALLOWED[@]}"}; do
  dir="${dir/#\~/$HOME}"   # "~/x" in quotes stays a literal ~
  dir="${dir%/}"   # a trailing slash would make the pattern `…/proj//*` never match
  holds_repo "$dir" && continue
  case "$LAUNCH_DIR" in
    "$dir"|"$dir"/*)
      START_DIR="$dir"; break
      ;;
  esac
done

# Models live in ~/.pi/agent/models.json (user-level, pi reads nothing else),
# so the repo's config/models.json is bind-mounted over the volume at launch:
# edit it and relaunch — no reinstall, no drift between repo and volume.
MODELS_ARGS=()
MODELS_FILE="$(dirname "$SCRIPT")/config/models.json"
[ -f "$MODELS_FILE" ] && MODELS_ARGS=(-v "$MODELS_FILE:/root/.pi/agent/models.json:ro")

if [ -n "$START_DIR" ]; then
  echo "→ Confined to: $START_DIR"
  # Mount at the folder's real host path so pi's footer shows the actual
  # location (e.g. ~/My_workspace/My_projects/pi-sandbox (main)), not a generic /workspace.
  ARGS=(-v "$START_DIR:$START_DIR")
  WORKDIR_ARGS=(-w "$LAUNCH_DIR")
else
  holds_repo "$LAUNCH_DIR" && { echo "❌ refusing to mount $LAUNCH_DIR: it is pi-sandbox, inside it, or contains it"; exit 1; }
  echo "⚠ $LAUNCH_DIR is not in ALLOWED (pi.conf)"
  printf "Add this folder to ALLOWED and launch confined to it? [y/N] "
  read -r answer || true
  case "$answer" in
    y|Y|yes|YES)
      # pi.conf is sourced on the host: these characters would run code or be mangled
      case "$LAUNCH_DIR" in
        *[\"\$\`\\]*) echo "❌ path contains \" \$ \` or \\ — add it to pi.conf by hand"; exit 1 ;;
      esac
      # Append at the end of the file: pi.conf is sourced, so ALLOWED+=() extends
      # the list wherever it was written (one-line lists included).
      grep -qF "\"$LAUNCH_DIR\"" pi.conf \
        || printf '\nALLOWED+=("%s")   # added by pi.sh\n' "$LAUNCH_DIR" >> pi.conf
      echo "✓ Added to ALLOWED (pi.conf), relaunching…"
      cd "$LAUNCH_DIR"
      exec "$SCRIPT"
      ;;
  esac
  echo "→ Mounting all allowed folders (add the folder to ALLOWED in pi.conf to confine)"
  ARGS=(); USED_NAMES=()
  for dir in ${ALLOWED[@]+"${ALLOWED[@]}"}; do
    dir="${dir/#\~/$HOME}"
    dir="${dir%/}"
    holds_repo "$dir" && { echo "⚠ skipping $dir (is, is inside, or contains pi-sandbox)"; continue; }
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

# API keys / env vars to forward. Source of truth: the macOS Keychain
# (service "pi-sandbox", account = variable name). A variable already set in the
# shell wins, so you can still override one key for a single launch.
#
# Keys with a keyproxy route (proxy/keyproxy.mjs) go to the SIDECAR only: pi
# gets the dummy value "proxy" and the sidecar injects the real one on the way
# out, so the agent can use the key but not read or copy it.
#
# Built-in routes, KEY|upstream: each one checked in pi's provider code (base
# URL as pi's provider has it). Route prefix = KEY minus _API_KEY, lowercased,
# _ → - (ANT_LING_API_KEY → /ant-ling, HF_TOKEN → /hf-token); config/models.json
# points there.
PROXY_TABLE=(
  "DEEPSEEK_API_KEY|https://api.deepseek.com"
  "OPENAI_API_KEY|https://api.openai.com/v1"
  "TAVILY_API_KEY|https://api.tavily.com"
  "ANTHROPIC_API_KEY|https://api.anthropic.com"
  "GEMINI_API_KEY|https://generativelanguage.googleapis.com/v1beta"
  "MISTRAL_API_KEY|https://api.mistral.ai"
  "GROQ_API_KEY|https://api.groq.com/openai/v1"
  "XAI_API_KEY|https://api.x.ai/v1"
  "CEREBRAS_API_KEY|https://api.cerebras.ai/v1"
  "TOGETHER_API_KEY|https://api.together.ai/v1"
  "NVIDIA_API_KEY|https://integrate.api.nvidia.com/v1"
  "HF_TOKEN|https://router.huggingface.co/v1"
  "MOONSHOT_API_KEY|https://api.moonshot.ai/v1"
  "ZAI_API_KEY|https://api.z.ai/api/coding/paas/v4"
  "KIMI_API_KEY|https://api.kimi.com/coding/v1"
  "MINIMAX_API_KEY|https://api.minimax.io/anthropic"
  "BASETEN_API_KEY|https://inference.baseten.co/v1"
  "META_API_KEY|https://api.meta.ai/v1"
  "XIAOMI_API_KEY|https://api.xiaomimimo.com/v1"
  "ANT_LING_API_KEY|https://api.ant-ling.com/v1"
  "QWEN_TOKEN_PLAN_API_KEY|https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1"
)
# Not OpenRouter: pi sends its anthropic/* models to openrouter.ai/api and the
# others to openrouter.ai/api/v1, and one models.json baseUrl cannot serve both.
# Every route is sent, loaded key or not (a route without key forwards as is).
# Reset first: a value exported in the calling shell must never reach the sidecar.
KEYPROXY_ROUTES=""
for r in "${PROXY_TABLE[@]}"; do
  name="${r%%|*}"
  KEYPROXY_ROUTES+="$name|/$(printf '%s' "${name%_API_KEY}" | tr 'A-Z_' 'a-z-')|${r#*|};"
done
export KEYPROXY_ROUTES
# Optional paths the sidecar refuses (403), from pi.conf: only the host sets it.
KEYPROXY_BLOCK="$(IFS=';'; printf '%s' "${KEYPROXY_BLOCK_PATHS[*]-}")"
export KEYPROXY_BLOCK
KEYCHAIN_SERVICE="pi-sandbox"
ENV_ARGS=()
PROXY_ENV=(-e KEYPROXY_ROUTES -e KEYPROXY_BLOCK)
PROXIED=0
for k in ${API_KEYS[@]+"${API_KEYS[@]}"}; do
  v="${!k:-}"
  if [ -z "$v" ] && command -v security >/dev/null 2>&1; then
    v="$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$k" -w 2>/dev/null)" || v=""
  fi
  [ -n "$v" ] || continue
  export "$k=$v"   # export keeps the secret out of docker's argv / `ps`
  case " ${PROXY_TABLE[*]} " in
    *" $k|"*)
      PROXY_ENV+=(-e "$k")
      ENV_ARGS+=(-e "$k=proxy")
      PROXIED=1
      # pi-web-access reads TAVILY_BASE_URL (verified in dist/index.js)
      [ "$k" = TAVILY_API_KEY ] && ENV_ARGS+=(-e TAVILY_BASE_URL=http://keyproxy:8787/tavily)
      ;;
    *)
      echo "⚠ $k has no proxy route, exposed to the agent"
      ENV_ARGS+=(-e "$k")
      ;;
  esac
done

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
  echo "→ Image ${IMAGE} not found, building…"
  "$UPDATER" || true
fi

# ====== keyproxy sidecar ======
# Private network per session, fixed alias "keyproxy" so config/models.json can
# hardcode http://keyproxy:8787/…; two sessions can neither share nor reach
# each other's sidecar. The script is bind-mounted, like config/models.json, so
# editing it needs no rebuild.
NET_ARGS=()
if [ "$PROXIED" = 1 ]; then
  conflict=""
  for a in ${DOCKER_ARGS[@]+"${DOCKER_ARGS[@]}"}; do
    case "$a" in --network|--net|--network=*|--net=*) conflict=1 ;; esac
  done
  if [ -n "$conflict" ]; then
    log_error "--network/--net in DOCKER_ARGS conflicts with keyproxy"
    echo "❌ --network in DOCKER_ARGS conflicts with keyproxy: remove it (see README)"
    exit 1
  fi

  # A closed terminal window or `kill -9` skips the trap, leaving a sidecar
  # holding the real keys forever: drop those of dead sessions (pid no longer alive).
  for name in $(docker ps -a --format '{{.Names}}' 2>/dev/null | grep '^pi-keyproxy-' || true); do
    kill -0 "${name#pi-keyproxy-}" 2>/dev/null || docker rm -f "$name" >/dev/null 2>&1 || true
  done
  for net in $(docker network ls --format '{{.Name}}' 2>/dev/null | grep '^pi-net-' || true); do
    kill -0 "${net#pi-net-}" 2>/dev/null || docker network rm "$net" >/dev/null 2>&1 || true
  done

  NET="pi-net-$$"; PROXY="pi-keyproxy-$$"
  trap 'docker rm -f "$PROXY" >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1' EXIT
  docker network create "$NET" >/dev/null
  # No -p: 8787 must never be reachable from the Mac, only from the session network.
  # no --rm: a sidecar that dies at startup must keep its logs for the error
  # below; the trap removes it.
  docker run -d --name "$PROXY" --network "$NET" --network-alias keyproxy \
    --read-only --cap-drop ALL --security-opt no-new-privileges --user node \
    -v "$(dirname "$SCRIPT")/proxy/keyproxy.mjs:/keyproxy.mjs:ro" \
    ${PROXY_ENV[@]+"${PROXY_ENV[@]}"} \
    --entrypoint node "$IMAGE" /keyproxy.mjs >/dev/null

  ready=0
  for _ in {1..25}; do   # 5 s max
    if ! out="$(docker logs "$PROXY" 2>&1)"; then break; fi
    case "$out" in *"keyproxy listening"*) ready=1; break ;; esac
    [ "$(docker inspect -f '{{.State.Running}}' "$PROXY" 2>/dev/null)" = false ] && break   # crashed
    sleep 0.2
  done
  if [ "$ready" != 1 ]; then
    log_error "keyproxy failed to start"
    echo "❌ keyproxy failed to start:"
    docker logs "$PROXY" 2>&1 | tail -n 5
    exit 1   # the trap removes the sidecar and the network
  fi
  NET_ARGS=(--network "$NET")
fi

code=0
# Tool caches stay in the volume: the container is ephemeral, so without this
# anything cached would be re-downloaded on every launch.
docker run --rm -it \
  ${NET_ARGS[@]+"${NET_ARGS[@]}"} \
  ${ENV_ARGS[@]+"${ENV_ARGS[@]}"} \
  -v "${VOLUME}:/root/.pi/agent" \
  -e XDG_CACHE_HOME=/root/.pi/agent/cache \
  ${MODELS_ARGS[@]+"${MODELS_ARGS[@]}"} \
  -v "${RTK_VOLUME}:/root/.local/share/rtk" \
  ${ARGS[@]+"${ARGS[@]}"} \
  "${WORKDIR_ARGS[@]}" \
  ${DOCKER_ARGS[@]+"${DOCKER_ARGS[@]}"} \
  "${IMAGE}" || code=$?
[ "$code" -ne 0 ] && log_error "pi session exited with error (code $code, image $(docker image inspect --format "{{.Id}}" "${IMAGE}" 2>/dev/null | cut -c1-19))" || true
exit "$code"
