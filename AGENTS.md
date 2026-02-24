# Zoid Agent Guide

## Purpose
Zoid is a Zig CLI project with embedded Lua support.

## Implementation
The project provides:
- A CLI binary (`zoid`) with command parsing in `src/cli.zig` and app entrypoint in `src/main.zig`.
- Lua script execution via `zoid execute <file.lua>` in `src/lua_runner.zig`.
- JSON config key/value storage via `zoid config set|get|unset|list` in `src/config_store.zig`.
- Service mode via `zoid serve` in `src/telegram_bot.zig` (currently Telegram long-polling), maintaining conversation context per Telegram `chat_id`, persisting it under the app-data directory, forwarding messages to OpenAI, replying with `sendMessage`, and running scheduled jobs from app-data scheduler storage (workspace-scoped namespace).
- OpenAI chat + one-shot run flows in `src/openai_client.zig` and `src/chat_session.zig`, including local tools (`filesystem_read`, `filesystem_list`, `filesystem_grep`, `filesystem_write`, `filesystem_mkdir`, `filesystem_rmdir`, `filesystem_delete`, `lua_execute`, `config`, `jobs`, `http_get`, `http_post`, `http_put`, `http_delete`) with workspace-root policy handling via `src/tool_runtime.zig`.
- Shared scheduler persistence/runtime in `src/scheduler_store.zig` + `src/scheduler_runtime.zig` with cron helper logic in `src/cron_adapter.zig`.
- Shared OpenAI model policy in `src/model_catalog.zig` (default model, picker fallback models, and chat-model ID filtering rules).
- Build + test pipeline in `build.zig`, including embedded Lua (static library from dependency `lua` in `build.zig.zon`).

When documentation conflicts, prefer: `src/` and tests for current behavior.

## Engineering Rules
- Keep all code, commit messages, and user-facing copy in English.
- Do not preserve backward compatibility for command naming before first release; prefer replacing old names entirely (for example, `zoid schedule` -> `zoid jobs`).
- Keep this `AGENTS.md` file updated whenever adding code or changing behavior.
- Keep `API.md` updated when Lua runtime behavior or Lua sandbox APIs change.
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

### CLI changes:
  - Update parsing + help text in `src/cli.zig`.
  - Update execution flow and user-visible errors in `src/main.zig`.
  - Jobs CLI commands live under `zoid jobs ...` with create/list/delete/pause/resume.
  - `zoid jobs create` takes a single path argument and infers job type from extension: `.lua` or `.md`.
  - `zoid execute <file.lua> [args...]` must forward extra positional args to Lua global `arg` (`arg[0]` script path, `arg[1..]` forwarded args).
  - `zoid execute` supports optional `--timeout <seconds>` before `<file.lua>` to override Lua runtime timeout for that invocation.
  - `zoid execute <file.lua>` must use the same sandbox restrictions and `.lua` path policy as `lua_execute` so local script runs match tool-mode behavior.
  - Default command is `chat` when running `zoid` with no arguments.
  - `zoid serve` is the long-running service entrypoint; currently it requires both `OPENAI_API_KEY` and `TELEGRAM_BOT_TOKEN` in config and runs a Telegram long-polling loop until interrupted.
  - `zoid chat` and `zoid serve` load `ZOID.md` from the workspace root on startup when present, and pass its content as additional agent instructions in OpenAI system context.
  - Telegram service mode keeps conversation history per `chat_id` (similar to local chat session continuity), persists it to app-data (`telegram_context.json` next to `config.json`), and enforces a per-chat history cap (`max_conversation_messages_per_chat` in `src/telegram_bot.zig`).
  - Telegram service mode acquires an app-data lock file (`telegram_serve.lock`) so only one `zoid serve` instance runs per user profile; a second instance fails with `error.ServiceAlreadyRunning`.
  - `/new` or `/reset` clears that chat's stored Telegram context.
  - While generating a reply in Telegram service mode, send the native `sendChatAction` typing indicator periodically so users see Telegram's built-in "typing..." state until `sendMessage` completes.
  - Service mode processes due scheduled jobs before polling updates; scheduler output is sent to the assistant and assistant replies are delivered to Telegram DM when a DM chat id is available.
  - Service mode persists the latest private-chat `chat_id` to app-data (`telegram_dm_chat_id.txt`), which is used as runtime DM fallback when scheduled jobs execute.
  - Scheduler metadata files (`scheduler_jobs.json` + lock/tmp) must live under `getAppDataDir("zoid")`, not inside the workspace tree; only user-authored script/markdown job payload files should live in workspace.

