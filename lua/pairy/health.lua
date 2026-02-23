local health = vim.health or require("health")
local config = require("pairy.config")
local util = require("pairy.util")

local M = {}

function M.check()
  health.start("pairy")

  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim 0.10+ available")
  else
    health.error("Neovim 0.10+ is required")
  end

  if util.has_executable("curl") then
    health.ok("curl found in PATH")
  else
    health.error("curl missing from PATH")
  end

  local cfg = config.get()
  if cfg.api_key and cfg.api_key ~= "" then
    health.ok("api_key configured")
  else
    health.warn("api_key is missing", {
      "Add ~/.config/pairy/config.json with your API key.",
      "Run :PairyDoctor for a quick status summary.",
    })
  end

  if cfg.model and cfg.model ~= "" then
    health.ok("model configured: " .. cfg.model)
  else
    health.warn("model not configured", { "Set a model in ~/.config/pairy/config.json" })
  end
end

return M
