# =============================================================================
# Dockerfile — Fully baked Neovim + LazyVim + LSPs
#
# Stages:
#   1. nvim-installer  — fetch & extract Neovim tarball from GitHub
#   2. node-installer  — fetch & extract Node.js LTS tarball from nodejs.org
#   3. builder         — full build env with build-essential; installs plugins,
#                        LSPs, and compiles all treesitter parsers
#   4. final           — runtime-only deps, no build-essential; copies all
#                        baked artifacts from builder
#
# The key optimization: build-essential (~200MB) lives only in the builder
# stage and is never copied to the final image.
#
# Usage:
#   docker build -t yourname/nvim .
#   docker run -it --rm -v $(pwd):/workspace yourname/nvim
#   docker run -it --rm -v $(pwd):/workspace yourname/nvim myfile.py
# =============================================================================

# -----------------------------------------------------------------------------
# Build args — override at build time if needed
#   docker build --build-arg NVIM_VERSION=0.11.2 ...
# -----------------------------------------------------------------------------
ARG NVIM_VERSION=0.11.2
ARG NODE_VERSION=22.14.0
ARG DEBIAN_FRONTEND=noninteractive

# =============================================================================
# Stage 1 — nvim-installer
# Download and extract the official Neovim prebuilt Linux tarball.
# The prebuilt binary includes LuaJIT, which is required by LazyVim.
# =============================================================================
FROM debian:stable-slim AS nvim-installer

ARG NVIM_VERSION
ARG DEBIAN_FRONTEND

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp/nvim

RUN echo "==> Downloading Neovim v${NVIM_VERSION}..." \
    && curl -fsSL \
        "https://github.com/neovim/neovim/releases/download/v${NVIM_VERSION}/nvim-linux-x86_64.tar.gz" \
        -o nvim.tar.gz \
    && echo "==> Extracting Neovim..." \
    && tar -xzf nvim.tar.gz \
    && mv nvim-linux-x86_64 /opt/nvim \
    && echo "==> Neovim installed:" \
    && /opt/nvim/bin/nvim --version | head -3

# =============================================================================
# Stage 2 — node-installer
# Download and extract the official Node.js LTS tarball from nodejs.org.
# Node.js is required by:
#   - pyright                  (Python LSP)
#   - typescript-language-server (TypeScript/JavaScript LSP)
#   - tree-sitter-cli          (nvim-treesitter parser compilation)
# =============================================================================
FROM debian:stable-slim AS node-installer

ARG NODE_VERSION
ARG DEBIAN_FRONTEND

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp/node

RUN echo "==> Downloading Node.js v${NODE_VERSION}..." \
    && curl -fsSL \
        "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
        -o node.tar.xz \
    && echo "==> Extracting Node.js..." \
    && tar -xJf node.tar.xz \
    && mv "node-v${NODE_VERSION}-linux-x64" /opt/node \
    && echo "==> Node.js extracted:" \
    && /opt/node/bin/node --version

# =============================================================================
# Stage 3 — builder
#
# Full build environment. Contains build-essential for treesitter parser
# compilation. This stage is heavy by design — its artifacts are selectively
# copied to the final stage, leaving build-essential behind.
#
# Responsibilities:
#   - Install all build + runtime deps (including build-essential)
#   - Create devuser
#   - Clone LazyVim starter config
#   - Headless lazy.nvim plugin sync
#   - Headless Mason LSP install
#   - Headless treesitter parser compilation (TSUpdateSync)
# =============================================================================
FROM debian:stable-slim AS builder

ARG DEBIAN_FRONTEND

