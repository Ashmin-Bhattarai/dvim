-- =============================================================================
-- ts_compile.lua
--
-- Headless treesitter parser compilation script for Docker build.
-- Run as devuser inside the builder stage via:
--   nvim --headless -u /tmp/ts_compile.lua
--
-- Requires:
--   - gcc on PATH (from build-essential in builder stage)
--   - tree-sitter-cli on PATH (installed via npm in builder stage)
--   - nvim-treesitter already cloned into lazy plugin dir
-- =============================================================================

vim.opt.runtimepath:append("/home/devuser/.local/share/nvim/lazy/nvim-treesitter")

local install = require("nvim-treesitter.install")
local config  = require("nvim-treesitter.config")

-- -----------------------------------------------------------------------------
-- Verify required tools
-- -----------------------------------------------------------------------------
local gcc = vim.fn.exepath("gcc")
local cc  = vim.fn.exepath("cc")
local ts  = vim.fn.exepath("tree-sitter")
local install_dir = config.get_install_dir()
print("[ts-compile] gcc:         " .. (gcc ~= "" and gcc or "NOT FOUND"))
print("[ts-compile] cc:          " .. (cc  ~= "" and cc  or "NOT FOUND"))
print("[ts-compile] tree-sitter: " .. (ts  ~= "" and ts  or "NOT FOUND"))
print("[ts-compile] install_dir: " .. vim.inspect(install_dir))

if gcc == "" and cc == "" then
  print("[ts-compile] ERROR: no C compiler found — aborting")
  os.exit(1)
end

-- -----------------------------------------------------------------------------
-- LazyVim default parsers
-- -----------------------------------------------------------------------------
local parsers = {
  "bash", "c", "cmake", "css", "diff", "dockerfile",
  "fish", "git_config", "git_rebase", "gitattributes", "gitcommit",
  "gitignore", "go", "graphql", "html", "ini", "java",
  "javascript", "jsdoc", "json", "json5", "jsonc",
  "lua", "luadoc", "luap", "make", "markdown",
  "markdown_inline", "ninja", "perl", "php", "printf",
  "python", "query", "regex", "requirements", "rst", "ruby",
  "rust", "scss", "sql", "toml", "tsx", "typescript",
  "vim", "vimdoc", "vue", "xml", "yaml",
}

-- -----------------------------------------------------------------------------
-- Install parsers one at a time with pcall so a single failure
-- doesn't hang or abort the entire compilation run.
-- Timeout is 120s per parser to handle slow compilation on build machines.
-- -----------------------------------------------------------------------------
local TIMEOUT_MS = 120000  -- 120s per parser
local ok_count   = 0
local fail_count = 0
local failed     = {}

print("[ts-compile] Compiling " .. #parsers .. " parsers one by one...")

for i, parser in ipairs(parsers) do
  io.write(string.format("[ts-compile] [%d/%d] %s ... ", i, #parsers, parser))
  io.flush()

  local ok, err = pcall(function()
    local task = install.install({ parser })
    task:wait(TIMEOUT_MS)
  end)

  if ok then
    print("OK")
    ok_count = ok_count + 1
  else
    print("FAILED: " .. tostring(err))
    fail_count = fail_count + 1
    table.insert(failed, parser)
  end
end

-- -----------------------------------------------------------------------------
-- Summary — check install_dir for .so files, not the lazy plugin dir
-- install_dir is typically ~/.local/share/nvim/site/parser/
-- -----------------------------------------------------------------------------
local so_glob = install_dir .. "/parser/*.so"
print("[ts-compile] Checking for .so files in: " .. so_glob)
local sofiles = vim.fn.glob(so_glob, false, true)

print("")
print("[ts-compile] ========================================")
print("[ts-compile] Compiled:  " .. ok_count)
print("[ts-compile] Failed:    " .. fail_count)
print("[ts-compile] .so files: " .. #sofiles)
if #failed > 0 then
  print("[ts-compile] Failed parsers: " .. table.concat(failed, ", "))
end
for _, f in ipairs(sofiles) do
  print("[ts-compile]   " .. vim.fn.fnamemodify(f, ":t"))
end
print("[ts-compile] ========================================")

if #sofiles == 0 then
  print("[ts-compile] ERROR: zero parsers compiled — failing build")
  os.exit(1)
end

print("[ts-compile] Done.")
vim.cmd("qa!")