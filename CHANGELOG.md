# Changelog

All notable changes to this project are documented here.

## [Unreleased]

### Fixed
- A folder list or key list written on one line (`ALLOWED=("/a" "/b")`) is
  now edited correctly. The launcher used to "add" the folder without writing
  it, then relaunch in an endless prompt loop, and `install.sh` reported a key
  it never added. Both edits go through `append-array-entry.awk`, which finds
  the array's closing `)` by paren depth (one-line lists included).
- Answering `y` to the DeepSeek question on a re-run no longer overwrites
  `settings.json`: `install.sh` merges the DeepSeek defaults into it instead of
  copying the file over, so extensions added with `!pi install` survive
  (`config/merge-deepseek-settings.py`).

### Changed
- `install.sh` and `update-pi-sandbox.sh` now read `IMAGE`, `VOLUME` and
  `RTK_VOLUME` from `pi.conf` — the same file `pi.sh` reads — instead of
  hardcoding `pi-sandbox`/`pi-agent-home`/`rtk-data`. Renaming them used to
  build and populate one image/volume while the launcher started another.
- The rtk release tarball is now verified against a pinned SHA-256 before it is
  installed (`Dockerfile.pi`), instead of trusting a movable tag.
  `update-pi-sandbox.sh` repins both architectures' hashes from the release's
  `checksums.txt` when it bumps `RTK_VERSION`, and skips the bump if that file
  is unavailable.

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
