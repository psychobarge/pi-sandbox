#!/usr/bin/env bash
# Hand-run checks for the risky host-side logic: the updater lock, the pi.conf
# edit in install.sh, the version comparison and the ALLOWED path matching.
# No Docker, no network, no repo writes.
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

# ===== rtk tarball pin (Dockerfile.pi / update-pi-sandbox.sh) ==============
# The release tag is movable (v1.0.0 can be retagged), so the tarball is
# verified against a hash pinned in the Dockerfile; the updater repins it when
# it bumps RTK_VERSION.
check "Dockerfile verifies the rtk tarball's sha256" \
  grep -q 'sha256sum -c -' "$SRC/Dockerfile.pi"
check "Dockerfile pins both arch hashes" \
  bash -c 'grep -q "^ARG RTK_SHA256_X86_64=[0-9a-f]\{64\}$" "$1" && grep -q "^ARG RTK_SHA256_AARCH64=[0-9a-f]\{64\}$" "$1"' _ "$SRC/Dockerfile.pi"
check "updater repins the rtk hashes on a version bump" \
  bash -c 'grep -q "checksums.txt" "$1" && grep -q "ARG RTK_SHA256_X86_64=" "$1"' _ "$SRC/update-pi-sandbox.sh"
# GitHub serves release assets through a redirect: without -L curl exits 0 with
# an empty body, the hashes are never found and rtk is never bumped.
check "checksums.txt download follows redirects (-L)" \
  bash -c 'grep -A1 "sums=.*curl" "$1" | grep -q "curl -[a-zA-Z]*L"' _ "$SRC/update-pi-sandbox.sh"

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
mkdir -p "$TMP/run0"
printf 'n\n' | ( cd "$TMP/run0" && PATH="$STUB:$PATH" "$P/pi.sh" ) >"$TMP/pi.out" 2>&1
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
AWK_PROG="$SRC/append-array-entry.awk"
check "array-append awk helper present" test -f "$AWK_PROG"
check "pi.sh uses the shared append helper" \
  grep -q 'append-array-entry.awk' "$SRC/pi.sh"
check "install.sh uses the shared append helper" \
  grep -q 'append-array-entry.awk' "$SRC/install.sh"
check "pi.conf creation guard present in install.sh" \
  grep -q '\[ -f pi.conf \] || cp pi.conf.example pi.conf' "$SRC/install.sh"
check "install.sh repoints a stale launcher symlink" \
  grep -qF '[ -L "$LAUNCHER" ] && [ "$(readlink "$LAUNCHER")" != "$TARGET" ]' "$SRC/install.sh"
# logs/ is gitignored and only pi.sh creates it; on a fresh clone the retention
# `find logs` errored and `set -e` returned 1 after install.sh had done its work.
check "install.sh creates logs before the retention find" \
  bash -c 'grep -B1 "find logs -name" "$1" | grep -q "mkdir -p logs"' _ "$SRC/install.sh"
# A failing `security add-generic-password` (locked keychain, SSH) was the last
# command of store_key: under set -e it stopped install.sh before the launcher.
check "install.sh survives a failed Keychain write" \
  bash -c 'grep -A1 "security add-generic-password -U -s \"\$KEYCHAIN_SERVICE\" -a \"\$name\" -w" "$1" | grep -q "|| echo"' _ "$SRC/install.sh"

