#!/usr/bin/env bash
# Hand-run checks for the risky host-side logic: the updater lock and the
# pi.conf edit in install.sh. No Docker, no network, no repo writes.
#   ./test-pi-sandbox.sh   (exits non-zero if anything fails)
set -uo pipefail
cd "$(dirname "$0")"
SRC="$(pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "PASS $1"; }
ko() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else ko "$name"; fi; }

# ===== updater lock =========================================================
# Run a copy of the updater in a temp dir (logs stay out of the repo) with a
# stubbed docker (ok, prints nothing) and curl (fails → no version change), so
# the run reaches the lock and stops before any build.
STUB="$TMP/stub"; mkdir -p "$STUB"
printf '#!/bin/sh\nexit 0\n' > "$STUB/docker"
printf '#!/bin/sh\nexit 1\n' > "$STUB/curl"
chmod +x "$STUB/docker" "$STUB/curl"
UPD="$TMP/upd"; mkdir -p "$UPD"; cp "$SRC/update-pi-sandbox.sh" "$UPD/"
LOCK="$TMP/lock"
run_updater() { PATH="$STUB:$PATH" PI_UPDATE_LOCK="$LOCK" "$UPD/update-pi-sandbox.sh" >/dev/null 2>&1; }

mkdir "$LOCK"
run_updater
check "stale lock without pid file is reclaimed" test ! -d "$LOCK"

mkdir "$LOCK"; echo 999999 > "$LOCK/pid"
run_updater
check "stale lock with a dead pid is reclaimed" test ! -d "$LOCK"

mkdir "$LOCK"; echo $$ > "$LOCK/pid"
run_updater
check "lock held by a live non-updater pid is reclaimed" test ! -d "$LOCK"

PS_OK=0
if command -v ps >/dev/null 2>&1; then
  PS_OK=1
elif [ -r /proc/self/cmdline ]; then   # minimal containers: emulate the one ps call
  printf '#!/bin/sh\npid=""; while [ $# -gt 0 ]; do [ "$1" = "-p" ] && { pid=$2; shift 2; continue; }; shift; done\ntr "\\0" " " < "/proc/$pid/cmdline" 2>/dev/null || exit 1\necho\n' > "$STUB/ps"
  chmod +x "$STUB/ps"
  PS_OK=1
fi
if [ "$PS_OK" = 1 ]; then
  FAKE="$TMP/update-pi-sandbox.sh"
  # a shell wrapper, not a copy of sleep: macOS kills copied signed binaries
  printf '#!/bin/sh\nsleep 30\n' > "$FAKE"
  chmod +x "$FAKE"
  "$FAKE" &
  FAKE_PID=$!
  rm -rf "$UPD/logs"
  mkdir "$LOCK"; echo "$FAKE_PID" > "$LOCK/pid"
  run_updater
  check "lock held by a live updater is respected" test -d "$LOCK"
  check "skip is logged" grep -q 'already running' "$UPD/logs/update-"*.log
  kill "$FAKE_PID" 2>/dev/null
  wait "$FAKE_PID" 2>/dev/null
  rm -rf "$LOCK"
else
  echo "SKIP live-lock case (no ps and no /proc on this machine)"
fi

# ===== previous-image cleanup (update-pi-sandbox.sh) =====================
# Scoped on purpose: a global `docker image prune` would also drop other
# projects' dangling images and is forbidden here.
check "updater never prunes images globally" \
  bash -c '! grep -q "image prune" "$0"' "$SRC/update-pi-sandbox.sh"
check "updater removes the previous image by exact id" \
  bash -c 'grep -q "docker image rm \"\$old_image\"" "$0"' "$SRC/update-pi-sandbox.sh"

# ===== empty ALLOWED / API_KEYS (pi.sh) ====================================
# macOS ships bash 3.2, where "${empty[@]}" under `set -u` is an unbound
# variable. Run the launcher for real with both lists empty and a stubbed
# docker: it must reach `docker run` instead of dying on the first loop.
P="$TMP/pi"; mkdir -p "$P"; cp "$SRC/pi.sh" "$P/"
cat > "$P/pi.conf" <<'EOF'
ALLOWED=()
API_KEYS=()
IMAGE="pi-sandbox"
VOLUME="pi-agent-home"
RTK_VOLUME="rtk-data"
WORKSPACE="/workspace"
DOCKER_ARGS=()
EOF
printf '#!/bin/sh\nexit 0\n' > "$P/update-pi-sandbox.sh"; chmod +x "$P/update-pi-sandbox.sh"
printf 'n\n' | ( cd "$P" && PATH="$STUB:$PATH" "$P/pi.sh" ) >"$TMP/pi.out" 2>&1
check "empty ALLOWED/API_KEYS: launcher starts" test $? -eq 0
check "empty ALLOWED/API_KEYS: no unbound-variable error" \
  bash -c '! grep -q "unbound variable" "$0"' "$TMP/pi.out"
