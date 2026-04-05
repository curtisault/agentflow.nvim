-- tests/minimal_init.lua — Minimal Neovim init for running tests with plenary.
-- Usage: nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/"

-- Point to plenary — tries vim.pack location first, then lazy.nvim fallback
local plenary_path = vim.fn.stdpath("data") .. "/site/pack/nvim/start/plenary.nvim"
if vim.fn.isdirectory(plenary_path) == 0 then
  plenary_path = vim.fn.stdpath("data") .. "/lazy/plenary.nvim"
end

vim.opt.runtimepath:prepend(plenary_path)

-- Add the plugin root to runtimepath so agentflow is require()-able
local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
vim.opt.runtimepath:prepend(plugin_root)

-- Stub vim.notify so test output stays clean
vim.notify = function(msg, level)
  local levels = { [1] = "ERROR", [2] = "WARN", [3] = "INFO", [4] = "DEBUG" }
  io.write(string.format("[notify %s] %s\n", levels[level] or "?", msg))
end
