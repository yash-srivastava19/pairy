-- pairy/client.lua — Gemini API client (streaming SSE via curl + vim.system)

local util = require("pairy.util")

local M = {}

---@class PairyCallbacks
---@field on_token fun(token: string)  Called for each streamed text chunk
---@field on_done  fun(text: string)   Called when stream completes with full response
---@field on_error fun(msg: string)    Called on any error (API, network, or parse)

local SYSTEM_PROMPT = [[You are a senior pair programmer. The user has left a `pair:` comment with a question or thought. Your job is not just to answer — it is to help them think more clearly and write better code.

How to respond:
- If the question reveals an unstated assumption or a gap in thinking, surface it first. Example: "Before deciding, what's the expected range of X?" or "Your question assumes Y is always non-nil — is that guaranteed by the caller?"
- If the surrounding code has a problem unrelated to the question, mention it briefly at the end.
- Give a direct opinion when asked. Do not hedge unless the tradeoff genuinely depends on context you don't have — and if so, say which specific factor is the deciding one.
- If they are on the right track, confirm it in one clause and push to the next consideration.
- If they are off track, say so directly and redirect. Do not soften it.
- Ask one probing question back when it would help them reason through the problem. Do not ask questions just to seem thorough.

Constraints:
- 2-5 sentences. Every word earns its place.
- No markdown headers. No bullet lists unless genuinely enumerating distinct things.
- No "great question", no preamble, no summary at the end.
- Write as if your response will appear as comment lines in the file — plain prose, ~80 chars per line.
- Always reference the actual code: use the variable names, function names, and patterns visible in the context.]]

-- Gemini streaming endpoint (key in URL, no auth header needed)
---@param cfg PairyConfig
---@return string
local function build_url(cfg)
  local model = cfg.model or "gemini-2.5-flash"
  return string.format(
    "https://generativelanguage.googleapis.com/v1beta/models/%s:streamGenerateContent?alt=sse&key=%s",
    model, cfg.api_key
  )
end

-- Build a Gemini request body.
-- opts.history        — prior answered pair: comments (for conversation threading)
-- opts.project_context — contents of PAIRY.md prepended to the system prompt
---@param pair_comment PairComment
---@param cfg          PairyConfig
---@param opts?        { history?: table, project_context?: string }
---@return table
local function build_request_body(pair_comment, cfg, opts)
  opts = opts or {}

  local user_content = table.concat({
    pair_comment.context,
    "",
    "Question: " .. pair_comment.question,
  }, "\n")

  local system_text = SYSTEM_PROMPT
  if opts.project_context then
    system_text = system_text
      .. "\n\nProject context (from PAIRY.md):\n"
      .. opts.project_context
  end

  -- Interleave prior Q&As then append the current question
  local contents = {}
  for _, exchange in ipairs(opts.history or {}) do
    table.insert(contents, { role = "user",  parts = { { text = exchange.question } } })
    table.insert(contents, { role = "model", parts = { { text = exchange.response } } })
  end
  table.insert(contents, { role = "user", parts = { { text = user_content } } })

  return {
    system_instruction = { parts = { { text = system_text } } },
    contents           = contents,
    generationConfig   = { maxOutputTokens = cfg.max_tokens },
  }
end

-- Parse a single SSE line from Gemini's stream.
-- Returns: delta_text string, "__ERROR__:msg", or nil (ignore line).
-- Note: Gemini does NOT send [DONE] — the stream ends when curl exits.
---@param line string
---@return string|nil
local function parse_sse_line(line)
  line = util.trim(line)
  if line == "" then return nil end
  if vim.startswith(line, "event:") then return nil end
  if vim.startswith(line, ":") then return nil end  -- SSE comment

  if not vim.startswith(line, "data:") then return nil end
  line = util.trim(line:sub(6))

  local ok, decoded = pcall(vim.json.decode, line)
  if not ok or type(decoded) ~= "table" then return nil end

  if decoded.error then
    return "__ERROR__:" .. (decoded.error.message or "unknown API error")
  end

  if decoded.candidates
    and decoded.candidates[1]
    and decoded.candidates[1].content
    and decoded.candidates[1].content.parts
    and decoded.candidates[1].content.parts[1]
    and type(decoded.candidates[1].content.parts[1].text) == "string"
  then
    return decoded.candidates[1].content.parts[1].text
  end

  return nil
