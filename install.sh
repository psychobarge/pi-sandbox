#!/usr/bin/env bash
# pi-sandbox setup on macOS: OrbStack + pi image + extensions.
# Usage: ./install.sh
set -euo pipefail
cd "$(dirname "$0")"

# ====== Extensions to install ======
EXTENSIONS=(
  "git:github.com/DietrichGebert/ponytail"
  "npm:pi-web-access"
  "npm:@narumitw/pi-plan-mode"
  "npm:pi-ask-mode"
)

# ====== 1. Check Docker (OrbStack or Docker Desktop) ======
if ! command -v docker >/dev/null 2>&1; then
  echo "❌ docker not found."
  echo "   Install OrbStack: https://orbstack.dev  (or Docker Desktop), then re-run ./install.sh"
  exit 1
fi

if ! docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
  echo "→ Docker is not responding, starting OrbStack…"
  open -a OrbStack 2>/dev/null || true
  for _ in {1..10}; do
    sleep 2
    docker version --format '{{.Server.Version}}' >/dev/null 2>&1 && break
  done
fi
docker version --format '{{.Server.Version}}' >/dev/null 2>&1 \
  || { echo "❌ Docker is not responding. Open OrbStack/Docker Desktop then re-run."; exit 1; }
echo "✓ Docker $(docker version --format '{{.Server.Version}}')"

# ====== 2. Pi image (Node 24 + pi pinned; auto-updated by update-pi-sandbox.sh) ======
echo "→ Building pi-sandbox image (Node 24 + latest pi)…"
docker build -t pi-sandbox -f Dockerfile.pi .
echo "✓ Image ready"

# ====== 2b. rtk data volume (persists `rtk gain` history across launches) ======
# Named volume, same isolation as pi-agent-home: survives container removal.
docker volume create rtk-data >/dev/null 2>&1 || true
echo "✓ rtk-data volume ready"

# ====== 3. Model & thinking config (settings.json) ======
# No default provider/model: pi asks on first run. DeepSeek is added
# later only if the user opts in at the end of this script.
echo "→ Installing model config (no default provider, pi asks on first run)…"
docker run --rm \
  -v pi-agent-home:/root/.pi/agent \
  -v "$(pwd)/config:/config:ro" \
  --entrypoint bash pi-sandbox -c \
  'mkdir -p /root/.pi/agent && cp -f /config/settings.json /root/.pi/agent/ && echo "✓ Model config installed"'

# ====== 4. Extensions (into the persistent pi-agent-home volume) ======
echo "→ Installing extensions…"
for ext in "${EXTENSIONS[@]}"; do
  echo "   • $ext"
  docker run --rm -v pi-agent-home:/root/.pi/agent pi-sandbox install "$ext"
done
echo "✓ Extensions installed"

# ====== 5. rtk hook (global pi extension, into the persistent volume) ======
echo "→ Installing rtk pi extension (compresses bash output for the agent)…"
docker run --rm \
  -e RTK_TELEMETRY_DISABLED=1 \
  -v pi-agent-home:/root/.pi/agent \
  --entrypoint bash pi-sandbox -c \
  'rtk init -g --agent pi'
echo "✓ rtk extension installed"

# ====== 6. DeepSeek opt-in (default: off) ======
echo
echo "DeepSeek is NOT installed by default."
printf "Add DeepSeek support (pi-deepseek-peak extension + deepseek model defaults + DEEPSEEK_API_KEY forwarding)? [y/N] "
read -r want_deepseek || true
case "$want_deepseek" in
  y|Y|yes|YES)
    echo "→ Installing pi-deepseek-peak…"
    docker run --rm -v pi-agent-home:/root/.pi/agent pi-sandbox install "git:github.com/psychobarge/pi-deepseek-peak"
    echo "→ Installing deepseek model config…"
    docker run --rm \
      -v pi-agent-home:/root/.pi/agent \
      -v "$(pwd)/config:/config:ro" \
      --entrypoint bash pi-sandbox -c \
      'cp -f /config/settings.deepseek.json /root/.pi/agent/settings.json && echo "✓ DeepSeek model config installed"'
    if ! grep -q '^  DEEPSEEK_API_KEY$' pi.conf; then
      awk '/^API_KEYS=\(/ { in_block=1 } in_block && /^\)/ { print "  DEEPSEEK_API_KEY"; in_block=0 } { print }' pi.conf > pi.conf.tmp && mv pi.conf.tmp pi.conf
      echo "✓ DEEPSEEK_API_KEY added to API_KEYS (pi.conf)"
    fi
    DEEPSEEK_OPTED=1
    ;;
  *)
    echo "ℹ️  Skipping DeepSeek. Re-run ./install.sh and answer yes to add it later."
    ;;
esac

# ====== 7. API keys (all optional) ======
RC_FILE="$HOME/.zshrc"
case "$SHELL" in
  *bash*) RC_FILE="$HOME/.bashrc" ;;
esac

echo
echo "════════════════════════════════════════════════════════════════"
echo "  API KEYS — add them to your shell ($RC_FILE)"
echo "════════════════════════════════════════════════════════════════"
if [ -n "${DEEPSEEK_OPTED:-}" ]; then
  echo "DeepSeek (required to use the deepseek model):"
  echo
  echo "  echo 'export DEEPSEEK_API_KEY=\"sk-…\"' >> $RC_FILE"
  echo
fi
echo "Tavily (optional — web search for pi-web-access):"
echo
echo "  echo 'export TAVILY_API_KEY=\"tvly-…\"' >> $RC_FILE"
echo
echo "Then reload your shell:  source $RC_FILE"
echo
echo "════════════════════════════════════════════════════════════════"

if [ -n "${DEEPSEEK_OPTED:-}" ] && [ -z "${DEEPSEEK_API_KEY:-}" ]; then
  echo "ℹ️  DEEPSEEK_API_KEY not detected in this shell."
fi

# ====== 8. Launcher in PATH ======
LAUNCHER="/usr/local/bin/pi"
if [ ! -e "$LAUNCHER" ]; then
  if ln -s "$(pwd)/pi.sh" "$LAUNCHER" 2>/dev/null; then
    echo "✓ Launcher installed: $LAUNCHER"
    echo "   → run \"pi\" from any allowed folder"
  else
    ORANGE='\033[1;38;5;208m'
    RESET='\033[0m'
    printf "${ORANGE}⚠ Could not create %s${RESET}\n" "$LAUNCHER"
    echo "   This installs the \"pi\" shortcut (a symlink) so you can"
    echo "   launch pi from any allowed folder. Run this manually:"
    echo "   sudo ln -s $(pwd)/pi.sh /usr/local/bin/pi"
  fi
else
  echo "ℹ️  $LAUNCHER already exists, skipping."
fi

echo
echo "To get started:"
echo "  1. Edit pi.conf (allowed folders, API keys):  nano pi.conf"
echo "  2. cd into one of the allowed folders, then:  pi"

# ====== Retention: keep 30 days ======
find logs -name '*.log' -mtime +30 -delete
