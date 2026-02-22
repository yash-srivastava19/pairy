-- pairy/client.lua — Gemini API client (streaming SSE via curl + vim.system)

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

-- Gemini streaming endpoint (key in URL, no auth header needed)
local function build_url(cfg)
  local model = cfg.model or "gemini-2.0-flash"
  return string.format(
    "https://generativelanguage.googleapis.com/v1beta/models/%s:streamGenerateContent?alt=sse&key=%s",
    model, cfg.api_key
  )
end

-- Gemini request body format
local function build_request_body(pair_comment, cfg)
  local content = table.concat({
    pair_comment.context,
    "",
    "Question: " .. pair_comment.question,
  }, "\n")

  return {
    system_instruction = {
      parts = { { text = SYSTEM_PROMPT } },
    },
    contents = {
      { role = "user", parts = { { text = content } } },
    },
    generationConfig = {
      maxOutputTokens = cfg.max_tokens or 512,
    },
  }
end

-- Parse a single SSE line from Gemini's stream.
-- Returns: delta_text string, "__ERROR__:msg", or nil (ignore).
-- Note: Gemini does NOT send [DONE] — the stream ends when curl exits.
local function parse_sse_line(line)
  line = util.trim(line)
  if line == "" then return nil end
  if vim.startswith(line, "event:") then return nil end
  if vim.startswith(line, ":") then return nil end  -- SSE comment

  if not vim.startswith(line, "data:") then return nil end
  line = util.trim(line:sub(6))  -- strip "data:" prefix

  local ok, decoded = pcall(vim.json.decode, line)
  if not ok then return nil end

  -- Gemini error response
  if decoded.error then
    return "__ERROR__:" .. (decoded.error.message or "unknown API error")
  end

  -- Gemini text delta: candidates[1].content.parts[1].text
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

-- Send a pair comment to Gemini.
-- pair_comment : PairComment table from detector
-- cfg          : config table from config.get()
-- callbacks    : { on_token(text), on_done(full_text), on_error(msg) }
-- Returns      : vim.system job object (for cancellation)
function M.send(pair_comment, cfg, callbacks)
  local api_key = cfg.api_key
  if not api_key or api_key == "" then
    callbacks.on_error("No API key. Add 'api_key' to ~/.config/pairy/config.json")
    return nil
  end

  local body      = build_request_body(pair_comment, cfg)
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
    local parts = vim.split(line_buf.partial, "\n", { plain = true })
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
      stderr = function(err, chunk)
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
        local msg = "curl error (code " .. result.code .. ")"
        if stderr_str ~= "" then
          msg = msg .. ": " .. util.trim(stderr_str):sub(1, 120)
        end
        vim.schedule(function() callbacks.on_error(msg) end)
      elseif acc.text ~= "" then
        -- Gemini: no [DONE] marker, stream ends when curl exits cleanly
        vim.schedule(function() callbacks.on_done(acc.text) end)
      else
        vim.schedule(function() callbacks.on_error("Empty response from API") end)
      end
    end
  )

  return job
end

return M
