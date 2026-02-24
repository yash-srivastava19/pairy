package.path = table.concat({
  vim.fn.getcwd() .. "/lua/?.lua",
  vim.fn.getcwd() .. "/lua/?/init.lua",
  package.path,
}, ";")

local util     = require("pairy.util")
local detector = require("pairy.detector")
local renderer = require("pairy.renderer")
local config   = require("pairy.config")
local client   = require("pairy.client")

local failures = {}
local total    = 0

local function fail(name, msg)
  table.insert(failures, string.format("  FAIL  %s\n        %s", name, msg))
end

local function expect(name, condition, msg)
  if not condition then fail(name, msg or "assertion failed") end
end

local function run(name, fn)
  total = total + 1
  local ok, err = pcall(fn)
  if not ok then
    fail(name, tostring(err))
    io.stdout:write("[FAIL] " .. name .. "\n")
  else
    io.stdout:write("[PASS] " .. name .. "\n")
  end
end

-- ─── util ───────────────────────────────────────────────────────────────────

run("util.trim: basic whitespace", function()
  expect("spaces",     util.trim("  hi  ") == "hi",         "spaces not stripped")
  expect("tabs",       util.trim("\t\thi\t") == "hi",       "tabs not stripped")
  expect("mixed",      util.trim("\t  hi  \t") == "hi",     "mixed not stripped")
  expect("inner kept", util.trim("  a b  ") == "a b",       "inner space removed")
  expect("empty",      util.trim("") == "",                  "empty should stay empty")
  expect("only space", util.trim("   ") == "",               "only whitespace should be empty")
  expect("no change",  util.trim("hello") == "hello",        "no whitespace should be unchanged")
end)

