-- pairy/init.lua — plugin entry point, public API

local config   = require("pairy.config")
local detector = require("pairy.detector")
local client   = require("pairy.client")
local renderer = require("pairy.renderer")
local util     = require("pairy.util")

local M = {}
local commands_registered = false
local _send_all_token = nil  -- sentinel to stop an in-progress send_all chain

-- ─── Setup ──────────────────────────────────────────────────────────────────

function M.setup(opts)
  config.apply_overrides(opts or {})

  renderer.setup_highlights()

  vim.api.nvim_create_autocmd("ColorScheme", {
    group    = vim.api.nvim_create_augroup("PairyHighlights", { clear = true }),
    callback = renderer.setup_highlights,
  })

  if not commands_registered then
    vim.api.nvim_create_user_command("PairySend",      M.send,         { desc = "Send pair: comment at cursor to AI" })
    vim.api.nvim_create_user_command("PairyClear",     M.clear,        { desc = "Clear all pairy responses in buffer" })
    vim.api.nvim_create_user_command("PairyClearLine", M.clear_line,   { desc = "Clear pairy response at cursor line" })
    vim.api.nvim_create_user_command("PairyAll",       M.send_all,     { desc = "Send all pair: comments in buffer" })
    vim.api.nvim_create_user_command("PairyCancel",    M.cancel,       { desc = "Cancel in-flight pairy request" })
    vim.api.nvim_create_user_command("PairySave",      M.save_session, { desc = "Save pairy session to a markdown file" })
    vim.api.nvim_create_user_command("PairyReload", function()
      config.reload()
      util.notify("Config reloaded.")
    end, { desc = "Reload pairy config from disk" })
    vim.api.nvim_create_user_command("PairyDoctor", M.doctor, { desc = "Validate pairy setup and dependencies" })
    commands_registered = true
  end
end

-- ─── Internal helpers ───────────────────────────────────────────────────────

-- Build the opts table passed to client.send():
--   history         — prior answered pair: comments in this buffer (for threading)
--   project_context — contents of PAIRY.md found in the project tree
-- current_line_nr is excluded from history so a re-send doesn't include itself.
local function gather_opts(buf, cfg, current_line_nr)
  local responses    = renderer.get_responses(buf)
  local all_comments = detector.find_all(buf, cfg)

  local history = {}
  for _, c in ipairs(all_comments) do
    if c.line_nr ~= current_line_nr
      and responses[c.line_nr] and responses[c.line_nr] ~= ""
    then
      table.insert(history, { question = c.question, response = responses[c.line_nr] })
    end
  end

  -- Keep only the most recent N exchanges to avoid token bloat
  local max_h = cfg.max_history or 5
  while #history > max_h do table.remove(history, 1) end

  return {
    history         = history,
    project_context = detector.find_project_context(buf),
  }
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

  local line_nr = pair_comment.line_nr
  local opts    = gather_opts(buf, cfg, line_nr)

  renderer.cancel_active(buf)
  renderer.show_pending(buf, line_nr)

  local job = client.send(pair_comment, cfg, {
    on_token = function(token) renderer.append_token(buf, line_nr, token) end,
    on_done  = function(text)  renderer.finalize(buf, line_nr, text) end,
    on_error = function(msg)
      renderer.show_error(buf, line_nr, msg)
      util.notify_err(msg)
    end,
  }, opts)

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

  local token = {}  -- unique sentinel for this send_all invocation
  _send_all_token = token

  local i = 1
  local function send_next()
    if _send_all_token ~= token then return end  -- cancelled or superseded

    local pair_comment = comments[i]
    if not pair_comment then
      util.notify("Finished sending all pair: comments.")
      return
    end

    local line_nr = pair_comment.line_nr
    local opts = gather_opts(buf, cfg, line_nr)
    renderer.show_pending(buf, line_nr)

    local job = client.send(pair_comment, cfg, {
      on_token = function(token_chunk) renderer.append_token(buf, line_nr, token_chunk) end,
      on_done  = function(text)
        renderer.finalize(buf, line_nr, text)
        i = i + 1
        send_next()
      end,
      on_error = function(msg)
        if _send_all_token ~= token then return end  -- swallow errors from a cancelled job
        renderer.show_error(buf, line_nr, msg)
        util.notify_err(string.format("Comment %d: %s", i, msg))
        i = i + 1
        send_next()
      end,
    }, opts)

    if job then renderer.set_active_job(buf, job) end
  end

  send_next()
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
  _send_all_token = nil  -- stop any in-progress send_all chain
  renderer.cancel_active(vim.api.nvim_get_current_buf())
end