CONF="$TMP/conf"; mkdir -p "$CONF"; cp "$SRC/pi.conf.example" "$CONF/pi.conf"
apply_edit() {  # mirrors install.sh: grep guard, mktemp, mv
  ( cd "$CONF" || exit 1
    grep -q '^  DEEPSEEK_API_KEY$' pi.conf && exit 0
    t="$(mktemp)"
    if awk -v array=API_KEYS -v entry=DEEPSEEK_API_KEY -f "$AWK_PROG" pi.conf > "$t"; then mv "$t" pi.conf; else rm -f "$t"; exit 1; fi )
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
( cd "$CONF2" && awk -v array=API_KEYS -v entry=DEEPSEEK_API_KEY -f "$AWK_PROG" pi.conf > "$TMP/out" ) 2>/dev/null; awk_status=$?
check "missing pi.conf: awk fails" test "$awk_status" -ne 0
check "missing pi.conf: no output written" test ! -s "$TMP/out"
check "missing pi.conf: no file created" test "$(ls -A "$CONF2")" = "pi.conf.example"

# A list written on one line has no line starting with ")". The old parser
# matched `^\)`, so it printed the file unchanged and exited 0: the launcher
# then "added" the folder, relaunched and looped forever.
printf 'ALLOWED=("/a" "/b")\n' > "$TMP/one-line.conf"
awk -v array=ALLOWED -v entry='\"/new\"' -f "$AWK_PROG" "$TMP/one-line.conf" > "$TMP/one-line.out"
check "one-line list: entry appended inside the array" \
  bash -c '. "$1"; [ "${ALLOWED[*]}" = "/a /b /new" ]' _ "$TMP/one-line.out"
printf 'ALLOWED=()\n' > "$TMP/empty-line.conf"
awk -v array=ALLOWED -v entry='\"/new\"' -f "$AWK_PROG" "$TMP/empty-line.conf" > "$TMP/empty-line.out"
check "one-line empty list: entry appended inside the array" \
  bash -c '. "$1"; [ "${ALLOWED[*]}" = "/new" ]' _ "$TMP/empty-line.out"
# A ")" in a quoted path must not be taken for the closing paren (a plain
# "match ) anywhere" fix would corrupt the list).
printf 'ALLOWED=(\n  "/a (old)"\n)\n' > "$TMP/paren.conf"
awk -v array=ALLOWED -v entry='\"/new\"' -f "$AWK_PROG" "$TMP/paren.conf" > "$TMP/paren.out"
check "paren inside a quoted path is not the array end" \
  bash -c '. "$1"; [ "${ALLOWED[*]}" = "/a (old) /new" ]' _ "$TMP/paren.out"
# Re-adding a folder that is already in a one-line list must not duplicate it.
printf 'ALLOWED=("/new" "/b")\n' > "$TMP/dup.conf"
awk -v array=ALLOWED -v entry='\"/new\"' -f "$AWK_PROG" "$TMP/dup.conf" > "$TMP/dup.out"
check "one-line list: an entry already there is not duplicated" \
  bash -c '. "$1"; [ "${ALLOWED[*]}" = "/new /b" ]' _ "$TMP/dup.out"

# ===== DeepSeek settings merge (config/merge-deepseek-settings.py) =========
# Answering yes to DeepSeek must not drop extensions the user installed with
# `!pi install` (the audit's finding 2: `cp -f` wiped them).
if command -v python3 >/dev/null 2>&1; then
  MERGE="$SRC/config/merge-deepseek-settings.py"
  DS="$SRC/config/settings.deepseek.json"
  M="$TMP/merge"; mkdir -p "$M"
  cat > "$M/settings.json" <<'EOF'
{
  "theme": "light",
  "packages": [
    "npm:@dietrichgebert/ponytail",
    "npm:mon-ext-perso"
  ]
}
EOF
  python3 "$MERGE" "$M/settings.json" "$DS" >/dev/null 2>&1
  check "merge: user's own package kept" \
    grep -q 'npm:mon-ext-perso' "$M/settings.json"
  check "merge: existing package not duplicated" \
    test "$(grep -c 'npm:@dietrichgebert/ponytail' "$M/settings.json")" = 1
  check "merge: pi-deepseek-peak added" \
    grep -q 'npm:pi-deepseek-peak' "$M/settings.json"
  check "merge: deepseek provider set" \
    grep -q '"defaultProvider": "deepseek"' "$M/settings.json"
  check "merge: user's own keys kept" grep -q '"theme": "light"' "$M/settings.json"
  check "merge: valid json" \
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$M/settings.json"
  M2="$TMP/merge-empty"; mkdir -p "$M2"
  python3 "$MERGE" "$M2/settings.json" "$DS" >/dev/null 2>&1
  check "merge: works with no settings.json (fresh volume)" \
    grep -q 'npm:pi-deepseek-peak' "$M2/settings.json"
else
  echo "SKIP DeepSeek merge cases (no python3 on this machine)"
fi

# ===== version comparison (update-pi-sandbox.sh --status) ==================
# The updater must rebuild exactly when a release differs from the version
# baked into the image, and stay quiet when curl fails (offline / rate limit).
VS="$TMP/vs"; mkdir -p "$VS"; cp "$SRC/update-pi-sandbox.sh" "$VS/"
VSSTUB="$TMP/vsstub"; mkdir -p "$VSSTUB"
cat > "$VSSTUB/docker" <<'STUB'
#!/bin/sh
case "$*" in
  *"version --format"*) exit 0 ;;
  *"pi --version; rtk --version"*)
    printf '%s\nrtk %s\n' "${STUB_PI_IMAGE:-1.2.0}" "${STUB_RTK_IMAGE:-1.0.0}" ;;
