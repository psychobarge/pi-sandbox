# Changelog

All notable changes to this project are documented here.

## [0.1.2] — 2026-10-02

### Updated
- pi bumped to `1.0.4` in `Dockerfile.pi` (auto-update via
  `update-pi-sandbox.sh`).
- DeepSeek model defaults moved to the ids the built-in pi provider actually
  serves (`deepseek-flash`); `deepseek-v4-flash` is retired upstream.
- `ponytail` and `pi-deepseek-peak` now install from npm
  (`npm:@dietrichgebert/ponytail`, `npm:pi-deepseek-peak`) instead of their
  git URLs, in `install.sh` and both `config/settings*.json`.

### Added
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
