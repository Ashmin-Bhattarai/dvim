-- =============================================================================
-- lua/config/options.lua
--
-- LazyVim user options entry point.
-- Add your own vim.opt settings here, or better — put them in
-- ~/.config/dvim/user.lua on your host (mounted by the dvim launcher).
--
-- See: https://www.lazyvim.org/configuration/general
-- =============================================================================

-- Load user and project configs (system-wide and project-level)
-- This must be at the bottom so LazyVim defaults are set first.
require("config.user")