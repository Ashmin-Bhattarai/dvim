
# =============================================================================
# Dockerfile — Fully baked Neovim + LazyVim + LSPs
#
# Stages:
#   1. nvim-installer   — fetch & extract Neovim tarball from GitHub
#   2. node-installer   — fetch & extract Node.js LTS tarball from nodejs.org
#   3. final            — assemble everything, bake plugins + LSPs headlessly
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
#   - pyright         (Python LSP)
#   - ts_ls           (TypeScript/JavaScript LSP)
#   - tree-sitter-cli (nvim-treesitter parser compilation)
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
# Stage 3 — final
# Assemble all components, create devuser, bake LazyVim config,
# pre-install all plugins via lazy.nvim and all LSPs via Mason.
# =============================================================================
FROM debian:stable-slim AS final

ARG DEBIAN_FRONTEND

# -----------------------------------------------------------------------------
# System dependencies
#
# build-essential   — gcc + make, required by nvim-treesitter to compile parsers
# git               — required by lazy.nvim for plugin cloning (needs >= 2.19)
# curl              — general downloads
# ca-certificates   — TLS cert verification
# unzip             — Mason uses unzip to extract LSP binaries
# gzip              — required by LazyVim for tree-sitter-cli auto-install fallback
# ripgrep           — Telescope live_grep
# fd-find           — Telescope file finder (binary is called fdfind on Debian)
# fzf               — fuzzy finder
# gosu              — clean privilege drop in entrypoint (Docker best practice)
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
# We run nvim as devuser (not root) so all plugin files are created with
# correct ownership from the start.
#
# Flags:
#   --headless          no UI
#   --noplugin          skip loading plugins before our command runs
#   "+Lazy! sync"       install/update all plugins, the '!' means no UI
#   "+qa!"              quit all windows forcefully after sync completes
#
# NVIM_APPNAME is not set — LazyVim uses the default ~/.config/nvim path.
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
    && echo "==> Installed plugin dirs:" \
    && ls /home/devuser/.local/share/nvim/lazy/ 2>/dev/null || echo "(lazy dir not found — check above for errors)"

# -----------------------------------------------------------------------------
# Pre-install LSPs via Mason headlessly
#
# Mason installs LSP binaries into ~/.local/share/nvim/mason/bin/
# We install:
#   lua-language-server       — Lua LSP
#   pyright                   — Python LSP (runs on Node.js)
#   typescript-language-server — TypeScript/JavaScript LSP (runs on Node.js)
#
# The sleep gives Mason time to finish async installation before nvim quits.
# This is a known pattern for headless Mason installs.
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
    && ls /home/devuser/.local/share/nvim/mason/bin/ 2>/dev/null || echo "(mason/bin not found — check above for errors)"

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

# Expose the devuser environment variables so nvim can find its config/data
ENV HOME=/home/devuser
ENV XDG_CONFIG_HOME=/home/devuser/.config
ENV XDG_DATA_HOME=/home/devuser/.local/share
ENV XDG_STATE_HOME=/home/devuser/.local/state
ENV XDG_CACHE_HOME=/home/devuser/.cache

# The container starts as root so the entrypoint can remap UID/GID,
# then gosu drops to devuser before nvim launches.
USER root

ENTRYPOINT ["/entrypoint.sh"]