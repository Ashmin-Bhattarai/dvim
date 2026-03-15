#!/bin/bash
# =============================================================================
# install.sh — dvim one-command installer
#
# Usage:
#   curl -fsSL https://get.dvim.ashmin.info.np/install.sh | bash
#   curl -fsSL https://get.dvim.ashmin.info.np/install.sh | bash -s v1.0
#
# What this does:
#   1. Checks prerequisites (docker, git, curl)
#   2. Pulls ashmin78/dvim Docker image (default: latest, or specified tag)
#   3. Clones the dvim repo to ~/.local/share/dvim/repo
#   4. Installs dvim launcher to ~/.local/bin/dvim
#   5. Adds ~/.local/bin to PATH in ~/.bashrc if not already there
#   6. Creates ~/.config/dvim/user.lua starter template
#   7. Creates persistent state directories
#   8. Prints usage instructions
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
DVIM_TAG="${1:-latest}"
DVIM_IMAGE="ashmin78/dvim:${DVIM_TAG}"
DVIM_REPO="https://github.com/ashmin-bhattarai/dvim.git"
DVIM_REPO_DIR="${HOME}/.local/share/dvim/repo"
DVIM_BIN_DIR="${HOME}/.local/bin"
DVIM_CONFIG_DIR="${HOME}/.config/dvim"
DVIM_STATE_DIR="${HOME}/.local/share/dvim"

# -----------------------------------------------------------------------------
# Colors
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log()     { echo -e "${CYAN}[dvim]${RESET} $*"; }
success() { echo -e "${GREEN}[dvim]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[dvim] WARN:${RESET} $*" >&2; }
die()     { echo -e "${RED}[dvim] ERROR:${RESET} $*" >&2; exit 1; }
header()  { echo -e "\n${BOLD}${CYAN}── $* ──${RESET}"; }

# -----------------------------------------------------------------------------
# Welcome
# -----------------------------------------------------------------------------
echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${CYAN}║         dvim installer               ║${RESET}"
echo -e "${BOLD}${CYAN}║   Docker-powered Neovim + LazyVim    ║${RESET}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════╝${RESET}"
echo ""
log "Installing dvim (image tag: ${DVIM_TAG})"

# -----------------------------------------------------------------------------
# Step 1: Check prerequisites
# -----------------------------------------------------------------------------
header "Checking prerequisites"

check_cmd() {
  if command -v "$1" &>/dev/null; then
    success "$1 found: $(command -v "$1")"
  else
    die "$1 is required but not installed. Please install $1 and re-run."
  fi
}

check_cmd docker
check_cmd git
check_cmd curl

# Check Docker daemon is running
if ! docker info &>/dev/null; then
  die "Docker daemon is not running. Please start Docker and re-run."
fi
success "Docker daemon is running"

# -----------------------------------------------------------------------------
# Step 2: Pull Docker image
# -----------------------------------------------------------------------------
header "Pulling Docker image"

log "Pulling ${DVIM_IMAGE}..."
if docker pull "${DVIM_IMAGE}"; then
  success "Image pulled: ${DVIM_IMAGE}"
else
  die "Failed to pull image ${DVIM_IMAGE}. Check your internet connection and Docker Hub."
fi

# -----------------------------------------------------------------------------
# Step 3: Clone or update repo
# -----------------------------------------------------------------------------
header "Setting up dvim repo"

mkdir -p "$(dirname "${DVIM_REPO_DIR}")"

if [ -d "${DVIM_REPO_DIR}/.git" ]; then
  log "Repo already exists, updating..."
  git -C "${DVIM_REPO_DIR}" pull --ff-only
  success "Repo updated"
else
  log "Cloning dvim repo to ${DVIM_REPO_DIR}..."
  git clone --depth 1 "${DVIM_REPO}" "${DVIM_REPO_DIR}"
  success "Repo cloned"
fi

# -----------------------------------------------------------------------------
# Step 4: Install launcher
# -----------------------------------------------------------------------------
header "Installing launcher"

mkdir -p "${DVIM_BIN_DIR}"
install -m755 "${DVIM_REPO_DIR}/launcher/dvim" "${DVIM_BIN_DIR}/dvim"
success "Launcher installed: ${DVIM_BIN_DIR}/dvim"

# -----------------------------------------------------------------------------
# Step 5: Add ~/.local/bin to PATH in ~/.bashrc
# -----------------------------------------------------------------------------
header "Configuring PATH"

BASHRC="${HOME}/.bashrc"
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'

if echo "${PATH}" | grep -q "${DVIM_BIN_DIR}"; then
  success "~/.local/bin is already in PATH"
elif grep -qF "${PATH_LINE}" "${BASHRC}" 2>/dev/null; then
  success "PATH already configured in ${BASHRC}"
else
  echo "" >> "${BASHRC}"
  echo "# Added by dvim installer" >> "${BASHRC}"
  echo "${PATH_LINE}" >> "${BASHRC}"
  success "Added ~/.local/bin to PATH in ${BASHRC}"
  warn "Run 'source ~/.bashrc' or open a new terminal to use dvim"
