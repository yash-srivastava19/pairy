-- pairy/renderer.lua — virtual text lifecycle via extmarks

local util = require("pairy.util")

local M = {}

-- One namespace for the entire plugin
local ns = vim.api.nvim_create_namespace("pairy")

-- Per-buffer state:
-- state[bufnr] = {
--   extmarks = { [line_nr_0] = extmark_id },
--   responses = { [line_nr_0] = accumulated_text },
--   active_job = job_handle | nil,
-- }
local state = {}

local MARKER   = "  ⬡ "
local CONT     = "    "   -- same width as MARKER for continuation lines
local WRAP_AT  = 72

local function get_state(buf)
  if not state[buf] then
    state[buf] = { extmarks = {}, responses = {}, active_job = nil }
  end
  return state[buf]
end

-- Register highlight groups. Called on setup and ColorScheme.
function M.setup_highlights()
  vim.api.nvim_set_hl(0, "PairyMarker",   { fg = "#7C7C7C", bold = true,   default = true })
  vim.api.nvim_set_hl(0, "PairyResponse", { fg = "#6C6C6C", italic = true, default = true })
  vim.api.nvim_set_hl(0, "PairyPending",  { fg = "#555555", italic = true, default = true })
  vim.api.nvim_set_hl(0, "PairyError",    { fg = "#C25A5A", italic = true, default = true })
end

-- Convert response text to virt_lines table.
-- Each logical line from text becomes one or more virt_lines entries (word-wrapped).
-- Format: { { {"  ⬡ ", "PairyMarker"}, {"content", hl} }, ... }
local function text_to_virt_lines(text, hl_group)
  hl_group = hl_group or "PairyResponse"
  if not text or text == "" then
    return { { { MARKER .. "...", "PairyPending" } } }
  end

  local result = {}
  local raw_lines = util.split_lines(text)

  for i, raw_line in ipairs(raw_lines) do
    if raw_line == "" then
      -- blank logical line = spacer (only between lines, not at end)
      if i < #raw_lines then
        table.insert(result, { { "", hl_group } })
      end
    else
      -- Word-wrap the line
      local wrapped = util.wrap_text(raw_line, WRAP_AT)
      for j, segment in ipairs(wrapped) do
        local prefix = (j == 1) and MARKER or CONT
        local marker_hl = (j == 1) and "PairyMarker" or hl_group
        table.insert(result, {
          { prefix, marker_hl },
          { segment, hl_group },
        })
      end
    end
  end

  if #result == 0 then
    result = { { { MARKER .. "...", "PairyPending" } } }
  end

  return result
end

-- Returns the namespace id (for external use if needed)
function M.get_namespace()
  return ns
end

-- Show a "thinking" indicator on line_nr (0-indexed).
-- Creates a new extmark and stores its id.
function M.show_pending(buf, line_nr)
  local st = get_state(buf)

  local virt = { { { MARKER .. "thinking...", "PairyPending" } } }

  local extmark_id = vim.api.nvim_buf_set_extmark(buf, ns, line_nr, 0, {
    virt_lines       = virt,
    virt_lines_above = false,
  })

  st.extmarks[line_nr] = extmark_id
  st.responses[line_nr] = ""
end

-- Append a streaming token to the response for line_nr.
-- Replaces the extmark in-place (no flicker via id = extmark_id).
-- MUST be called via vim.schedule() from async contexts.
function M.append_token(buf, line_nr, token)
  local st = get_state(buf)
  local extmark_id = st.extmarks[line_nr]
  if not extmark_id then return end

  st.responses[line_nr] = (st.responses[line_nr] or "") .. token

  local virt = text_to_virt_lines(st.responses[line_nr], "PairyPending")

  vim.api.nvim_buf_set_extmark(buf, ns, line_nr, 0, {
    id               = extmark_id,   -- atomic in-place replace, no flicker
    virt_lines       = virt,
    virt_lines_above = false,
  })
end

-- Finalize the response for line_nr — switches to final highlight.
-- MUST be called via vim.schedule() from async contexts.
function M.finalize(buf, line_nr, full_text)
  local st = get_state(buf)
  local extmark_id = st.extmarks[line_nr]
  if not extmark_id then return end

  st.responses[line_nr] = full_text

  local virt = text_to_virt_lines(full_text, "PairyResponse")

  vim.api.nvim_buf_set_extmark(buf, ns, line_nr, 0, {
    id               = extmark_id,
    virt_lines       = virt,
    virt_lines_above = false,
  })

  st.active_job = nil
end

-- Show an error for line_nr.
-- MUST be called via vim.schedule() from async contexts.
function M.show_error(buf, line_nr, msg)
  local st = get_state(buf)
  local extmark_id = st.extmarks[line_nr]
  if not extmark_id then return end

  local short = msg:sub(1, 60)
  local virt = { {
    { MARKER, "PairyMarker" },
    { "error: " .. short, "PairyError" },
  } }

  vim.api.nvim_buf_set_extmark(buf, ns, line_nr, 0, {
    id               = extmark_id,
    virt_lines       = virt,
    virt_lines_above = false,
  })

  st.active_job = nil
end

-- Clear the virtual text response for a single line_nr (0-indexed).
function M.clear_line(buf, line_nr)
  local st = get_state(buf)
  local extmark_id = st.extmarks[line_nr]
  if extmark_id then
    vim.api.nvim_buf_del_extmark(buf, ns, extmark_id)
    st.extmarks[line_nr] = nil
    st.responses[line_nr] = nil
  end
end

-- Clear ALL virtual text in buffer (fast namespace-level clear).
function M.clear_all(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  state[buf] = nil
end

-- Store a job handle for the buffer (for cancellation).
function M.set_active_job(buf, job)
  get_state(buf).active_job = job
end

-- Kill the active job for a buffer, if any.
function M.cancel_active(buf)
  local st = get_state(buf)
  if st.active_job then
    st.active_job:kill(9)
    st.active_job = nil
    util.notify("Cancelled.")
  end
end

return M
