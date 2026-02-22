-- pairy/client.lua — Claude API client (streaming SSE via curl + vim.system)

local util = require("pairy.util")

local M = {}

local SYSTEM_PROMPT = [[You are a pair programmer reviewing code in real time. The user has left a `pair:` annotation in their code with a question or thought. Respond as if you're sitting next to them — brief, direct, and code-focused.

Rules:
- Keep responses short: 1-4 sentences or a few bullet points. Never write more than you need.
- Respond to exactly what was asked. Do not add unsolicited advice, tangents, or "great question!".
- When you have an opinion (prefer A over B), state it directly. No "it depends" unless you explain which factors matter.
- Format responses as plain prose or short bullet points. No markdown headers. No code blocks unless a short snippet directly answers the question.
- If the question is about a tradeoff or design decision, give your actual recommendation.
- You are looking at the code around the comment — use it. Reference specific variable names, function names, or patterns from the context.
- Never repeat the user's question back to them.
- Write as if your response will appear as inline comment lines in the code file. Keep each sentence under ~80 characters.]]

-- Build the messages API request body as a Lua table
local function build_request_body(pair_comment, cfg)
  local content = table.concat({
    pair_comment.context,
    "",
    "Question: " .. pair_comment.question,
  }, "\n")

  return {
    model      = cfg.model,
    max_tokens = cfg.max_tokens,
    stream     = true,
    system     = SYSTEM_PROMPT,
    messages   = {
      { role = "user", content = content },
    },
  }
end

-- Parse a single SSE line.
-- Returns: delta_text string, "__DONE__", or nil (ignore).
local function parse_sse_line(line)
  line = util.trim(line)
  if line == "" then return nil end
  if vim.startswith(line, "event:") then return nil end
  if vim.startswith(line, ":") then return nil end  -- SSE comment

  -- Strip "data: " prefix
  if not vim.startswith(line, "data:") then return nil end
  line = util.trim(line:sub(6))  -- remove "data:" and trim

  if line == "[DONE]" then return "__DONE__" end

  local ok, decoded = pcall(vim.json.decode, line)
  if not ok then return nil end

  -- Anthropic streaming: content_block_delta with text_delta
  if decoded.type == "content_block_delta"
    and decoded.delta
    and decoded.delta.type == "text_delta"
    and type(decoded.delta.text) == "string"
  then
    return decoded.delta.text
  end

  -- Check for error in response (non-streaming error, arrives as one JSON blob)
  if decoded.type == "error" and decoded.error then
    return "__ERROR__:" .. (decoded.error.message or "unknown API error")
  end

  return nil
end

-- Check if collected output looks like an API error JSON body
-- (non-streaming error: entire response is one JSON object)
local function check_for_api_error(text)
  local trimmed = util.trim(text)
  if not vim.startswith(trimmed, "{") then return nil end
  local ok, decoded = pcall(vim.json.decode, trimmed)
  if not ok then return nil end
  if decoded.error then
    return decoded.error.message or ("API error type: " .. (decoded.error.type or "unknown"))
  end
  return nil
end

-- Send a pair comment to Claude.
-- pair_comment: PairComment table from detector
-- cfg: config table from config.get()
-- callbacks: { on_token(text), on_done(full_text), on_error(msg) }
-- Returns: the vim.system job object (for cancellation)
function M.send(pair_comment, cfg, callbacks)
  local api_key = cfg.api_key
  if not api_key or api_key == "" then
    callbacks.on_error("No API key. Add 'api_key' to ~/.config/pairy/config.json")
    return nil
  end

  -- Write request body to temp file (avoids shell quoting issues)
  local body = build_request_body(pair_comment, cfg)
  local body_json = vim.json.encode(body)
  local tmp_path = util.tmp_file(body_json)
  if not tmp_path then
    callbacks.on_error("Failed to create temp file for request body")
    return nil
  end

  -- State for chunk processing
  local line_buf = { partial = "" }
  local acc      = { text = "", done = false, error = nil }
  local stderr_chunks = {}

  -- Process a complete SSE line
  local function process_line(line)
    if acc.done then return end

    local result = parse_sse_line(line)
    if result == "__DONE__" then
      acc.done = true
      vim.schedule(function()
        callbacks.on_done(acc.text)
      end)
    elseif result and vim.startswith(result, "__ERROR__:") then
      acc.done = true
      local msg = result:sub(10)
      vim.schedule(function()
        callbacks.on_error(msg)
      end)
    elseif result then
      acc.text = acc.text .. result
      local token = result
      vim.schedule(function()
        callbacks.on_token(token)
      end)
    end
  end

  -- Reconstruct lines from arbitrary stdout chunks
  local function handle_chunk(chunk)
    if not chunk then return end
    -- Append to partial buffer, split on newlines
    line_buf.partial = line_buf.partial .. chunk
    local parts = vim.split(line_buf.partial, "\n", { plain = true })
    -- Last element is the incomplete tail
    line_buf.partial = table.remove(parts)
    for _, line in ipairs(parts) do
      process_line(line)
    end
  end

  local job = vim.system(
    {
      "curl",
      "--silent",
      "--no-buffer",
      "--http1.1",         -- avoid h2 framing complexity with SSE
      "-X", "POST",
      "-H", "x-api-key: " .. api_key,
      "-H", "anthropic-version: " .. cfg.api_version,
      "-H", "content-type: application/json",
      "-H", "accept: text/event-stream",
      "--data-binary", "@" .. tmp_path,
      cfg.api_url,
    },
    {
      text   = false,       -- binary mode; we handle newlines ourselves
      stdout = function(err, chunk)
        if err then return end
        handle_chunk(chunk)
      end,
      stderr = function(err, chunk)
        if chunk then table.insert(stderr_chunks, chunk) end
      end,
    },
    function(result)         -- on_exit
      os.remove(tmp_path)

      if acc.done then return end  -- already handled via SSE

      -- Flush any remaining partial line (non-streaming error response lands here)
      if line_buf.partial ~= "" then
        -- Check if it's a JSON error body
        local api_err = check_for_api_error(line_buf.partial)
        if api_err then
          vim.schedule(function() callbacks.on_error(api_err) end)
          return
        end
        -- Otherwise try to process it as a data line
        process_line(line_buf.partial)
        if acc.done then return end
      end

      -- curl non-zero exit
      if result.code ~= 0 then
        local stderr_str = table.concat(stderr_chunks, "")
        local msg = "curl error (code " .. result.code .. ")"
        if stderr_str ~= "" then
          msg = msg .. ": " .. util.trim(stderr_str):sub(1, 120)
        end
        vim.schedule(function() callbacks.on_error(msg) end)
      elseif not acc.done then
        -- Stream ended without [DONE] — treat accumulated text as final
        if acc.text ~= "" then
          vim.schedule(function() callbacks.on_done(acc.text) end)
        else
          vim.schedule(function() callbacks.on_error("Empty response from API") end)
        end
      end
    end
  )

  return job
end

return M
