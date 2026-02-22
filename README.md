# pairy

Pair program with Claude inside Neovim. Write a `pair:` comment, hit a keymap, watch Claude's response stream in as inline virtual text — right below the comment, inside your code, no chat interface.

```ruby
def insert(node, val)
  # pair: should I handle the nil root case here or in the caller?
  # ⬡ Handle it here — the function owns its invariants.
  # ⬡ Callers shouldn't need to know internal structure. Guard at top.
  if node.val > val
```

The `⬡` lines are virtual text — they don't exist in your file, don't affect git diffs, and stream in token by token.

---

## Setup

### 1. Add your API key

Edit `~/.config/pairy/config.json`:

```json
{
  "api_key": "sk-ant-api03-...",
  "model": "claude-sonnet-4-6",
  "context_lines": 20,
  "max_tokens": 512
}
```

Get a key at [console.anthropic.com](https://console.anthropic.com).

### 2. Add to LazyVim

The spec is already at `~/.config/nvim/lua/plugins/pairy.lua`. Restart Neovim and lazy.nvim will pick it up automatically.

---

## Usage

Write a `pair:` comment in any language:

```lua
-- pair: is this the right data structure for this use case?
```
```ruby
# pair: should I extract this into its own method?
```
```python
# pair: is there a more pythonic way to do this?
```
```javascript
// pair: should I use async/await or a promise chain here?
```

### Keymaps

| Key | Action |
|---|---|
| `<leader>ais` | Send `pair:` comment at/near cursor to Claude |
| `<leader>aic` | Clear all responses in current buffer |
| `<leader>aix` | Clear response at cursor line |
| `<leader>aia` | Send all `pair:` comments in buffer |
| `<leader>aiK` | Cancel in-flight request |
| `<leader>air` | Reload config from disk |

### Commands

`:PairySend`, `:PairyClear`, `:PairyClearLine`, `:PairyAll`, `:PairyCancel`, `:PairyReload`

---

## Config options

| Key | Default | Description |
|---|---|---|
| `api_key` | — | **Required.** Anthropic API key |
| `model` | `claude-sonnet-4-6` | Model to use |
| `context_lines` | `20` | Lines of code above/below the comment sent as context |
| `max_tokens` | `512` | Max response length (keep low — responses are inline comments) |

---

## How it works

1. You write a `pair:` comment explaining your thought or question
2. Press `<leader>ais` — pairy finds the comment, extracts surrounding code context
3. The context + question are sent to Claude via the Anthropic API (streaming)
4. Claude's response streams in as inline virtual text below the comment
5. The virtual text lives until you clear it — it's never written to the file

Claude is given a system prompt that makes it respond as a concise pair programmer: direct opinions, no padding, code-aware, comment-friendly formatting.
