#!/bin/bash
# =============================================================================
# test.sh — Integration test suite for the nvim Docker image
#
# Usage:
#   ./test.sh                  # uses default image name 'nvim'
#   ./test.sh yourname/nvim    # explicit image name
#
# Each test has a timeout to prevent hangs. All tests run regardless of
# failures. A summary is printed at the end. Exit code is 0 if all pass,
# 1 if any fail.
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------------
IMAGE="${1:-nvim}"
TEST_TIMEOUT=30       # seconds per test before considered hung
PASS_COUNT=0
FAIL_COUNT=0
FAILED_TESTS=()

# -----------------------------------------------------------------------------
# Colors
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
log_header() {
    echo ""
    echo -e "${CYAN}${BOLD}══════════════════════════════════════════${RESET}"
    echo -e "${CYAN}${BOLD}  $1${RESET}"
    echo -e "${CYAN}${BOLD}══════════════════════════════════════════${RESET}"
}

pass() {
    echo -e "  ${GREEN}✓${RESET} $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo -e "  ${RED}✗${RESET} $1"
    if [ -n "${2:-}" ]; then
        echo -e "    ${RED}↳ $2${RESET}"
    fi
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("$1")
}

# Run a command inside the container without entrypoint, with timeout.
# Usage: run_in_container <command>
# Returns stdout, exit code reflects command success.
run() {
    timeout "${TEST_TIMEOUT}" \
        docker run --rm --entrypoint="" \
        "${IMAGE}" sh -c "$1" 2>&1
}

# Run as devuser inside the container
run_as_devuser() {
    timeout "${TEST_TIMEOUT}" \
        docker run --rm --entrypoint="" \
        "${IMAGE}" sh -c "su devuser -c \"$1\"" 2>&1
}

# Run with workspace volume mounted (triggers entrypoint)
run_with_workspace() {
    local tmpdir
    tmpdir=$(mktemp -d)
    timeout "${TEST_TIMEOUT}" \
        docker run --rm \
        -v "${tmpdir}:/workspace" \
        "${IMAGE}" sh -c "$1" 2>&1
    local exit_code=$?
    rm -rf "${tmpdir}"
    return $exit_code
}

# Assert output contains expected string
assert_contains() {
    local test_name="$1"
    local output="$2"
    local expected="$3"
    if echo "${output}" | grep -q "${expected}"; then
        pass "${test_name}"
    else
        fail "${test_name}" "Expected '${expected}' in output: ${output}"
    fi
}

# Assert output matches exact string
assert_equals() {
    local test_name="$1"
    local output="$2"
    local expected="$3"
    if [ "${output}" = "${expected}" ]; then
        pass "${test_name}"
    else
        fail "${test_name}" "Expected '${expected}', got '${output}'"
    fi
}

# Assert numeric output is >= threshold
assert_gte() {
    local test_name="$1"
    local value="$2"
    local threshold="$3"
    if [ "${value}" -ge "${threshold}" ] 2>/dev/null; then
        pass "${test_name}"
    else
        fail "${test_name}" "Expected >= ${threshold}, got '${value}'"
    fi
}

# Assert command exits 0
assert_success() {
    local test_name="$1"
    local output="$2"
    local exit_code="$3"
    if [ "${exit_code}" -eq 0 ]; then
        pass "${test_name}"
    else
        fail "${test_name}" "Command failed with exit code ${exit_code}: ${output}"
    fi
}

# =============================================================================
# Pre-flight check
# =============================================================================
echo ""
echo -e "${BOLD}nvim Docker Image Test Suite${RESET}"
echo -e "Image: ${CYAN}${IMAGE}${RESET}"
echo -e "Timeout per test: ${YELLOW}${TEST_TIMEOUT}s${RESET}"

if ! docker image inspect "${IMAGE}" > /dev/null 2>&1; then
    echo -e "${RED}ERROR: Image '${IMAGE}' not found. Build it first.${RESET}"
    exit 1
fi

# =============================================================================
# 1. Image integrity
# =============================================================================
log_header "1. Image Integrity"

output=$(run 'nvim --version | head -1')
assert_contains "Neovim version >= 0.11" "${output}" "NVIM v0.11"

output=$(run 'nvim --version | head -3')
assert_contains "LuaJIT present" "${output}" "LuaJIT"

output=$(run 'test -f /opt/nvim/bin/nvim && echo "exists"')
assert_contains "Neovim binary at /opt/nvim/bin/nvim" "${output}" "exists"

output=$(run 'test -f /opt/node/bin/node && echo "exists"')
assert_contains "Node.js binary at /opt/node/bin/node" "${output}" "exists"

