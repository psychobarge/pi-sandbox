# pi-sandbox

> Runs the [pi](https://github.com/earendil-works/pi-mono) coding agent in an
> isolated Docker container on macOS (OrbStack). The agent only sees **the
> folders you list** and the Internet — never your home dir, `~/.ssh` or host
> `~/.pi/agent`.

## Requirements

Any Docker engine works (OrbStack or Docker Desktop):

  ```bash
  open -a OrbStack
  docker version   # should answer "server: x.y.z"
  ```

## Files

| File | Purpose |
|------|---------|
| `Dockerfile.pi` | Image: Node 24 + pi + git + ripgrep + rtk |
| `install.sh` | One-time setup: image, config, extensions, launcher |
| `pi.sh` | Launches the container (reads `pi.conf`, checks for updates) |
| `update-pi-sandbox.sh` | Checks pi.dev for a newer pi, rebuilds the image |
| `pi.conf` | All configuration: allowed folders, API keys, docker options |
| `config/settings.json` | Model defaults (no provider by default — pi asks on first run) |
| `config/settings.deepseek.json` | DeepSeek model defaults (installed only if you opt in) |

## Install

```bash
./install.sh
```

What it does:

1. Checks Docker and starts OrbStack if needed.
2. Builds the pi image (Node 24, pi pinned at `0.84.2` — see `Dockerfile.pi`).
3. Installs the model config into the `pi-agent-home` volume (no default
   provider; thinking level `high`).
4. Installs the predefined extensions (ponytail, pi-web-access,
   pi-plan-mode, pi-ask-mode).
5. Installs the **rtk** hook (compresses bash output, up to ~90% fewer input
   tokens) and creates the `rtk-data` volume so its history survives
   container recreation.
6. Asks whether you want DeepSeek: `y` installs the `pi-deepseek-peak`
   extension, restores the deepseek model defaults and adds
   `DEEPSEEK_API_KEY` to `API_KEYS`.
7. Prints the `~/.zshrc`/`~/.bashrc` lines for the API keys
   (`TAVILY_API_KEY` is always optional).
8. Installs the `pi` launcher into `/usr/local/bin`.

Re-running `install.sh` rebuilds the image with the **same pinned version** and
resets the volume config. It does **not** update pi — updates happen at launch
(see below).

## Configuration

Everything lives in `pi.conf`:

```bash
ALLOWED=(                     # folders the container may see
  "$HOME/Workspace/projects/project_1"
)
API_KEYS=(TAVILY_API_KEY OPENAI_API_KEY)   # forwarded if defined in your shell
IMAGE="pi-sandbox"
VOLUME="pi-agent-home"        # sessions, config, extensions (persists)
RTK_VOLUME="rtk-data"         # rtk history
WORKSPACE="/workspace"
DOCKER_ARGS=(-e PI_SKIP_VERSION_CHECK=1)   # e.g. add --network none to cut the Internet
```

> ⚠️ Host `~/.pi/agent` is **never mounted**: pi sessions, config and
> extensions live in the `pi-agent-home` named volume; rtk history in
> `rtk-data`. Both are isolated from the host.

## Usage

```bash
./pi.sh        # from the pi-sandbox folder
pi             # from anywhere (installed by install.sh)
```

- **Inside an allowed folder** → the container mounts only that folder at
  `/workspace` and pi starts there (works from subdirectories).
- **Elsewhere** → pi asks whether to add the current folder to `ALLOWED`;
  answer `y` to whitelist it and relaunch confined to it, or `n` to mount all
  allowed folders under `/workspace/<name>`.

Inside the session: `!ls /workspace` runs shell commands, `/reload` hot-loads
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

## Updating pi

Automatic: at each launch, `pi.sh` compares the baked-in version against the
latest pi.dev release and rebuilds the image in the background
(`update-pi-sandbox.log`, macOS notification when done). Quit and relaunch to
use it.

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
| No API key found | Define the variable in your shell before `./pi.sh` |
