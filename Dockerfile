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
    && echo "==> Node.js installed:" \
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
# TSUpdateSync compiles all parsers that LazyVim enables by default.
# This requires gcc (from build-essential) and tree-sitter-cli (installed
# above via npm). The compiled .so files land in:
#   ~/.local/share/nvim/lazy/nvim-treesitter/parser/
#
# These .so files are copied to the final stage — build-essential is not.
# defer_fn with 300s timeout: parser compilation can be slow for many parsers.
# -----------------------------------------------------------------------------
RUN echo "==> Compiling treesitter parsers (this may take a while)..." \
    && su devuser -c ' \
        nvim --headless \
             "+lua vim.defer_fn(function() vim.cmd([[TSUpdateSync]]) end, 5000)" \
             "+lua vim.defer_fn(function() vim.cmd([[qa!]]) end, 300000)" \
        2>&1 \
    ' \
    && echo "==> Treesitter parser compilation complete" \
    && echo "==> Compiled parsers:" \
    && ls /home/devuser/.local/share/nvim/lazy/nvim-treesitter/parser/ 2>/dev/null \
    || echo "WARNING: parser dir not found — TSUpdateSync may have failed"

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
# Copy tree-sitter-cli from builder
# Needed at runtime only if users install additional parsers manually.
# -----------------------------------------------------------------------------
COPY --from=builder /opt/node/lib/node_modules/tree-sitter-cli \
                    /opt/node/lib/node_modules/tree-sitter-cli
COPY --from=builder /opt/node/bin/tree-sitter \
                    /opt/node/bin/tree-sitter

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
    && ls /home/devuser/.local/share/nvim/lazy/nvim-treesitter/parser/ 2>/dev/null \
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