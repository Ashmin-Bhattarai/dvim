-- =============================================================================
-- lua/plugins/blink-override.lua
--
-- Override blink.cmp to use the pure Lua fuzzy implementation.
--
-- Why: blink.cmp is installed from the main branch (not a release tag),
-- so it cannot resolve a GitHub release to download the pre-built Rust binary.
-- The Lua implementation is functionally equivalent and requires no binary.
-- =============================================================================
return {
  "saghen/blink.cmp",
  opts = {
    fuzzy = {
      implementation = "lua",
    },
  },
}