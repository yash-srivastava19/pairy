-- pairy/util.lua — shared helpers

local M = {}

function M.notify(msg, level)
  vim.notify("[pairy] " .. msg, level or vim.log.levels.INFO)
end

function M.notify_err(msg)
  vim.notify("[pairy] " .. msg, vim.log.levels.ERROR)
end

function M.notify_warn(msg)
  vim.notify("[pairy] " .. msg, vim.log.levels.WARN)
end

function M.has_executable(bin)
  return vim.fn.executable(bin) == 1
end

function M.trim(s)
  return s:match("^%s*(.-)%s*$")
end

function M.split_lines(s)
  local lines = {}
  for line in (s .. "\n"):gmatch("(.-)\n") do
    table.insert(lines, line)
  end
  return lines
end

-- Word-wrap text to max_width, returns list of strings
function M.wrap_text(text, max_width)
  max_width = max_width or 72
  if #text <= max_width then return { text } end

  local result = {}
  local words = vim.split(text, " ", { plain = true })
  local current = ""

  for _, word in ipairs(words) do
    if current == "" then
      current = word
    elseif #current + 1 + #word <= max_width then
      current = current .. " " .. word
    else
      table.insert(result, current)
      current = word
    end
  end

  if current ~= "" then
    table.insert(result, current)
  end

  return result
end

-- Write content to a temp file, return path
function M.tmp_file(content)
  local path = os.tmpname()
  local f = io.open(path, "w")
  if not f then return nil end
  f:write(content)
  f:close()
  return path
end

-- Read and decode a JSON file, returns (table, nil) or (nil, error_string)
function M.read_json_file(path)
  if vim.fn.filereadable(path) == 0 then
    return nil, "file not found: " .. path
  end
  local lines = vim.fn.readfile(path)
  local content = table.concat(lines, "\n")
  local ok, decoded = pcall(vim.json.decode, content)
  if not ok then
    return nil, "invalid JSON: " .. tostring(decoded)
  end
  return decoded, nil
end

-- Safely get buffer lines (0-indexed, end exclusive)
function M.buf_lines(buf, start_0, end_0)
  local line_count = vim.api.nvim_buf_line_count(buf)
  start_0 = math.max(0, start_0)
  end_0 = math.min(line_count, end_0)
  if start_0 >= end_0 then return {} end
  return vim.api.nvim_buf_get_lines(buf, start_0, end_0, false)
end

return M
