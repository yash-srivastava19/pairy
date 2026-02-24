---
name: pairy-feature
description: Add a new feature to the pairy plugin — implement in Neovim (Lua), port to Emacs (pairy.el), write tests for both editors, update README, commit and push.
argument-hint: [feature description]
allowed-tools: Read, Edit, Write, Glob, Grep, Bash(nvim *), Bash(emacs *), Bash(git *)
---

# Pairy Feature Workflow

Implement $ARGUMENTS as a feature in the pairy plugin, following the established pattern for this repo.

## Architecture Overview

**Neovim** (Lua):
- `lua/pairy/init.lua` — public API (`M.fn()`), user commands (`:PairyX`), called from keymaps
- `lua/pairy/renderer.lua` — extmark/virtual text lifecycle; per-buffer state in `state[buf]`
- `lua/pairy/detector.lua` — `pair:` comment scanner; returns `PairComment` structs
- `lua/pairy/client.lua` — curl subprocess + SSE streaming; `on_token`/`on_done`/`on_error` callbacks
- `lua/pairy/config.lua` — `config.get()` returns merged config + overrides
- `lua/pairy/util.lua` — `trim`, `wrap_text`, `split_lines`, `notify`, `notify_err`, `notify_warn`

**Emacs** (Elisp, `pairy.el`):
- Renderer: `pairy--overlays` hash (line-nr → overlay), `pairy--responses` hash (line-nr → text)
- Always call `(pairy--ensure-state)` before touching the hashes — they're lazily initialized per buffer
- `pairy--set-overlay` creates/updates the overlay via `overlay-put 'after-string`
- State vars: `pairy--active-process`, `pairy--hidden`, `pairy--config`

## Step-by-Step

### 1. Implement in Neovim

Read the relevant files first — understand what exists before adding anything.

For a typical feature:
- Add internal helpers/state in `renderer.lua` if it's a display feature
- Add the public function to `init.lua` as `M.feature_name()`
- Register a user command in `M.setup()` inside the `if not commands_registered` block:
  ```lua
  vim.api.nvim_create_user_command("PairyX", M.feature_name, { desc = "..." })
  ```
- The LazyVim spec (`~/.config/nvim/lua/plugins/pairy.lua`) holds the keymaps — add the keymap using the wrapper pattern:
  ```lua
  map("n", "<leader>aiX", p("feature_name"), { desc = "Pairy: ..." })
  ```

### 2. Port to Emacs

In `pairy.el`:
- Add any new `defvar-local` state variables after the existing ones (around line 246)
- Add the public command as `(defun pairy-feature ...)` with `;;;###autoload` and `(interactive)` before `pairy-reload`
- Add the keymap binding inside the `pairy-mode-map` `let` block (around line 429)

Follow existing patterns:
- `(pairy--ensure-state)` at the start of any function that reads/writes hashes
- `(user-error "pairy: ...")` for user-facing errors
- `(message "pairy: ...")` for success/status messages

### 3. Write Neovim tests

In `tests/run.lua`, add test cases using:
```lua
run("renderer.feature: description", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "-- pair: test" })
  -- ... setup ...
  -- Use vim.wait() for async operations (word-drip, finalize):
  vim.wait(500, function() return condition end, 20)
  expect("label", condition, "failure message")
end)
```

Add tests just before the `-- ─── Results ───` section at the bottom.

### 4. Write Emacs ERT tests

In `tests/pairy-test.el`, add test cases using:
```elisp
(ert-deftest pairy-feature/description ()
  "What this test verifies."
  (with-temp-buffer
    (insert "# pair: question\n")
    (goto-char (point-min))
    (pairy--ensure-state)
    ;; ... setup and assertions ...
    (should condition)
    (should-not other-condition)
    (should-error (pairy-fn) :type 'user-error)))
```

Add tests before the final `;;; pairy-test.el ends here` line.

### 5. Run tests

```bash
nvim --headless -u NONE -n -l tests/run.lua
emacs --batch -l pairy.el -l tests/pairy-test.el -f ert-run-tests-batch-and-exit
```

All tests must pass before committing. Fix any failures before proceeding.

### 6. Update README

In `README.md`, update:
- **Neovim keymaps table** (around the `## Keymaps` section) — add the new `<leader>aiX` row
- **Neovim commands table** (around the `## Commands` section) — add the new `:PairyX` row
- **Emacs keymaps table** — add the new `C-c a x` row
- **Emacs commands table** — add the new `M-x pairy-feature` row

### 7. Commit and push

Stage only the changed files (never stage `~/.config/pairy/config.json`):
```bash
git add lua/pairy/init.lua lua/pairy/renderer.lua pairy.el \
        tests/run.lua tests/pairy-test.el README.md \
        ~/.config/nvim/lua/plugins/pairy.lua  # if keymaps changed
```

Commit message format (atomic, describes the why):
```
feat: [concise description of what was added and why]

Neovim: brief summary of Lua changes
Emacs: brief summary of pairy.el changes
Tests: N total (X Neovim + Y Emacs), all passing.
README: note what was updated.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
```

Then push: `git push`

## Key Rules

- **Never touch `~/.config/pairy/config.json`** — real API key lives there, never commit it
- **Parity**: every feature must exist in both Neovim and Emacs
- **Tests first** — run the full suite before committing; fix failures, don't skip them
- **Keymaps prefix**: Neovim uses `<leader>ai`, Emacs uses `C-c a`
- The pre-push hook runs the full test suite — if it fails, the push is blocked
