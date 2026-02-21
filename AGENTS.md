# Zoid Agent Guide

## Purpose
Zoid is a Zig CLI project with embedded Lua support.

`README.md` describes the long-term product vision (simple, lightweight, secure OpenClaw alternative). Treat that vision as direction, not as a statement of already shipped features.

## Current Implementation (Source of Truth: `src/`)
Today the project provides:
- A CLI binary (`zoid`) with command parsing in `src/cli.zig` and app entrypoint in `src/main.zig`.
- Lua script execution via `zoid execute <file.lua>` in `src/lua_runner.zig`.
- JSON config key/value storage via `zoid config set|get|unset|list` in `src/config_store.zig`.
- OpenAI chat + one-shot run flows in `src/openai_client.zig` and `src/chat_session.zig`, including local tools (`filesystem_read`, `filesystem_write`, `filesystem_delete`, `lua_execute`, `config`, `http_get`, `http_post`, `http_put`, `http_delete`) with workspace-root policy handling via `src/tool_runtime.zig`.
- Shared OpenAI model policy in `src/model_catalog.zig` (default model, picker fallback models, and chat-model ID filtering rules).
- Build + test pipeline in `build.zig`, including embedded Lua (static library from dependency `lua` in `build.zig.zon`).

Not implemented yet (vision-stage in `README.md`):
- E2E chat encryption flows.
- Encrypted key vault + gateway unlock flow.
- Daemon/gateway product behavior described at a higher level.

When documentation conflicts, prefer:
1. `src/` and tests for current behavior.
2. `README.md` for long-term intent.

## Engineering Rules
- Keep all code, commit messages, and user-facing copy in English.
- Always write commit messages in English.
- Keep this `AGENTS.md` file updated whenever adding code or changing behavior.
- Keep `docs/lua_api.md` updated when Lua runtime behavior or Lua sandbox APIs change.
- Add notable implementation learnings to `AGENTS.md` so future changes can reuse them.
- For adding Zig packages/dependencies, use `https://zigistry.dev/` as an input source.
- Keep tests updated with behavior changes.
- After code updates:
  - Format the code.
  - Run `zig build` and ensure it passes; if it fails, fix the issues before finishing.
  - Run tests.

## Required Local Commands After Code Changes
- Format:
  - `zig fmt build.zig src/*.zig`
- Build:
  - `zig build`
- Tests:
  - `zig build test`

If you change command behavior, error handling, config format, or Lua execution behavior, add/update tests in the corresponding Zig files.

## Practical Change Guidance
- CLI changes:
  - Update parsing + help text in `src/cli.zig`.
  - Update execution flow and user-visible errors in `src/main.zig`.
  - `zoid execute <file.lua>` must use the same sandbox restrictions and `.lua` path policy as `lua_execute` so local script runs match tool-mode behavior.
  - Default command is `chat` when running `zoid` with no arguments.
- Chat interface changes:
  - `src/chat_session.zig` now uses fullscreen `libvaxis` UI in the alternate screen when running on a TTY, with `vaxis.widgets.TextInput` handling readline-style editing (`Ctrl+A`, `Ctrl+E`, arrows, backspace/delete).
  - When submitting chat input, snapshot text with `snapshotInputText`/`takeInputText` and then clear the widget; avoid `TextInput.toOwnedSlice()` in the live TUI loop to prevent input buffer corruption/ghost text rendering.
  - Sanitize transcript text before rendering: strip ANSI escape sequences, normalize `\r`/`\r\n` to `\n`, replace tabs with spaces, and replace other control bytes with spaces to avoid terminal state corruption from model/tool output.
  - Chat input history is session-local: `Up`/`Down` browse previously submitted prompts/commands, and moving down past the newest history entry restores the current draft.
  - Slash commands in chat: `/new` clears the current conversation+transcript (new local session), `/help` appends a local command list message, and `/exit`/`/quit` exits chat.
  - `chat` is TTY-only; non-interactive one-shot usage should go through `zoid run <prompt...>` and write only the agent output to stdout.
  - Keep the input box anchored at the bottom of the screen.
  - Input rendering is manual soft word-wrap, and the input box grows vertically upward as lines increase.
  - Transcript viewport selection must always include at least the latest entry even when a single message exceeds viewport height, so large tool outputs do not blank the transcript area.
  - Transcript scrollback in chat is row-based with a 500-row buffer; `Ctrl+P`/`Ctrl+N` scroll one row up/down and `Ctrl+U`/`Ctrl+D` scroll half a screen up/down.
  - Assistant/error transcript rendering strips Markdown backtick delimiters and draws inline/fenced code with dedicated styles (no literal `` ` ``/``` fences shown).
  - `build.zig` must import the `vaxis` module into the `zoid` module for `@import("vaxis")` usage inside `src/`.
  - Model picker fallback models come from `src/model_catalog.zig` (`fallback_models`).