esac
exit 0
STUB
cat > "$VSSTUB/curl" <<'STUB'
#!/bin/sh
case "$*" in
  *github*)
    [ -n "${STUB_RTK_LATEST:-}" ] || exit 22
    printf '{\n  "tag_name": "v%s"\n}\n' "$STUB_RTK_LATEST" ;;
  *)
    [ -n "${STUB_PI_LATEST:-}" ] || exit 22
    printf '{"version":"%s"}\n' "$STUB_PI_LATEST" ;;
esac
STUB
chmod +x "$VSSTUB/docker" "$VSSTUB/curl"
status_case() {  # pi_image pi_latest rtk_image rtk_latest
  PATH="$VSSTUB:$PATH" STUB_PI_IMAGE="$1" STUB_PI_LATEST="$2" \
    STUB_RTK_IMAGE="$3" STUB_RTK_LATEST="$4" "$VS/update-pi-sandbox.sh" --status
}
check "status: same versions -> up-to-date" \
  test "$(status_case 1.2.0 1.2.0 1.0.0 1.0.0)" = "up-to-date"
check "status: new pi -> stale pi" \
  test "$(status_case 1.2.0 1.3.0 1.0.0 1.0.0)" = "stale:pi v1.3.0"
check "status: new rtk -> stale rtk" \
  test "$(status_case 1.2.0 1.2.0 1.0.0 1.1.0)" = "stale:rtk v1.1.0"
check "status: both new -> both named" \
  test "$(status_case 1.2.0 1.3.0 1.0.0 1.1.0)" = "stale:pi v1.3.0 + rtk v1.1.0"
# network down / GitHub rate limit: an empty latest version must never be
# treated as a difference, or every launch would rebuild.
check "status: curl fails -> up-to-date (never blocks a launch)" \
  test "$(status_case 1.2.0 '' 1.0.0 '')" = "up-to-date"
DOCKER_DOWN="$TMP/dockerdown"; mkdir -p "$DOCKER_DOWN"
printf '#!/bin/sh\nexit 1\n' > "$DOCKER_DOWN/docker"; chmod +x "$DOCKER_DOWN/docker"
check "status: docker down -> up-to-date (never blocks a launch)" \
  test "$(PATH="$DOCKER_DOWN:$PATH" "$VS/update-pi-sandbox.sh" --status)" = "up-to-date"
# pi and rtk used to be probed by two separate `docker run` (2 x ~0.3-1 s dead
# time per launch); they are now read from a single container start.
CNT="$TMP/vscount"; mkdir -p "$CNT"
cat > "$CNT/docker" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$COUNT_FILE"
case "$*" in
  *"version --format"*) exit 0 ;;
  *"pi --version; rtk --version"*) printf '1.2.0\nrtk 1.0.0\n' ;;
esac
exit 0
STUB
chmod +x "$CNT/docker"
: > "$TMP/vscount.args"
PATH="$CNT:$VSSTUB:$PATH" COUNT_FILE="$TMP/vscount.args" "$VS/update-pi-sandbox.sh" --status >/dev/null
check "status probes the image once (one docker run)" \
  test "$(grep -c 'pi --version; rtk --version' "$TMP/vscount.args")" = 1
# macOS ships BSD sed, where `\?` and `\+` in a basic regex are literals, not
# GNU repetition — that silently broke rtk_latest_version.
check "no GNU-only \\?/\\+ escapes in sed expressions (BSD sed)" \
  bash -c '[ -z "$(grep -nE "$1" "$2" | grep -v ":[[:space:]]*#")" ]' \
  _ 'sed[^|]*\\[?+]' "$SRC/update-pi-sandbox.sh"