-- Ask a question about a visual selection without writing a pair: comment.
-- Triggered from visual mode; uses vim.ui.input for the question prompt.
-- The response appears as virtual text at the last line of the selection.
function M.ask_selection()
  local buf = vim.api.nvim_get_current_buf()
  local cfg = config.get()

  if not cfg.api_key or cfg.api_key == "" then
    util.notify_err("No API key found. Add 'api_key' to ~/.config/pairy/config.json")
    return
  end

  -- Visual marks '<  and '> are set when leaving visual mode (which this keymap does)
  local start_line = vim.fn.line("'<") - 1  -- 0-indexed
  local end_line   = vim.fn.line("'>")       -- exclusive
  local selected   = util.buf_lines(buf, start_line, end_line)

  if #selected == 0 then
    util.notify_warn("No selection.")
    return
  end

  local filetype = vim.bo[buf].filetype
  local filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
  if filename == "" then filename = "[unnamed]" end

  local context = string.format(
    "File: %s (%s)\nSelected lines %d-%d:\n\n```%s\n%s\n```",
    filename, filetype ~= "" and filetype or "text",
    start_line + 1, end_line,
    filetype,
    table.concat(selected, "\n")
  )

  -- Response virtual text anchors to the last line of the selection
  local line_nr = end_line - 1  -- 0-indexed

  vim.ui.input({ prompt = "pair: " }, function(question)
    if not question or util.trim(question) == "" then return end

    local pair_comment = {
      line_nr  = line_nr,
      question = util.trim(question),
      context  = context,
      filetype = filetype,
      filename = filename,
    }

    local opts = gather_opts(buf, cfg, line_nr)

    renderer.cancel_active(buf)
    renderer.show_pending(buf, line_nr)

    local job = client.send(pair_comment, cfg, {
      on_token = function(token) renderer.append_token(buf, line_nr, token) end,
      on_done  = function(text)  renderer.finalize(buf, line_nr, text) end,
      on_error = function(msg)
        renderer.show_error(buf, line_nr, msg)
        util.notify_err(msg)
      end,
    }, opts)

    if job then renderer.set_active_job(buf, job) end
  end)
end

-- Save all answered pair: comments in the buffer to a timestamped markdown file.
-- The file is a readable log of the session: question, code context, and response.
function M.save_session()
  local cfg       = config.get()
  local buf       = vim.api.nvim_get_current_buf()
  local comments  = detector.find_all(buf, cfg)
  local responses = renderer.get_responses(buf)

  -- Only save comments that have a response
  local answered = {}
  for _, c in ipairs(comments) do
    if responses[c.line_nr] and responses[c.line_nr] ~= "" then
      table.insert(answered, c)
    end
  end

  if #answered == 0 then
    util.notify_warn("Nothing to save — no answered pair: comments in buffer.")
    return
  end

  local filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
  if filename == "" then filename = "unnamed" end

  -- Build markdown content
  local lines = {
    "# Pairy Session",
    "",
    "**File:** " .. filename,
    "**Date:** " .. os.date("%Y-%m-%d %H:%M"),
    "",
    "---",
    "",
  }

  for _, c in ipairs(answered) do
    table.insert(lines, "### " .. c.question)
    table.insert(lines, "")
    table.insert(lines, c.context)
    table.insert(lines, "")
    table.insert(lines, "**Response:**")
    table.insert(lines, "")
    table.insert(lines, responses[c.line_nr])
    table.insert(lines, "")
    table.insert(lines, "---")
    table.insert(lines, "")
  end

  -- Write to sessions directory
  local sessions_dir = vim.fn.expand(cfg.sessions_dir)
  vim.fn.mkdir(sessions_dir, "p")

  local safe_name    = filename:gsub("[^%w%-_.]", "_")
  local timestamp    = os.date("%Y%m%d_%H%M%S")
  local session_path = sessions_dir .. "/" .. timestamp .. "_" .. safe_name .. ".md"

  local f = io.open(session_path, "w")
  if not f then
    util.notify_err("Could not write to " .. session_path)
    return
  end
  f:write(table.concat(lines, "\n"))
  f:close()

  util.notify(string.format("Session saved (%d Q&A) → %s", #answered, session_path))
  open_float(session_path)
end

-- Open a file in a centered floating window. Press q to dismiss.
-- Does not create any splits or disturb the current window layout.
local function open_float(path)
  local width  = math.floor(vim.o.columns * 0.82)
  local height = math.floor(vim.o.lines   * 0.82)
  local row    = math.floor((vim.o.lines   - height) / 2)
  local col    = math.floor((vim.o.columns - width)  / 2)

  -- bufadd + bufload = file-backed buffer without opening it in any window
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  vim.bo[buf].buflisted  = false
  vim.bo[buf].filetype   = "markdown"
  vim.bo[buf].modifiable = false

  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    width     = width,
    height    = height,
    row       = row,
    col       = col,
    style     = "minimal",
    border    = "rounded",
    title     = " Pairy Session ",
    title_pos = "center",
  })

  vim.wo[win].wrap      = true
  vim.wo[win].linebreak = true

  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf, silent = true, nowait = true })
end

function M.doctor()
  vim.cmd("checkhealth pairy")
end

return M
