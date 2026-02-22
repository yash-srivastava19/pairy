-- pairy/config.lua — configuration loading and management

local util = require("pairy.util")

local M = {}

M.defaults = {
  model           = "claude-sonnet-4-6",
  context_lines   = 20,
  max_tokens      = 512,
  comment_trigger = "pair:",
  api_url         = "https://api.anthropic.com/v1/messages",
  api_version     = "2023-06-01",
}

M._config = nil   -- cached after first load
M._overrides = {} -- inline overrides from setup(opts)

function M.config_path()
  return vim.fn.expand("~/.config/pairy/config.json")
end

function M.load()
  local path = M.config_path()
  local decoded, err = util.read_json_file(path)

  if not decoded then
    if err:find("file not found") then
      util.notify_warn("Config not found at " .. path .. ". Create it with your API key.")
    else
      util.notify_err("Config error: " .. err)
    end
    decoded = {}
  end

  -- Merge: defaults < file < inline overrides
  M._config = vim.tbl_deep_extend("force",
    vim.deepcopy(M.defaults),
    decoded,
    M._overrides
  )

  return M._config
end

-- Returns cached config, loads on first access
function M.get()
  if not M._config then
    M.load()
  end
  return M._config
end

-- Returns api_key or nil
function M.get_api_key()
  local cfg = M.get()
  if not cfg.api_key or cfg.api_key == "" then
    return nil
  end
  return cfg.api_key
end

-- Apply inline overrides from setup(opts) — called before first M.get()
function M.apply_overrides(opts)
  if opts and type(opts) == "table" then
    M._overrides = opts
  end
  -- Invalidate cache so next M.get() picks up overrides
  M._config = nil
end

-- Reload from disk (useful for hot-reloading config changes)
function M.reload()
  M._config = nil
  return M.load()
end

return M
