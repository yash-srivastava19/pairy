-- pairy/init.lua — plugin entry point, public API

local config   = require("pairy.config")
local detector = require("pairy.detector")
local client   = require("pairy.client")
local renderer = require("pairy.renderer")
local util     = require("pairy.util")

local M = {}
local commands_registered = false
local _send_all_token     = nil  -- sentinel to stop an in-progress send_all chain

-- Per-session state for the inspect floating window
local inspect_state = { buf = nil, win = nil, job = nil, acc = "" }

local INSPECT_PROMPT = [[You are a concise code explanation assistant. The developer is hovering over a symbol or snippet and wants a quick explanation — like an enhanced hover.

Constraints:
- 2-4 sentences. Plain prose.
- No markdown headers. No bullet lists.
- Reference actual variable, function, and type names from the context.
- If it is a function, explain what it does and what to watch out for.
- If it is a variable or type, explain its role and typical values.
- If it is a code snippet, explain what the block accomplishes.]]

-- ─── Inspect float helpers ───────────────────────────────────────────────────

-- Close the inspect floating window and cancel any active request.
local function close_inspect()
  if inspect_state.job then
    inspect_state.job:kill(9)
    inspect_state.job = nil
  end
  if inspect_state.win and vim.api.nvim_win_is_valid(inspect_state.win) then
    vim.api.nvim_win_close(inspect_state.win, true)
  end
  inspect_state.buf = nil
  inspect_state.win = nil
  inspect_state.acc = ""
end

-- Open a small floating window near the cursor for inspect output.
-- Closes any previous inspect float first.
---@param caller_buf number  Buffer to watch for CursorMoved (auto-close trigger)
---@return number, number    (ibuf, iwin)
local function open_inspect_float(caller_buf)
  close_inspect()

  local width = math.min(70, math.floor(vim.o.columns * 0.65))
  local ibuf  = vim.api.nvim_create_buf(false, true)
  vim.bo[ibuf].filetype = "markdown"

  local iwin = vim.api.nvim_open_win(ibuf, false, {
    relative  = "cursor",
    row       = 1,
    col       = 0,
    width     = width,
    height    = 3,
    style     = "minimal",
    border    = "rounded",
    title     = " ⬡ Inspect ",
    title_pos = "center",
  })
  vim.wo[iwin].wrap      = true
  vim.wo[iwin].linebreak = true

  -- Auto-close when the user moves the cursor in the source buffer
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufLeave" }, {
    buffer   = caller_buf,
    once     = true,
    callback = close_inspect,
  })

  -- q closes the float from inside it
  vim.keymap.set("n", "q", close_inspect, {
    buffer = ibuf, silent = true, nowait = true,
  })

  inspect_state.buf = ibuf
  inspect_state.win = iwin
  inspect_state.acc = ""
  return ibuf, iwin
end