# ===== ALLOWED path matching (pi.sh) =======================================
# Confinement matches the launch dir against ALLOWED: a folder inside an
# allowed path is confined to it, a sibling sharing the prefix (`proj` vs
# `proj-extra`) is not.
P3="$TMP/pi3"; mkdir -p "$P3/run" "$P3/allowed/proj/sub" "$P3/allowed/proj-extra"
cp "$SRC/pi.sh" "$P3/"
cat > "$P3/pi.conf" <<EOF
ALLOWED=("$P3/allowed/proj")
API_KEYS=()
IMAGE="pi-sandbox"
VOLUME="pi-agent-home"
RTK_VOLUME="rtk-data"
WORKSPACE="/workspace"
DOCKER_ARGS=()
EOF
printf '#!/bin/sh\nexit 0\n' > "$P3/update-pi-sandbox.sh"; chmod +x "$P3/update-pi-sandbox.sh"
run_pi3() { ( cd "$1" && printf 'n\n' | PATH="$STUB2:$PATH" ARGS_LOG="$TMP/docker.args" "$P3/pi.sh" ) >"$2" 2>&1; }
: > "$TMP/docker.args"
run_pi3 "$P3/allowed/proj/sub" "$TMP/pi3-confined.out"
check "inside an allowed folder: confined to it" \
  grep -qF "Confined to: $P3/allowed/proj" "$TMP/pi3-confined.out"
check "inside an allowed folder: mounted at its host path" \
  bash -c 'grep -qxF "$1" "$2"' _ "$P3/allowed/proj:$P3/allowed/proj" "$TMP/docker.args"
check "inside an allowed folder: workdir is the subfolder" \
  bash -c '[ "$(grep -A 1 -x -F -- "-w" "$1" | tail -1)" = "$2" ]' _ "$TMP/docker.args" "$P3/allowed/proj/sub"
: > "$TMP/docker.args"
run_pi3 "$P3/allowed/proj-extra" "$TMP/pi3-sibling.out"
check "sibling sharing the prefix is not confined" \
  grep -qF "not in ALLOWED" "$TMP/pi3-sibling.out"
check "sibling: allowed folders still mounted" \
  bash -c 'grep -qxF "$1" "$2"' _ "$P3/allowed/proj:/workspace/proj" "$TMP/docker.args"

# A trailing slash used to turn the pattern into `…/proj//*` (no match) and
# append the same folder to ALLOWED on every launch.
P4="$TMP/pi4"; mkdir -p "$P4/run" "$P4/allowed/proj/sub"
cp "$SRC/pi.sh" "$P4/"
cat > "$P4/pi.conf" <<EOF
ALLOWED=("$P4/allowed/proj/")
API_KEYS=()
IMAGE="pi-sandbox"
VOLUME="pi-agent-home"
RTK_VOLUME="rtk-data"
WORKSPACE="/workspace"
DOCKER_ARGS=()
EOF
printf '#!/bin/sh\nexit 0\n' > "$P4/update-pi-sandbox.sh"; chmod +x "$P4/update-pi-sandbox.sh"
( cd "$P4/allowed/proj/sub" && printf 'n\n' | PATH="$STUB2:$PATH" ARGS_LOG="$TMP/docker.args" "$P4/pi.sh" ) >"$TMP/pi4.out" 2>&1
check "trailing slash in ALLOWED still confines" \
  grep -qF "Confined to: $P4/allowed/proj" "$TMP/pi4.out"
check "trailing slash: folder not appended again" \
  test "$(grep -c 'allowed/proj' "$P4/pi.conf")" = 1

# ===== repo never mounted (pi.sh) =========================================
# ALLOWED naming the repo, or a parent of it, would let the agent rewrite
# pi.conf/pi.sh, which then run on the host at the next launch.
P5="$TMP/pi5"; mkdir -p "$P5" "$TMP/ok5" "$TMP/run5"
cp "$SRC/pi.sh" "$P5/"
cat > "$P5/pi.conf" <<EOF2
ALLOWED=("$TMP" "$P5" "$TMP/ok5")
API_KEYS=()
IMAGE="pi-sandbox"
VOLUME="pi-agent-home"
RTK_VOLUME="rtk-data"
WORKSPACE="/workspace"
DOCKER_ARGS=()
EOF2
printf '#!/bin/sh\nexit 0\n' > "$P5/update-pi-sandbox.sh"; chmod +x "$P5/update-pi-sandbox.sh"
: > "$TMP/docker.args"
( cd "$TMP/run5" && printf 'n\n' | PATH="$STUB2:$PATH" ARGS_LOG="$TMP/docker.args" "$P5/pi.sh" ) >"$TMP/pi5.out" 2>&1
check "repo parent is skipped, not mounted" \
  bash -c '! grep -q "^$1:" "$2" && ! grep -q "^$3:" "$2"' _ "$TMP" "$TMP/docker.args" "$P5"