# -----------------------------------------------------------------------------
# System dependencies (build + runtime combined)
#
# build-essential   — gcc + make, required by nvim-treesitter to compile parsers
#                     THIS IS NOT COPIED TO THE FINAL IMAGE
# git               — required by lazy.nvim for plugin cloning (needs >= 2.19)
# curl              — general downloads
# ca-certificates   — TLS cert verification
# unzip             — Mason uses unzip to extract LSP binaries
# gzip              — required by LazyVim for tree-sitter-cli auto-install fallback
# ripgrep           — Telescope live_grep
# fd-find           — Telescope file finder (binary is called fdfind on Debian)
# fzf               — fuzzy finder
# gosu              — clean privilege drop in entrypoint
# python3           — pyright analyses Python source code at runtime
# -----------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        git \
        curl \
        ca-certificates \
        unzip \
        gzip \
        ripgrep \
        fd-find \
        fzf \
        gosu \
        python3 \
    && rm -rf /var/lib/apt/lists/* \
    && echo "==> System deps installed" \
    && gcc --version | head -1 \
    && git --version \
    && python3 --version \
    # Debian names the binary 'fdfind', create an 'fd' symlink for nvim plugins
    && ln -s $(which fdfind) /usr/local/bin/fd \
    && echo "==> fd symlink created: $(which fd)"

# -----------------------------------------------------------------------------
# Copy Neovim and Node.js from installer stages
# -----------------------------------------------------------------------------
COPY --from=nvim-installer /opt/nvim /opt/nvim
COPY --from=node-installer /opt/node /opt/node

# -----------------------------------------------------------------------------
# Add Neovim and Node.js to PATH system-wide
# -----------------------------------------------------------------------------
ENV PATH="/opt/nvim/bin:/opt/node/bin:${PATH}"

RUN echo "==> Verifying binaries on PATH..." \
    && nvim --version | head -3 \
    && node --version \
    && npm --version

# -----------------------------------------------------------------------------
# Install tree-sitter-cli globally via npm
#
# Required by nvim-treesitter (LazyVim v15+) to compile language parsers.
# We have Node.js already so this adds zero extra toolchain overhead.
# -----------------------------------------------------------------------------
RUN echo "==> Installing tree-sitter-cli via npm..." \
    && npm install -g tree-sitter-cli \
    && echo "==> tree-sitter-cli version: $(tree-sitter --version)"

# -----------------------------------------------------------------------------
# Create devuser
#
# UID/GID 1000:1000 is the default — the entrypoint script will remap
# these at container startup to match the mounted volume's host owner.
# -----------------------------------------------------------------------------
RUN groupadd --gid 1000 devuser \
    && useradd \
        --uid 1000 \
        --gid 1000 \
        --create-home \
        --shell /bin/bash \
        devuser \
    && echo "==> devuser created (UID=1000 GID=1000)"

# -----------------------------------------------------------------------------
# Install LazyVim starter config
#
# We clone the official LazyVim starter repo into devuser's config directory.
# The .git directory is removed — we don't need history, and it keeps the
# image lean and prevents accidental git operations on the config.
# -----------------------------------------------------------------------------
RUN echo "==> Cloning LazyVim starter config..." \
    && git clone \
        --depth 1 \
        https://github.com/LazyVim/starter \
        /home/devuser/.config/nvim \
    && rm -rf /home/devuser/.config/nvim/.git \
    && chown -R devuser:devuser /home/devuser/.config/nvim \
    && echo "==> LazyVim starter config installed"

# -----------------------------------------------------------------------------
# Override blink.cmp to use pure Lua fuzzy implementation
#
# blink.cmp is installed from the main branch (not a release tag), so it
# cannot resolve a GitHub release to download the pre-built Rust binary.
# The Lua implementation is functionally equivalent and requires no binary,
# eliminating the "Downloading pre-built binary" message on first launch.
# -----------------------------------------------------------------------------
COPY blink-override.lua /home/devuser/.config/nvim/lua/plugins/blink-override.lua
RUN chown devuser:devuser /home/devuser/.config/nvim/lua/plugins/blink-override.lua \
    && echo "==> blink.cmp override installed"

# -----------------------------------------------------------------------------
# Bake user config stub and options.lua into the LazyVim config
#
# user.lua    — stub that loads dvim.user and dvim.project via pcall
#              these are mounted at runtime by the dvim launcher
# options.lua — LazyVim options entry point, calls require("config.user")
# -----------------------------------------------------------------------------
COPY nvim-config/lua/config/options.lua /home/devuser/.config/nvim/lua/config/options.lua
COPY nvim-config/lua/config/user.lua    /home/devuser/.config/nvim/lua/config/user.lua
RUN mkdir -p /home/devuser/.config/nvim/lua/dvim \
    && chown -R devuser:devuser /home/devuser/.config/nvim/lua/config/ \
    && chown -R devuser:devuser /home/devuser/.config/nvim/lua/dvim/ \
    && echo "==> user.lua and options.lua installed"

# -----------------------------------------------------------------------------
# Pre-install all lazy.nvim plugins headlessly
#
# Run as devuser so all plugin files are created with correct ownership.
#
# Flags:
#   --headless      no UI
#   --noplugin      skip loading plugins before our command runs
#   "+Lazy! sync"   install/update all plugins, '!' means no UI
#   "+qa!"          quit all windows forcefully after sync completes
# -----------------------------------------------------------------------------
RUN echo "==> Pre-installing lazy.nvim plugins (this may take a while)..." \
    && su devuser -c ' \
        nvim --headless \
             --noplugin \
             "+Lazy! sync" \
             "+qa!" \
        2>&1 \
    ' \
    && echo "==> Plugin installation complete" \
    && echo "==> Installed plugins:" \
    && ls /home/devuser/.local/share/nvim/lazy/

# -----------------------------------------------------------------------------
# Pre-install LSPs via Mason headlessly
#
# Mason installs LSP binaries into ~/.local/share/nvim/mason/bin/
# LSPs installed:
#   lua-language-server        — Lua LSP
#   pyright                    — Python LSP (runs on Node.js)
#   typescript-language-server — TypeScript/JavaScript LSP (runs on Node.js)
#
# defer_fn with 120s timeout: Mason installs are async so we wait for
# completion before quitting. 120s is generous but safe for slow networks.
# -----------------------------------------------------------------------------
RUN echo "==> Pre-installing LSPs via Mason (this may take a while)..." \
    && su devuser -c ' \
        nvim --headless \
             "+MasonInstall lua-language-server pyright typescript-language-server" \
             "+lua vim.defer_fn(function() vim.cmd([[qa!]]) end, 120000)" \
        2>&1 \
    ' \
    && echo "==> Mason installation complete" \
    && echo "==> Installed Mason bins:" \
    && ls /home/devuser/.local/share/nvim/mason/bin/

# -----------------------------------------------------------------------------
# Compile treesitter parsers headlessly
#
# The new nvim-treesitter main branch (required by LazyVim v15+) is fully
# async. TSUpdateSync no longer exists. The correct API is:
#   install.install({parsers}):wait(timeout_ms)
#
# The script is kept in ts_compile.lua (separate file, not inlined here).
# gcc (from build-essential) and tree-sitter-cli (from npm) must be on PATH.
#
# Parsers compiled here are the LazyVim defaults. The resulting .so files
# are copied to the final stage — build-essential is NOT.
# -----------------------------------------------------------------------------
COPY ts_compile.lua /tmp/ts_compile.lua
RUN echo "==> Starting treesitter parser compilation (this will take several minutes)..." \
    && su devuser -c "nvim --headless -u /tmp/ts_compile.lua 2>&1" \
    && echo "==> Treesitter compilation step complete" \
    && echo "==> Final parser count:" \
    && ls /home/devuser/.local/share/nvim/site/parser/*.so 2>/dev/null | wc -l \
    || (echo "ERROR: treesitter compilation failed" && exit 1)

# =============================================================================
# Stage 4 — final
#
# Lean runtime image. No build-essential. Only what's needed to run nvim.
# All heavy artifacts (plugins, LSPs, parsers) are copied from builder.
# =============================================================================
FROM debian:stable-slim AS final

ARG DEBIAN_FRONTEND

# -----------------------------------------------------------------------------
# Runtime-only system dependencies — NO build-essential
#
# git               — lazy.nvim needs git to check plugin updates at runtime
# curl              — occasional runtime downloads
# ca-certificates   — TLS cert verification
# unzip             — Mason may need to install/update LSPs at runtime
# gzip              — tree-sitter-cli fallback
# ripgrep           — Telescope live_grep
# fd-find           — Telescope file finder
# fzf               — fuzzy finder
# gosu              — privilege drop in entrypoint
# python3           — pyright runtime code analysis
# -----------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        curl \
        ca-certificates \
        unzip \
        gzip \
        ripgrep \
        fd-find \
        fzf \
        gosu \
        python3 \
    && rm -rf /var/lib/apt/lists/* \
    && echo "==> Runtime deps installed" \
    && git --version \
    && python3 --version \
    # Debian names the binary 'fdfind', create an 'fd' symlink for nvim plugins
    && ln -s $(which fdfind) /usr/local/bin/fd \
    && echo "==> fd symlink created: $(which fd)" \
    # Strip locale/doc/perl bloat pulled in by git and python3 packages
    # None of this is needed for nvim/LSP operation
    && rm -rf /usr/share/perl \
    && rm -rf /usr/share/doc \
    && rm -rf /usr/share/man \
    && rm -rf /usr/share/info \
    && rm -rf /usr/share/zoneinfo \
    && rm -rf /usr/share/gitweb \
    && rm -rf /usr/lib/python3.13/test \
    && rm -rf /usr/lib/python3.13/unittest \
    && echo "==> Bloat stripped from /usr/share and /usr/lib"

# -----------------------------------------------------------------------------
# Copy Neovim from installer stage
# -----------------------------------------------------------------------------
COPY --from=nvim-installer /opt/nvim /opt/nvim

# -----------------------------------------------------------------------------
# Copy Node.js — selectively, stripping build-time-only artifacts
#
# We copy only what is needed at runtime:
#   bin/node              — the Node.js runtime (pyright + ts_ls need this)
#   lib/node_modules/     — LSP node_modules installed by Mason via npm
#
# Intentionally NOT copied:
#   include/              — C headers for native addon compilation (56MB)
#   lib/node_modules/npm  — package manager, only needed during build (20MB)
#   lib/node_modules/corepack — not needed anywhere (1.2MB)
#   share/                — docs (72KB)
#   *.md, LICENSE         — docs (~600KB)
# -----------------------------------------------------------------------------
RUN mkdir -p /opt/node/bin /opt/node/lib/node_modules
COPY --from=node-installer /opt/node/bin/node /opt/node/bin/node
COPY --from=node-installer /opt/node/lib/node_modules /opt/node/lib/node_modules
RUN rm -rf /opt/node/lib/node_modules/npm \
    && rm -rf /opt/node/lib/node_modules/corepack \
    && echo "==> Node.js runtime size after stripping:" \
    && du -sh /opt/node

# -----------------------------------------------------------------------------
# Copy tree-sitter-cli from builder (installed via npm during build)
# Needed at runtime if users want to install additional parsers manually.
# -----------------------------------------------------------------------------
COPY --from=builder /opt/node/lib/node_modules/tree-sitter-cli \
                    /opt/node/lib/node_modules/tree-sitter-cli
COPY --from=builder /opt/node/bin/tree-sitter \
                    /opt/node/bin/tree-sitter

# -----------------------------------------------------------------------------
# Add Neovim and Node.js to PATH system-wide
# -----------------------------------------------------------------------------
ENV PATH="/opt/nvim/bin:/opt/node/bin:${PATH}"

RUN echo "==> Verifying binaries on PATH..." \
    && nvim --version | head -3 \
    && node --version

# -----------------------------------------------------------------------------
# Recreate devuser with same UID/GID as in builder
# -----------------------------------------------------------------------------
RUN groupadd --gid 1000 devuser \
    && useradd \
        --uid 1000 \
        --gid 1000 \
        --create-home \
        --shell /bin/bash \
        devuser \
    && echo "==> devuser created (UID=1000 GID=1000)"

# -----------------------------------------------------------------------------
# Copy all baked artifacts from builder into devuser's home
#
# This includes:
#   ~/.config/nvim/                          — LazyVim config
#   ~/.local/share/nvim/lazy/                — pre-installed plugins
#   ~/.local/share/nvim/mason/               — pre-installed LSPs
#   ~/.local/share/nvim/lazy/nvim-treesitter/parser/ — compiled .so parsers
# -----------------------------------------------------------------------------
COPY --from=builder /home/devuser /home/devuser

# Fix ownership — COPY --from preserves numeric ids from builder but the
# user may not exist yet in final with same uid at copy time
RUN chown -R devuser:devuser /home/devuser \
    && echo "==> Home directory ownership fixed" \
    && echo "==> Plugins:" \
    && ls /home/devuser/.local/share/nvim/lazy/ \
    && echo "==> Mason bins:" \
    && ls /home/devuser/.local/share/nvim/mason/bin/ \
    && echo "==> Treesitter parsers:" \
    && ls /home/devuser/.local/share/nvim/site/parser/*.so 2>/dev/null | wc -l \
    || echo "WARNING: no parsers found"

# -----------------------------------------------------------------------------
# Copy and configure entrypoint script
# -----------------------------------------------------------------------------
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh \
    && echo "==> entrypoint.sh installed"

# -----------------------------------------------------------------------------
# Final image metadata
# -----------------------------------------------------------------------------
WORKDIR /workspace

# XDG env vars so nvim always finds config/data regardless of invocation
ENV HOME=/home/devuser
ENV XDG_CONFIG_HOME=/home/devuser/.config
ENV XDG_DATA_HOME=/home/devuser/.local/share
ENV XDG_STATE_HOME=/home/devuser/.local/state
ENV XDG_CACHE_HOME=/home/devuser/.cache

# Container starts as root so entrypoint can remap UID/GID,
# then gosu drops to devuser before nvim launches.
USER root

ENTRYPOINT ["/entrypoint.sh"]