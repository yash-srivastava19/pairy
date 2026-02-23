-- pairy/config.lua — configuration loading and management

local util = require("pairy.util")

local M = {}

---@class PairyConfig
---@field api_key       string  Google AI Studio API key (required)
---@field model         string  Gemini model ID
---@field context_lines number  Lines of code above/below pair: comment sent as context
---@field max_tokens    number  Max response token limit
---@field max_history   number  Max prior Q&As included as conversation context
---@field sessions_dir  string  Directory where :PairySave writes files

---@type PairyConfig
M.defaults = {
  model         = "gemini-2.5-flash",
  context_lines = 20,
  max_tokens    = 8192,
  max_history   = 5,
  sessions_dir  = "~/.local/share/pairy/sessions",
}

M._config    = nil  -- cached after first load
M._overrides = {}   -- inline overrides from setup(opts)

---@return string  Absolute path to the config file
function M.config_path()
  return vim.fn.expand("~/.config/pairy/config.json")
end

---@return PairyConfig
function M.load()
  local path          = M.config_path()
  local decoded, err  = util.read_json_file(path)

  if not decoded then
    if err:find("file not found") then
      util.notify_warn("Config not found at " .. path .. ". Run :PairyInit to create it.")
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

-- Returns cached config; loads from disk on first access.
---@return PairyConfig
function M.get()
  if not M._config then M.load() end
  return M._config
end

-- Apply inline overrides from setup(opts). Call before first M.get().
---@param opts table
function M.apply_overrides(opts)
  if opts and type(opts) == "table" then
    M._overrides = opts
  end
  M._config = nil  -- invalidate cache so next get() picks up overrides
end

-- Reload config from disk (useful for :PairyReload).
---@return PairyConfig
function M.reload()
  M._config = nil
  return M.load()
end

return M