run("util.wrap_text: basic wrapping", function()
  local lines = util.wrap_text("a bb ccc dddd", 6)
  expect("multiple lines", #lines >= 2, "expected wrapping")
  for i, line in ipairs(lines) do
    expect("line " .. i .. " width", #line <= 6, "line exceeded max width: '" .. line .. "'")
  end
end)

run("util.wrap_text: text at exact width is not wrapped", function()
  local lines = util.wrap_text("exactly", 7)  -- 7 chars, limit 7
  expect("no wrap", #lines == 1, "expected single line at exact width")
  expect("content", lines[1] == "exactly", "content changed")
end)

run("util.wrap_text: single word longer than limit stays intact", function()
  local lines = util.wrap_text("superlongword", 5)
  expect("one line",  #lines == 1,               "long word should not be broken")
  expect("preserved", lines[1] == "superlongword", "long word content changed")
end)

run("util.wrap_text: empty string returns one empty line", function()
  local lines = util.wrap_text("", 72)
  expect("count",   #lines == 1,  "expected 1 element")
  expect("content", lines[1] == "", "expected empty string")
end)

run("util.split_lines: splits on newlines", function()
  local lines = util.split_lines("line1\nline2\nline3")
  expect("count", #lines == 3,      "expected 3 lines")
  expect("first", lines[1] == "line1", "wrong first line")
  expect("last",  lines[3] == "line3", "wrong last line")
end)

run("util.split_lines: single line with no newline", function()
  local lines = util.split_lines("only one")
  expect("count",   #lines == 1,       "expected 1 line")
  expect("content", lines[1] == "only one", "wrong content")
end)

run("util.split_lines: empty string returns one empty element", function()
  local lines = util.split_lines("")
  expect("count",   #lines == 1, "expected 1 element")
  expect("content", lines[1] == "", "expected empty string")
end)

run("util.buf_lines: full buffer", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b", "c" })
  local lines = util.buf_lines(buf, 0, 3)
  expect("count", #lines == 3,    "expected 3 lines")
  expect("first", lines[1] == "a", "wrong first")
  expect("last",  lines[3] == "c", "wrong last")
end)

run("util.buf_lines: clamps end beyond buffer size", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b", "c" })
  local lines = util.buf_lines(buf, 0, 9999)
  expect("clamped", #lines == 3, "expected clamp to buffer size")
end)

run("util.buf_lines: empty range returns no lines", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b" })
  expect("equal bounds", #util.buf_lines(buf, 2, 2) == 0, "start==end should return empty")
  expect("inverted",     #util.buf_lines(buf, 3, 1) == 0, "start>end should return empty")
end)

run("util.read_json_file: parses valid JSON", function()
  local tmp = os.tmpname()
  local f = assert(io.open(tmp, "w"))
  f:write('{"key": "value", "num": 42}')
  f:close()
  local result, err = util.read_json_file(tmp)
  os.remove(tmp)
  expect("no error",    err == nil,            "unexpected error: " .. tostring(err))
  expect("string val",  result.key == "value", "wrong string value")
  expect("number val",  result.num == 42,      "wrong number value")
end)

run("util.read_json_file: errors on nonexistent file", function()
  local result, err = util.read_json_file("/tmp/pairy_no_such_file_xyz123.json")
  expect("nil result",  result == nil,              "expected nil result")
  expect("has error",   err ~= nil,                 "expected error message")
  expect("error text",  err:find("file not found"), "expected 'file not found' in error")
end)

run("util.read_json_file: errors on invalid JSON", function()
  local tmp = os.tmpname()
  local f = assert(io.open(tmp, "w"))
  f:write("{not valid json{{{{")
  f:close()
  local result, err = util.read_json_file(tmp)
  os.remove(tmp)
  expect("nil result", result == nil,             "expected nil result")
  expect("has error",  err ~= nil,                "expected error message")
  expect("error text", err:find("invalid JSON"),  "expected 'invalid JSON' in error")
end)

run("util.has_executable: detects known binary", function()
  expect("nvim exists",   util.has_executable("nvim"),                       "nvim should be found")
  expect("false on fake", not util.has_executable("pairy_no_such_bin_xyz"),  "fake binary should not be found")
end)

-- ─── detector: pattern matching ─────────────────────────────────────────────

run("detector: standalone comment on its own line (all styles)", function()
  expect("lua --",     detector.extract_question("-- pair: lua") == "lua",       "lua standalone")
  expect("lua --- ",   detector.extract_question("--- pair: lua3") == "lua3",    "lua triple dash")
  expect("hash #",     detector.extract_question("# pair: hash") == "hash",      "hash standalone")
  expect("hash ##",    detector.extract_question("## pair: dbl") == "dbl",       "double hash")
  expect("slash //",   detector.extract_question("// pair: slash") == "slash",   "slash standalone")
  expect("c block /*", detector.extract_question("/* pair: cblock") == "cblock", "c block standalone")
end)

run("detector: inline comment — code before comment marker (the fixed bug)", function()
  -- These are the patterns that were broken before the ^.- fix
  expect("ruby inline",   detector.extract_question("n * n * 2 # pair: right?") == "right?",          "ruby inline failed")
  expect("python inline", detector.extract_question("return x * 2  # pair: cache this?") == "cache this?", "python inline failed")
  expect("lua inline",    detector.extract_question("local x = 1 -- pair: overflow?") == "overflow?",  "lua inline failed")
  expect("js inline",     detector.extract_question("const x = 1; // pair: const ok?") == "const ok?", "js inline failed")
  expect("c inline",      detector.extract_question("int n = 0; /* pair: start at 1?") == "start at 1?", "c inline failed")
end)

run("detector: indented standalone comments", function()
  expect("two spaces",  detector.extract_question("  # pair: indented") == "indented",         "two spaces failed")
  expect("four spaces", detector.extract_question("    -- pair: deep") == "deep",              "four spaces failed")
  expect("tab indent",  detector.extract_question("\t# pair: tabbed") == "tabbed",             "tab indent failed")
  expect("mixed",       detector.extract_question("  \t  // pair: mixed ws") == "mixed ws",   "mixed whitespace failed")
end)

run("detector: question text is trimmed", function()
  expect("trailing spaces", detector.extract_question("# pair: question   ") == "question",       "trailing spaces not trimmed")
  expect("no space after :", detector.extract_question("# pair:nospace") == "nospace",            "no space after colon failed")
end)

run("detector: lines that must NOT match", function()
  expect("regular comment",  detector.extract_question("# just a comment") == nil,           "regular comment matched")
  expect("plain code",       detector.extract_question("local x = 1") == nil,               "code matched")
  expect("empty line",       detector.extract_question("") == nil,                           "empty line matched")
  expect("similar word",     detector.extract_question("# pairs: plural") == nil,            "'pairs:' should not match")
  expect("no comment char",  detector.extract_question("pair: no comment prefix") == nil,    "no comment char matched")
  expect("pair in string",   detector.extract_question('x = "pair: in string"') == nil,     "pair: inside string without # matched")
end)

run("detector: real-world code lines with inline pair: comments", function()
  -- Patterns that commonly appear in actual code reviews
  expect("def with comment",    detector.extract_question("def magic(n): # pair: naming?") == "naming?",                     "python def failed")
  expect("if condition",        detector.extract_question("if n > 0: # pair: should be >=?") == "should be >=?",             "if condition failed")
  expect("assignment",          detector.extract_question("result = n * n # pair: memoize?") == "memoize?",                  "assignment failed")
  expect("return statement",    detector.extract_question("  return x  # pair: early return ok here?") == "early return ok here?", "return failed")
  expect("rust fn",             detector.extract_question("fn compute(n: i32) -> i32 { // pair: use usize?") == "use usize?", "rust fn failed")
end)

-- ─── detector: find_at_cursor ────────────────────────────────────────────────

run("detector.find_at_cursor: cursor exactly on pair: line", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "local x = 1",
    "-- pair: at cursor",
    "print(x)",
  })
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })  -- line 2 (1-indexed) = line_nr 1

  local hit = detector.find_at_cursor(buf, { context_lines = 3 })
  expect("found",    hit ~= nil,                         "expected a match")
  expect("question", hit.question == "at cursor",        "wrong question")
  expect("line_nr",  hit.line_nr == 1,                   "wrong line_nr")
end)

run("detector.find_at_cursor: cursor up to 3 lines below pair:", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "-- pair: scan up",   -- line_nr 0
    "a = 1",
    "b = 2",
    "c = 3",              -- cursor here: 3 lines below pair:
  })
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { 4, 0 })

  local hit = detector.find_at_cursor(buf, { context_lines = 5 })
  expect("found at offset 3", hit ~= nil,          "should find pair: 3 lines up")
  expect("question",          hit.question == "scan up", "wrong question")
end)

run("detector.find_at_cursor: does NOT scan more than 3 lines up", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "-- pair: too far",  -- line_nr 0
    "a = 1",
    "b = 2",
    "c = 3",
    "d = 4",             -- cursor here: 4 lines below pair:
  })
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { 5, 0 })

  local hit = detector.find_at_cursor(buf, { context_lines = 5 })
  expect("not found", hit == nil, "should not find pair: 4+ lines up")
end)

run("detector.find_at_cursor: no pair: comment near cursor", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a = 1", "b = 2", "c = 3" })
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { 3, 0 })

  local hit = detector.find_at_cursor(buf, { context_lines = 3 })
  expect("nil", hit == nil, "expected nil when no pair: comment nearby")
end)

run("detector.find_at_cursor: cursor on line 0 (no lines above)", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "-- pair: first line",
    "x = 1",
  })
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })

  local hit = detector.find_at_cursor(buf, { context_lines = 5 })
  expect("found on line 0", hit ~= nil,            "expected match on line 0")
  expect("question",        hit.question == "first line", "wrong question")
