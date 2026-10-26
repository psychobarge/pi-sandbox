# Changelog

All notable changes to this project are documented here.

## [1.2.0] — 2026-10-26

### Added
- 18 more providers are proxied like DeepSeek, OpenAI and Tavily: Anthropic,
  Ant Ling, Baseten, Cerebras, Gemini, Groq, Hugging Face (`HF_TOKEN`), Kimi
  Coding, Meta, MiniMax, Mistral, Moonshot AI, NVIDIA, Qwen Token Plan,
  Together AI, xAI, Xiaomi MiMo and Z.ai. Add the name to `API_KEYS` and the
  agent only sees `proxy`; before, these keys were passed as plain env vars.
  Each route uses the base URL of pi 1.4.0's own provider. The README lists
  the supported keys. OpenRouter is not proxied: pi sends its `anthropic/*`
  models to a different base path, which one proxy route cannot serve.
- The proxy route table now lives in `pi.sh` only. The sidecar checks it at
  startup (https only, no userinfo, query or fragment, one-segment prefix)
  and refuses to start on any error.

### Changed
- pi bumped `1.3.0` → `1.4.0` and rtk `v1.0.1` → `v1.1.0` in `Dockerfile.pi`.
- `config/models.json` points the new providers at the proxy. If you edited
  this file, merge the new `baseUrl` entries when you pull.
- The sidecar puts the real key where the client sent `proxy`
  (`Authorization: Bearer`, `x-api-key` or `x-goog-api-key`) instead of always
  forcing `Authorization: Bearer`. Any other credential, such as a `/login`
  token, is forwarded unchanged, and a provider without a loaded key is
  forwarded too instead of answering 404: `/login` keeps working while the
  sidecar runs (it is still not recommended).

### Fixed
- A sidecar that fails at startup now shows its error. It ran with `--rm`, so
  its logs were gone before the launcher read them, and the launcher waited
  the full 5 s instead of stopping as soon as it exited.

## [1.1.0] — 2026-10-16

### Fixed
- The DeepSeek settings merge no longer loses data: an invalid `settings.json`
  (e.g. a trailing comma) now stops the script instead of being rewritten with
  only the DeepSeek keys, and `enabledModels` is merged like `packages` instead
  of replaced.
- `install.sh` no longer stops silently when the Keychain write fails (locked
  keychain, SSH session): under `set -e` that aborted the install before the
  `pi` launcher was created. It now prints how to add the key later and goes on.
- A leading `~` in an `ALLOWED` entry (`"~/proj"`) is now expanded to `$HOME`:
  inside double quotes bash leaves it literal, so the folder never confined,
  never mounted and was offered for addition again at every launch.
- `config/models.json` is now bind-mounted read-only: a session could edit the
  repo's file on the host (provider, base URL) even when the repo was not in
  `ALLOWED`.
