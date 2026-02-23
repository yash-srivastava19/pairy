package.path = table.concat({
  vim.fn.getcwd() .. "/lua/?.lua",
  vim.fn.getcwd() .. "/lua/?/init.lua",
  package.path,
}, ";")

local util = require("pairy.util")
local detector = require("pairy.detector")
local renderer = require("pairy.renderer")

local failures = {}

local function fail(name, msg)
  table.insert(failures, string.format("%s: %s", name, msg))
end

local function expect(name, condition, msg)
  if not condition then fail(name, msg) end
end

local function run(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    fail(name, tostring(err))
  else
    io.stdout:write("[PASS] " .. name .. "\n")
  end
end

run("util.trim strips surrounding whitespace", function()
  expect("trim", util.trim("  hi\t") == "hi", "unexpected trim output")
end)

run("util.wrap_text keeps width constraints", function()
  local wrapped = util.wrap_text("a bb ccc dddd", 6)
  expect("wrap count", #wrapped >= 2, "expected multiple wrapped lines")
  for _, line in ipairs(wrapped) do
    expect("wrap width", #line <= 6, "line exceeded max width: " .. line)
  end
end)

run("detector.extract_question supports common comments", function()
  expect("lua", detector.extract_question("-- pair: foo") == "foo", "failed lua pattern")
  expect("hash", detector.extract_question("# pair: bar") == "bar", "failed hash pattern")
  expect("slash", detector.extract_question("// pair: baz") == "baz", "failed slash pattern")
end)

run("detector.find_at_cursor finds nearest pair comment", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "local x = 1",
    "-- pair: should x be memoized?",
    "print(x)",
  })
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { 3, 0 })

  local hit = detector.find_at_cursor(buf, { context_lines = 3 })
  expect("hit exists", hit ~= nil, "expected comment at/above cursor")
  expect("question", hit.question == "should x be memoized?", "unexpected question")
  expect("line", hit.line_nr == 1, "unexpected line number")
end)

run("renderer lifecycle stores and clears responses", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "-- pair: test",
    "print('ok')",
  })

  renderer.show_pending(buf, 0)
  renderer.append_token(buf, 0, "Hello world")
  vim.wait(200, function()
    local responses = renderer.get_responses(buf)
    return responses[0] ~= nil and #responses[0] > 0
  end, 20)

  renderer.finalize(buf, 0, "Hello world")
  vim.wait(200, function()
    local responses = renderer.get_responses(buf)
    return responses[0] == "Hello world"
  end, 20)

  local responses = renderer.get_responses(buf)
  expect("finalized", responses[0] == "Hello world", "final text mismatch")

  renderer.clear_line(buf, 0)
  responses = renderer.get_responses(buf)
  expect("cleared", responses[0] == nil, "response should be removed")
end)

if #failures > 0 then
  io.stderr:write("\n[pairy:test] FAILURES:\n")
  for _, item in ipairs(failures) do
    io.stderr:write("- " .. item .. "\n")
  end
  os.exit(1)
end

io.stdout:write("\n[pairy:test] All tests passed.\n")
os.exit(0)