end)

-- ─── detector: find_all ──────────────────────────────────────────────────────

run("detector.find_all: finds multiple comments in order", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "-- pair: first",
    "local a = 1",
    "-- pair: second",
    "local b = 2",
    "-- pair: third",
  })

  local results = detector.find_all(buf, { context_lines = 5 })
  expect("count",    #results == 3,                   "expected 3 comments")
  expect("first q",  results[1].question == "first",  "wrong first question")
  expect("second q", results[2].question == "second", "wrong second question")
  expect("third q",  results[3].question == "third",  "wrong third question")
  expect("line 0",   results[1].line_nr == 0,         "wrong line_nr for first")
  expect("line 2",   results[2].line_nr == 2,         "wrong line_nr for second")
  expect("line 4",   results[3].line_nr == 4,         "wrong line_nr for third")
end)

run("detector.find_all: returns empty list when no pair: comments", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a = 1", "b = 2", "# normal comment" })
  local results = detector.find_all(buf, { context_lines = 5 })
  expect("empty", #results == 0, "expected no matches")
end)

run("detector.find_all: inline comments are found", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "x = 1  # pair: inline one",
    "y = 2",
    "z = x + y  # pair: inline two",
  })
  local results = detector.find_all(buf, { context_lines = 5 })
  expect("count",  #results == 2,                    "expected 2 inline comments")
  expect("first",  results[1].question == "inline one", "wrong first inline question")
  expect("second", results[2].question == "inline two", "wrong second inline question")
end)

-- ─── detector: build_context ─────────────────────────────────────────────────