-- Append streaming text to the inspect float, resizing height to content.
---@param ibuf number  The inspect scratch buffer
---@param iwin number  The inspect window
---@param text string  New text chunk
local function inspect_append(ibuf, iwin, text)
  if not vim.api.nvim_buf_is_valid(ibuf) then return end
  inspect_state.acc = inspect_state.acc .. text
  local lines = vim.split(inspect_state.acc, "\n", { plain = true })
  vim.api.nvim_buf_set_lines(ibuf, 0, -1, false, lines)
  if vim.api.nvim_win_is_valid(iwin) then
    vim.api.nvim_win_set_height(iwin, math.max(3, math.min(15, #lines)))
  end
end

-- Shared internal: launch an inspect request and stream into the float.
---@param caller_buf   number
---@param cfg          PairyConfig
---@param pair_comment PairComment
local function do_inspect(caller_buf, cfg, pair_comment)
  local ibuf, iwin = open_inspect_float(caller_buf)
  vim.api.nvim_buf_set_lines(ibuf, 0, -1, false, { "thinking..." })

  local job = client.send(pair_comment, cfg, {
    on_token = function(token)
      if inspect_state.buf == ibuf then inspect_append(ibuf, iwin, token) end
    end,
    on_done  = function(_) end,
    on_error = function(msg)
      if inspect_state.buf == ibuf then
        vim.api.nvim_buf_set_lines(ibuf, 0, -1, false, { "error: " .. msg:sub(1, 60) })
        if vim.api.nvim_win_is_valid(iwin) then
          vim.api.nvim_win_set_height(iwin, 3)
        end
      end
    end,
  }, { system_prompt = INSPECT_PROMPT })

  if job then inspect_state.job = job end
end

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
    vim.api.nvim_create_user_command("PairyRetry",     M.retry,        { desc = "Re-send pair: comment at cursor" })
    vim.api.nvim_create_user_command("PairyClear",     M.clear,        { desc = "Clear all pairy responses in buffer" })
    vim.api.nvim_create_user_command("PairyClearLine", M.clear_line,   { desc = "Clear pairy response at cursor line" })
    vim.api.nvim_create_user_command("PairyAll",       M.send_all,     { desc = "Send all pair: comments in buffer" })
    vim.api.nvim_create_user_command("PairyCancel",    M.cancel,       { desc = "Cancel in-flight pairy request" })
    vim.api.nvim_create_user_command("PairyYank",      M.yank,         { desc = "Yank response at cursor to clipboard" })
    vim.api.nvim_create_user_command("PairyToggle",    M.toggle,       { desc = "Toggle visibility of all responses" })
    vim.api.nvim_create_user_command("PairySave",      M.save_session, { desc = "Save pairy session to a markdown file" })
    vim.api.nvim_create_user_command("PairyInspect",   M.inspect,      { desc = "Hover-style AI explanation of word under cursor" })
    vim.api.nvim_create_user_command("PairyInit",      M.init,         { desc = "Create config file from template" })
    vim.api.nvim_create_user_command("PairyDoctor",    M.doctor,       { desc = "Run :checkhealth pairy" })
    vim.api.nvim_create_user_command("PairyReload", function()
      for key in pairs(package.loaded) do
        if key:match("^pairy") then
          package.loaded[key] = nil
        end
      end
      require("pairy").setup({})
      util.notify("Pairy modules reloaded.")
    end, { desc = "Reload all pairy Lua modules from disk" })
    commands_registered = true
  end
end

-- ─── Internal helpers ───────────────────────────────────────────────────────

-- Build the opts table passed to client.send():
--   history         — prior answered pair: comments (for conversation threading)
--   project_context — contents of PAIRY.md found in the project tree
-- current_line_nr is excluded from history so a re-send doesn't include itself.
---@param buf            number
---@param cfg            PairyConfig
---@param current_line_nr number
---@return { history: table, project_context: string|nil }
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

  local max_h = cfg.max_history or 5
  while #history > max_h do table.remove(history, 1) end

  return {
    history         = history,
    project_context = detector.find_project_context(buf),
  }
end

-- Open a file in a centered floating window. Press q to dismiss.
-- Defined before save_session so the local is in scope when save_session closes over it.
---@param path string Absolute file path to display
local function open_float(path)
  local width  = math.floor(vim.o.columns * 0.82)
  local height = math.floor(vim.o.lines   * 0.82)
  local row    = math.floor((vim.o.lines   - height) / 2)
  local col    = math.floor((vim.o.columns - width)  / 2)

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

-- ─── Core actions ───────────────────────────────────────────────────────────

-- Common send logic shared by M.send, M.retry, M.ask_selection, M.send_all.
-- Starts a request for pair_comment and wires up renderer callbacks.
---@param buf          number
---@param pair_comment PairComment
---@param cfg          PairyConfig
---@param phase?       string  Pending indicator text (default: "thinking...")
local function do_send(buf, pair_comment, cfg, phase)
  local line_nr = pair_comment.line_nr
  local opts    = gather_opts(buf, cfg, line_nr)

  renderer.cancel_active(buf)
  renderer.show_pending(buf, line_nr, phase)

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

function M.send()
  local cfg = config.get()
  if not cfg.api_key or cfg.api_key == "" then
    util.notify_err("No API key. Run :PairyInit to set one up.")
    return
  end

  local buf          = vim.api.nvim_get_current_buf()
  local pair_comment = detector.find_at_cursor(buf, cfg)

  if not pair_comment then
    util.notify_warn("No 'pair:' comment found at or above cursor.")
    return
  end

  do_send(buf, pair_comment, cfg)
end

-- Re-send the pair: comment at cursor. Shows "retrying..." as the pending label
-- so it's visually distinct from a first send.
function M.retry()
  local cfg = config.get()
  if not cfg.api_key or cfg.api_key == "" then
    util.notify_err("No API key. Run :PairyInit to set one up.")
    return
  end

  local buf          = vim.api.nvim_get_current_buf()
  local pair_comment = detector.find_at_cursor(buf, cfg)

  if not pair_comment then
    util.notify_warn("No 'pair:' comment found at or above cursor.")
    return
  end

  do_send(buf, pair_comment, cfg, "retrying...")
end

function M.send_all()
  local cfg = config.get()
  if not cfg.api_key or cfg.api_key == "" then
    util.notify_err("No API key. Run :PairyInit to set one up.")
    return
  end

  local buf      = vim.api.nvim_get_current_buf()
  local comments = detector.find_all(buf, cfg)
  local total    = #comments

  if total == 0 then
    util.notify_warn("No 'pair:' comments found in buffer.")
    return
  end

  local token = {}  -- unique sentinel for this send_all invocation
  _send_all_token = token

  local i = 1
  local function send_next()
    if _send_all_token ~= token then return end

    local pair_comment = comments[i]
    if not pair_comment then
      util.notify(string.format("Done (%d/%d answered).", i - 1, total))
      return
    end

    local line_nr = pair_comment.line_nr
    local opts    = gather_opts(buf, cfg, line_nr)
    renderer.show_pending(buf, line_nr, string.format("[%d/%d]", i, total))

    local job = client.send(pair_comment, cfg, {
      on_token = function(tk) renderer.append_token(buf, line_nr, tk) end,
      on_done  = function(text)
        renderer.finalize(buf, line_nr, text)
        i = i + 1
        send_next()
      end,
      on_error = function(msg)
        if _send_all_token ~= token then return end
        renderer.show_error(buf, line_nr, msg)
        util.notify_err(string.format("[%d/%d] %s", i, total, msg))
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
  _send_all_token = nil
  renderer.cancel_active(vim.api.nvim_get_current_buf())
end

-- Copy the AI response for the pair: comment at/near cursor to the clipboard.
function M.yank()
  local buf = vim.api.nvim_get_current_buf()
  local cfg = config.get()
  local pair_comment = detector.find_at_cursor(buf, cfg)
  if not pair_comment then
    util.notify_warn("No 'pair:' comment found at or above cursor.")
    return
  end
  local text = renderer.get_responses(buf)[pair_comment.line_nr]
  if not text or text == "" then
    util.notify_warn("No response yet for this comment.")
    return
  end
  vim.fn.setreg("+", text)  -- system clipboard
  vim.fn.setreg('"', text)  -- unnamed register
  util.notify("Response yanked.")
end

-- Toggle visibility of all responses in the buffer without discarding them.
function M.toggle()
  local buf    = vim.api.nvim_get_current_buf()
  local hidden = renderer.toggle_hidden(buf)
  util.notify(hidden and "Responses hidden." or "Responses shown.")
end

-- Ask a question about a visual selection without writing a pair: comment.
-- Uses vim.ui.input for the prompt; anchors response to the last line of selection.
function M.ask_selection()
  local buf = vim.api.nvim_get_current_buf()
  local cfg = config.get()

  if not cfg.api_key or cfg.api_key == "" then
    util.notify_err("No API key. Run :PairyInit to set one up.")
    return
  end

  local start_line = vim.fn.line("'<") - 1
  local end_line   = vim.fn.line("'>")
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

  local line_nr = end_line - 1  -- 0-indexed, anchors to last selected line

  vim.ui.input({ prompt = "pair: " }, function(question)
    if not question or util.trim(question) == "" then return end

    local pair_comment = {
      line_nr  = line_nr,
      question = util.trim(question),
      context  = context,
      filetype = filetype,
      filename = filename,
    }

    do_send(buf, pair_comment, cfg)
  end)
end

-- Hover-style AI explanation of the word under cursor in a floating window.
-- No pair: comment needed — press <leader>aii on any symbol.
function M.inspect()
  local cfg = config.get()
  if not cfg.api_key or cfg.api_key == "" then
    util.notify_err("No API key. Run :PairyInit to set one up.")
    return
  end

  local buf       = vim.api.nvim_get_current_buf()
  local ok, word  = pcall(vim.fn.expand, "<cword>")
  if not ok or not word or word == "" then
    util.notify_warn("No word under cursor.")
    return
  end

  local filetype = vim.bo[buf].filetype
  local filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
  if filename == "" then filename = "[unnamed]" end

  local cur_line = vim.api.nvim_win_get_cursor(0)[1]   -- 1-indexed
  local ctx      = cfg.context_lines or 20
  local total    = vim.api.nvim_buf_line_count(buf)
  local start_l  = math.max(1, cur_line - ctx)
  local end_l    = math.min(total, cur_line + ctx)
  local raw      = vim.api.nvim_buf_get_lines(buf, start_l - 1, end_l, false)
  local numbered = {}
  for i, line in ipairs(raw) do
    local abs    = start_l + i - 1
    local marker = abs == cur_line and ">" or " "
    table.insert(numbered, string.format("%s %3d: %s", marker, abs, line))
  end

  local pair_comment = {
    line_nr  = cur_line - 1,  -- 0-indexed
    question = string.format("Explain `%s`.", word),
    context  = string.format(
      "File: %s (%s)\nLines %d-%d:\n\n```%s\n%s\n```",
      filename, filetype ~= "" and filetype or "text",
      start_l, end_l, filetype,
      table.concat(numbered, "\n")
    ),
    filetype = filetype,
    filename = filename,
  }

  do_inspect(buf, cfg, pair_comment)
end

-- Hover-style AI explanation of a visual selection in a floating window.
function M.inspect_selection()
  local cfg = config.get()
  if not cfg.api_key or cfg.api_key == "" then
    util.notify_err("No API key. Run :PairyInit to set one up.")
    return
  end

  local buf        = vim.api.nvim_get_current_buf()
  local start_line = vim.fn.line("'<") - 1
  local end_line   = vim.fn.line("'>")
  local selected   = util.buf_lines(buf, start_line, end_line)

  if #selected == 0 then
    util.notify_warn("No selection.")
    return
  end

  local filetype = vim.bo[buf].filetype
  local filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
  if filename == "" then filename = "[unnamed]" end

  local pair_comment = {
    line_nr  = end_line - 1,  -- 0-indexed, anchor to last selected line
    question = "Explain this code snippet.",
    context  = string.format(
      "File: %s (%s)\nSelected lines %d-%d:\n\n```%s\n%s\n```",
      filename, filetype ~= "" and filetype or "text",
      start_line + 1, end_line, filetype,
      table.concat(selected, "\n")
    ),
    filetype = filetype,
    filename = filename,
  }

  do_inspect(buf, cfg, pair_comment)
end

-- Save all answered pair: comments to a timestamped markdown file.
function M.save_session()
  local cfg       = config.get()
  local buf       = vim.api.nvim_get_current_buf()
  local comments  = detector.find_all(buf, cfg)
  local responses = renderer.get_responses(buf)

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

-- Create ~/.config/pairy/config.json from a template if it doesn't exist,
-- then open it for editing.
function M.init()
  local path = config.config_path()

  if vim.fn.filereadable(path) == 1 then
    util.notify("Config exists at " .. path .. ". Run :checkhealth pairy to validate.")
    return
  end

  local dir = vim.fn.fnamemodify(path, ":h")
  vim.fn.mkdir(dir, "p")

  local template = table.concat({
    "{",
    '  "api_key": "YOUR_GEMINI_API_KEY",',
    '  "model": "gemini-2.5-flash",',
    '  "context_lines": 20,',
    '  "max_tokens": 8192',
    "}",
    "",
  }, "\n")

  local f = io.open(path, "w")
  if not f then
    util.notify_err("Could not create " .. path)
    return
  end
  f:write(template)
  f:close()

  util.notify("Created " .. path .. " — add your API key and save.")
  vim.cmd("edit " .. path)
end

function M.doctor()
  vim.cmd("checkhealth pairy")
end

return M
