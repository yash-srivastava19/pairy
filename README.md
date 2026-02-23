# pairy

Pair programming with AI, without leaving your editor.

Instead of switching to a chat interface, you write a `pair:` comment in your code. Hit a keymap. The response streams in as inline virtual text right below — visible in context, never written to the file.

The AI doesn't just answer. It pushes back: surfaces assumptions you haven't stated, asks one probing question when your reasoning has a gap, and redirects you when you're off track. The goal is to make you think more clearly, not to think for you.

```ruby
def insert(node, val)
  # pair: should I handle the nil root case here or in the caller?
  ⬡ Handle it here — the function owns its invariants.
  ⬡ Callers shouldn't need to know your internal structure.
  if node.val > val
```

Works in any language. Responses are scoped to the code around the comment — the AI sees what you see.

---

## Requirements

- Neovim 0.10+
- [lazy.nvim](https://github.com/folke/lazy.nvim)
- `curl` (already on most systems)
- A [Google AI Studio API key](https://aistudio.google.com/app/apikey) — free tier is sufficient

---

## Installation

**1. Clone the repo**

```sh
git clone https://github.com/yash-srivastava19/pairy ~/.local/share/pairy
```

**2. Create your config**

```sh
mkdir -p ~/.config/pairy
```

`~/.config/pairy/config.json`:

```json
{
  "api_key": "YOUR_GEMINI_API_KEY",
  "model": "gemini-2.5-flash",
  "context_lines": 20,
  "max_tokens": 8192
}
```

**3. Add the plugin spec**

In your lazy.nvim plugins directory (e.g. `~/.config/nvim/lua/plugins/pairy.lua`):

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
      map("n", "<leader>ais", pairy.send,       { desc = "Pairy: Send comment at cursor" })
      map("n", "<leader>aic", pairy.clear,      { desc = "Pairy: Clear all responses" })
      map("n", "<leader>aix", pairy.clear_line, { desc = "Pairy: Clear response at cursor" })
      map("n", "<leader>aia", pairy.send_all,   { desc = "Pairy: Send all pair: comments" })
      map("n", "<leader>aiK", pairy.cancel,     { desc = "Pairy: Cancel request" })
    end,
  },
}
```

**4. Restart Neovim**

---

## Usage

Write a `pair:` comment anywhere in your code. The syntax works in any language:

```lua
-- pair: is a hash map the right structure here?
```
```python
# pair: should this be a class method or a standalone function?
```
```javascript
// pair: is there a reason to prefer reduce over a plain loop?
```
```rust
// pair: when should I use Arc vs Rc here?
```

Place your cursor on or near the comment and press `<leader>ais`. The response streams in word by word below the line. It never touches your file.

### Keymaps

| Key | Action |
|---|---|
| `<leader>ais` | Send `pair:` comment at/near cursor |
| `<leader>aia` | Send all `pair:` comments in buffer |
| `<leader>aiw` | Save session to a markdown file |
| `<leader>aic` | Clear all responses in buffer |
| `<leader>aix` | Clear response at cursor |
| `<leader>aiK` | Cancel in-flight request |

### Commands

`:PairySend` `:PairyAll` `:PairySave` `:PairyClear` `:PairyClearLine` `:PairyCancel` `:PairyReload`

### Saving a session

`:PairySave` (or `<leader>aiw`) collects every answered `pair:` comment in the buffer — question, code context, and response — and writes it to a timestamped markdown file in `~/.local/share/pairy/sessions/`. The file opens in a vertical split immediately so you can read, edit, or save it elsewhere.

This is useful for revisiting your own reasoning later, or as a record during pair programming interviews.

---

## Config reference

| Key | Default | Description |
|---|---|---|
| `api_key` | — | **Required.** Google AI Studio API key |
| `model` | `gemini-2.5-flash` | Any Gemini model ID |
| `context_lines` | `20` | Lines of code above/below the comment sent as context |
| `max_tokens` | `8192` | Max response length |
| `sessions_dir` | `~/.local/share/pairy/sessions` | Where session files are saved |

To reload config without restarting: `:PairyReload`
