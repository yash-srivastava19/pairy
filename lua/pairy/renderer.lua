-- pairy/renderer.lua — virtual text lifecycle via extmarks + word-drip streaming

local util = require("pairy.util")

local M = {}

local ns = vim.api.nvim_create_namespace("pairy")

local MARKER     = "⬡ "   -- 2 chars, prepended after indentation
local WORD_DELAY = 45      -- ms between words in the drip animation

-- Per-buffer state
-- state[bufnr] = { extmarks={[line_nr]=id}, responses={[line_nr]=str}, active_job=nil }
local state = {}

-- Per-line word queues for the drip animation
-- queues[bufnr][line_nr] = { words={str,...}, active=bool, finalized=bool }
local queues = {}

local function get_state(buf)
  if not state[buf] then
    state[buf] = { extmarks = {}, responses = {}, active_job = nil }
  end
  return state[buf]
end

local function get_queue(buf, line_nr)
  if not queues[buf] then queues[buf] = {} end
  if not queues[buf][line_nr] then
    queues[buf][line_nr] = { words = {}, active = false, finalized = false }
  end
  return queues[buf][line_nr]
end

-- Get the leading whitespace of a buffer line (for indentation matching)
local function get_indent(buf, line_nr)
  local lines = vim.api.nvim_buf_get_lines(buf, line_nr, line_nr + 1, false)
  if not lines[1] then return "" end
  return lines[1]:match("^(%s*)") or ""
end

-- Get the display width of the window showing this buffer
local function get_win_width(buf)
  local wins = vim.fn.win_findbuf(buf)
  if wins and wins[1] then
    return vim.api.nvim_win_get_width(wins[1])
  end
  return vim.o.columns
end

