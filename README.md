# pi-sandbox

> Runs the [pi](https://github.com/earendil-works/pi-mono) coding agent in an
> isolated Docker container on macOS (OrbStack). The agent only sees **the
> folders you list** and the Internet — never your home dir, `~/.ssh` or host
> `~/.pi/agent`.

**Everything after `./install.sh` is automatic:** each `pi` launch checks for
new pi and rtk releases and rebuilds the image in the background if needed,
config and extensions persist across launches, and rtk compresses bash output —
no manual steps, just run `pi`.

## Requirements

Any Docker engine works (OrbStack or Docker Desktop):

  ```bash
  open -a OrbStack
  docker version   # should answer "server: x.y.z"
  ```

## Files

| File | Purpose |
|------|---------|
| `Dockerfile.pi` | Image: Node 24 + pi + git + ripgrep + rtk + Python 3.13 (pip, venv) |
| `install.sh` | One-time setup: image, config, extensions, launcher |
| `pi.sh` | Launches the container (reads `pi.conf`, checks for updates) |
| `update-pi-sandbox.sh` | Checks pi.dev + the rtk GitHub releases, bumps the pins and rebuilds the image |
| `pi.conf.example` | Configuration template (allowed folders, API keys, docker options) |
| `pi.conf` | Your **local, gitignored** config — copy the example and fill it in |
| `config/settings.json` | Model defaults (no provider by default — pi asks on first run) |
| `config/settings.deepseek.json` | DeepSeek model defaults (installed only if you opt in) |
| `config/merge-deepseek-settings.py` | Merges those defaults into `settings.json` without dropping your extensions |
| `config/models.json` | Per-model overrides (DeepSeek V4 Pro `low` thinking; mounted at every launch) |

## Install

```bash
./install.sh
```

What it does:

1. Checks Docker and starts OrbStack if needed.
2. Builds the pi image (Node 24, pi and rtk pinned — see `Dockerfile.pi`).
3. Seeds the model config into the `pi-agent-home` volume (no default
   provider; thinking level `high`); pi installs the extensions that config
   lists (ponytail, pi-web-access, pi-plan-mode, pi-ask-mode) on first launch.
4. Installs the **rtk** hook (compresses bash output, up to ~90% fewer input
   tokens — re-installed by `update-pi-sandbox.sh` after an rtk bump) and creates
   the `rtk-data` volume so its history survives container recreation.
5. Asks whether you want DeepSeek: `y` installs the `pi-deepseek-peak`
   extension (listed in the deepseek config), restores the deepseek model
   defaults and adds `DEEPSEEK_API_KEY` to `API_KEYS`.
6. Offers to store the API keys in the macOS Keychain (hidden input — nothing
   in your shell history, nothing in `~/.zshrc`). `TAVILY_API_KEY` is always
   optional.
7. Installs the `pi` launcher into `/usr/local/bin`.

Re-running `install.sh` rebuilds the image with the **same pinned version** and
keeps your volume config: an existing `settings.json`, and the extensions you
added to it, are left alone. It does **not** update pi — updates happen at launch
(see below).

## Configuration

Configuration is a **local** file, never committed:

```bash
cp pi.conf.example pi.conf   # then edit pi.conf
```

`pi.sh` creates `pi.conf` from the example automatically on first run if it is
missing. `pi.conf` is gitignored because it holds your personal folder paths —
keep private paths out of git. It looks like:

```bash
ALLOWED=(                     # folders the container may see
  "$HOME/Workspace/projects/project_1"
)
API_KEYS=(TAVILY_API_KEY OPENAI_API_KEY)   # shell env, else macOS Keychain (service pi-sandbox)
IMAGE="pi-sandbox"
VOLUME="pi-agent-home"        # sessions, config, extensions (persists)
RTK_VOLUME="rtk-data"         # rtk history
WORKSPACE="/workspace"
DOCKER_ARGS=(-e PI_SKIP_VERSION_CHECK=1)   # e.g. add --network none to cut the Internet
```

> ⚠️ Host `~/.pi/agent` is **never mounted**: pi sessions, config and
> extensions live in the `pi-agent-home` named volume; rtk history in
> `rtk-data`. Both are isolated from the host. Tool caches (`XDG_CACHE_HOME`)
> live in the volume too, so they survive across launches.

### API keys (macOS Keychain)

Keys are **not** exported in `~/.zshrc`: `pi.sh` reads them from the login
keychain and passes them to the container. The service is always `pi-sandbox`,
the account is the variable name:

```bash
security add-generic-password -U -s pi-sandbox -a TAVILY_API_KEY -w   # hidden prompt
security add-generic-password -U -s pi-sandbox -a OPENAI_API_KEY -w
security find-generic-password -s pi-sandbox -a TAVILY_API_KEY -w     # check
security delete-generic-password -s pi-sandbox -a TAVILY_API_KEY      # remove
```

`-w` last makes `security` prompt for the value (hidden input), so it never
appears in your shell history or in a process list. A key already exported in
the shell wins over the Keychain, which lets you override one key for a single
launch. In *Keychain Access* both items share the `pi-sandbox` label — the
account column tells them apart.

## Usage

```bash
./pi.sh        # from the pi-sandbox folder
pi             # from anywhere (installed by install.sh)
```

- **Inside an allowed folder** → the container mounts only that folder at its
  real path and pi starts there (works from subdirectories). The footer shows
  the actual location, e.g. `~/pi-sandbox (main)`, not a
  generic `workspace`.
- **Elsewhere** → pi asks whether to add the current folder to `ALLOWED`;
  answer `y` to whitelist it and relaunch confined to it, or `n` to mount all
  allowed folders under `/workspace/<name>`.

Inside the session: `!pwd` shows where you are (the real host path), `/reload` hot-loads
newly added extensions.

### Adding / removing an allowed folder

Mounts are fixed at container start: edit `ALLOWED=` in `pi.conf`, quit the
session (`Ctrl-D`), relaunch. Sessions and config are preserved — only the
mounts change.

## Extensions

From the pi session (recommended):

```
!pi install npm:@author/package
!pi install git:github.com/user/repo
!curl -L -o ~/.pi/agent/extensions/my-ext.ts https://url/file.ts
/reload
```

From the host:

```bash
docker run --rm -v pi-agent-home:/root/.pi/agent pi-sandbox install npm:@author/package
```

Extensions persist across launches (volume `pi-agent-home`). Uninstall with
`!pi uninstall npm:@author/package` or by deleting the file.

> 🔒 Extensions run with the pi process permissions: inside the container they
> can't touch the host beyond the mounted folders. Only install sources you
> trust.

## Updating pi & rtk

Automatic: at each launch, `pi.sh` compares the versions baked into the image
against the latest pi.dev release and the latest rtk GitHub release, and
rebuilds the image in the background if either is behind
(`update-pi-sandbox.log`, macOS notification when done). An rtk bump also
refreshes its pi hook (`~/.pi/agent/extensions/rtk.ts` is generated by the rtk
binary). Quit and relaunch to use the new image.

Manual:

```bash
./update-pi-sandbox.sh    # rebuild now (blocking)
```

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `failed to connect to the docker API ... orbstack` | Open OrbStack / Docker Desktop, retry |
| `⚠ folder not found: ...` | Fix the path in `ALLOWED` |
| Pi doesn't see a folder | Check `ALLOWED` and relaunch after the edit |
| Key ignored / provider not authenticated | Check `security find-generic-password -s pi-sandbox -a <KEY> -w`; if macOS re-asks for permission on every launch, click *Always Allow* or recreate the item |
