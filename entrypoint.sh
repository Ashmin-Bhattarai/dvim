#!/bin/bash
set -euo pipefail

# =============================================================================
# entrypoint.sh
#
# Responsibilities:
#   1. Detect UID/GID of /workspace (mounted volume)
#   2. Remap internal 'devuser' to match host UID/GID
#   3. Fix ownership of devuser's home directory (only when remapping occurred)
#   4. Drop privileges via gosu and exec nvim
#
# This ensures files created/edited inside the container are owned by the
# same UID/GID as the host user who mounted the volume — no root-owned
# files left behind.
# =============================================================================

LOG_PREFIX="[entrypoint]"

log()  { echo "${LOG_PREFIX} $*"; }
warn() { echo "${LOG_PREFIX} WARN: $*" >&2; }
die()  { echo "${LOG_PREFIX} ERROR: $*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Detect host UID/GID from the mounted workspace
# -----------------------------------------------------------------------------
WORKSPACE="/workspace"

if [ ! -d "${WORKSPACE}" ]; then
    warn "/workspace does not exist or is not mounted."
    warn "Falling back to devuser UID/GID 1000:1000."
    WORKSPACE_UID=1000
    WORKSPACE_GID=1000
else
    WORKSPACE_UID=$(stat -c '%u' "${WORKSPACE}")
    WORKSPACE_GID=$(stat -c '%g' "${WORKSPACE}")
    log "Detected /workspace owner — UID=${WORKSPACE_UID} GID=${WORKSPACE_GID}"
fi

# -----------------------------------------------------------------------------
# Safety guard: refuse to run as root inside the container
# -----------------------------------------------------------------------------
if [ "${WORKSPACE_UID}" = "0" ]; then
    warn "/workspace is owned by root (UID=0)."
    warn "Running as root inside the container is not allowed."
    warn "Falling back to devuser UID/GID 1000:1000."
    WORKSPACE_UID=1000
    WORKSPACE_GID=1000
fi

# -----------------------------------------------------------------------------
# Remap devuser to match host UID/GID
#
# We track whether any remapping actually happened via REMAPPED flag.
# This lets us skip the expensive recursive chown when nothing changed.
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
    # -o allows non-unique UID in case host UID collides with another system user
    usermod -u "${WORKSPACE_UID}" -o devuser
    REMAPPED=1
else
    log "User UID already matches (${CURRENT_UID}), skipping usermod."
fi

# -----------------------------------------------------------------------------
# Fix ownership of devuser's home directory — only when remapping occurred.
#
# Skipped when UID/GID already match to avoid a costly recursive chown over
# thousands of plugin and LSP files baked into /home/devuser/.local/
# On a typical run where host UID=1000 matches devuser, this is never run.
# -----------------------------------------------------------------------------
if [ "${REMAPPED}" = "1" ]; then
    log "UID/GID remapped — fixing ownership of /home/devuser (this runs once per new UID)..."
    chown -R "${WORKSPACE_UID}:${WORKSPACE_GID}" /home/devuser
    log "Ownership fixed."
else
    log "No remapping needed, skipping chown."
fi

# -----------------------------------------------------------------------------
# Drop privileges and exec nvim
#
# gosu is used instead of su/sudo because:
#   - It does a clean exec (no extra shell process)
#   - It properly drops supplementary groups
#   - It is the Docker-recommended way to drop privileges
#
# "$@" passes any arguments the user provides, e.g.:
#   docker run ... yourimage myfile.py   → opens myfile.py directly
#   docker run ... yourimage             → opens nvim at /workspace
# -----------------------------------------------------------------------------
log "Dropping privileges to devuser (UID=${WORKSPACE_UID} GID=${WORKSPACE_GID})"
log "Launching nvim..."

if [ "$#" -eq 0 ]; then
    # No arguments — open nvim at workspace root
    exec gosu devuser nvim "${WORKSPACE}"
else
    # Arguments provided — pass them directly to nvim
    exec gosu devuser nvim "$@"
fi