- OpenAI model policy changes:
  - Keep `src/model_catalog.zig` as the single source of truth for `default_model`, `fallback_models`, and `isChatModelId`.
  - `src/openai_client.zig` should use `model_catalog.isChatModelId` when filtering `/v1/models` results.
  - `src/main.zig` should use `model_catalog.default_model` when `OPENAI_MODEL` is unset.
  - `src/chat_session.zig` should use `model_catalog.fallback_models` for picker fallback choices.
  - Keep model catalog invariants covered by tests (`default_model` included in `fallback_models`, fallback IDs unique, fallback IDs chat-capable).
- Tool runtime changes:
  - `src/tool_runtime.zig` enforces `workspace-write` policy rooted at current working directory and exposes `filesystem_read`, `filesystem_write`, `filesystem_delete`, `lua_execute`, `config`, `http_get`, `http_post`, `http_put`, and `http_delete`.
  - Shared filesystem sandbox/path enforcement lives in `src/workspace_fs.zig`; both `lua_execute` (`zoid.file(...)`) and direct filesystem tools must use this module.
  - Shared outbound HTTP request behavior lives in `src/http_client.zig`; both `lua_execute` (`zoid.uri(...)`) and direct HTTP tools must use this module to avoid divergence.
  - Shared config mutation/read behavior lives in `src/config_runtime.zig`; both `lua_execute` (`zoid.config():list/get/set/unset`) and direct `config` tool calls must use this module to avoid divergence.
  - `filesystem_delete` only removes files whose canonical path resolves inside workspace root; traversal outside root must return `error.PathNotAllowed`.
  - `lua_execute` runs scripts via the embedded Lua runtime (`src/lua_runner.zig`) in-process, not via shell process execution, and only accepts `.lua` files under workspace root.
  - `lua_execute` must intercept Lua script output so it is never written to process stdout/stderr in TUI mode; instead surface captured streams in tool JSON (`stdout` and `stderr`, with truncation flags) so the agent can read outputs safely.
  - `http_get`/`http_post`/`http_put`/`http_delete` are direct HTTP(S) tools (no Lua script required); accepted input is a `uri` string plus optional `body` for `post`/`put`, and responses include `status` + `body` with `ok` reflecting 2xx status.
  - In `lua_execute` tool-mode, remove `os`/`package`/`debug`/`require`/`dofile`/`loadfile`; expose `zoid.file(path):read([max_bytes])`, `zoid.file(path):write(content)`, `zoid.file(path):delete()`, `zoid.uri(uri):get/post/put/delete`, and `zoid.config():list/get/set/unset`.
  - `zoid.uri(uri)` allows only HTTP/HTTPS requests and returns a Lua table with `status`, `body`, and `ok`; response body capture is capped by sandbox policy (currently 1 MiB in `lua_execute`).
  - Tool-mode `io` must be a minimal capture-only table (`io.write` and `io.stderr:write`) so scripts can emit stdout/stderr for agent inspection without gaining general file I/O APIs.
  - `shell_command` and `exec` are intentionally disabled for OpenAI tool calls; unknown/disabled tool calls must return `error.ToolDisabled`.
  - Keep path checks strict: resolve to canonical paths and reject access outside workspace root.
- Config changes:
  - Preserve valid JSON object format (string keys and string values).
  - Keep deterministic key listing behavior (`list` is currently sorted).
  - Keep OpenAI config key names centralized in `src/config_keys.zig` and reuse those constants in command/chat code paths.
- Lua runner changes:
  - Keep clear load/runtime error reporting.
  - Preserve current error contract (`LuaStateInitFailed`, `LuaLoadFailed`, `LuaRuntimeFailed`).
- Public module surface:
  - Keep `src/root.zig` exports aligned with intended package API.

## Scope Discipline
For near-term tasks, prioritize incremental CLI and reliability improvements that move toward the README vision without claiming unimplemented security/daemon features as complete.
