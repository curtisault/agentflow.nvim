-- tests/minimal_init.lua — Minimal Neovim init for running tests with plenary.
-- Usage: nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/"

-- Point to plenary — search common pack locations
local data = vim.fn.stdpath("data")
local candidates = {
  data .. "/site/pack/nvim/start/plenary.nvim",
  data .. "/lazy/plenary.nvim",
  data .. "/site/pack/core/opt/plenary.nvim",
  data .. "/site/pack/core/start/plenary.nvim",
}
local plenary_path
for _, p in ipairs(candidates) do
  if vim.fn.isdirectory(p) == 1 then
    plenary_path = p
    break
  end
end
if not plenary_path then
  error("plenary.nvim not found — install it via your package manager")
end

vim.opt.runtimepath:prepend(plenary_path)

-- Add the plugin root to runtimepath so agentflow is require()-able
local this_file = debug.getinfo(1, "S").source:sub(2)
local plugin_root = vim.fn.fnamemodify(this_file, ":h:h")
vim.opt.runtimepath:prepend(plugin_root)

-- Stub vim.notify so test output stays clean
vim.notify = function(msg, level)
  local levels = { [1] = "ERROR", [2] = "WARN", [3] = "INFO", [4] = "DEBUG" }
  io.write(string.format("[notify %s] %s\n", levels[level] or "?", msg))
end
