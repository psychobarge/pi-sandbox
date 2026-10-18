# pi-sandbox 1.0.0

Run the [pi](https://github.com/earendil-works/pi-mono) coding agent in a
Docker container on macOS. The agent sees **only the folders you allow** —
not your home directory, not `~/.ssh`, not your host `~/.pi/agent`, and never
your API keys. It has limits: see
[what the sandbox does not protect](#what-the-sandbox-does-not-protect).

Also available for Windows / PowerShell:
[pi-sandbox-windows](https://github.com/psychobarge/pi-sandbox-windows),
at the same security level.

## Quick start

Requires Docker ([OrbStack](https://orbstack.dev) or Docker Desktop).

```bash
git clone https://github.com/psychobarge/pi-sandbox && cd pi-sandbox
./install.sh
```

The installer builds the image, asks for your API keys (stored in the macOS
Keychain) and installs the `pi` command. Then, from any project:

```bash
cd ~/my-project
pi
```

The first time, pi asks to add the folder to the allowed list. Answer `y`.
That's it.

## Configuration

Everything lives in `pi.conf` (created from `pi.conf.example`, gitignored):

```bash
ALLOWED=(                     # folders the agent may see
  "$HOME/my-project"
)
API_KEYS=(DEEPSEEK_API_KEY OPENAI_API_KEY TAVILY_API_KEY)
```

Edit it, quit pi (`Ctrl-D`) and relaunch. Sessions, settings and extensions are
kept across launches. `pi.conf.example` lists every proxied key, commented out:
uncomment the ones you use and re-run `./install.sh` to store them.

To add or change a key later:

```bash
security add-generic-password -U -s pi-sandbox -a OPENAI_API_KEY -w
```

A key exported in your shell **overrides the Keychain** for that launch. This is
not safe: the key sits in plain text in your shell config or history, readable by
any program on your Mac. **Use the Keychain to keep your keys secure.**

## Extensions

Install them from inside a pi session, then reload:

```
!pi install npm:@author/package
/reload
```

Extensions run with the agent's permissions: only install what you trust.

## Updates

Automatic. Each launch checks for new pi and rtk releases and rebuilds the
image in the background; relaunch to use it. To update right away:

```bash
./update-pi-sandbox.sh
```

## How it works

- **Isolation** — only the folders in `ALLOWED` are mounted, at their real path.
  pi's data lives in Docker volumes, never in your host `~/.pi`.
- **Keys stay outside** — the container only sees the value `proxy`. A small
  sidecar ([`proxy/keyproxy.mjs`](proxy/keyproxy.mjs)) adds the real key to
  requests sent to the provider. The agent can use a key but not read it.
  Proxied keys: `TAVILY_API_KEY` and, for pi's providers, `DEEPSEEK_API_KEY`,
  `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`, `GROQ_API_KEY`,
  `CEREBRAS_API_KEY`, `XAI_API_KEY`, `MISTRAL_API_KEY`, `TOGETHER_API_KEY`,
  `NVIDIA_API_KEY`, `HF_TOKEN`, `MOONSHOT_API_KEY` (moonshot.ai only),
  `ZAI_API_KEY`, `KIMI_API_KEY`, `MINIMAX_API_KEY`, `BASETEN_API_KEY`,
  `META_API_KEY`, `XIAOMI_API_KEY`, `ANT_LING_API_KEY`,
  `QWEN_TOKEN_PLAN_API_KEY`. OpenRouter, Fireworks, OpenCode and the cloud
  providers (Bedrock, Vertex, Azure, Cloudflare) are not proxied yet.
- **Fewer tokens** — [rtk](https://github.com/rtk-ai/rtk) compresses the output
  of shell commands.

## What the sandbox does not protect

- **Files in allowed folders** are readable: `.env`, tokens, credentials. Keep
  secrets out of them.
- **Keys can be spent.** The agent could call any proxied provider, whatever
  model you picked: with a DeepSeek and an OpenAI key, a session on a DeepSeek
  model can still call the OpenAI API. **This is true of pi without the sandbox
  too** (there it can even read the keys). Keep only the keys you use and set a
  spending cap on each.
- **Keys without a proxy route** (anything not in the list above) are passed to the agent as plain env vars. pi warns you at launch.
- **Never use `/login` in pi**: it saves the key where the agent can read it.
- **Written files can run on your Mac**: git hooks, `.envrc`, `package.json`
  scripts… Review the agent's changes before running anything.

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `failed to connect to the docker API` | Start OrbStack / Docker Desktop |
| `⚠ folder not found` | Fix the path in `ALLOWED` |
| pi doesn't see a folder | Add it to `ALLOWED`, then relaunch |
| Provider not authenticated | `security find-generic-password -s pi-sandbox -a <KEY> -w` should print the key |
| macOS asks for Keychain access every launch | Click *Always Allow* |

## License

[MIT](LICENSE)
