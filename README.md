# pairy

AI pair programming inside Neovim. Write a `pair:` comment, hit a keymap, get a response as inline virtual text — never written to the file.

```ruby
def insert(node, val)
  # pair: should I handle the nil root case here or in the caller?
  ⬡ Handle it here — the function owns its invariants.
  ⬡ Callers shouldn't need to know your internal structure.
```

The AI pushes back, not just answers. It surfaces unstated assumptions and asks one probing question when your reasoning has a gap.

![pairy demo](assets/demo.png)

---

## Requirements

- Neovim 0.10+
- lazy.nvim
- `curl`
- [Google AI Studio API key](https://aistudio.google.com/app/apikey) — free tier works

---

## Installation

**1.** Clone the repo:
```sh
git clone https://github.com/yash-srivastava19/pairy ~/.local/share/pairy
```

**2.** Create `~/.config/pairy/config.json`:
```json
{
  "api_key": "YOUR_GEMINI_API_KEY",
  "model": "gemini-2.5-flash",
  "context_lines": 20,
  "max_tokens": 8192
}
```

**3.** Add `~/.config/nvim/lua/plugins/pairy.lua`:
```lua
return {
  {
    dir    = vim.fn.expand("~/.local/share/pairy"),
    name   = "pairy",
    lazy   = false,
    config = function()
      local pairy = require("pairy")
      pairy.setup({})

      local map = vim.keymap.set
      map("n", "<leader>ais", pairy.send,           { desc = "Pairy: Send comment at cursor" })
      map("v", "<leader>ais", pairy.ask_selection,  { desc = "Pairy: Ask about selection" })
      map("n", "<leader>aia", pairy.send_all,       { desc = "Pairy: Send all pair: comments" })
      map("n", "<leader>aiw", pairy.save_session,   { desc = "Pairy: Save session to markdown" })
      map("n", "<leader>aic", pairy.clear,          { desc = "Pairy: Clear all responses" })
      map("n", "<leader>aix", pairy.clear_line,     { desc = "Pairy: Clear response at cursor" })
      map("n", "<leader>aiK", pairy.cancel,         { desc = "Pairy: Cancel request" })
    end,
  },
}
```

**4.** Restart Neovim.

---

## Usage

Write a `pair:` comment in any language and press `<leader>ais`:

```python
# pair: is there a reason to use a class here instead of a module?
```

In **visual mode**, select any block and press `<leader>ais` — you'll be prompted for a question. Useful for pasting in stack traces, logs, or data and asking about them directly.

### Keymaps

| Key | Mode | Action |
|---|---|---|
| `<leader>ais` | normal | Send `pair:` comment at/near cursor |
| `<leader>ais` | visual | Ask about selection |
| `<leader>aia` | normal | Send all `pair:` comments in buffer |
| `<leader>aiw` | normal | Save session to markdown |
| `<leader>aic` | normal | Clear all responses |
| `<leader>aix` | normal | Clear response at cursor |
| `<leader>aiK` | normal | Cancel in-flight request |

### Commands

`:PairySend` `:PairyAll` `:PairySave` `:PairyClear` `:PairyClearLine` `:PairyCancel` `:PairyReload`

---

## Features

**Conversation threading** — prior answered `pair:` comments in the buffer are sent as history, so the AI knows what was already discussed.

**Project context** — create `PAIRY.md` at the project root. Its contents are included with every request:
```
Rails 7.2, Postgres, Sidekiq. Service objects in app/services/. RSpec for tests.
```

**Session saving** — `:PairySave` writes every answered comment (question + code context + response) to a timestamped file in `~/.local/share/pairy/sessions/` and opens it in a floating window.

---

## Config

| Key | Default | Description |
|---|---|---|
| `api_key` | — | **Required.** Google AI Studio API key |
| `model` | `gemini-2.5-flash` | Any Gemini model ID |
| `context_lines` | `20` | Lines above/below the comment sent as context |
| `max_tokens` | `8192` | Max response length |
| `max_history` | `5` | Prior Q&As included as conversation history |
| `sessions_dir` | `~/.local/share/pairy/sessions` | Where `:PairySave` writes files |
