# CLAUDE.md — dvim Project Context

This file summarizes the full conversation and current state of the dvim project
so development can be resumed in a new session without losing context.

---

## What is dvim?

**dvim** (Docker Vim) is a fully baked, portable Neovim + LazyVim IDE packed into
a single Docker image. The goal is VSCode-like portability — pull and run instantly
from anywhere, with optional user and project-level config via simple Lua files.

- **Docker Hub:** `ashminbhattarai/dvim:latest`
- **GitHub:** `https://github.com/ashmin-bhattarai/dvim`
- **Landing page:** `https://dvim.ashmin.info.np`
- **Install script:** `https://dvim.ashmin.info.np/install.sh`
- **Domain registrar/CDN:** Cloudflare (domain: ashmin.info.np)

---

## Repo Structure

```
dvim/
├── Dockerfile                        # 4-stage multi-stage build
├── entrypoint.sh                     # UID/GID remapping + venv detection
├── ts_compile.lua                    # Headless treesitter parser compilation
├── blink-override.lua                # Forces blink.cmp to use Lua impl
├── pyright-override.lua              # Pyright LSP venv config via env var
├── install.sh                        # One-command installer
├── test.sh                           # Integration test suite (40 tests)
├── launcher/
│   └── dvim                          # Launcher script → ~/.local/bin/dvim
├── nvim-config/
│   └── lua/
│       └── config/
│           ├── user.lua              # Baked stub — loads dvim.user + dvim.project
│           └── options.lua           # LazyVim options entry point
└── docs/
    ├── index.html                    # Landing page (GitHub Pages)
    └── CNAME                         # dvim.ashmin.info.np
```

---

## Docker Image Details

### Base
- `debian:stable-slim`

### Build stages
1. **nvim-installer** — downloads Neovim v0.11.2 tarball from GitHub
2. **node-installer** — downloads Node.js v22.14.0 tarball from nodejs.org
3. **builder** — full build env with `build-essential`; installs plugins, LSPs,
   compiles treesitter parsers. build-essential is NOT copied to final image.
4. **final** — lean runtime image; copies artifacts from builder

### What's baked in
- Neovim 0.11.2 with LuaJIT
- LazyVim defaults (32 plugins)
- 50 treesitter parsers (compiled .so files at `~/.local/share/nvim/site/parser/`)
- LSPs via Mason: `lua-language-server`, `pyright`, `typescript-language-server`
- Companion tools: `ripgrep`, `fd`, `fzf`, `git`, `node`, `python3`, `tree-sitter`
- blink.cmp configured to use Lua fuzzy implementation (no binary download)

### Image size
~975MB

### Key paths inside container
```
/opt/nvim/                                    Neovim binary
/opt/node/                                    Node.js runtime
/home/devuser/.config/nvim/                   LazyVim config (baked)
/home/devuser/.config/nvim/lua/config/user.lua  Stub that loads dvim.user + dvim.project
/home/devuser/.config/nvim/lua/dvim/          Mount point for runtime configs
/home/devuser/.local/share/nvim/lazy/         Plugins
/home/devuser/.local/share/nvim/mason/        LSPs
/home/devuser/.local/share/nvim/site/parser/  Treesitter .so files
/entrypoint.sh                                Startup script
/workspace                                    Symlink → actual project path
```

---

## entrypoint.sh Responsibilities

Runs as root, then drops to devuser via gosu:

1. Reads `HOST_PROJECT_PATH` env var (set by launcher)
2. Creates `/workspace` symlink → actual project path
3. Stats project dir to get host UID/GID
4. Remaps `devuser` UID/GID to match (only chowns home if remapping occurred)
5. Detects Python venv in project root:
   - Checks for `.venv/` or `venv/` dir
   - Skips if `pyrightconfig.json` or `[tool.pyright]` in `pyproject.toml` exists
   - Detects actual Python version from venv binary (avoids hardcoded version mismatch)
   - Generates `/tmp/pyrightconfig.json` inside container only (never modifies host)
   - Exports `DVIM_PYRIGHT_CONFIG` and `DVIM_PROJECT_PATH` env vars