fi

# -----------------------------------------------------------------------------
# Step 6: Create user config template
# -----------------------------------------------------------------------------
header "Setting up user config"

mkdir -p "${DVIM_CONFIG_DIR}"

USER_CONFIG="${DVIM_CONFIG_DIR}/user.lua"
if [ -f "${USER_CONFIG}" ]; then
  warn "User config already exists, skipping: ${USER_CONFIG}"
else
  cat > "${USER_CONFIG}" << 'LUAEOF'
-- =============================================================================
-- ~/.config/dvim/user.lua — dvim system-wide user config
--
-- This file is loaded automatically by dvim on every launch.
-- For project-specific settings, create a .dvim.lua in your project root.
--
-- Changes here take effect immediately on next dvim launch — no rebuild needed.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Options
-- Examples:
-- -----------------------------------------------------------------------------
-- vim.opt.relativenumber = true       -- relative line numbers
-- vim.opt.scrolloff = 8               -- keep 8 lines above/below cursor
-- vim.opt.tabstop = 2                 -- 2-space tabs
-- vim.opt.shiftwidth = 2
-- vim.opt.wrap = false                -- disable line wrap
-- vim.opt.colorcolumn = "80"          -- show column ruler at 80 chars

-- -----------------------------------------------------------------------------
-- Keymaps
-- Examples:
-- -----------------------------------------------------------------------------
-- vim.keymap.set("n", "<leader>q", "<cmd>q<cr>",       { desc = "Quit" })
-- vim.keymap.set("n", "<leader>w", "<cmd>w<cr>",       { desc = "Save" })
-- vim.keymap.set("n", "<C-d>",     "<C-d>zz",          { desc = "Scroll down centered" })
-- vim.keymap.set("n", "<C-u>",     "<C-u>zz",          { desc = "Scroll up centered" })
-- vim.keymap.set("v", "J",         ":m '>+1<CR>gv=gv", { desc = "Move line down" })
-- vim.keymap.set("v", "K",         ":m '<-2<CR>gv=gv", { desc = "Move line up" })

-- -----------------------------------------------------------------------------
-- Colorscheme (LazyVim default is tokyonight)
-- Examples:
-- -----------------------------------------------------------------------------
-- vim.cmd.colorscheme("catppuccin")
-- vim.cmd.colorscheme("tokyonight-moon")
LUAEOF

  success "User config template created: ${USER_CONFIG}"
fi

# -----------------------------------------------------------------------------
# Step 7: Create persistent state directories
# -----------------------------------------------------------------------------
header "Setting up persistent state"

mkdir -p \
  "${DVIM_STATE_DIR}/state" \
  "${DVIM_STATE_DIR}/shada" \
  "${DVIM_STATE_DIR}/swap"

success "Persistent state dirs created: ${DVIM_STATE_DIR}/{state,shada,swap}"

# -----------------------------------------------------------------------------
# Step 8: Verify installation
# -----------------------------------------------------------------------------
header "Verifying installation"

if [ -x "${DVIM_BIN_DIR}/dvim" ]; then
  success "dvim launcher: ${DVIM_BIN_DIR}/dvim"
else
  die "Launcher not found or not executable: ${DVIM_BIN_DIR}/dvim"
fi

if docker image inspect "${DVIM_IMAGE}" &>/dev/null; then
  IMAGE_SIZE=$(docker image inspect "${DVIM_IMAGE}" --format='{{.Size}}' | awk '{printf "%.0fMB", $1/1024/1024}')
  success "Docker image: ${DVIM_IMAGE} (${IMAGE_SIZE})"
else
  die "Docker image not found after pull: ${DVIM_IMAGE}"
fi

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${GREEN}║   dvim installed successfully! ✓     ║${RESET}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════╝${RESET}"
echo ""
echo -e "${BOLD}Quick start:${RESET}"
echo -e "  ${CYAN}dvim${RESET}                  open nvim in current directory"
echo -e "  ${CYAN}dvim myfile.py${RESET}        open a specific file"
echo -e "  ${CYAN}dvim update${RESET}           pull latest image + update launcher"
echo ""
echo -e "${BOLD}Config files:${RESET}"
echo -e "  ${CYAN}~/.config/dvim/user.lua${RESET}   system-wide settings and keymaps"
echo -e "  ${CYAN}.dvim.lua${RESET}                  project-specific settings (place in project root)"
echo ""
echo -e "${BOLD}Persistent state:${RESET}"
echo -e "  ${CYAN}~/.local/share/dvim/${RESET}       undo history, sessions, marks survive container restarts"
echo ""

# Remind to source bashrc if PATH was just added
if ! command -v dvim &>/dev/null; then
  echo -e "${YELLOW}NOTE: Run the following to use dvim in this terminal:${RESET}"
  echo -e "  ${BOLD}source ~/.bashrc${RESET}"
  echo ""
fi