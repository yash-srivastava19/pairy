# Pairy — JetBrains Plugin

A JetBrains/PyCharm port of Pairy's core loop: write a `pair:` comment above or
on a line of code, trigger Send, and get an AI response rendered as an inline
editor annotation (via the Gemini API). The response is never written to the
file — it lives only in the editor's inlay/rendering layer and disappears with
Clear or when the file changes. This plugin is for personal local install use
only; it is not published to the JetBrains Marketplace.

## Requirements

This plugin reuses the same config file as the Neovim and Emacs versions of
Pairy — no separate setup needed if you already have one:

```
~/.config/pairy/config.json
```

Schema (all fields optional, sensible defaults applied):

| Field           | JSON key        | Default            | Description                          |
|-----------------|------------------|---------------------|---------------------------------------|
| API key         | `api_key`        | `""`                | Gemini API key                        |
| Model           | `model`          | `gemini-2.5-flash`  | Gemini model id                       |
| Context lines   | `context_lines`  | `20`                | Lines of surrounding context to send  |
| Max tokens      | `max_tokens`     | `8192`              | Max output tokens per response        |

## Keybindings

Each action is a single shortcut (no chord/leader key) and is also available
from **Tools → Pairy**. All six are verified against PyCharm's default keymap
(`$default.xml`) to not collide with any built-in binding.

| Action     | Shortcut       | Description                                          |
|------------|----------------|-------------------------------------------------------|
| Send       | `Alt+Shift+S`  | Send the `pair:` comment at cursor, or ask about the selection |
| Retry      | `Alt+Shift+R`  | Re-send the `pair:` comment at cursor                |
| Send All   | `Alt+Shift+L`  | Send every `pair:` comment in the file               |
| Clear      | `Alt+Shift+X`  | Clear the response at cursor                         |
| Clear All  | `Alt+Shift+C`  | Clear all responses in the file                      |
| Cancel     | `Alt+Shift+K`  | Cancel the in-flight request at cursor               |

## Build & Install

Build the distributable plugin zip:

```bash
cd jetbrains-plugin
./gradlew buildPlugin
```

The zip is produced under `build/distributions/`. Install it in PyCharm (or
any IntelliJ Platform IDE) via:

**Settings → Plugins → gear icon → Install Plugin from Disk...** → select the
zip.

## Manual testing (sandbox IDE)

To try changes without building a distributable, launch a sandboxed IDE
instance with the plugin pre-loaded:

```bash
./gradlew runIde
```

## Known v1 limitations

This is a minimal port of the core loop, not a full port of every Pairy
feature:

- **Non-streaming** — the full response arrives at once; there is no live
  token-by-token streaming as it generates.
- **Core loop only** — no conversation threading, no `PAIRY.md` project
  context file, no session save/restore, and no hover-to-inspect. These
  exist in the Neovim/Emacs versions but were not ported here.