6. `exec gosu devuser nvim "$@"`

---

## launcher/dvim Responsibilities

Installed to `~/.local/bin/dvim` on the host.

Key behaviors:
- Mounts project at **same absolute path** as host (e.g. `/home/user/myapp:/home/user/myapp`)
  so venv paths, LSP references, and absolute paths all match
- Passes `HOST_PROJECT_PATH=$(pwd)` to container
- Mounts `~/.config/dvim/user.lua` if it exists (system-wide config)
- Mounts `./.dvim.lua` if it exists (project config)
- Mounts persistent state dirs:
  - `~/.local/share/dvim/state` → `~/.local/state/nvim`
  - `~/.local/share/dvim/shada` → `~/.local/share/nvim/shada`
  - `~/.local/share/dvim/swap` → `~/.local/state/nvim/swap`
- Subcommand: `dvim update [tag]` — pulls latest image + updates launcher from repo

---

## Config System

### How it works
The baked `user.lua` stub at `~/.config/nvim/lua/config/user.lua` does:
```lua
pcall(require, "dvim.user")    -- system-wide config
pcall(require, "dvim.project") -- project config
```

The launcher mounts:
- `~/.config/dvim/user.lua` → `lua/dvim/user.lua` (if exists)
- `./.dvim.lua` → `lua/dvim/project.lua` (if exists)

### User config locations
```
~/.config/dvim/user.lua     system-wide (all projects)
./.dvim.lua                 project-specific (highest priority)
```

### Example user config
```lua
vim.opt.relativenumber = true
vim.opt.scrolloff = 8
vim.keymap.set("n", "<leader>q", "<cmd>q<cr>", { desc = "Quit" })
```

---

## Python Venv / Pyright Integration

### Problem solved
- Project mounted at same absolute path → paths match between host and container
- venv auto-detected → pyright configured automatically, no manual config needed
- Python version detected from venv binary → no version mismatch

### Detection priority
1. `.venv/` in project root → use it, detect Python version
2. `venv/` in project root → use it, detect Python version
3. `pyrightconfig.json` exists → use it as-is (user-managed)
4. `[tool.pyright]` in `pyproject.toml` → pyright reads natively
5. None found → global python (no config generated)

### Generated pyrightconfig.json (inside container only)
```json
{
  "pythonVersion": "3.13",   // detected from .venv/bin/python
  "venvPath": "/home/user/myapp",
  "venv": ".venv",
  "include": ["/home/user/myapp"],
  "exclude": [".venv", ".git", "__pycache__", ".mypy_cache"],
  "reportMissingImports": true,
  "reportMissingModuleSource": false
}
```

---

## Known Issues / Pending

### 1. Python version detection — PARTIALLY FIXED, needs rebuild
The entrypoint was updated to detect Python version from the venv binary instead
of hardcoding `3.12`. The fix is in `entrypoint.sh` but the Docker image cache
is not busting correctly.

**To fix:**
```bash
# Option A — commit on top of existing image (fast)
docker create --name dvim-temp ashminbhattarai/dvim:latest
docker cp entrypoint.sh dvim-temp:/entrypoint.sh
docker commit dvim-temp ashminbhattarai/dvim:latest
docker rm dvim-temp

# Option B — full rebuild (slow but clean)
docker build --no-cache -t ashminbhattarai/dvim:latest .
```

### 2. Not yet pushed to Docker Hub
Image is built and tagged locally as `ashminbhattarai/dvim:latest` but not yet
pushed to Docker Hub.

```bash
docker login
docker push ashminbhattarai/dvim:latest
```

### 3. Repo not yet pushed to GitHub
```bash
git add .
git commit -m "initial release: dvim v1.0"
git remote add origin https://github.com/ashmin-bhattarai/dvim.git
git push -u origin main
```

