# pi-sandbox — isolated pi under OrbStack (macOS)

Runs the [pi](https://github.com/earendil-works/pi-mono) agent in an isolated
Docker container: it only has access to **the folders you list**, plus the
Internet. Nothing else (home dir, `~/.ssh`, host `~/.pi/agent`…).

It's the macOS equivalent of a "compartmentalized Ubuntu WSL2" setup: a confined
Linux with only the working directories mounted.

---

## Prerequisites

- [OrbStack](https://orbstack.dev) (includes Docker engine), running:
  ```bash
  open -a OrbStack
  docker version   # should answer "server: x.y.z"
  ```

## Files

| File           | Purpose                                                     |
|----------------|-------------------------------------------------------------|
| `Dockerfile.pi` | Image: Node 24 (trixie) + pi + git + ripgrep + rtk |
| `install.sh`   | Setup: OrbStack + pi image + config + extensions + API keys |
| `update-pi-sandbox.sh` | Auto-update: checks pi.dev for a newer pi, rebuilds the image |
| `pi.conf`      | Config: allowed folders, API keys, docker options           |
| `pi.sh`        | Launches the container (reads `pi.conf`, triggers auto-update) |
| `config/settings.json` | Model defaults (no provider by default — pi asks on first run) |
| `config/settings.deepseek.json` | DeepSeek model defaults, installed only if you opt in |
| `README.md`    | This file                                                    |

## Installation (one time)

```bash
./install.sh
```

The script:
1. checks Docker (OrbStack or Docker Desktop) and starts it if needed
2. builds the pi image (Node 24 + pinned pi version — currently `0.84.2`,
   see `Dockerfile.pi`; `update-pi-sandbox.sh` bumps the pin on update)
3. installs the model config into the `pi-agent-home` volume: **no default
   provider** — pi asks you to pick a provider/model on first run; thinking
   level defaults to `high`
4. installs the predefined extensions (ponytail, pi-web-access,
   pi-plan-mode, pi-ask-mode)
5. installs the **rtk** hook (compresses bash output, up to ~90% fewer
   input tokens; pinned in `Dockerfile.pi`) and creates the `rtk-data`
   volume so rtk's history (`rtk gain` stats) survives container removal
6. **asks whether you want DeepSeek** — answer `y` and it installs the
   `pi-deepseek-peak` extension, restores the deepseek model defaults
   (`deepseek-v4-flash`) in the volume, and adds `DEEPSEEK_API_KEY` to
   `API_KEYS` in `pi.conf`
7. prints the commands to add the API keys matching your choice
   (`DEEPSEEK_API_KEY` only if you opted in; `TAVILY_API_KEY` is always
   optional) to your `~/.zshrc`/`~/.bashrc`
8. installs the `pi` launcher into `/usr/local/bin` so you can run it
   from any allowed folder

Re-running `./install.sh` rebuilds the image **with the same pinned pi version**
and reinstalls config + extensions. It does **not** update pi — updates happen
automatically at launch (see “Updating pi in the image” below). The DeepSeek
question is re-asked each run, and the volume `settings.json` is reset to the
template matching your answer (default, or deepseek if you opted in).

## Configuration

All configuration lives in **`pi.conf`**:

1. **Allowed folders** — the `ALLOWED` list:
   ```bash
   ALLOWED=(
     "$HOME/Workspace/projects/project_1"
     "$HOME/Workspace/projects/project_2"
   )
   ```
   Each folder appears under `/workspace/<folder-name>` inside the container.

2. **API keys** — the script automatically forwards the variables already
   defined in your shell among the `API_KEYS` list (`TAVILY_API_KEY`,
   `OPENAI_API_KEY`, plus `DEEPSEEK_API_KEY` if you opted in during
   install). Add your providers to this list.

3. **Other settings** — image, volumes, workdir (`IMAGE`, `VOLUME`,
   `RTK_VOLUME`, `WORKSPACE`) and extra docker options (`DOCKER_ARGS`, e.g.
   `--network none` to cut Internet access). `RTK_VOLUME` (default
   `rtk-data`) holds rtk's history so `rtk gain` keeps counting tokens
   across container recreations — same named-volume isolation as `VOLUME`.

> ⚠️ The host `~/.pi/agent` is **not** mounted (on purpose). Pi sessions,
> config and extensions live in the named volume `pi-agent-home`, isolated from
> the host. Same for rtk: its data lives in the named volume `rtk-data`
> (`/root/.local/share/rtk` inside the container), never in a host path.

## Usage

```bash
./pi.sh          # from the pi-sandbox folder
pi               # from anywhere (installed by install.sh into /usr/local/bin)
```

**If you run it from inside an allowed folder** (`ALLOWED` in `pi.conf`), the
container mounts **only that folder** at `/workspace` and pi starts inside it
(even in a subdirectory).

**If you run it from a non-allowed folder**, pi asks whether to add that folder
to `ALLOWED` in `pi.conf` — answer `y` and it's whitelisted and pi relaunches
confined to it. Answering no mounts all allowed folders under
`/workspace/<name>` and pi starts at `/workspace`.

Pi starts in `/workspace`. From the session you can:

- run shell commands with `!` (e.g. `!ls /workspace`)
- hot-load a freshly added extension with `/reload`

### Adding / removing an allowed folder

Mounts are fixed at container start. To change the list:

1. Edit `ALLOWED=` in `pi.conf`
2. Quit the session (`Ctrl-D`), relaunch `./pi.sh`

Sessions, config and extensions are preserved (volume `pi-agent-home`); only
the set of mounted folders changes.

---

## Installing extensions / packages

Two equivalent methods.

### From the pi session (recommended)

For an npm or git package (extensions, skills, prompt templates…):

```
!pi install npm:@author/package
!pi install git:github.com/user/repo
!pi install https://github.com/user/repo
```

For a single `.ts` file (global extension):

```
!curl -L -o ~/.pi/agent/extensions/my-ext.ts https://url/file.ts
```

Then reload without restarting:

```
/reload
```

### From the host

```bash
docker run --rm -v pi-agent-home:/root/.pi/agent pi-sandbox install npm:@author/package
```

Extensions are stored in the container's `~/.pi/agent/extensions/`
(= volume `pi-agent-home`): installed once, they persist across launches.
Packages installed via `pi install` are declared in
`~/.pi/agent/settings.json` (volume).

### Uninstalling

```
!pi uninstall npm:@author/package
```
or delete the relevant file in `~/.pi/agent/extensions/`.

> 🔒 Extensions run with the pi process permissions, so inside the container
> they cannot touch the host beyond the mounted folders. Only install
> sources you trust.

---

## Updating pi in the image

Updates are **automatic**: at each launch, `pi.sh` asks
`update-pi-sandbox.sh --status`, which compares the version baked in the image
against the latest release on pi.dev. If a newer release exists, the image is
rebuilt in the background (`update-pi-sandbox.log`, with a macOS notification
when done) — quit the session and relaunch `pi` to use it.

Manual alternatives:

```bash
./update-pi-sandbox.sh               # rebuild now (blocking)
# or
sed -i '' 's|@earendil-works/pi-coding-agent@[0-9.]*|@earendil-works/pi-coding-agent@X.Y.Z|' Dockerfile.pi
docker build -t pi-sandbox -f Dockerfile.pi .
```

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `failed to connect to the docker API ... orbstack` | `open -a OrbStack`, then retry |
| `⚠ folder not found: ...` at launch | Fix the path in `ALLOWED` |
| Pi doesn't see a folder | Check it's in `ALLOWED` **and** the container was relaunched after the edit |
| No API key found | Define the variable in your shell before `./pi.sh` |
