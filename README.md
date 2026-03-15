# dvim — Docker-powered Neovim + LazyVim

**dvim** (Docker Vim) is a fully baked, portable Neovim + LazyVim IDE packed into a single Docker image. Pull it and run from anywhere — no installation of Neovim, LSPs, or plugins required.

[![Docker Hub](https://img.shields.io/docker/pulls/ashminbhattarai/dvim?label=Docker%20Pulls&logo=docker)](https://hub.docker.com/r/ashminbhattarai/dvim)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

---

## Features

- **Zero local dependencies** — only Docker required
- **LazyVim defaults** — 32 plugins baked in, sensible IDE defaults out of the box
- **50 treesitter parsers** — pre-compiled, instant startup
- **LSPs ready to go** — `lua-language-server`, `pyright`, `typescript-language-server`
- **Python venv auto-detection** — pyright configured automatically for `.venv/` and `venv/`
- **Persistent state** — undo history, marks, and sessions survive container restarts
- **User & project config** — customize via plain Lua files, no rebuild needed
- **UID/GID remapping** — files you create inside the container are owned by you on the host

---

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) (daemon must be running)
- `git` and `curl` (for the installer)

---

## Quick Install

```bash
curl -fsSL https://get.dvim.ashmin.info.np/install.sh | bash
```

Install a specific version tag:

```bash
curl -fsSL https://get.dvim.ashmin.info.np/install.sh | bash -s v1.0
```

The installer:
1. Pulls the `ashminbhattarai/dvim` Docker image
2. Clones the repo to `~/.local/share/dvim/repo`
3. Installs the `dvim` launcher to `~/.local/bin/dvim`
4. Adds `~/.local/bin` to `PATH` in `~/.bashrc`
5. Creates a starter config at `~/.config/dvim/user.lua`
6. Creates persistent state directories under `~/.local/share/dvim/`

After install, open a new terminal (or run `source ~/.bashrc`) and you're ready.

---

## Usage

```bash
dvim                  # open Neovim in the current directory
dvim myfile.py        # open a specific file
dvim .                # open current directory explicitly
dvim update           # pull latest image + update launcher
dvim update v1.0      # update to a specific tag
```

> dvim mounts your current directory into the container at the same absolute path, so all file references, LSP paths, and Python venv paths match the host exactly.

---

## Configuration

### System-wide config

`~/.config/dvim/user.lua` — loaded on every dvim launch.

```lua
-- ~/.config/dvim/user.lua
vim.opt.relativenumber = true
vim.opt.scrolloff = 8

vim.keymap.set("n", "<leader>q", "<cmd>q<cr>", { desc = "Quit" })
```

### Project-specific config

`.dvim.lua` in your project root — loaded after `user.lua`, highest priority.

```lua
-- .dvim.lua (project root)
vim.opt.tabstop = 4
vim.opt.shiftwidth = 4
```

Neither file requires rebuilding the image — changes take effect on the next `dvim` launch.

---

## Python Venv Support

dvim auto-detects Python virtual environments and configures pyright accordingly:

| Condition | Behavior |
|---|---|
| `.venv/` found in project root | pyright configured automatically |
| `venv/` found in project root | pyright configured automatically |
| `pyrightconfig.json` exists | used as-is (user-managed) |
| `[tool.pyright]` in `pyproject.toml` | pyright reads natively |
| None of the above | global Python, no extra config |

The generated pyright config is written to `/tmp/pyrightconfig.json` inside the container only — your project directory is never modified.

---

## Persistent State

State directories are mounted from the host so they survive container restarts:

| Host path | Container path | Contents |
|---|---|---|
| `~/.local/share/dvim/state` | `~/.local/state/nvim` | undo history, sessions |
| `~/.local/share/dvim/shada` | `~/.local/share/nvim/shada` | marks, command history |
| `~/.local/share/dvim/swap` | `~/.local/state/nvim/swap` | swap files |

---

## What's Baked In

| Component | Version |
|---|---|
| Neovim | 0.11.2 |
| Node.js | 22.14.0 LTS |
| LazyVim | latest (32 plugins) |
| Treesitter parsers | 50 pre-compiled |
| lua-language-server | via Mason |
| pyright | via Mason |
| typescript-language-server | via Mason |
| ripgrep, fd, fzf | latest |

---

## Building Locally

```bash
# Standard build
docker build -t ashminbhattarai/dvim:latest .

# Force full rebuild (no cache)
docker build --no-cache -t ashminbhattarai/dvim:latest .

# Run the integration test suite (requires Docker)
bash test.sh ashminbhattarai/dvim:latest
```

### Quick entrypoint-only update (no full rebuild)

```bash
docker create --name dvim-temp ashminbhattarai/dvim:latest
docker cp entrypoint.sh dvim-temp:/entrypoint.sh
docker commit dvim-temp ashminbhattarai/dvim:latest
docker rm dvim-temp
```

---

## Project Structure

```
dvim/
├── Dockerfile              # 4-stage multi-stage build
├── entrypoint.sh           # UID/GID remapping + venv detection
├── install.sh              # One-command installer
├── ts_compile.lua          # Headless treesitter parser compilation
├── blink-override.lua      # Forces blink.cmp to use Lua impl
├── pyright-override.lua    # Pyright LSP venv config via env var
├── launcher/
│   └── dvim                # Launcher script → ~/.local/bin/dvim
├── nvim-config/
│   └── lua/config/
│       ├── user.lua        # Stub — loads dvim.user + dvim.project
│       └── options.lua     # LazyVim options entry point
└── docs/
    ├── index.html          # Landing page (GitHub Pages)
    └── CNAME               # dvim.ashmin.info.np
```

---

## License

[MIT](LICENSE)
