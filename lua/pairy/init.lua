-- pairy/init.lua — plugin entry point, public API

local config   = require("pairy.config")
local detector = require("pairy.detector")
local client   = require("pairy.client")
local renderer = require("pairy.renderer")
local util     = require("pairy.util")

local M = {}

-- ─── Setup ──────────────────────────────────────────────────────────────────

function M.setup(opts)
  config.apply_overrides(opts or {})

  renderer.setup_highlights()

  vim.api.nvim_create_autocmd("ColorScheme", {
    group    = vim.api.nvim_create_augroup("PairyHighlights", { clear = true }),
    callback = renderer.setup_highlights,
  })

  vim.api.nvim_create_user_command("PairySend",      M.send,       { desc = "Send pair: comment at cursor to AI" })
  vim.api.nvim_create_user_command("PairyClear",     M.clear,      { desc = "Clear all pairy responses in buffer" })
  vim.api.nvim_create_user_command("PairyClearLine", M.clear_line, { desc = "Clear pairy response at cursor line" })
  vim.api.nvim_create_user_command("PairyAll",       M.send_all,   { desc = "Send all pair: comments in buffer" })
  vim.api.nvim_create_user_command("PairyCancel",    M.cancel,     { desc = "Cancel in-flight pairy request" })
  vim.api.nvim_create_user_command("PairyReload", function()
    config.reload()
    util.notify("Config reloaded.")
  end, { desc = "Reload pairy config from disk" })
end

-- ─── Core actions ───────────────────────────────────────────────────────────

function M.send()
  local cfg = config.get()
  if not cfg.api_key or cfg.api_key == "" then
    util.notify_err("No API key found. Add 'api_key' to ~/.config/pairy/config.json")
    return
  end

  local buf          = vim.api.nvim_get_current_buf()
  local pair_comment = detector.find_at_cursor(buf, cfg)

  if not pair_comment then
    util.notify_warn("No 'pair:' comment found at or above cursor.")
    return
  end

  renderer.cancel_active(buf)
  renderer.show_pending(buf, pair_comment.line_nr)

  local line_nr = pair_comment.line_nr

  local job = client.send(pair_comment, cfg, {
    on_token = function(token) renderer.append_token(buf, line_nr, token) end,
    on_done  = function(text)  renderer.finalize(buf, line_nr, text) end,
    on_error = function(msg)
      renderer.show_error(buf, line_nr, msg)
      util.notify_err(msg)
    end,
  })

  if job then renderer.set_active_job(buf, job) end
end

function M.send_all()
  local cfg = config.get()
  if not cfg.api_key or cfg.api_key == "" then
    util.notify_err("No API key found. Add 'api_key' to ~/.config/pairy/config.json")
    return
  end

  local buf      = vim.api.nvim_get_current_buf()
  local comments = detector.find_all(buf, cfg)

  if #comments == 0 then
    util.notify_warn("No 'pair:' comments found in buffer.")
    return
  end

  util.notify(string.format("Sending %d pair: comment(s)...", #comments))

  for i, pair_comment in ipairs(comments) do
    vim.defer_fn(function()
      local line_nr = pair_comment.line_nr
      renderer.show_pending(buf, line_nr)
      client.send(pair_comment, cfg, {
        on_token = function(token) renderer.append_token(buf, line_nr, token) end,
        on_done  = function(text)  renderer.finalize(buf, line_nr, text) end,
        on_error = function(msg)
          renderer.show_error(buf, line_nr, msg)
          util.notify_err(string.format("Comment %d: %s", i, msg))
        end,
      })
    end, (i - 1) * 300)
  end
end

function M.clear()
  local buf = vim.api.nvim_get_current_buf()
  renderer.cancel_active(buf)
  renderer.clear_all(buf)
end

function M.clear_line()
  local buf          = vim.api.nvim_get_current_buf()
  local pair_comment = detector.find_at_cursor(buf, config.get())
  local line_nr      = pair_comment and pair_comment.line_nr
                       or (vim.api.nvim_win_get_cursor(0)[1] - 1)
  renderer.clear_line(buf, line_nr)
end

function M.cancel()
  renderer.cancel_active(vim.api.nvim_get_current_buf())
end

return M