### Chat interface changes:
  - `src/chat_session.zig` now uses fullscreen `libvaxis` UI in the alternate screen when running on a TTY, with `vaxis.widgets.TextInput` handling readline-style editing (`Ctrl+A`, `Ctrl+E`, arrows, backspace/delete).
  - When submitting chat input, snapshot text with `snapshotInputText`/`takeInputText` and then clear the widget; avoid `TextInput.toOwnedSlice()` in the live TUI loop to prevent input buffer corruption/ghost text rendering.
  - Sanitize transcript text before rendering: strip ANSI escape sequences, normalize `\r`/`\r\n` to `\n`, replace tabs with spaces, and replace other control bytes with spaces to avoid terminal state corruption from model/tool output.
  - Chat input history is session-local: `Up`/`Down` browse previously submitted prompts/commands, and moving down past the newest history entry restores the current draft.
  - Slash commands in chat: `/new` clears the current conversation+transcript (new local session), `/help` appends a local command list message, and `/exit`/`/quit` exits chat.
  - In chat input, `Enter` submits, while `Shift+Enter` inserts a newline without sending.
  - `chat` is TTY-only; non-interactive one-shot usage should go through `zoid run <prompt...>` and write only the agent output to stdout.
  - Keep the input box anchored at the bottom of the screen.
  - Input rendering is manual soft word-wrap, and the input box grows vertically upward as lines increase.
  - Transcript viewport selection must always include at least the latest entry even when a single message exceeds viewport height, so large tool outputs do not blank the transcript area.
  - Transcript scrollback in chat is row-based with a 500-row buffer; `Ctrl+P`/`Ctrl+N` scroll one row up/down and `Ctrl+U`/`Ctrl+D` scroll half a screen up/down.
  - Assistant/error transcript rendering strips Markdown backtick delimiters and draws inline/fenced code with dedicated styles (no literal `` ` ``/``` fences shown).
  - `build.zig` must import the `vaxis` module into the `zoid` module for `@import("vaxis")` usage inside `src/`.
  - Model picker fallback models come from `src/model_catalog.zig` (`fallback_models`).

### OpenAI model policy changes:
  - Keep `src/model_catalog.zig` as the single source of truth for `default_model`, `fallback_models`, and `isChatModelId`.
  - `src/openai_client.zig` should use `model_catalog.isChatModelId` when filtering `/v1/models` results.
  - When writing OpenAI tool-definition JSON in `src/openai_client.zig`, prefer `writeAll` segments plus targeted `writer.print` for numeric inserts instead of one large escaped-brace format string; malformed formatting can trigger OpenAI `400` with `We could not parse the JSON body`.
  - `src/openai_client.zig` currently allows up to 16 tool-call rounds per request; if that budget is exhausted it performs one final chat-completions call with `tool_choice=\"none\"` to let the model synthesize a final answer before returning `ToolCallLimitExceeded`.
  - `src/main.zig` should use `model_catalog.default_model` when `OPENAI_MODEL` is unset.
  - `src/chat_session.zig` should use `model_catalog.fallback_models` for picker fallback choices.
  - Keep model catalog invariants covered by tests (`default_model` included in `fallback_models`, fallback IDs unique, fallback IDs chat-capable).