end

-- Check if collected output looks like a top-level API error JSON body
---@param text string
---@return string|nil  Error message, or nil if not an error
local function check_for_api_error(text)
  local trimmed = util.trim(text)
  if not vim.startswith(trimmed, "{") then return nil end
  local ok, decoded = pcall(vim.json.decode, trimmed)
  if not ok then return nil end
  if decoded.error then
    return decoded.error.message or ("API error: " .. (decoded.error.status or "unknown"))
  end
  return nil
end

-- Send a pair comment to Gemini (streaming SSE via curl).
---@param pair_comment PairComment
---@param cfg          PairyConfig
---@param callbacks    PairyCallbacks
---@param opts?        { history?: table, project_context?: string }
---@return vim.SystemObj|nil  Job handle for cancellation, or nil on early failure
function M.send(pair_comment, cfg, callbacks, opts)
  if not util.has_executable("curl") then
    callbacks.on_error("curl not found in PATH")
    return nil
  end

  local api_key = cfg.api_key
  if not api_key or api_key == "" then
    callbacks.on_error("No API key. Add 'api_key' to ~/.config/pairy/config.json")
    return nil
  end

  local body      = build_request_body(pair_comment, cfg, opts)
  local body_json = vim.json.encode(body)
  local tmp_path  = util.tmp_file(body_json)
  if not tmp_path then
    callbacks.on_error("Failed to create temp file for request body")
    return nil
  end

  local line_buf      = { partial = "" }
  local acc           = { text = "", done = false }
  local stderr_chunks = {}

  local function process_line(line)
    if acc.done then return end
    local result = parse_sse_line(line)
    if not result then return end

    if vim.startswith(result, "__ERROR__:") then
      acc.done = true
      vim.schedule(function() callbacks.on_error(result:sub(10)) end)
    else
      acc.text = acc.text .. result
      vim.schedule(function() callbacks.on_token(result) end)
    end
  end

  local function handle_chunk(chunk)
    if not chunk then return end
    line_buf.partial = line_buf.partial .. chunk
    local parts      = vim.split(line_buf.partial, "\n", { plain = true })
    line_buf.partial = table.remove(parts)  -- keep incomplete tail
    for _, line in ipairs(parts) do
      process_line(line)
    end
  end

  local job = vim.system(
    {
      "curl",
      "--silent",
      "--no-buffer",
      "--http1.1",
      "-X", "POST",
      "-H", "content-type: application/json",
      "--data-binary", "@" .. tmp_path,
      build_url(cfg),
    },
    {
      text   = false,
      stdout = function(err, chunk)
        if err then return end
        handle_chunk(chunk)
      end,
      stderr = function(_, chunk)
        if chunk then table.insert(stderr_chunks, chunk) end
      end,
    },
    function(result)  -- on_exit
      os.remove(tmp_path)

      if acc.done then return end

      -- Flush any remaining partial line
      if line_buf.partial ~= "" then
        local api_err = check_for_api_error(line_buf.partial)
        if api_err then
          vim.schedule(function() callbacks.on_error(api_err) end)
          return
        end
        process_line(line_buf.partial)
        if acc.done then return end
      end

      if result.code ~= 0 then
        local stderr_str = table.concat(stderr_chunks, "")
        local msg        = "curl error (code " .. result.code .. ")"
        if stderr_str ~= "" then
          msg = msg .. ": " .. util.trim(stderr_str):sub(1, 120)
        end
        vim.schedule(function() callbacks.on_error(msg) end)
      elseif acc.text ~= "" then
        vim.schedule(function() callbacks.on_done(acc.text) end)
      else
        vim.schedule(function() callbacks.on_error("Empty response from API") end)
      end
    end
  )

  return job
end

-- Exposed for tests only — not part of the public API.
M._parse_sse_line = parse_sse_line

return M
