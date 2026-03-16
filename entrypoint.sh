#!/bin/bash
set -euo pipefail

# =============================================================================
# entrypoint.sh
#
# Responsibilities:
#   1. Detect UID/GID of mounted project dir and remap devuser to match
#   2. Fix home ownership if remapping occurred
#   3. Create /workspace symlink → actual project path
#   4. Detect Python venv in project root, generate pyrightconfig.json
#   5. Drop privileges via gosu and launch nvim
# =============================================================================

LOG_PREFIX="[entrypoint]"

log()  { echo "${LOG_PREFIX} $*"; }
warn() { echo "${LOG_PREFIX} WARN: $*" >&2; }
die()  { echo "${LOG_PREFIX} ERROR: $*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# The project is mounted at its actual host path (e.g. /home/user/myapp)
# HOST_PROJECT_PATH is set by the dvim launcher
# -----------------------------------------------------------------------------
PROJECT_PATH="${HOST_PROJECT_PATH:-/workspace}"

if [ ! -d "${PROJECT_PATH}" ]; then
    warn "Project path '${PROJECT_PATH}' does not exist or is not mounted."
    warn "Falling back to /workspace"
    PROJECT_PATH="/workspace"
    mkdir -p "${PROJECT_PATH}"
fi

log "Project path: ${PROJECT_PATH}"

# -----------------------------------------------------------------------------
# Create /workspace symlink → actual project path
# Allows 'cd /workspace' to always work regardless of mount path
# -----------------------------------------------------------------------------
if [ "${PROJECT_PATH}" != "/workspace" ]; then
    rm -f /workspace 2>/dev/null || true
    ln -sf "${PROJECT_PATH}" /workspace
    log "Symlink: /workspace → ${PROJECT_PATH}"
fi

# -----------------------------------------------------------------------------
# Detect UID/GID from the mounted project directory
# -----------------------------------------------------------------------------
WORKSPACE_UID=$(stat -c '%u' "${PROJECT_PATH}")
WORKSPACE_GID=$(stat -c '%g' "${PROJECT_PATH}")
log "Detected project owner — UID=${WORKSPACE_UID} GID=${WORKSPACE_GID}"

# Safety guard: refuse root
if [ "${WORKSPACE_UID}" = "0" ]; then
    warn "Project dir is owned by root (UID=0) — falling back to 1000:1000."
    WORKSPACE_UID=1000
    WORKSPACE_GID=1000
fi

# -----------------------------------------------------------------------------
# Remap devuser UID/GID to match host user
# Only chown home if remapping actually happened (expensive on large dirs)
# -----------------------------------------------------------------------------
CURRENT_UID=$(id -u devuser)
CURRENT_GID=$(id -g devuser)
REMAPPED=0

log "Current devuser — UID=${CURRENT_UID} GID=${CURRENT_GID}"

if [ "${WORKSPACE_GID}" != "${CURRENT_GID}" ]; then
    log "Remapping devuser group: ${CURRENT_GID} → ${WORKSPACE_GID}"
    groupmod -g "${WORKSPACE_GID}" devuser
    REMAPPED=1
else
    log "Group GID already matches (${CURRENT_GID}), skipping groupmod."
fi

if [ "${WORKSPACE_UID}" != "${CURRENT_UID}" ]; then
    log "Remapping devuser user: ${CURRENT_UID} → ${WORKSPACE_UID}"
    usermod -u "${WORKSPACE_UID}" -o devuser
    REMAPPED=1
else
    log "User UID already matches (${CURRENT_UID}), skipping usermod."
fi

if [ "${REMAPPED}" = "1" ]; then
    log "UID/GID remapped — fixing ownership of /home/devuser..."
    chown -R "${WORKSPACE_UID}:${WORKSPACE_GID}" /home/devuser
    log "Ownership fixed."
else
    log "No remapping needed, skipping chown."
fi

# -----------------------------------------------------------------------------
# Python venv detection and pyrightconfig.json generation
#
# Priority:
#   1. .venv/ in project root  → use it
#   2. venv/ in project root   → use it
#   3. pyrightconfig.json exists → let pyright handle it natively, skip
#   4. pyproject.toml exists   → let pyright handle it natively, skip
#   5. none found              → no config generated, pyright uses global python
#
# The generated config is written to /tmp/pyrightconfig.json inside the
# container only — the host project dir is never modified.
#
# DVIM_PYRIGHT_CONFIG env var is set so the nvim pyright LSP config
# can point pyright at the right config file.
# -----------------------------------------------------------------------------
PYRIGHT_CONFIG_PATH=""
VENV_PATH=""

# Check for existing user-managed pyright config first — don't override
if [ -f "${PROJECT_PATH}/pyrightconfig.json" ]; then
    log "Found pyrightconfig.json in project — using it as-is."
    PYRIGHT_CONFIG_PATH="${PROJECT_PATH}/pyrightconfig.json"
elif [ -f "${PROJECT_PATH}/pyproject.toml" ] && grep -q '\[tool\.pyright\]' "${PROJECT_PATH}/pyproject.toml" 2>/dev/null; then
    log "Found [tool.pyright] in pyproject.toml — pyright will read it natively."
    # No generated config needed — pyright finds pyproject.toml automatically
else
    # Auto-detect venv
    if [ -d "${PROJECT_PATH}/.venv" ]; then
        VENV_PATH="${PROJECT_PATH}/.venv"
        log "Detected venv: ${VENV_PATH}"
    elif [ -d "${PROJECT_PATH}/venv" ]; then
        VENV_PATH="${PROJECT_PATH}/venv"
        log "Detected venv: ${VENV_PATH}"
    else
        log "No venv found in project root — pyright will use global python."
    fi

    # Generate pyrightconfig.json if venv found
    if [ -n "${VENV_PATH}" ]; then
        # Detect actual Python version from pyvenv.cfg
        # This works for uv venvs which symlink to system Python instead of
        # copying the binary — executing the symlink would fail inside the
        # container since the host Python path doesn't exist there.
        # pyvenv.cfg is always written by uv/venv and contains the real version.
        PYTHON_VERSION="3.12"
        PYVENV_CFG="${VENV_PATH}/pyvenv.cfg"
        if [ -f "${PYVENV_CFG}" ]; then
            # Parse version_info = 3.13.1 → extract major.minor (3.13)
            DETECTED=$(grep -i "^version_info" "${PYVENV_CFG}" | grep -oP '\d+\.\d+' | head -1)
            if [ -n "${DETECTED}" ]; then
                PYTHON_VERSION="${DETECTED}"
                log "Detected Python version from pyvenv.cfg: ${PYTHON_VERSION}"
            else
                # Fallback: try 'version' field (some tools write this instead)
                DETECTED=$(grep -i "^version " "${PYVENV_CFG}" | grep -oP '\d+\.\d+' | head -1)
                if [ -n "${DETECTED}" ]; then
                    PYTHON_VERSION="${DETECTED}"
                    log "Detected Python version from pyvenv.cfg (version field): ${PYTHON_VERSION}"
                fi
            fi
        else
            log "pyvenv.cfg not found — falling back to Python ${PYTHON_VERSION}"
        fi

        # Write pyrightconfig.json to project root so pyright finds it
        # automatically when it searches from the workspace root.
        # A cleanup trap removes it when nvim exits — host dir is left clean.
        PYRIGHT_CONFIG_PATH="${PROJECT_PATH}/pyrightconfig.json"
        log "Generating ${PYRIGHT_CONFIG_PATH} for venv: ${VENV_PATH}"
        cat > "${PYRIGHT_CONFIG_PATH}" << PYRIGHT_EOF
{
  "pythonVersion": "${PYTHON_VERSION}",
  "venvPath": "${PROJECT_PATH}",
  "venv": "$(basename "${VENV_PATH}")",
  "include": ["${PROJECT_PATH}"],
  "exclude": [
    "${VENV_PATH}",
    "${PROJECT_PATH}/.git",
    "${PROJECT_PATH}/__pycache__",
    "${PROJECT_PATH}/.mypy_cache"
  ],
  "reportMissingImports": true,
  "reportMissingModuleSource": false
}
PYRIGHT_EOF
        chown "${WORKSPACE_UID}:${WORKSPACE_GID}" "${PYRIGHT_CONFIG_PATH}"
        log "pyrightconfig.json generated with venv: $(basename "${VENV_PATH}") (Python ${PYTHON_VERSION})"
        # Register cleanup — remove the generated config when nvim exits
        # This keeps the host project dir clean after dvim closes
        trap "rm -f '${PYRIGHT_CONFIG_PATH}'" EXIT
    fi
fi

# Export for nvim LSP config to consume
export DVIM_PYRIGHT_CONFIG="${PYRIGHT_CONFIG_PATH}"
export DVIM_PROJECT_PATH="${PROJECT_PATH}"

# -----------------------------------------------------------------------------
# Drop privileges and launch nvim
# -----------------------------------------------------------------------------
log "Dropping privileges to devuser (UID=${WORKSPACE_UID} GID=${WORKSPACE_GID})"
log "Launching nvim..."

if [ "$#" -eq 0 ]; then
    exec gosu devuser nvim "${PROJECT_PATH}"
else
    exec gosu devuser nvim "$@"
fi