# =============================================================================
# 2. User & permissions
# =============================================================================
log_header "2. User & Permissions"

output=$(run 'su devuser -c "whoami"')
assert_equals "devuser exists" "${output}" "devuser"

output=$(run 'su devuser -c "id -u"')
assert_equals "devuser UID is 1000" "${output}" "1000"

output=$(run 'su devuser -c "id -g"')
assert_equals "devuser GID is 1000" "${output}" "1000"

output=$(run 'id -u')
assert_equals "Container starts as root (for entrypoint remapping)" "${output}" "0"

output=$(run 'test ! -f /usr/bin/gcc && echo "no gcc" || echo "has gcc"')
assert_equals "build-essential not in final image" "${output}" "no gcc"

# =============================================================================
# 3. File ownership
# =============================================================================
log_header "3. File Ownership (Volume Mount)"

tmpdir=$(mktemp -d)
timeout "${TEST_TIMEOUT}" \
    docker run --rm \
    -v "${tmpdir}:/workspace" \
    --entrypoint="" \
    "${IMAGE}" \
    sh -c 'su devuser -c "touch /workspace/test_ownership.txt"' > /dev/null 2>&1

if [ -f "${tmpdir}/test_ownership.txt" ]; then
    file_owner=$(stat -c '%U' "${tmpdir}/test_ownership.txt")
    current_user=$(whoami)
    if [ "${file_owner}" = "${current_user}" ]; then
        pass "Files created in workspace owned by host user (${current_user})"
    else
        fail "File ownership" "Expected owner '${current_user}', got '${file_owner}'"
    fi
else
    fail "File creation in workspace" "File was not created"
fi
rm -rf "${tmpdir}"

# =============================================================================
# 4. Companion tools
# =============================================================================
log_header "4. Companion Tools"

for tool in rg fd fzf git node python3 tree-sitter; do
    output=$(run "which ${tool} 2>/dev/null && echo found || echo missing")
    assert_contains "${tool} on PATH" "${output}" "found"
done

# =============================================================================
# 5. Plugins
# =============================================================================
log_header "5. Plugins (lazy.nvim)"

output=$(run 'ls /home/devuser/.local/share/nvim/lazy/ | wc -l | tr -d " "')
assert_gte "At least 30 plugins installed" "${output}" 30

for plugin in LazyVim nvim-treesitter blink.cmp mason.nvim nvim-lspconfig; do
    output=$(run "test -d /home/devuser/.local/share/nvim/lazy/${plugin} && echo exists || echo missing")
    assert_contains "Plugin ${plugin} present" "${output}" "exists"
done

# =============================================================================
# 6. LSPs (Mason)
# =============================================================================
log_header "6. LSPs (Mason)"

for lsp in lua-language-server pyright typescript-language-server; do
    output=$(run "test -f /home/devuser/.local/share/nvim/mason/bin/${lsp} && echo exists || echo missing")
    assert_contains "Mason LSP ${lsp} present" "${output}" "exists"
done

# =============================================================================
# 7. LSP attach
# =============================================================================
log_header "7. LSP Attach"

tmpdir=$(mktemp -d)
echo 'import os' > "${tmpdir}/test.py"
echo 'def hello(): pass' >> "${tmpdir}/test.py"

output=$(timeout "${TEST_TIMEOUT}" \
    docker run --rm \
    -v "${tmpdir}:/workspace" \
    --entrypoint="" \
    "${IMAGE}" \
    sh -c 'su devuser -c "nvim --headless /workspace/test.py +\"lua vim.defer_fn(function() local c=vim.lsp.get_clients() print(#c) for _,v in ipairs(c) do print(v.name) end vim.cmd(\\\"qa\\\") end, 5000)\" 2>&1"' \
    2>&1 || echo "timeout")

assert_contains "Pyright attaches to .py file" "${output}" "pyright"
rm -rf "${tmpdir}"

tmpdir=$(mktemp -d)
echo 'local x = 1' > "${tmpdir}/test.lua"

output=$(timeout "${TEST_TIMEOUT}" \
    docker run --rm \
    -v "${tmpdir}:/workspace" \
    --entrypoint="" \
    "${IMAGE}" \
    sh -c 'su devuser -c "nvim --headless /workspace/test.lua +\"lua vim.defer_fn(function() local c=vim.lsp.get_clients() print(#c) for _,v in ipairs(c) do print(v.name) end vim.cmd(\\\"qa\\\") end, 5000)\" 2>&1"' \
    2>&1 || echo "timeout")

