-- pairy/init.lua — plugin entry point, public API

local M = {}

-- Lazy-load sub-modules to keep startup fast
local function cfg()    return require("pairy.config")   end
local function det()    return require("pairy.detector")  end
local function cli()    return require("pairy.client")    end
local function ren()    return require("pairy.renderer")  end

-- ─── Setup ──────────────────────────────────────────────────────────────────

function M.setup(opts)
  -- Apply any inline overrides (model, context_lines, etc.)
  cfg().apply_overrides(opts or {})

  -- Register highlight groups
  ren().setup_highlights()

  -- Re-register highlights after colorscheme changes
  vim.api.nvim_create_autocmd("ColorScheme", {
    group    = vim.api.nvim_create_augroup("PairyHighlights", { clear = true }),
    callback = function() ren().setup_highlights() end,
  })

  -- Register user commands
  vim.api.nvim_create_user_command("PairySend", function()
    M.send()
  end, { desc = "Send pair: comment at cursor to Claude" })

  vim.api.nvim_create_user_command("PairyClear", function()
    M.clear()
  end, { desc = "Clear all pairy virtual text responses in buffer" })

  vim.api.nvim_create_user_command("PairyClearLine", function()
    M.clear_line()
  end, { desc = "Clear pairy response at cursor line" })

  vim.api.nvim_create_user_command("PairyAll", function()
    M.send_all()
  end, { desc = "Process all pair: comments in buffer" })

  vim.api.nvim_create_user_command("PairyCancel", function()
    M.cancel()
  end, { desc = "Cancel in-flight pairy request" })

  vim.api.nvim_create_user_command("PairyReload", function()
    cfg().reload()
    require("pairy.util").notify("Config reloaded.")
  end, { desc = "Reload pairy config from disk" })

  -- Register keymaps
  local map = vim.keymap.set
  local opts_map = { noremap = true, silent = true }

  map("n", "<leader>ais", function() M.send() end,
    vim.tbl_extend("force", opts_map, { desc = "Pairy: Send comment at cursor" }))

  map("n", "<leader>aic", function() M.clear() end,
    vim.tbl_extend("force", opts_map, { desc = "Pairy: Clear all responses" }))

  map("n", "<leader>aix", function() M.clear_line() end,
    vim.tbl_extend("force", opts_map, { desc = "Pairy: Clear response at cursor" }))

  map("n", "<leader>aia", function() M.send_all() end,
    vim.tbl_extend("force", opts_map, { desc = "Pairy: Send all pair: comments" }))

  map("n", "<leader>aiK", function() M.cancel() end,
    vim.tbl_extend("force", opts_map, { desc = "Pairy: Cancel in-flight request" }))

  map("n", "<leader>air", function() cfg().reload(); require("pairy.util").notify("Config reloaded.") end,
    vim.tbl_extend("force", opts_map, { desc = "Pairy: Reload config" }))
end

-- ─── Core actions ───────────────────────────────────────────────────────────

-- Send the pair: comment at (or near) the cursor to Claude.
function M.send()
  local config = cfg().get()
  local api_key = cfg().get_api_key()
  if not api_key then
    require("pairy.util").notify_err(
      "No API key found. Add 'api_key' to ~/.config/pairy/config.json"
    )
    return
  end

  local buf          = vim.api.nvim_get_current_buf()
  local pair_comment = det().find_at_cursor(buf, config)

  if not pair_comment then
    require("pairy.util").notify_warn(
      "No 'pair:' comment found at or above cursor. Write '# pair: your question' first."
    )
    return
  end

  -- Cancel any in-flight request for this buffer
  ren().cancel_active(buf)

  -- Show pending indicator immediately
  ren().show_pending(buf, pair_comment.line_nr)

  local line_nr = pair_comment.line_nr

  -- Send to Claude
  local job = cli().send(pair_comment, config, {
    on_token = function(token)
      -- vim.schedule already applied inside client.lua
      ren().append_token(buf, line_nr, token)
    end,
    on_done = function(full_text)
      ren().finalize(buf, line_nr, full_text)
    end,
    on_error = function(msg)
      ren().show_error(buf, line_nr, msg)
      require("pairy.util").notify_err(msg)
    end,
  })

  if job then
    ren().set_active_job(buf, job)
  end
end

-- Send ALL pair: comments in the buffer, staggered to avoid rate limits.
function M.send_all()
  local config = cfg().get()
  if not cfg().get_api_key() then
    require("pairy.util").notify_err(
      "No API key found. Add 'api_key' to ~/.config/pairy/config.json"
    )
    return
  end

  local buf      = vim.api.nvim_get_current_buf()
  local comments = det().find_all(buf, config)

  if #comments == 0 then
    require("pairy.util").notify_warn("No 'pair:' comments found in buffer.")
    return
  end

  require("pairy.util").notify(
    string.format("Sending %d pair: comment(s)...", #comments)
  )

  -- Stagger requests 300ms apart to be polite to the API
  for i, pair_comment in ipairs(comments) do
    vim.defer_fn(function()
      ren().show_pending(buf, pair_comment.line_nr)
      local line_nr = pair_comment.line_nr
      cli().send(pair_comment, config, {
        on_token = function(token)
          ren().append_token(buf, line_nr, token)
        end,
        on_done = function(full_text)
          ren().finalize(buf, line_nr, full_text)
        end,
        on_error = function(msg)
          ren().show_error(buf, line_nr, msg)
          require("pairy.util").notify_err(
            string.format("Error on comment %d: %s", i, msg)
          )
        end,
      })
    end, (i - 1) * 300)
  end
end

-- Clear all virtual text responses in the current buffer.
function M.clear()
  local buf = vim.api.nvim_get_current_buf()
  ren().cancel_active(buf)
  ren().clear_all(buf)
end

-- Clear the virtual text response at/near the cursor line.
function M.clear_line()
  local buf          = vim.api.nvim_get_current_buf()
  local config       = cfg().get()
  local pair_comment = det().find_at_cursor(buf, config)

  if not pair_comment then
    -- Fall back to clearing the exact cursor line
    local line_nr = vim.api.nvim_win_get_cursor(0)[1] - 1
    ren().clear_line(buf, line_nr)
  else
    ren().clear_line(buf, pair_comment.line_nr)
  end
end

-- Cancel any in-flight request for the current buffer.
function M.cancel()
  local buf = vim.api.nvim_get_current_buf()
  ren().cancel_active(buf)
end

return M
