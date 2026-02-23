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

**Visual mode:** select any block of code, press `<leader>ais`, type your question at the prompt. No comment needed — useful for quick questions or when working with logs and data you've pasted in.

### Keymaps

| Key | Mode | Action |
|---|---|---|
| `<leader>ais` | normal | Send `pair:` comment at/near cursor |
| `<leader>ais` | visual | Ask a question about the selection |
| `<leader>aia` | normal | Send all `pair:` comments in buffer |
| `<leader>aiw` | normal | Save session to a markdown file |
| `<leader>aic` | normal | Clear all responses in buffer |
| `<leader>aix` | normal | Clear response at cursor |
| `<leader>aiK` | normal | Cancel in-flight request |

### Commands

`:PairySend` `:PairyAll` `:PairySave` `:PairyClear` `:PairyClearLine` `:PairyCancel` `:PairyReload`

### Conversation threading

Each `pair:` send automatically includes your prior answered Q&As from the same buffer as conversation history. The AI can reference what was discussed earlier — useful when debugging step by step or refining an approach across multiple comments. Capped at `max_history` (default 5) exchanges.

### Project context (PAIRY.md)

Create a `PAIRY.md` file in your project root (or anywhere in the tree up to the git root). Its contents are silently appended to every request so the AI knows your stack and constraints without you repeating it.

```markdown
# PAIRY.md
Rails 7.2, Ruby 3.3, Postgres. Service objects in app/services/.
We avoid fat models. Sidekiq for background jobs. RSpec for tests.
```

### Saving a session

`:PairySave` (or `<leader>aiw`) collects every answered `pair:` comment — question, code context, and response — and writes it to a timestamped markdown file in `~/.local/share/pairy/sessions/`. Opens in a floating window (press `q` to close).

Good for revisiting your reasoning, debugging post-mortems, or keeping a record during pair programming interviews.

---

## Config reference

| Key | Default | Description |
|---|---|---|
| `api_key` | — | **Required.** Google AI Studio API key |
| `model` | `gemini-2.5-flash` | Any Gemini model ID |
| `context_lines` | `20` | Lines of code above/below the comment sent as context |
| `max_tokens` | `8192` | Max response length |
| `max_history` | `5` | Max prior Q&As sent as conversation context |
| `sessions_dir` | `~/.local/share/pairy/sessions` | Where session files are saved |

To reload config without restarting: `:PairyReload`