run("detector.build_context: includes '>' marker on pair: line", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "def foo():",
    "  # pair: better approach?",
    "  return 42",
  })
  vim.bo[buf].filetype = "python"

  local ctx = detector.build_context(buf, 1, 5)
  expect("has > marker",   ctx:find(">") ~= nil,        "expected '>' marker")
  expect("has python fence", ctx:find("```python") ~= nil, "expected python code fence")
  expect("has filename",   ctx:find("File:") ~= nil,    "expected File: header")
end)

run("detector.build_context: pair: at line 0 (no lines above)", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "# pair: at top",
    "x = 1",
    "y = 2",
  })

  local ctx = detector.build_context(buf, 0, 5)
  expect("non-empty", ctx ~= nil and #ctx > 0, "expected non-empty context")
  expect("> on line 0", ctx:find(">") ~= nil,  "expected '>' on first line")
end)

run("detector.build_context: pair: at last line (no lines below)", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "x = 1",
    "y = 2",
    "# pair: at bottom",
  })

  local ctx = detector.build_context(buf, 2, 5)
  expect("non-empty", ctx ~= nil and #ctx > 0, "expected non-empty context")
  expect("> present",  ctx:find(">") ~= nil,   "expected '>' on last line")
end)

-- ─── renderer ────────────────────────────────────────────────────────────────

run("renderer.show_pending: creates extmark", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "-- pair: test" })

  renderer.show_pending(buf, 0)

  local marks = vim.api.nvim_buf_get_extmarks(buf, renderer.get_namespace(), 0, -1, {})
  expect("one extmark", #marks == 1, "expected exactly 1 extmark")
end)

run("renderer.show_pending: second call does NOT leave orphan extmarks (regression test)", function()
  -- This is the bug: calling show_pending twice on the same line created two extmarks.
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "-- pair: test" })

  renderer.show_pending(buf, 0)
  renderer.show_pending(buf, 0)  -- e.g. user presses <leader>ais twice

  local marks = vim.api.nvim_buf_get_extmarks(buf, renderer.get_namespace(), 0, -1, {})
  expect("one extmark", #marks == 1, "re-sending should replace extmark, not add a second")
end)

run("renderer.finalize: sets response text directly when queue empty", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "-- pair: test" })

  renderer.show_pending(buf, 0)
  renderer.finalize(buf, 0, "Hello world")

  local responses = renderer.get_responses(buf)
  expect("text set", responses[0] == "Hello world", "expected 'Hello world'")
end)

run("renderer.append_token: streams words into response", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "-- pair: test" })

  renderer.show_pending(buf, 0)
  renderer.append_token(buf, 0, "Hello ")
  renderer.append_token(buf, 0, "world")
  renderer.finalize(buf, 0, "Hello world")

  vim.wait(500, function()
    return renderer.get_responses(buf)[0] == "Hello world"
  end, 20)

  expect("streamed", renderer.get_responses(buf)[0] == "Hello world", "word-drip did not complete")
end)

run("renderer.clear_line: removes response and extmark for one line", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "-- pair: test", "code" })

  renderer.show_pending(buf, 0)
  renderer.finalize(buf, 0, "some response")
  renderer.clear_line(buf, 0)

  local responses = renderer.get_responses(buf)
  local marks     = vim.api.nvim_buf_get_extmarks(buf, renderer.get_namespace(), 0, -1, {})
  expect("response gone", responses[0] == nil, "response should be nil after clear_line")
  expect("extmark gone",  #marks == 0,         "extmark should be deleted after clear_line")
end)

run("renderer.clear_all: removes all responses and extmarks", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "-- pair: first",
    "code",
    "-- pair: second",
  })

  renderer.show_pending(buf, 0)
  renderer.finalize(buf, 0, "response one")
  renderer.show_pending(buf, 2)
  renderer.finalize(buf, 2, "response two")

  local before = renderer.get_responses(buf)
  expect("before: line 0", before[0] == "response one", "expected response at line 0")
  expect("before: line 2", before[2] == "response two", "expected response at line 2")

  renderer.clear_all(buf)

  local after = renderer.get_responses(buf)
  local marks = vim.api.nvim_buf_get_extmarks(buf, renderer.get_namespace(), 0, -1, {})
  expect("after: line 0 gone",  after[0] == nil, "line 0 not cleared")
  expect("after: line 2 gone",  after[2] == nil, "line 2 not cleared")
  expect("no extmarks",         #marks == 0,     "extmarks should all be gone")
end)

