local health = vim.health or require("health")
local config = require("pairy.config")
local util   = require("pairy.util")

local M = {}

function M.check()
  health.start("pairy")

  -- Neovim version
  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim 0.10+ available")
  else
    health.error("Neovim 0.10+ is required", {
      "Upgrade Neovim: https://github.com/neovim/neovim/releases",
    })
  end

  -- curl
  if util.has_executable("curl") then
    health.ok("curl found in PATH")
  else
    health.error("curl is required but not found in PATH", {
      "Install curl — on Arch: sudo pacman -S curl",
      "             — on Ubuntu/Debian: sudo apt install curl",
      "             — on macOS: brew install curl",
    })
  end

  -- API key
  local cfg = config.get()
  if cfg.api_key and cfg.api_key ~= "" then
    health.ok("api_key configured")
  else
    health.warn("api_key is missing — pairy cannot send requests", {
      "1. Get a free key: https://aistudio.google.com/app/apikey",
      "2. Run :PairyInit to create the config file from a template.",
      "   Then edit ~/.config/pairy/config.json and add your key.",
    })
  end

  -- Model
  if cfg.model and cfg.model ~= "" then
    health.ok("model: " .. cfg.model)
  else
    health.warn("model not set — will fall back to gemini-2.5-flash", {
      'Add "model": "gemini-2.5-flash" to ~/.config/pairy/config.json',
    })
  end

  -- Sessions dir writability
  local sessions_dir = vim.fn.expand(cfg.sessions_dir or "~/.local/share/pairy/sessions")
  vim.fn.mkdir(sessions_dir, "p")
  if vim.fn.isdirectory(sessions_dir) == 1 then
    health.ok("sessions_dir writable: " .. sessions_dir)
  else
    health.warn("sessions_dir could not be created: " .. sessions_dir, {
      "Check permissions or set a different sessions_dir in config.",
    })
  end
end

return M