check "repo parent: the legit folder is still mounted" \
  grep -qx "$TMP/ok5:/workspace/ok5" "$TMP/docker.args"
( cd "$P5" && printf 'y\n' | PATH="$STUB2:$PATH" "$P5/pi.sh" ) >"$TMP/pi5b.out" 2>&1
check "launching from the repo itself is refused" test $? -ne 0
check "launch from the repo: pi.conf untouched" test "$(grep -c "$P5" "$P5/pi.conf")" = 1

# ===== unsafe launch path (pi.sh) =========================================
# pi.conf is sourced: a folder named x$(cmd) written between double quotes
# would run cmd on the host at every launch.
P6="$TMP/pi6"; mkdir -p "$P6" "$TMP"'/bad$(touch '"$TMP"'/pwned)'
cp "$SRC/pi.sh" "$P6/"; cp "$P/pi.conf" "$P6/pi.conf"
printf '#!/bin/sh\nexit 0\n' > "$P6/update-pi-sandbox.sh"; chmod +x "$P6/update-pi-sandbox.sh"
cp "$P6/pi.conf" "$TMP/pi6.conf.orig"
( cd "$TMP"'/bad$(touch '"$TMP"'/pwned)' && printf 'y\n' | PATH="$STUB2:$PATH" "$P6/pi.sh" ) >"$TMP/pi6.out" 2>&1
check "unsafe launch path: refused" grep -q 'add it to pi.conf by hand' "$TMP/pi6.out"
check "unsafe launch path: pi.conf unchanged" cmp -s "$P6/pi.conf" "$TMP/pi6.conf.orig"

# ===== models.json mount (pi.sh) ===========================================
# Without :ro any session could edit the repo's models.json on the host, even
# when the repo is not in ALLOWED.
mkdir -p "$P3/config"; echo '{}' > "$P3/config/models.json"
: > "$TMP/docker.args"
run_pi3 "$P3/allowed/proj" "$TMP/pi3-models.out"
check "models.json is mounted read-only" \
  grep -qx "$P3/config/models.json:/root/.pi/agent/models.json:ro" "$TMP/docker.args"

# ===== ~ in ALLOWED (pi.sh) ================================================
# Bash does not expand ~ inside double quotes: "~/x" stayed a literal path that
# never matched and was never mounted.
P7="$TMP/pi7"; H7="$TMP/home7"; mkdir -p "$P7" "$H7/proj/sub"
cp "$SRC/pi.sh" "$P7/"; cp "$P/pi.conf" "$P7/pi.conf"
printf 'ALLOWED=("~/proj")\n' >> "$P7/pi.conf"
printf '#!/bin/sh\nexit 0\n' > "$P7/update-pi-sandbox.sh"; chmod +x "$P7/update-pi-sandbox.sh"
: > "$TMP/docker.args"
( cd "$H7/proj/sub" && printf 'n\n' | HOME="$H7" PATH="$STUB2:$PATH" ARGS_LOG="$TMP/docker.args" "$P7/pi.sh" ) >"$TMP/pi7.out" 2>&1
check "~ in ALLOWED: confines like \$HOME" grep -qF "Confined to: $H7/proj" "$TMP/pi7.out"
( cd "$TMP/run0" && printf 'n\n' | HOME="$H7" PATH="$STUB2:$PATH" ARGS_LOG="$TMP/docker.args" "$P7/pi.sh" ) >"$TMP/pi7b.out" 2>&1
check "~ in ALLOWED: fallback mount finds the folder" bash -c '! grep -q "folder not found" "$0"' "$TMP/pi7b.out"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