run("renderer.show_error: extmark persists after error", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "-- pair: test" })

  renderer.show_pending(buf, 0)
  renderer.show_error(buf, 0, "API key not valid.")

  local marks = vim.api.nvim_buf_get_extmarks(buf, renderer.get_namespace(), 0, -1, {})
  expect("extmark exists", #marks == 1, "expected extmark to survive error")
end)

run("renderer.get_responses: returns deepcopy, not internal state", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "-- pair: test" })

  renderer.show_pending(buf, 0)
  renderer.finalize(buf, 0, "original")

  local r1 = renderer.get_responses(buf)
  r1[0] = "mutated"  -- mutate the copy

  local r2 = renderer.get_responses(buf)
  expect("not mutated", r2[0] == "original", "get_responses should return a copy")
end)

-- ─── config ──────────────────────────────────────────────────────────────────

local function reset_config()
  config._config    = nil
  config._overrides = {}
end

run("config: defaults are applied when no overrides", function()
  reset_config()
  config.apply_overrides({ api_key = "test-key" })  -- avoid real file warning
  local cfg = config.get()
  expect("model",         cfg.model == "gemini-2.5-flash", "wrong default model")
  expect("context_lines", cfg.context_lines == 20,         "wrong default context_lines")
  expect("max_tokens",    cfg.max_tokens == 8192,          "wrong default max_tokens")
  expect("max_history",   cfg.max_history == 5,            "wrong default max_history")
  reset_config()
end)

run("config: apply_overrides merges over defaults", function()
  reset_config()
  config.apply_overrides({ api_key = "sk-test", max_tokens = 999 })
  local cfg = config.get()
  expect("override applied",    cfg.max_tokens == 999,             "override not applied")
  expect("other key overridden", cfg.api_key == "sk-test",         "api_key not applied")
  expect("default preserved",   cfg.model == "gemini-2.5-flash",  "default should survive override")
  reset_config()
end)

run("config: reload picks up new overrides", function()
  reset_config()
  config.apply_overrides({ api_key = "key1", max_tokens = 100 })
  local cfg1 = config.get()
  expect("initial", cfg1.max_tokens == 100, "initial override not applied")

  config._overrides = { api_key = "key2", max_tokens = 200 }
  config.reload()
  local cfg2 = config.get()
  expect("after reload", cfg2.max_tokens == 200, "reload did not pick up new override")
  reset_config()
end)

-- ─── client: SSE parser ─────────────────────────────────────────────────────

local parse = client._parse_sse_line

run("client SSE: empty and blank lines return nil", function()
  expect("empty string",    parse("") == nil,       "empty line should be nil")
  expect("only whitespace", parse("   ") == nil,    "whitespace-only should be nil")
end)

run("client SSE: non-data control lines return nil", function()
  expect("event: line",  parse("event: delta") == nil,     "event: line should be nil")
  expect("SSE comment",  parse(": keep-alive") == nil,     "SSE comment should be nil")
  expect("retry: line",  parse("retry: 5000") == nil,      "retry: should be nil")
  expect("unknown field", parse("id: 42") == nil,          "unknown SSE field should be nil")
end)

run("client SSE: valid Gemini delta returns text", function()
  local payload = vim.json.encode({
    candidates = {{
      content = { parts = {{ text = "Hello world" }}, role = "model" }
    }}
  })
  local result = parse("data: " .. payload)
  expect("text extracted", result == "Hello world", "expected 'Hello world', got: " .. tostring(result))
end)

run("client SSE: API error returns __ERROR__ prefix", function()
  local payload = vim.json.encode({
    error = { message = "API key not valid.", code = 400 }
  })
  local result = parse("data: " .. payload)
  expect("has prefix",   result ~= nil and result:sub(1, 9) == "__ERROR__", "expected __ERROR__ prefix")
  expect("has message",  result:find("API key not valid"),                  "expected error message in result")
end)

run("client SSE: malformed JSON returns nil (no crash)", function()
  expect("bad json",     parse("data: {not valid") == nil,   "malformed JSON should return nil")
  expect("empty data",   parse("data: ") == nil,             "empty data value should return nil")
  expect("data is null", parse("data: null") == nil,         "null data should return nil")
end)

run("client SSE: partial delta structure returns nil gracefully", function()
  -- Missing parts[1].text — incomplete but valid JSON
  local payload = vim.json.encode({ candidates = {{ content = { parts = {} } }} })
  local result = parse("data: " .. payload)
  expect("nil on empty parts", result == nil, "missing text field should return nil")
end)

