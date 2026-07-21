# Pairy for JetBrains (PyCharm) — Design

## Purpose

Bring Pairy's core loop — write a `pair:` comment, trigger it, get an AI response as
inline text that never touches the file — to PyCharm. Personal use only: local install
via "Install Plugin from Disk," no JetBrains Marketplace, no signing, single user.

## Scope

**In scope (v1 — core loop):**
- Detect `pair:` comments (cursor-adjacent, or all in buffer)
- Send to Gemini, render the response as non-editable inline text
- Retry, clear (single/all), send-all, cancel in-flight request
- Selection-based questions (visual-mode equivalent)
- Reuse the existing `~/.config/pairy/config.json`

**Out of scope (deferred to later iterations):**
- Conversation threading (multi-turn history per comment)
- `PAIRY.md` project-context injection
- Session saving to markdown
- Hover inspect (`PairyInspect`)
- Yank-to-clipboard, toggle visibility
- Streaming responses (v1 is a single blocking call — see below)
- Marketplace publishing, plugin signing, multi-user config

## Why non-streaming for v1

The Lua client streams tokens via `curl` + SSE into virtual text as they arrive.
Replicating that against IntelliJ's `Inlay` API means updating a live block element on
every chunk — extra plumbing that changes *how the response arrives*, not *what you can
do with it*. v1 does one blocking HTTP call to Gemini's non-streaming
`generateContent` endpoint and renders the full response when it lands, with a
"thinking…" placeholder inlay while waiting. Streaming can be added later without
changing the detector, client contract, or actions.

## Architecture

Standalone Gradle project using the IntelliJ Platform Gradle Plugin, Kotlin, targeting
PyCharm (platformType `PC`). Lives at `pairy/jetbrains-plugin/` inside this repo,
alongside the existing Neovim/Emacs code — same repo, separate build system, no shared
runtime dependency between them.

Five components, mirroring the existing `lua/pairy/*.lua` module split:

```
jetbrains-plugin/
├── build.gradle.kts
├── src/main/kotlin/pairy/
│   ├── PairyConfig.kt      — reads ~/.config/pairy/config.json
│   ├── PairyDetector.kt    — pair: comment regex + context extraction
│   ├── PairyClient.kt      — Gemini API call (blocking, on a background thread)
│   ├── PairyRenderer.kt    — Inlay-based response rendering
│   └── PairyActions.kt     — Send/Retry/Clear/ClearAll/SendAll/Cancel actions
└── src/main/resources/META-INF/plugin.xml
```

## Component detail

### PairyConfig
Reads and parses `~/.config/pairy/config.json` (same file the Neovim/Emacs versions
use — no new config, no re-entering the API key). Same schema: `api_key` (required),
`model` (default `gemini-2.5-flash`), `context_lines` (default 20), `max_tokens`
(default 8192). Missing file or missing `api_key` → IntelliJ balloon notification
pointing at the config path, mirroring the Lua version's `:PairyInit` nudge (no
`PairyInit` command in v1 — if the file's missing, the notification tells you to create
it by hand or run the existing `:PairyInit` in Neovim once).

### PairyDetector
Same four regex patterns as `detector.lua`'s `PAIR_PATTERNS`, translated to Kotlin
`Regex`, tried in order against the raw line text:
- Lua-style: `--`
- Ruby/Python/shell: `#`
- JS/TS/Rust/Go: `//`
- C block: `/*`

Two entry points, matching the Lua API:
- `findAtCursor(editor)` — checks the cursor's line, then up to 3 lines above, first
  match wins.
- `findAll(editor)` — every `pair:` comment in the document, in order.

`buildContext(editor, lineNumber, contextLines)` — numbered code block with a `>`
marker on the `pair:` line, same format as `build_context` in the Lua version, so the
prompt shape sent to Gemini is unchanged.

### PairyClient
Builds the same request body as `client.lua`'s `build_request_body`: same
`SYSTEM_PROMPT` text verbatim, `system_instruction` + `contents` + `generationConfig`
(`maxOutputTokens`). Posts to
`https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={api_key}`
(non-streaming variant — no `alt=sse`, no `stream` in the path) using
`java.net.http.HttpClient`, off the EDT via a coroutine or `ProgressManager` background
task. Parses the JSON response for `candidates[0].content.parts[0].text`. Errors
(non-2xx, network failure, empty response, malformed JSON) all surface as an
IntelliJ notification, matching the Lua version's `on_error` callback behavior.

### PairyRenderer
Renders responses via `InlayModel.addBlockElement` — a read-only block inlay placed
after the `pair:` comment's line, styled as gray/italic text wrapped to a readable
width. Tracks one inlay per pair-comment line in a per-editor map so `Clear` (single)
and `ClearAll` can dispose the right ones. Never modifies the `Document` — same
guarantee as Neovim's extmark-based virtual text ("never written to the file").

While a request is in flight, the same inlay slot shows a "thinking…" placeholder,
replaced with the real response on completion (or cleared with an error notification
on failure).

### PairyActions
Registered in `plugin.xml` with default keymaps (avoiding common PyCharm shortcuts —
final bindings chosen during implementation, adjustable via Settings → Keymap
afterward):

| Action | Behavior |
|---|---|
| Send | No selection: find `pair:` comment at/near cursor, send it. Active selection: prompt for a question via `Messages.showInputDialog`, send selection + question as context (visual-mode equivalent). |
| Retry | Re-send the `pair:` comment at cursor. |
| Send All | Send every `pair:` comment in the buffer. |
| Clear | Dispose the inlay at cursor. |
| Clear All | Dispose every inlay in the buffer. |
| Cancel | Cancel the in-flight request for the comment at cursor. |

## Data flow

```
keypress → PairyActions.Send
  → PairyDetector.findAtCursor (or selection prompt)
  → PairyRenderer: show "thinking…" placeholder inlay
  → PairyClient.send (background thread)
       → PairyConfig.get() for api_key/model
       → HTTP POST to Gemini generateContent
  → on success: PairyRenderer replaces placeholder with response text
  → on error: PairyRenderer clears placeholder, notification shown
```

## Testing

No JetBrains UI test harness for v1 — that's disproportionate effort for a personal
single-user plugin. Two levels:
- Unit tests (JUnit, no platform dependency) for `PairyDetector`'s regex extraction and
  context-building, ported from the intent of the existing Lua behavior.
- Manual verification via `./gradlew runIde` (launches a sandboxed PyCharm instance
  with the plugin loaded) — exercise Send/Retry/Clear/SendAll/Cancel against a real
  file with `pair:` comments before calling it done.

## Distribution

`./gradlew buildPlugin` produces a zip under `build/distributions/`. Install via
PyCharm → Settings → Plugins → gear icon → "Install Plugin from Disk." No signing, no
marketplace listing — IntelliJ allows unsigned local installs with a one-time warning,
which is expected and fine for this use case.