- Answering `y` to "Add this folder to ALLOWED" in a folder whose path contains
  `"`, `$`, a backtick or `\` is now refused: the path was written unescaped
  into the sourced `pi.conf`, so a folder named `x$(cmd)` ran `cmd` on the host
  at every launch.
- rtk updates work again: the `checksums.txt` download did not follow GitHub's
  redirect (`curl` without `-L` returned an empty body with exit 0), so the
  updater never found the hashes and never bumped rtk.
- `pi.sh` never mounts the pi-sandbox repo or a folder containing it, even if
  `ALLOWED` lists it: the agent could rewrite `pi.conf`/`pi.sh` and get them
  executed on the host at the next launch. A folder inside the repo (its
  `.git` hooks run on the host) is refused too, and the check resolves
  symlinks and ignores case (APFS). Launching from the repo is refused, and the
  example config no longer lists the repo.
- A folder list or key list written on one line (`ALLOWED=("/a" "/b")`) is
  now edited correctly. The launcher used to "add" the folder without writing
  it, then relaunch in an endless prompt loop, and `install.sh` reported a key
  it never added. Both now append `ALLOWED+=("…")` / `API_KEYS+=(…)` at the end
  of the sourced `pi.conf`, which works whatever the list's layout.
- Answering `y` to the DeepSeek question on a re-run no longer overwrites
  `settings.json`: `install.sh` merges the DeepSeek defaults into it instead of
  copying the file over, so extensions added with `!pi install` survive
  (`config/merge-deepseek-settings.py`).
- `install.sh` no longer ends in an error on a fresh clone: it creates the
  gitignored `logs/` directory before the 30-day retention `find`, which used
  to fail on the missing directory and, under `set -e`, report an install that
  had actually succeeded as failed.

### Added
- **keyproxy**: the model and web-search keys (DEEPSEEK/OPENAI/TAVILY) no
  longer enter the pi container. `pi.sh` starts a sidecar
  (`proxy/keyproxy.mjs`, Node stdlib) on a private per-session docker network
  and passes pi the dummy value `proxy`; the sidecar injects the real key in the
  outbound `Authorization` header. The route table is fixed
  (`/deepseek`, `/openai`, `/tavily`), unknown paths get a 404, redirects are
  not followed, the port is never published and the sidecar is removed on exit
  (Ctrl-C included) with orphan cleanup at the next launch. `API_KEYS` entries
  without a route are still forwarded as plain env vars, with a warning.
- GitHub Actions workflow running `./test-pi-sandbox.sh` on every push and PR.
- README: a "What the sandbox does not protect" section (what the agent can
  still read: secrets in the mounted folders and in the volumes, keys without a
  proxy route; files it writes in an allowed repo can run on the host
  through git hooks and editor/shell tooling).
- Numerous unit tests for the launcher, the installer and the update script
  (`test-pi-sandbox.sh`), runnable with `./test-pi-sandbox.sh` (no Docker, no network).

### Changed
- The "pi session exited with error" log line now includes the image id, so
  codes like 137 or 127 can be tied to a given build.
- The pre-launch version probes time out after 2 s instead of 5 s, so a
  dropping network delays pi's start by less.
- `update-pi-sandbox.sh` no longer resolves symlinks: nothing launches it
  through one.
- `pi.sh` passes the launch folder straight to `-w` instead of rebuilding it
  from the allowed folder; the old unquoted pattern gave a wrong workdir for
  paths containing `[` or `*`.
- `install.sh` and `update-pi-sandbox.sh` now read `IMAGE`, `VOLUME` and
  `RTK_VOLUME` from `pi.conf` — the same file `pi.sh` reads — instead of
  hardcoding `pi-sandbox`/`pi-agent-home`/`rtk-data`. Renaming them used to
  build and populate one image/volume while the launcher started another.
- The rtk release tarball is now verified against a pinned SHA-256 before it is
  installed (`Dockerfile.pi`), instead of trusting a movable tag.
  `update-pi-sandbox.sh` repins both architectures' hashes from the release's
  `checksums.txt` when it bumps `RTK_VERSION`, and skips the bump if that file
  is unavailable.
- `config/models.json` points the deepseek and openai providers at
  `http://keyproxy:8787/deepseek` and `http://keyproxy:8787/openai`: both are
  only reachable through the launcher (the sidecar).
- `pi.sh` now runs its `Authorization: Bearer proxy` path only when a key with a
  proxy route is configured; without one, no sidecar and no extra network.

### Updated
- pi bumped `1.2.0` → `1.3.0` and rtk `v1.0.0` → `v1.0.1` in `Dockerfile.pi`
  (rtk SHA-256 pins refreshed).

### Security
- **Rotate the DeepSeek/OpenAI/Tavily keys once after upgrading.** Earlier
  sessions held them in the container environment and the `pi-agent-home`
  transcripts may contain them, so the proxy would otherwise protect keys that
  are already exposed.

## [1.0.0] — 2026-10-15

First stable release. Covers everything since 0.1.1; the intermediate 0.1.2,
0.2.0, 0.2.1 and 0.2.2 drafts were never published.

### Changed
- **Breaking**: API keys no longer live in `~/.zshrc`. `pi.sh` reads them from
  the macOS Keychain (service `pi-sandbox`, account = variable name, e.g.
  `-a TAVILY_API_KEY`) and forwards them to the container. A variable already
  exported in the shell still wins (one-off override); on a machine without
  `security` only the shell env is used, as before.
  Migration from items created as `-s deepseek-api-key -a "$USER"`:
  `security add-generic-password -U -s pi-sandbox -a DEEPSEEK_API_KEY -w "$(security find-generic-password -s deepseek-api-key -a "$USER" -w)"`
  (same for `TAVILY_API_KEY`/`tavily-api-key`), then delete the old items and
  the `export` lines in `~/.zshrc`.
  Alternatively, re-run `./install.sh` for each key.
- `install.sh` stores the keys in the Keychain with a hidden prompt instead of
  printing `export` lines for the shell rc (nothing in the history, nothing in
  `ps`, no file on disk).
- `pi.sh` announces updates with the pi/rtk label instead of pi only.
- DeepSeek model defaults moved to the ids the built-in pi provider actually
  serves (`deepseek-flash`); `deepseek-v4-flash` is retired upstream.
- `ponytail` and `pi-deepseek-peak` now install from npm
  (`npm:@dietrichgebert/ponytail`, `npm:pi-deepseek-peak`) instead of their
  git URLs, in `install.sh` and both `config/settings*.json`.
- The tracked `pi.conf` is gone: it held personal folder paths and had leaked
  them through history. `pi.conf` is now gitignored, `pi.conf.example` ships as
  the template, and `pi.sh` recreates `pi.conf` from the example when missing.
  Existing installs keep their local `pi.conf` untouched.

### Added
- Python 3.13 in the image (`python3`, `python`, `pip`, `venv` from Debian
  trixie) — for the agent's throwaway helper scripts, not for running a
  project's dependencies.
- `update-pi-sandbox.sh` now follows pi **and** rtk: it compares the versions
  baked into the image against pi.dev and the latest rtk GitHub release, bumps
  the matching pin and rebuilds once. After an rtk bump it also re-installs the
  pi hook (`rtk init -g --agent pi --auto-patch`) — the extension file is an
  rtk-generated template and changed in rtk 1.0.0.

### Updated
- **rtk** bumped `0.44.2` → `1.0.0` in `Dockerfile.pi`. Default edition kept
  (Apache-2.0 + BUSL-1.1, compression engine included; `rtk-oss` is the engine-less
  Apache-2.0 build). Asset names and the history path
  (`~/.local/share/rtk/history.db`) are unchanged.
- pi bumped to `1.0.4` in `Dockerfile.pi` (auto-update via
  `update-pi-sandbox.sh`).
- `pi.sh` sets `XDG_CACHE_HOME` into the `pi-agent-home` volume: tool caches
  would otherwise be re-downloaded on every launch (ephemeral container).
- `pi.sh` bind-mounts `config/models.json` at launch. It now holds only the
  `deepseek-v4-pro` `low` thinking-level override, which pi's catalog still
  lacks. The duplicated `deepseek-flash` model entry was dropped: it replaced
  the built-in entry and silently lost `compat.supportsStrictMode`.
- `defaultTools: ["+grep", "+find", "+ls"]` in both settings files.

### Removed
- `hideThinkingBlock` (pi's default) and `lastChangelogVersion` (pi-managed)
  from the settings templates.

> Migration: run `./update-pi-sandbox.sh` once (rebuild + hook refresh), or
> `./install.sh`. A bare `docker build` refreshes the binaries but not the hook.
> Python is only picked up by an image rebuild.

> Upstream breaking changes with no impact on this repo: `rtk proxy` is now
> `rtk bypass` (old name kept as an alias), `--ultra-compact` removed, `rtk gain`
> excludes oversized outputs from its headline rate. Neither flag/command is
> used here.

## [0.1.1] — 2026-08-24

### Changed
- `pi.sh` mounts the confined folder at its real host path instead of
  `/workspace`, so pi's footer shows the actual folder (e.g.
  `~/pi-sandbox (main)`) instead of a generic `workspace`.

### Updated
- pi bumped to `0.84.3` in `Dockerfile.pi` (auto-update via
  `update-pi-sandbox.sh`).

## [0.1.0] — 2026-08-24

Initial release: isolated pi sandbox under OrbStack (macOS).

### Added
- `install.sh`: checks/starts Docker (OrbStack or Docker Desktop), builds the
  `pi-sandbox` image (Node 24 + pinned pi), installs model config, extensions
  and the rtk hook into the persistent `pi-agent-home` volume, creates the
  `rtk-data` volume, and installs the `pi` launcher into `/usr/local/bin`.
- DeepSeek opt-in at the end of `install.sh`: answering `y` installs the
  `pi-deepseek-peak` extension, restores the deepseek model defaults
  (`deepseek-v4-flash`) and adds `DEEPSEEK_API_KEY` to `API_KEYS` in `pi.conf`.
- `pi.sh`: launches pi in a container confined to the allowed folders from
  `pi.conf` (whitelist prompt when launched elsewhere), forwards configured
  API keys, auto-updates the image in the background when a newer pi release
  exists, and logs host-side errors to `logs/`.
- `update-pi-sandbox.sh`: checks pi.dev for newer releases, bumps the pi pin in
  `Dockerfile.pi` and rebuilds the image (self-healing on failed builds).
- `Dockerfile.pi`: Node 24 (trixie) image with pi, git, ripgrep and rtk pinned.
- Default extensions: ponytail, pi-web-access, pi-plan-mode, pi-ask-mode.