run("client SSE: whitespace around data: prefix is trimmed", function()
  local payload = vim.json.encode({
    candidates = {{
      content = { parts = {{ text = "trimmed" }}, role = "model" }
    }}
  })
  -- Extra whitespace after "data:" (as sometimes seen in real SSE streams)
  local result = parse("data:  " .. payload)
  expect("trimmed ok", result == "trimmed", "whitespace after data: should be handled")
end)

run("renderer.toggle_hidden: hides extmarks, preserves responses", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "-- pair: test", "code" })

  renderer.show_pending(buf, 0)
  renderer.finalize(buf, 0, "the response")

  -- Wait for the word-drip to drain
  vim.wait(500, function()
    return renderer.get_responses(buf)[0] == "the response"
  end, 20)

  renderer.toggle_hidden(buf)  -- hide

  local marks = vim.api.nvim_buf_get_extmarks(buf, renderer.get_namespace(), 0, -1, {})
  local resp  = renderer.get_responses(buf)
  expect("extmarks gone",  #marks == 0,              "extmarks should be removed when hidden")
  expect("response kept",  resp[0] == "the response", "response data should survive toggle")
end)

run("renderer.toggle_hidden: restores extmarks on second call", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "-- pair: test", "code" })

  renderer.show_pending(buf, 0)
  renderer.finalize(buf, 0, "answer")

  vim.wait(500, function()
    return renderer.get_responses(buf)[0] == "answer"
  end, 20)

  renderer.toggle_hidden(buf)  -- hide
  renderer.toggle_hidden(buf)  -- show

  local marks = vim.api.nvim_buf_get_extmarks(buf, renderer.get_namespace(), 0, -1, {})
  expect("extmarks restored", #marks >= 1, "extmarks should be re-created on show")
end)

run("renderer.toggle_hidden: returns true when hiding, false when showing", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "-- pair: test" })

  renderer.show_pending(buf, 0)
  renderer.finalize(buf, 0, "answer")

  vim.wait(500, function()
    return renderer.get_responses(buf)[0] == "answer"
  end, 20)

  local hidden = renderer.toggle_hidden(buf)
  expect("returns true on hide",  hidden == true,  "toggle_hidden should return true when hiding")
  local shown = renderer.toggle_hidden(buf)
  expect("returns false on show", shown  == false, "toggle_hidden should return false when showing")
end)

-- ─── init: inspect ───────────────────────────────────────────────────────────

local init = require("pairy")

run("init.inspect: error notification when API key is empty", function()
  local orig      = vim.notify
  local got_error = false
  vim.notify = function(_, level)
    if level == vim.log.levels.ERROR then got_error = true end
  end

  config.apply_overrides({ api_key = "" })
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello" })
  vim.api.nvim_set_current_buf(buf)
  init.inspect()

  vim.notify = orig
  config.apply_overrides({ api_key = "test-key" })
  expect("error fired", got_error, "expected ERROR notification when API key empty")
end)

run("init.inspect_selection: error notification when API key is empty", function()
  local orig      = vim.notify
  local got_error = false
  vim.notify = function(_, level)
    if level == vim.log.levels.ERROR then got_error = true end
  end

  config.apply_overrides({ api_key = "" })
  init.inspect_selection()

  vim.notify = orig
  config.apply_overrides({ api_key = "test-key" })
  expect("error fired", got_error, "expected ERROR notification when API key empty")
end)

run("init.inspect: warn when no word under cursor", function()
  local orig     = vim.notify
  local got_warn = false
  vim.notify = function(_, level)
    if level == vim.log.levels.WARN then got_warn = true end
  end

  config.apply_overrides({ api_key = "test-key" })
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "   " })
  vim.api.nvim_set_current_buf(buf)
  init.inspect()

  vim.notify = orig
  expect("warn fired", got_warn, "expected WARN when no word under cursor")
end)

-- ─── Results ────────────────────────────────────────────────────────────────

io.stdout:write(string.format("\n%d tests run.\n", total))

if #failures > 0 then
  io.stderr:write("\n[pairy:test] FAILURES (" .. #failures .. "):\n")
  for _, item in ipairs(failures) do
    io.stderr:write(item .. "\n")
  end
  os.exit(1)
end

io.stdout:write("[pairy:test] All tests passed.\n")
os.exit(0)
