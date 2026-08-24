# Changelog

All notable changes to this project are documented here.

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