### Tool runtime changes:
  - `src/tool_runtime.zig` enforces `workspace-write` policy rooted at current working directory and exposes `filesystem_read`, `filesystem_list`, `filesystem_grep`, `filesystem_write`, `filesystem_mkdir`, `filesystem_rmdir`, `filesystem_delete`, `lua_execute`, `config`, `jobs`, `http_get`, `http_post`, `http_put`, and `http_delete`.
  - Shared filesystem sandbox/path enforcement and metadata/listing logic lives in `src/workspace_fs.zig`; both `lua_execute` (`zoid.file(...)` / `zoid.dir(...)`) and direct filesystem tools must use this module.
  - Shared outbound HTTP request behavior lives in `src/http_client.zig`; both `lua_execute` (`zoid.uri(...)`) and direct HTTP tools must use this module to avoid divergence.
  - Shared config mutation/read behavior lives in `src/config_runtime.zig`; both `lua_execute` (`zoid.config():list/get/set/unset`) and direct `config` tool calls must use this module to avoid divergence.
  - `filesystem_mkdir` creates one directory whose canonical path resolves inside workspace root and fails if it already exists.
  - `filesystem_rmdir` removes one empty directory whose canonical path resolves inside workspace root.
  - `filesystem_delete` only removes files whose canonical path resolves inside workspace root; traversal outside root must return `error.PathNotAllowed`.
  - `lua_execute` runs scripts via the embedded Lua runtime (`src/lua_runner.zig`) in-process, not via shell process execution, and only accepts `.lua` files under workspace root.
  - `lua_execute` accepts optional `args` (array of strings) and forwards them to Lua global `arg[1..]` (with script path in `arg[0]`).
  - `lua_execute` enforces runtime timeout (default 10s) and accepts optional `timeout` override in seconds (`1..600`).
  - `lua_execute` must intercept Lua script output so it is never written to process stdout/stderr in TUI mode; instead surface captured streams in tool JSON (`stdout` and `stderr`, with truncation flags) so the agent can read outputs safely.
  - `http_get`/`http_post`/`http_put`/`http_delete` are direct HTTP(S) tools (no Lua script required); accepted input is a `uri` string plus optional `body` for `post`/`put`, and responses include `status` + `body` with `ok` reflecting 2xx status.
  - In `lua_execute` tool-mode, remove `os`/`package`/`debug`/`require`/`dofile`/`loadfile`; expose `zoid.file(path)` metadata handles with `:read([max_bytes])/:write(content)/:delete()`, `zoid.dir(path)` metadata handles with `:list()/:create()/:remove()/:grep(pattern, [options])`, `zoid.uri(uri):get/post/put/delete`, `zoid.config():list/get/set/unset`, `zoid.import(path)`, `zoid.json.decode`, `zoid.time([table])`, `zoid.date([format[, epoch]])`, and `zoid.exit([code])`.
  - `zoid.import(path)` only loads `.lua` files inside workspace root, resolves relative paths from the importing module's directory, caches loaded modules per script execution, and rejects cyclic imports.
  - `zoid.exit([code])` must stop only the current Lua script execution and never terminate the hosting `zoid` process; tool JSON should surface `exit_code` and report non-zero exits as `LuaExit`.
  - `zoid.dir(path):create()` must fail when the target directory already exists, and `zoid.dir(path):remove()` must fail when the target directory is non-empty.
  - `filesystem_grep` searches file content under a workspace path with optional recursion and match limits; tool result includes match path/line/column/text, files scanned, and truncation status.
  - `zoid.dir(path):grep(pattern, [options])` uses the same workspace sandbox/path rules as filesystem tools and supports `options.recursive` (default `true`) and `options.max_matches` (default `200`, max `5000`).
  - `zoid.uri(uri)` allows only HTTP/HTTPS requests and returns a Lua table with `status`, `body`, and `ok`; response body capture is capped by sandbox policy (currently 1 MiB in `lua_execute`).
  - `zoid.uri(...):get/delete/post/put` accept optional request options with `headers` table (string->string); header names/values are validated and dangerous overrides such as `Host`/`Content-Length` are rejected.
  - `zoid.json.decode` maps JSON values to Lua tables/scalars and maps JSON `null` to the sentinel `zoid.json.null`.
  - `zoid.time([table])` and `zoid.date([format[, epoch]])` provide safe time/date helpers inside sandboxed Lua while global `os` remains disabled; behavior is aligned with Lua `os.time`/`os.date`, including date-table normalization in `zoid.time`.
  - `jobs` tool supports `create/list/delete/pause/resume`; create supports `.lua` and `.md` paths with exactly one schedule input (`run_at` RFC3339 or 5-field `cron`), and does not resolve Telegram destination at create time.
  - In `telegram_bot` scheduled processing, skip agent dispatch when Lua stdout+stderr are both empty (after trim), or when markdown content is empty (after trim).
  - Tool-mode `io` must be a minimal capture-only table (`io.write` and `io.stderr:write`) so scripts can emit stdout/stderr for agent inspection without gaining general file I/O APIs.
  - `shell_command` and `exec` are intentionally disabled for OpenAI tool calls; unknown/disabled tool calls must return `error.ToolDisabled`.
  - Keep path checks strict: resolve to canonical paths and reject access outside workspace root.

### Config changes:
  - Preserve valid JSON object format (string keys and string values).
  - Keep deterministic key listing behavior (`list` is currently sorted).
  - Keep OpenAI and Telegram config key names centralized in `src/config_keys.zig` and reuse those constants in command/chat code paths.

### Lua runner changes:
  - Keep clear load/runtime error reporting.
  - Preserve current error contract (`LuaStateInitFailed`, `LuaLoadFailed`, `LuaRuntimeFailed`).
  - Tool-mode `zoid.jobs` API mirrors scheduler operations: `create/list/delete/pause/resume`.

### Lua script examples (`scripts/*.lua`) changes:
  - Keep scripts compatible with the sandboxed `zoid` API surface (`zoid.file`, `zoid.dir`, `zoid.uri`, `zoid.config`, `zoid.jobs`, `zoid.import`, `zoid.json`, `zoid.time`, `zoid.date`, `zoid.exit`) and do not rely on removed globals like `os`/`package`/`require`.
  - `zoid execute <file.lua> [args...]` exposes Lua global `arg` with `arg[0]` as script path and `arg[1..]` as forwarded positional arguments.
  - `scripts/gmail.lua` is a CLI-style utility; it supports `--query`, `--limit`, `--id`, and `--labels`, with default query `is:unread in:inbox`.
  - `scripts/counter.lua` creates `counter.txt` with `1` when missing; otherwise it reads the current integer value, increments by `1`, and writes it back.

### Public module surface:
  - Keep `src/root.zig` exports aligned with intended package API.