### 4. Cloudflare DNS not yet configured
Two CNAME records needed:
```
CNAME  dvim      → ashmin-bhattarai.github.io  (Proxy ON)
CNAME  get.dvim  → ashmin-bhattarai.github.io  (Proxy ON)
```
Redirect rule needed:
```
Hostname = get.dvim.ashmin.info.np
→ https://raw.githubusercontent.com/ashmin-bhattarai/dvim/main/${uri.path}
Type: 301
```

### 5. GitHub Pages not yet enabled
Repo Settings → Pages → Branch: main → Folder: /docs

---

## Test Suite

```bash
bash test.sh dvim                        # run against local image
bash test.sh ashminbhattarai/dvim:latest # run against tagged image
```

40 tests covering: image integrity, user/permissions, file ownership,
companion tools, plugins, LSPs, LSP attach, treesitter, blink.cmp, entrypoint.

Last result: **40/40 passing** (before Python version fix was applied)

---

## Build Commands

```bash
# Normal build (uses cache)
docker build -t ashminbhattarai/dvim:latest .

# Force full rebuild
docker build --no-cache -t ashminbhattarai/dvim:latest .

# Quick entrypoint-only update (no full rebuild)
docker create --name dvim-temp ashminbhattarai/dvim:latest
docker cp entrypoint.sh dvim-temp:/entrypoint.sh
docker commit dvim-temp ashminbhattarai/dvim:latest
docker rm dvim-temp

# Run locally
DVIM_IMAGE=ashminbhattarai/dvim:latest bash launcher/dvim
dvim   # after install.sh has been run
```

---

## Install Flow (for users)

```bash
# Install
curl -fsSL https://dvim.ashmin.info.np/install.sh | bash

# Install specific tag
curl -fsSL https://dvim.ashmin.info.np/install.sh | bash -s v1.0

# Update
dvim update

# Use
dvim                  # open current dir
dvim myfile.py        # open file
```

---

## Key Decisions Made

| Decision | Choice | Reason |
|---|---|---|
| Base image | debian:stable-slim | Good package availability, slim |
| Neovim install | GitHub tarball | Pinned version, includes LuaJIT |
| Node.js install | nodejs.org tarball | LTS, avoids stale distro package |
| Config | LazyVim defaults | Maintained, sensible defaults |
| blink.cmp | Lua impl | Not on git tag, can't download binary |
| Treesitter | Pre-compiled .so | Instant startup, no gcc at runtime |
| build-essential | Builder stage only | Saves ~200MB from final image |
| UID/GID | Dynamic remap at startup | Works for all users on Docker Hub |
| Project mount | Same absolute path | Venv/LSP paths match host exactly |
| Pyright config | Generated in /tmp | Never modifies host project dir |
| Persistence | Host-mounted state dirs | Survives container restarts |
| Config format | Lua files | Native to Neovim, familiar |

---

## What Was Built Session by Session

1. Designed architecture — multi-stage Dockerfile, entrypoint strategy
2. Wrote Dockerfile (4 stages) and entrypoint.sh
3. Fixed Node.js npm check in installer stage
4. Fixed entrypoint exec format error (leading newline in shebang)
5. Fixed slow startup — chown only when UID/GID actually changes
6. Reduced image 1.44GB → 950MB by stripping build-essential (multi-stage)
7. Further reduced to 975MB by stripping Node.js include/, npm, docs
8. Debugged treesitter parser compilation — new async API, one-by-one with pcall
9. Fixed treesitter install_dir path (.site not .lazy)
10. Moved ts_compile.lua to separate file
11. Fixed blink.cmp binary download message — switched to Lua impl
12. Added user config system (user.lua stub, dvim.user, dvim.project)
13. Added install.sh one-command installer
14. Added dvim launcher script
15. Added landing page (docs/index.html) for GitHub Pages
16. Configured custom domain plan (dvim.ashmin.info.np, get.dvim.ashmin.info.np)
17. Added same-path mounting for venv compatibility
18. Added Python venv auto-detection and pyrightconfig.json generation
19. Added Python version detection from venv binary (fix pending rebuild)
20. Fixed Docker Hub username ashmin78 → ashminbhattarai
21. Wrote 40-test integration test suite