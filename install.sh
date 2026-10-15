#!/usr/bin/env bash
# pi-sandbox setup on macOS: OrbStack + pi image + extensions.
# Usage: ./install.sh
set -euo pipefail
cd "$(dirname "$0")"

# ====== 1. Check Docker (OrbStack or Docker Desktop) ======
if ! command -v docker >/dev/null 2>&1; then
  echo "❌ docker not found."
  echo "   Install OrbStack: https://orbstack.dev  (or Docker Desktop), then re-run ./install.sh"
  exit 1
fi

if ! docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
  echo "→ Docker is not responding, starting OrbStack / Docker Desktop…"
  open -a OrbStack 2>/dev/null || open -a "Docker Desktop" 2>/dev/null || true
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
# Seed a fresh volume only: re-running must not wipe packages the user
# installed with `!pi install` (they live in this same settings.json).
echo "→ Installing model config (no default provider, pi asks on first run)…"
docker run --rm \
  -v pi-agent-home:/root/.pi/agent \
  -v "$(pwd)/config:/config:ro" \
  --entrypoint bash pi-sandbox -c \
  'mkdir -p /root/.pi/agent
   if [ -f /root/.pi/agent/settings.json ]; then
     echo "✓ Model config kept (existing extensions preserved)"
   else
     cp /config/settings.json /root/.pi/agent/ && echo "✓ Model config installed"
   fi'

# ====== 4. Extensions ======
# pi installs the packages declared in config/settings*.json on first launch
# (settings.json was seeded in step 3), so the list lives only there.

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
    echo "→ Installing deepseek model config (pi installs pi-deepseek-peak from it)…"
    docker run --rm \
      -v pi-agent-home:/root/.pi/agent \
      -v "$(pwd)/config:/config:ro" \
      --entrypoint bash pi-sandbox -c \
      'cp -f /config/settings.deepseek.json /root/.pi/agent/settings.json && echo "✓ DeepSeek model config installed"'
    # pi.sh creates pi.conf on first launch; install.sh may run first.
    [ -f pi.conf ] || cp pi.conf.example pi.conf
    if ! grep -q '^  DEEPSEEK_API_KEY$' pi.conf; then
      tmp="$(mktemp)"
      if awk '/^API_KEYS=\(/ { in_block=1 } in_block && /^\)/ { print "  DEEPSEEK_API_KEY"; in_block=0 } { print }' pi.conf > "$tmp"; then
        mv "$tmp" pi.conf
        echo "✓ DEEPSEEK_API_KEY added to API_KEYS (pi.conf)"
      else
        rm -f "$tmp"
        echo "❌ Failed to add DEEPSEEK_API_KEY to pi.conf"
      fi
    fi
    DEEPSEEK_OPTED=1
    ;;
  *)
    echo "ℹ️  Skipping DeepSeek. Re-run ./install.sh and answer yes to add it later."
    ;;
esac

# ====== 7. API keys → macOS Keychain (never in ~/.zshrc) ======
# pi.sh reads them from the login keychain at launch (service "pi-sandbox",
# account = variable name), so no secret ever lands in a shell rc file.
KEYCHAIN_SERVICE="pi-sandbox"
store_key() {
  local name="$1" answer=""
  if security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$name" -w >/dev/null 2>&1; then
    echo "  ✓ $name already in the Keychain"
    return 0
  fi
  if [ -t 0 ]; then
    printf "  Store %s in the Keychain now? [y/N] " "$name"
    read -r answer || true
  fi
  case "$answer" in
    y|Y|yes|YES)
      # -w last: security prompts for the value (hidden input), so it never
      # reaches argv, the shell history, or a file.
      security add-generic-password -U -s "$KEYCHAIN_SERVICE" -a "$name" -w ;;
    *)
      echo "  ℹ  later: security add-generic-password -U -s $KEYCHAIN_SERVICE -a $name -w" ;;
  esac
}

echo
echo "════════════════════════════════════════════════════════════════"
echo "  API KEYS — stored in your macOS Keychain (login keychain)"
echo "════════════════════════════════════════════════════════════════"
store_key TAVILY_API_KEY
[ -n "${DEEPSEEK_OPTED:-}" ] && store_key DEEPSEEK_API_KEY
echo
echo "pi.sh forwards them to the container automatically at launch."
echo "macOS may ask \"security wants to use…\" on first read: click Always Allow."
echo "Remove any 'export …_API_KEY=' line left in ~/.zshrc."
echo "════════════════════════════════════════════════════════════════"

if [ -n "${DEEPSEEK_OPTED:-}" ] \
   && ! security find-generic-password -s "$KEYCHAIN_SERVICE" -a DEEPSEEK_API_KEY -w >/dev/null 2>&1; then
  echo "ℹ️  DEEPSEEK_API_KEY not in the Keychain (the deepseek model won't authenticate)."
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
echo "  1. Edit pi.conf (allowed folders):  nano pi.conf"
echo "  2. cd into one of the allowed folders, then:  pi"

# ====== Retention: keep 30 days ======
find logs -name '*.log' -mtime +30 -delete