# bash 3.2 is the real target and this machine may not have it, so also assert
# statically that every list that can be empty is expanded with the guard.
check "every emptyable array in pi.sh is expanded with the guard" bash -c '
  for v in API_KEYS ALLOWED ARGS ENV_ARGS MODELS_ARGS DOCKER_ARGS; do
    [ "$(grep -c "\"\${$v\[@\]}\"" "$1")" = "$(grep -c "\${$v\[@\]+" "$1")" ] || exit 1
  done' _ "$SRC/pi.sh"

# ===== duplicate basenames (pi.sh) ========================================
# Two allowed folders named `api` used to give one container target, so Docker
# dropped one mount. Both must now be mounted, the second under a suffix.
P2="$TMP/pi2"; mkdir -p "$P2/a/api" "$P2/b/api" "$P2/run"
cp "$SRC/pi.sh" "$P2/"
cat > "$P2/pi.conf" <<EOF
ALLOWED=("$P2/a/api" "$P2/b/api")
API_KEYS=()
IMAGE="pi-sandbox"
VOLUME="pi-agent-home"
RTK_VOLUME="rtk-data"
WORKSPACE="/workspace"
DOCKER_ARGS=()
EOF
printf '#!/bin/sh\nexit 0\n' > "$P2/update-pi-sandbox.sh"; chmod +x "$P2/update-pi-sandbox.sh"
STUB2="$TMP/stub2"; mkdir -p "$STUB2"
cat > "$STUB2/docker" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" >> "$ARGS_LOG"
exit 0
STUB
chmod +x "$STUB2/docker"
: > "$TMP/docker.args"
( cd "$P2/run" && printf 'n\n' | PATH="$STUB2:$PATH" ARGS_LOG="$TMP/docker.args" "$P2/pi.sh" ) >"$TMP/pi2.out" 2>&1
check "duplicate basenames: both folders are mounted" bash -c '
  grep -q ":/workspace/api$" "$0" && grep -q ":/workspace/api-2$" "$0"' "$TMP/docker.args"

# ===== pi.conf edit (install.sh) ===========================================
AWK_PROG="$(sed -n "s/.*awk '\(.*\)' pi.conf.*/\1/p" "$SRC/install.sh" | head -1)"
check "awk program found in install.sh" test -n "$AWK_PROG"
check "pi.conf creation guard present in install.sh" \
  grep -q '\[ -f pi.conf \] || cp pi.conf.example pi.conf' "$SRC/install.sh"

CONF="$TMP/conf"; mkdir -p "$CONF"; cp "$SRC/pi.conf.example" "$CONF/pi.conf"
apply_edit() {  # mirrors install.sh: grep guard, mktemp, mv
  ( cd "$CONF" || exit 1
    grep -q '^  DEEPSEEK_API_KEY$' pi.conf && exit 0
    t="$(mktemp)"
    if awk "$AWK_PROG" pi.conf > "$t"; then mv "$t" pi.conf; else rm -f "$t"; exit 1; fi )
}
in_api_keys() {
  awk '/^API_KEYS=\(/ { f=1; next } f && /^\)/ { f=0 } f && /^  DEEPSEEK_API_KEY$/ { found=1 } END { exit found ? 0 : 1 }' "$CONF/pi.conf"
}
apply_edit
check "DEEPSEEK_API_KEY added to pi.conf" grep -q '^  DEEPSEEK_API_KEY$' "$CONF/pi.conf"
check "line sits inside the API_KEYS block" in_api_keys
apply_edit
check "second run is idempotent" test "$(grep -c '^  DEEPSEEK_API_KEY$' "$CONF/pi.conf")" = 1
check "no leftover temp file in the directory" test "$(ls -A "$CONF")" = "pi.conf"

CONF2="$TMP/conf2"; mkdir -p "$CONF2"; cp "$SRC/pi.conf.example" "$CONF2/pi.conf.example"
( cd "$CONF2" && awk "$AWK_PROG" pi.conf > "$TMP/out" ) 2>/dev/null; awk_status=$?
check "missing pi.conf: awk fails" test "$awk_status" -ne 0
check "missing pi.conf: no output written" test ! -s "$TMP/out"
check "missing pi.conf: no file created" test "$(ls -A "$CONF2")" = "pi.conf.example"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
