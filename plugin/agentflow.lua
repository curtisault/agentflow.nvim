-- plugin/agentflow.lua — Lazy-load entry point.
--
-- This file is sourced by Neovim automatically when the plugin directory
-- is on the runtimepath. It defers the actual setup so the plugin only
-- loads when explicitly configured by the user via require("agentflow").setup().

if vim.g.loaded_agentflow then return end
vim.g.loaded_agentflow = 1

-- Register the :checkhealth agentflow handler
vim.api.nvim_create_autocmd("User", {
  pattern  = "AgentFlowCheckhealth",
  callback = function()
    require("agentflow.health").check()
  end,
})