assert_contains "lua-language-server attaches to .lua file" "${output}" "lua_ls"
rm -rf "${tmpdir}"

tmpdir=$(mktemp -d)
echo 'const x: number = 1' > "${tmpdir}/test.ts"

output=$(timeout "${TEST_TIMEOUT}" \
    docker run --rm \
    -v "${tmpdir}:/workspace" \
    --entrypoint="" \
    "${IMAGE}" \
    sh -c 'su devuser -c "nvim --headless /workspace/test.ts +\"lua vim.defer_fn(function() local c=vim.lsp.get_clients() print(#c) for _,v in ipairs(c) do print(v.name) end vim.cmd(\\\"qa\\\") end, 5000)\" 2>&1"' \
    2>&1 || echo "timeout")

assert_contains "ts_ls attaches to .ts file" "${output}" "ts_ls"
rm -rf "${tmpdir}"

# =============================================================================
# 8. Treesitter
# =============================================================================
log_header "8. Treesitter"

output=$(run 'ls /home/devuser/.local/share/nvim/site/parser/*.so 2>/dev/null | wc -l | tr -d " "')
assert_gte "At least 40 treesitter parsers compiled" "${output}" 40

for parser in lua python typescript javascript bash; do
    output=$(run "test -f /home/devuser/.local/share/nvim/site/parser/${parser}.so && echo exists || echo missing")
    assert_contains "Parser ${parser}.so present" "${output}" "exists"
done

tmpdir=$(mktemp -d)
echo 'local x = 1' > "${tmpdir}/test.lua"
output=$(timeout "${TEST_TIMEOUT}" \
    docker run --rm \
    -v "${tmpdir}:/workspace" \
    --entrypoint="" \
    "${IMAGE}" \
    sh -c 'su devuser -c "nvim --headless /workspace/test.lua +\"lua vim.defer_fn(function() local ok=pcall(vim.treesitter.get_parser,0,\\\"lua\\\") print(tostring(ok)) vim.cmd(\\\"qa\\\") end, 3000)\" 2>&1"' \
    2>&1 || echo "timeout")
assert_contains "Treesitter Lua parser loads for .lua file" "${output}" "true"
rm -rf "${tmpdir}"

# =============================================================================
# 9. blink.cmp
# =============================================================================
log_header "9. blink.cmp"

output=$(run 'su devuser -c "nvim --headless +\"lua vim.defer_fn(function() local ok,b=pcall(require,\\\"blink.cmp.config\\\") if ok then print(b.fuzzy.implementation) end vim.cmd(\\\"qa\\\") end, 3000)\" 2>&1"')
assert_equals "blink.cmp using Lua implementation (no binary download)" "${output}" "lua"

output=$(run 'test ! -f /home/devuser/.local/share/nvim/lazy/blink.cmp/target/release/libblink_cmp_fuzzy.so && echo "no binary" || echo "has binary"')
assert_equals "No pre-built Rust binary present (using Lua impl)" "${output}" "no binary"

# =============================================================================
# 10. Entrypoint
# =============================================================================
log_header "10. Entrypoint"

tmpdir=$(mktemp -d)
output=$(timeout "${TEST_TIMEOUT}" \
    docker run --rm \
    -v "${tmpdir}:/workspace" \
    "${IMAGE}" sh -c 'echo done' \
    2>&1 || echo "timeout")
assert_contains "Entrypoint runs and remaps UID/GID" "${output}" "Dropping privileges"
assert_contains "Entrypoint detects workspace owner" "${output}" "Detected /workspace owner"
rm -rf "${tmpdir}"

# =============================================================================
# Summary
# =============================================================================
TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo ""
echo -e "${CYAN}${BOLD}══════════════════════════════════════════${RESET}"
echo -e "${BOLD}  Test Summary${RESET}"
echo -e "${CYAN}${BOLD}══════════════════════════════════════════${RESET}"
echo -e "  Total:  ${TOTAL}"
echo -e "  ${GREEN}Passed: ${PASS_COUNT}${RESET}"
echo -e "  ${RED}Failed: ${FAIL_COUNT}${RESET}"

if [ ${FAIL_COUNT} -gt 0 ]; then
    echo ""
    echo -e "  ${RED}${BOLD}Failed tests:${RESET}"
    for t in "${FAILED_TESTS[@]}"; do
        echo -e "  ${RED}  • ${t}${RESET}"
    done
    echo ""
    exit 1
else
    echo ""
    echo -e "  ${GREEN}${BOLD}All tests passed! ✓${RESET}"
    echo ""
    exit 0
fi