-- Compute indent string and available wrap width for a given line
local function layout(buf, line_nr)
  local indent   = get_indent(buf, line_nr)
  local win_w    = get_win_width(buf)
  -- subtract: indent + marker + small safety margin
  local wrap_w   = math.max(20, win_w - #indent - #MARKER - 2)
  local cont_pad = indent .. string.rep(" ", #MARKER)  -- continuation indent
  return indent, cont_pad, wrap_w
end

-- Convert response text to virt_lines, respecting window width and indentation
local function text_to_virt_lines(text, hl_group, indent, cont_pad, wrap_w)
  hl_group = hl_group or "PairyResponse"
  indent   = indent   or ""
  cont_pad = cont_pad or string.rep(" ", #MARKER)
  wrap_w   = wrap_w   or 72

  if not text or text == "" then
    return { { { indent .. MARKER .. "...", "PairyPending" } } }
  end

  local result    = {}
  local raw_lines = util.split_lines(text)

  for i, raw_line in ipairs(raw_lines) do
    if raw_line == "" then
      if i < #raw_lines then
        table.insert(result, { { "", hl_group } })
      end
    else
      local wrapped = util.wrap_text(raw_line, wrap_w)
      for j, segment in ipairs(wrapped) do
        if j == 1 then
          table.insert(result, {
            { indent .. MARKER, "PairyMarker" },
            { segment, hl_group },
          })
        else
          table.insert(result, {
            { cont_pad, hl_group },
            { segment, hl_group },
          })
        end
      end
    end
  end

  if #result == 0 then
    result = { { { indent .. MARKER .. "...", "PairyPending" } } }
  end
  return result
end

-- Redraw the extmark for a given line with current accumulated text
local function redraw(buf, line_nr, hl)
  local st = get_state(buf)
  local extmark_id = st.extmarks[line_nr]
  if not extmark_id then return end
  local text               = st.responses[line_nr] or ""
  local indent, cont_pad, wrap_w = layout(buf, line_nr)
  local virt               = text_to_virt_lines(text, hl, indent, cont_pad, wrap_w)
  vim.api.nvim_buf_set_extmark(buf, ns, line_nr, 0, {
    id               = extmark_id,
    virt_lines       = virt,
    virt_lines_above = false,
  })
end

-- Split a string into displayable units, keeping spacing attached to each word.
-- "Hello world" -> {"Hello", " world"}
local function tokenize(s)
  local parts = {}
  local i = 1
  while i <= #s do
    local space = s:match("^(%s+)", i) or ""
    i = i + #space
    if i > #s then
      if space ~= "" then table.insert(parts, space) end
      break
    end
    local word = s:match("^(%S+)", i) or ""
    i = i + #word
    table.insert(parts, space .. word)
  end
  return parts
end

-- Word-drip consumer: pop one word, display it, schedule next tick
local function tick(buf, line_nr)
  local q = get_queue(buf, line_nr)
  if #q.words == 0 then
    q.active = false
    if q.finalized then
      redraw(buf, line_nr, "PairyResponse")
    end
    return
  end

  local st = get_state(buf)
  if not st or not st.extmarks[line_nr] then
    q.active = false
    return
  end

  local word = table.remove(q.words, 1)
  st.responses[line_nr] = (st.responses[line_nr] or "") .. word
  redraw(buf, line_nr, "PairyPending")

  vim.defer_fn(function() tick(buf, line_nr) end, WORD_DELAY)
end

-- ─── Public API ─────────────────────────────────────────────────────────────

function M.setup_highlights()
  vim.api.nvim_set_hl(0, "PairyMarker",   { fg = "#7C7C7C", bold = true,   default = true })
  vim.api.nvim_set_hl(0, "PairyResponse", { fg = "#6C6C6C", italic = true, default = true })
  vim.api.nvim_set_hl(0, "PairyPending",  { fg = "#555555", italic = true, default = true })
  vim.api.nvim_set_hl(0, "PairyError",    { fg = "#C25A5A", italic = true, default = true })
end

---@return number  Extmark namespace id
function M.get_namespace() return ns end

-- Show a pending indicator when a request starts.
-- Deletes any existing extmark on this line first to avoid orphaned virtual text.
---@param buf     number Buffer handle
---@param line_nr number 0-indexed line
---@param phase?  string Status text (default: "thinking...")
function M.show_pending(buf, line_nr, phase)
  local st = get_state(buf)

  -- Delete existing extmark for this line before creating a new one
  if st.extmarks[line_nr] then
    vim.api.nvim_buf_del_extmark(buf, ns, st.extmarks[line_nr])
  end

  local indent     = get_indent(buf, line_nr)
  local label      = phase or "thinking..."
  local virt       = { { { indent .. MARKER .. label, "PairyPending" } } }
  local extmark_id = vim.api.nvim_buf_set_extmark(buf, ns, line_nr, 0, {
    virt_lines       = virt,
    virt_lines_above = false,
  })
  st.extmarks[line_nr]  = extmark_id
  st.responses[line_nr] = ""
  if queues[buf] then queues[buf][line_nr] = nil end
end

-- Enqueue a token's words for word-by-word drip display.
---@param buf     number Buffer handle
---@param line_nr number 0-indexed line
---@param token   string Text chunk from the stream
function M.append_token(buf, line_nr, token)
  local st = get_state(buf)
  if not st or not st.extmarks[line_nr] then return end

  local q = get_queue(buf, line_nr)
  if q.finalized then return end

  for _, w in ipairs(tokenize(token)) do
    table.insert(q.words, w)
  end

  if not q.active and #q.words > 0 then
    q.active = true
    vim.defer_fn(function() tick(buf, line_nr) end, 0)
  end
end

-- Called when the stream ends. Drains the word queue then applies final highlight.
---@param buf       number Buffer handle
---@param line_nr   number 0-indexed line
---@param full_text string Complete response text
function M.finalize(buf, line_nr, full_text)
  local st = get_state(buf)
  if not st or not st.extmarks[line_nr] then return end

  local q    = get_queue(buf, line_nr)
  q.finalized = true

  -- Queue already empty: set final state directly
  if not q.active and #q.words == 0 then
    st.responses[line_nr] = full_text
    redraw(buf, line_nr, "PairyResponse")
  end
  -- Otherwise tick() will switch highlight when the queue drains
end

---@param buf     number Buffer handle
---@param line_nr number 0-indexed line
---@param msg     string Error message to display
function M.show_error(buf, line_nr, msg)
  local st         = get_state(buf)
  local extmark_id = st and st.extmarks[line_nr]
  if not extmark_id then return end

  if queues[buf] then queues[buf][line_nr] = nil end

  local indent     = get_indent(buf, line_nr)
  local short      = msg:sub(1, 60)
  vim.api.nvim_buf_set_extmark(buf, ns, line_nr, 0, {
    id               = extmark_id,
    virt_lines       = { {
      { indent .. MARKER, "PairyMarker" },
      { "error: " .. short, "PairyError" },
    } },
    virt_lines_above = false,
  })

  if state[buf] then state[buf].active_job = nil end
end

function M.clear_line(buf, line_nr)
  local st         = get_state(buf)
  local extmark_id = st.extmarks[line_nr]
  if extmark_id then
    vim.api.nvim_buf_del_extmark(buf, ns, extmark_id)
    st.extmarks[line_nr]  = nil
    st.responses[line_nr] = nil
  end
  if queues[buf] then queues[buf][line_nr] = nil end
end

-- Re-draw one line from saved response data (used by toggle_hidden).
local function restore_line(buf, line_nr)
  local st   = get_state(buf)
  local text = st.responses[line_nr]
  if not text or text == "" then return end
  local indent, cont_pad, wrap_w = layout(buf, line_nr)
  local virt = text_to_virt_lines(text, "PairyResponse", indent, cont_pad, wrap_w)
  local id   = vim.api.nvim_buf_set_extmark(buf, ns, line_nr, 0, {
    virt_lines       = virt,
    virt_lines_above = false,
  })
  st.extmarks[line_nr] = id
end

-- Toggle visibility of all responses in the buffer without discarding them.
-- Hiding clears extmarks; showing re-creates them from saved response text.
---@param buf number Buffer handle
---@return boolean  true = now hidden, false = now visible
function M.toggle_hidden(buf)
  local st = get_state(buf)
  st.hidden = not (st.hidden or false)

  if st.hidden then
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    st.extmarks = {}
  else
    for line_nr in pairs(st.responses) do
      restore_line(buf, line_nr)
    end
  end

  return st.hidden
end

function M.clear_all(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  state[buf]  = nil
  queues[buf] = nil
end

-- Return a snapshot of all saved responses for a buffer.
---@param buf number Buffer handle
---@return table<number, string>  Map of 0-indexed line_nr → response text
function M.get_responses(buf)
  local st = state[buf]
  if not st then return {} end
  return vim.deepcopy(st.responses)
end

function M.set_active_job(buf, job)
  get_state(buf).active_job = job
end

function M.cancel_active(buf)
  local st = get_state(buf)
  if st.active_job then
    st.active_job:kill(9)
    st.active_job = nil
    util.notify("Cancelled.")
  end
end

return M
