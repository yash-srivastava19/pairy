-- pairy/detector.lua — pair: comment detection and context extraction

local util = require("pairy.util")

local M = {}

-- Language-agnostic patterns (Lua pattern syntax).
-- Each pattern captures: (comment_prefix, question_text)
-- Tried in order; first match wins.
local PAIR_PATTERNS = {
  "^(%s*%-%-+%s*)pair:%s*(.+)$",   -- Lua:           -- pair: text
  "^(%s*#+%s*)pair:%s*(.+)$",      -- Ruby/Python/sh: # pair: text
  "^(%s*//+%s*)pair:%s*(.+)$",     -- JS/TS/Rust/Go:  // pair: text
  "^(%s*/%*+%s*)pair:%s*(.+)$",    -- C block:        /* pair: text
}

-- Extract the question from a raw line. Returns question string or nil.
function M.extract_question(line_text)
  for _, pat in ipairs(PAIR_PATTERNS) do
    local _, question = line_text:match(pat)
    if question then
      return util.trim(question)
    end
  end
  return nil
end

-- Build a formatted context block to send to Claude.
-- Returns a multi-line string with: header, code fence, numbered lines,
-- with the pair: line marked with '>'.
function M.build_context(buf, line_nr_0, context_lines)
  local total = vim.api.nvim_buf_line_count(buf)
  local start_0 = math.max(0, line_nr_0 - context_lines)
  local end_0   = math.min(total, line_nr_0 + context_lines + 1)

  local lines = util.buf_lines(buf, start_0, end_0)
  local filetype = vim.bo[buf].filetype
  local filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
  if filename == "" then filename = "[unnamed]" end

  -- Build numbered lines with '>' marker on the pair: line
  local width = #tostring(end_0)  -- zero-pad to match widest line number
  local numbered = {}
  for i, line in ipairs(lines) do
    local abs_line = start_0 + i  -- 1-indexed display number
    local marker = (start_0 + i - 1 == line_nr_0) and ">" or " "
    table.insert(numbered, string.format("%s %" .. width .. "d: %s", marker, abs_line, line))
  end

  local header = string.format("File: %s (%s)\nLines %d-%d:\n",
    filename, filetype ~= "" and filetype or "text",
    start_0 + 1, end_0)

  return header
    .. "```" .. (filetype ~= "" and filetype or "") .. "\n"
    .. table.concat(numbered, "\n") .. "\n"
    .. "```"
end

-- PairComment data structure:
-- {
--   line_nr   : number,  -- 0-indexed buffer line
--   line_text : string,  -- raw line content
--   question  : string,  -- extracted question text
--   context   : string,  -- formatted context block
--   filetype  : string,
--   filename  : string,
-- }
local function make_pair_comment(buf, line_nr_0, line_text, question, cfg)
  local context_lines = (cfg and cfg.context_lines) or 20
  return {
    line_nr   = line_nr_0,
    line_text = line_text,
    question  = question,
    context   = M.build_context(buf, line_nr_0, context_lines),
    filetype  = vim.bo[buf].filetype,
    filename  = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t"),
  }
end

-- Find pair: comment at or near the cursor.
-- Checks cursor line first, then scans up to 3 lines above.
-- Returns PairComment or nil.
function M.find_at_cursor(buf, cfg)
  buf = buf or vim.api.nvim_get_current_buf()
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1  -- convert to 0-indexed

  -- Search cursor line + up to 3 lines above
  for offset = 0, 3 do
    local line_nr = cursor_line - offset
    if line_nr < 0 then break end

    local lines = util.buf_lines(buf, line_nr, line_nr + 1)
    if lines[1] then
      local question = M.extract_question(lines[1])
      if question then
        return make_pair_comment(buf, line_nr, lines[1], question, cfg)
      end
    end
  end

  return nil
end

-- Find all pair: comments in the entire buffer.
-- Returns list of PairComment (in order of appearance).
function M.find_all(buf, cfg)
  buf = buf or vim.api.nvim_get_current_buf()
  local total = vim.api.nvim_buf_line_count(buf)
  local all_lines = util.buf_lines(buf, 0, total)
  local results = {}

  for i, line_text in ipairs(all_lines) do
    local line_nr = i - 1  -- 0-indexed
    local question = M.extract_question(line_text)
    if question then
      table.insert(results, make_pair_comment(buf, line_nr, line_text, question, cfg))
    end
  end

  return results
end

-- Walk up from the buffer's file directory looking for a PAIRY.md file.
-- Stops at the git root or the filesystem root, whichever comes first.
-- Returns the file contents as a string, or nil if not found.
function M.find_project_context(buf)
  local filepath = vim.api.nvim_buf_get_name(buf)
  if filepath == "" then return nil end

  local dir = vim.fn.fnamemodify(filepath, ":p:h")

  while true do
    if vim.fn.filereadable(dir .. "/PAIRY.md") == 1 then
      return table.concat(vim.fn.readfile(dir .. "/PAIRY.md"), "\n")
    end
    if vim.fn.isdirectory(dir .. "/.git") == 1 then break end  -- stop at git root
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then break end  -- filesystem root
    dir = parent
  end

  return nil
end

return M
