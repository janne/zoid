# Zoid Agent Guide

## Purpose
Zoid is a Zig CLI project with embedded Lua support.

## Implementation
The project provides:
- A CLI binary (`zoid`) with command parsing in `src/cli.zig` and app entrypoint in `src/main.zig`.
- Workspace bootstrap via `zoid init [<path>] [--force]` in `src/workspace_init.zig`, copying embedded template files sourced from `workspace/`.
- Lua script execution via `zoid execute <file.lua>` in `src/lua_runner.zig`.
- JSON config key/value storage via `zoid config set|get|unset|list` in `src/config_store.zig`.
- Service mode via `zoid serve` in `src/telegram_bot.zig` (Telegram long-polling), maintaining conversation context per Telegram conversation key (`chat_id` + optional `message_thread_id`), persisting it under the app-data directory, forwarding messages to OpenAI, replying with `sendMessage` plus `sendPhoto`/`sendDocument` for generated file attachments, and running scheduled jobs from app-data scheduler storage (workspace-scoped namespace).
- OpenAI chat + one-shot run flows in `src/openai_client.zig` and `src/chat_session.zig`, including local tools (`filesystem_read`, `image_analyze`, `filesystem_list`, `filesystem_grep`, `filesystem_write`, `filesystem_mkdir`, `filesystem_rmdir`, `filesystem_delete`, `lua_execute`, `config`, `jobs`, `http_get`, `http_post`, `http_put`, `http_delete`, `datetime_now`) with workspace-root policy handling via `src/tool_runtime.zig`.
- Shared scheduler persistence/runtime in `src/scheduler_store.zig` + `src/scheduler_runtime.zig` with cron helper logic in `src/cron_adapter.zig`.
- Shared OpenAI model policy in `src/model_catalog.zig` (default model, picker fallback models, and chat-model ID filtering rules).
- Build + test pipeline in `build.zig`, including embedded Lua (static library from dependency `lua` in `build.zig.zon`).
- Workspace template file contents are embedded at compile-time by recursively scanning `workspace/` in `build.zig`, generating module `workspace_templates`, and consuming it from `src/workspace_init.zig`.

When documentation conflicts, prefer: `src/` and tests for current behavior.

## Engineering Rules
- Keep all code, commit messages, and user-facing copy in English.
- Do not preserve backward compatibility for command naming before first release; prefer replacing old names entirely (for example, `zoid schedule` -> `zoid jobs`).
- Keep this `AGENTS.md` file updated whenever adding code or changing behavior.
- Keep `workspace/API.md` updated when Lua runtime behavior or Lua sandbox APIs change.
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
  - `zoid init [<path>] [--force]` copies embedded template files from `workspace/` into `<path>` (default current directory), fails on any existing target file unless `--force` is provided.
  - `zoid init` template payload is generated recursively from all files under `workspace/` at build time; adding/removing files under `workspace/` requires rebuild but no code changes.
  - Jobs CLI commands live under `zoid jobs ...` with create/list/delete/pause/resume.
  - Browser setup CLI commands live under `zoid browser ...` with install/status/doctor/uninstall.
  - `zoid browser install` is distro-agnostic: it does not call OS package managers (`apt`, `pacman`, etc.); it requires an available JS runner (`npx`, `bunx`, `pnpm dlx`, or `yarn dlx`) and installs pinned Playwright Chromium artifacts in app-data.
  - Browser setup artifacts live under app-data (`getAppDataDir("zoid")/browser`) with Playwright browser binaries in `ms-playwright` and setup state metadata in `state.json`.
  - `zoid browser doctor` exits non-zero when browser support is not ready, reports missing runtime/state/artifact checks, and runs a minimal Chromium launch probe so host dependency/runtime launch failures are surfaced before normal `browser_automate` usage.
  - `zoid jobs create` takes a single path argument and requires a `.lua` extension.
  - `zoid jobs create` accepts exactly one schedule input: `--at <datetime-expression>` or `--cron "<min hour dom mon dow>"`.
  - `--at` is parsed via timelib and accepts natural-language date/time text.
  - Scheduler job ids are short random 5-character base36 strings; generation retries under scheduler lock to avoid collisions.
  - `zoid jobs list` renders a compact single-line table (`JOB ST NEXT SCHEDULE LAST PATH`); `JOB` is the job id.
  - Workspace paths accept both relative paths and leading-slash workspace-absolute paths (`/path/from/workspace/root`) for `zoid execute` and `zoid jobs create`; `zoid jobs list` prints paths in this workspace-absolute `/...` format.
  - `zoid execute <file.lua> [args...]` must forward extra positional args to Lua global `arg` (`arg[0]` script path, `arg[1..]` forwarded args).
  - `zoid execute` supports optional `--timeout <seconds>` before `<file.lua>` to override Lua runtime timeout for that invocation.
  - `zoid execute <file.lua>` must use the same sandbox restrictions and `.lua` path policy as `lua_execute` so local script runs match tool-mode behavior.
  - Default command is `chat` when running `zoid` with no arguments.
  - `zoid serve` is the long-running service entrypoint; currently it requires both `OPENAI_API_KEY` and `TELEGRAM_BOT_TOKEN` in config and runs a Telegram long-polling loop until interrupted.
  - `zoid chat` and `zoid serve` load `ZOID.md` from the workspace root on startup when present, and pass its content as additional agent instructions in OpenAI system context.
  - Telegram service mode keeps conversation history per conversation key (`chat_id` + optional `message_thread_id`), persists it to app-data (`telegram_context.json` next to `config.json`), and enforces a per-conversation history cap from config key `TELEGRAM_MAX_CONVERSATION_MESSAGES` (default `20`).
  - Telegram service mode treats forum topics as separate sessions by keying context with `message_thread_id`, and sends replies/typing actions back to the same topic thread when present.
  - Telegram service mode processes inbound updates with a worker pool so different conversation keys can run in parallel; processing remains serialized per conversation key (`chat_id` + optional `message_thread_id`) to preserve in-topic ordering/context. Worker count is config key `TELEGRAM_INBOUND_WORKER_COUNT` (default `4`, min `1`, max `32`).
  - Telegram service mode clears a conversation key's stored context before handling a new prompt when the last inbound user message for that key is older than config key `TELEGRAM_USER_INACTIVITY_RESET_SECONDS` (default `28800` / 8h).
  - Telegram service mode acquires an app-data lock file (`telegram_serve.lock`) so only one `zoid serve` instance runs per user profile; a second instance fails with `error.ServiceAlreadyRunning`.
  - `/new` or `/reset` clears stored Telegram context for the current conversation key (`chat_id` + optional `message_thread_id`).
  - While generating a reply in Telegram service mode, send the native `sendChatAction` typing indicator periodically so users see Telegram's built-in "typing..." state until `sendMessage` completes.
  - Telegram `sendMessage` requests set `parse_mode` to `MarkdownV2`.
  - Telegram reply delivery should sanitize outgoing text for `MarkdownV2` (escape reserved punctuation that commonly breaks entity parsing) before send, and fall back to plain text (`parse_mode` omitted) when Telegram still rejects a chunk, so replies are still delivered.
  - Telegram MarkdownV2 sanitization should preserve valid inline entities for bold (`*text*`), italic (`_text_`), underline (`__text__`), strikethrough (`~text~`), spoiler (`||text||`), inline/fenced code (`` `code` `` / ````` ```code``` `````), inline links (`[text](https://...)`), and blockquote lines that start with `>`.
  - Telegram MarkdownV2 sanitization should preserve valid inline label links (`[text](https://...)`) so Telegram renders them as links, while still escaping unsafe punctuation outside link syntax.
  - Telegram MarkdownV2 sanitization should preserve valid strikethrough (`~text~`) and underline (`__text__`) spans instead of escaping those delimiters as plain text; common markdown double-tilde input (`~~text~~`) is normalized to Telegram strikethrough.
  - Telegram Markdown-style headings at start-of-line (`#`, `##`, `###` with following space) are rewritten to bold lines without `#` so they remain readable under Telegram `MarkdownV2`.
  - Telegram delivery should upload generated attachments from browser outputs before text (both direct `browser_automate` tool calls and `lua_execute` runs that call `zoid.browser.automate(...)`): screenshots via `sendPhoto` (with fallback to `sendDocument` when photo upload fails), and downloaded files via `sendDocument`.
  - For Telegram chat requests, system instructions should tell the agent that browser screenshot/download artifacts are host-delivered automatically, so the agent should not read files for base64 media transport.
  - Service mode processes due scheduled jobs before polling updates; scheduler output is sent to the assistant and assistant replies are delivered to Telegram DM when a DM chat id is available.
  - Service mode persists the latest private-chat `chat_id` to app-data (`telegram_dm_chat_id.txt`), which is used as runtime DM fallback when scheduled jobs execute.
  - Scheduler metadata files (`scheduler_jobs.json` + lock/tmp) must live under `getAppDataDir("zoid")`, not inside the workspace tree; only user-authored Lua job payload files and documents should live in workspace.

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
  - `src/openai_client.zig` uses config-driven runtime limits for prompt/tool execution budgets (`OPENAI_MAX_INPUT_TOKENS`, `OPENAI_MAX_MESSAGE_CHARS`, `OPENAI_MAX_TOOL_ROUNDS`, `OPENAI_MAX_TOOL_RESULT_CHARS`) and trims oldest non-system messages when estimated request tokens exceed budget.
  - If the tool-round budget is exhausted it performs one final chat-completions call with `tool_choice=\"none\"` to let the model synthesize a final answer before returning `ToolCallLimitExceeded`.
  - `src/main.zig` should use `model_catalog.default_model` when `OPENAI_MODEL` is unset.
  - `src/chat_session.zig` should use `model_catalog.fallback_models` for picker fallback choices.
  - Keep model catalog invariants covered by tests (`default_model` included in `fallback_models`, fallback IDs unique, fallback IDs chat-capable).

### Tool runtime changes:
  - `src/tool_runtime.zig` enforces `workspace-write` policy rooted at current working directory and exposes `filesystem_read`, `image_analyze`, `filesystem_list`, `filesystem_grep`, `filesystem_write`, `filesystem_mkdir`, `filesystem_rmdir`, `filesystem_delete`, `lua_execute`, `config`, `jobs`, `http_get`, `http_post`, `http_put`, `http_delete`, `datetime_now`, and `browser_automate`.
  - Shared filesystem sandbox/path enforcement and metadata/listing logic lives in `src/workspace_fs.zig`; both `lua_execute` (`zoid.file(...)` / `zoid.dir(...)`) and direct filesystem tools must use this module.
  - In workspace path APIs, absolute inputs are treated as workspace-relative paths: a leading `/` means workspace root (not filesystem root), and host filesystem absolute semantics are not used.
  - Shared outbound HTTP request behavior lives in `src/http_client.zig`; both `lua_execute` (`zoid.uri(...)`) and direct HTTP tools must use this module to avoid divergence.
  - Shared config mutation/read behavior lives in `src/config_runtime.zig`; both `lua_execute` (`zoid.config():list/get/set/unset`) and direct `config` tool calls must use this module to avoid divergence.
  - `filesystem_mkdir` creates one directory whose canonical path resolves inside workspace root and fails if it already exists.
  - `filesystem_rmdir` removes one empty directory whose canonical path resolves inside workspace root.
  - `filesystem_delete` only removes files whose canonical path resolves inside workspace root; traversal outside root must return `error.PathNotAllowed`.
  - `lua_execute` runs scripts via the embedded Lua runtime (`src/lua_runner.zig`) in-process, not via shell process execution, and only accepts `.lua` files under workspace root.
  - `lua_execute` accepts optional `args` (array of strings) and forwards them to Lua global `arg[1..]` (with script path in `arg[0]`).
  - `lua_execute` enforces runtime timeout (default 10s) and accepts optional `timeout` override in seconds (`1..600`).
  - `lua_execute` must intercept Lua script output so it is never written to process stdout/stderr in TUI mode; instead surface captured streams in tool JSON (`stdout` and `stderr`, with truncation flags), plus browser attachment metadata (`attachments`) from `zoid.browser.automate` screenshot/download actions so host integrations can auto-deliver generated files.
  - `http_get`/`http_post`/`http_put`/`http_delete` are direct HTTP(S) tools (no Lua script required); accepted input is a `uri` string plus optional `headers` map (all methods) and optional `body` for `post`/`put`. Responses include `status` + lowercase-keyed `headers` + `body`, with `ok` reflecting 2xx status.
  - `image_analyze` reads one workspace image file (`.png/.jpg/.jpeg/.webp/.gif`) and sends it to OpenAI vision chat-completions using `OPENAI_API_KEY` plus optional `model` override (otherwise `OPENAI_MODEL` config, then `model_catalog.default_model` fallback); returns textual analysis with file metadata.
  - `datetime_now` takes an empty object and returns current wall-clock time as `epoch` (Unix seconds), plus `utc` and `local` ISO-8601 strings.
  - In `lua_execute` tool-mode, remove `os`/`package`/`debug`/`require`/`dofile`/`loadfile`; expose `zoid.file(path)` metadata handles with `:read([max_bytes])/:write(content)/:delete()`, `zoid.dir(path)` metadata handles with `:list()/:create()/:remove()/:grep(pattern, [options])`, `zoid.uri(uri):get/post/put/delete`, `zoid.config():list/get/set/unset`, `zoid.jobs`, `zoid.browser.automate(options)`, `zoid.import(path)`, `zoid.json.decode`, `zoid.time([table])`, `zoid.date([format[, epoch]])`, and `zoid.exit([code])`.
  - `zoid.import(path)` only loads `.lua` files inside workspace root, resolves relative paths from the importing module's directory, caches loaded modules per script execution, and rejects cyclic imports.
  - `zoid.exit([code])` must stop only the current Lua script execution and never terminate the hosting `zoid` process; tool JSON should surface `exit_code` and report non-zero exits as `LuaExit`.
  - `zoid.dir(path):create()` must fail when the target directory already exists, and `zoid.dir(path):remove()` must fail when the target directory is non-empty.
  - `filesystem_grep` searches file content under a workspace path with optional recursion and match limits; tool result includes match path/line/column/text, files scanned, and truncation status.
  - Filesystem/tool/Lua/jobs path outputs should use workspace-absolute `/...` paths for user-facing JSON/tables/CLI output instead of host filesystem absolute paths.
  - `jobs` tool JSON returns timestamp fields (`at`, `next_run_at`, `created_at`, `updated_at`, `last_run_at`) formatted as `YYYY-MM-DD HH:MM` local time, with matching numeric `*_epoch` companion fields.
  - `zoid.dir(path):grep(pattern, [options])` uses the same workspace sandbox/path rules as filesystem tools and supports `options.recursive` (default `true`) and `options.max_matches` (default `200`, max `5000`).
  - `zoid.uri(uri)` allows only HTTP/HTTPS requests and returns a Lua table with `status`, lowercase-keyed `headers`, `body`, and `ok`; response body capture is capped by tool policy (currently 1 MiB in `lua_execute`).
  - Outbound HTTP tools (`zoid.uri(...)` and direct `http_*`) must reject internal destinations by default (`localhost`, loopback, private/link-local ranges including IPv6 private/link-local blocks), and should not auto-follow redirects.
  - `browser_automate` runs a headless Chromium automation session (Playwright) per tool call and supports multi-step page actions (navigation, click/type/fill/submit/wait/select/check, content extraction, and JS evaluation in page context).
  - Shared browser-automation validation/runtime logic lives in `src/browser_tool.zig`; both direct `browser_automate` tool calls and Lua `zoid.browser.automate(...)` must use this module to avoid divergence.
  - `browser_automate` currently executes Playwright via `npx` at runtime while reusing browser binaries from app-data (`PLAYWRIGHT_BROWSERS_PATH`); missing `npx` should return a browser-runtime error.
  - In `browser_automate`, `npx -p playwright ... node -e ...` does not reliably make `require("playwright")` resolve from workspace context; JS driver bootstrap should include PATH `.bin`-based fallback module resolution for Playwright package discovery.
  - `browser_automate` requires browser setup from `zoid browser install`; if setup artifacts are missing it should fail with a clear browser-support error.
  - When the Playwright driver process fails before returning tool JSON, `browser_automate` should still return a structured `ok:false` tool payload with `exit_code` plus `stdout_excerpt`/`stderr_excerpt` for debugging instead of only surfacing a generic runtime error name.
  - `browser_automate` must enforce the same outbound destination policy as HTTP tools by default (block localhost/private/link-local destinations unless policy override explicitly allows private destinations).
  - `browser_automate` supports persistent session state via `session_id`; session files are stored under app-data browser storage and allow continuation across tool calls.
  - `browser_automate` supports `screenshot`, `download`, and `upload` actions; local file paths must always resolve inside workspace root (same path policy as filesystem tools).
  - `browser_automate` `screenshot` actions require `path` and save images to workspace files.
  - Browser automation results use `extracts` as an array of objects (not a map): `extract_page_text` yields `{ kind: "page_text", value }`, `extract_links` yields `{ kind: "links", items = [{ href, text }, ...] }`, and there is no `results` field.
  - `zoid.uri(...):get/delete/post/put` accept optional request options with `headers` table (string->string); header names/values are validated and dangerous overrides such as `Host`/`Content-Length` are rejected.
  - `zoid.json.decode` maps JSON values to Lua tables/scalars and maps JSON `null` to the sentinel `zoid.json.null`.
  - `zoid.time([table])` and `zoid.date([format[, epoch]])` provide safe time/date helpers while global `os` remains disabled; behavior is aligned with Lua `os.time`/`os.date`, including date-table normalization in `zoid.time`.
  - `jobs` tool supports `create/list/delete/pause/resume`; create supports `.lua` paths with exactly one schedule input (`at` natural-language date-time or 5-field `cron`), and does not resolve Telegram destination at create time.
  - Timelib integration is compiled from the timelib sources vendored in `php-src` (`ext/date/lib`) because that tree includes generated parser files (`parse_date.c`, `parse_iso_intervals.c`) without requiring local `re2c`.
  - In `telegram_bot` scheduled processing, skip agent dispatch when Lua stdout+stderr are both empty (after trim).
  - Tool-mode routes stderr through `zoid.eprint(...)` and stdout through global `print(...)`, both captured for agent inspection without enabling general file I/O APIs.
  - `shell_command` and `exec` are intentionally disabled for OpenAI tool calls; unknown/disabled tool calls must return `error.ToolDisabled`.
  - Keep path checks strict: resolve to canonical paths and reject access outside workspace root.

### Config changes:
  - Preserve valid JSON object format (string keys and string values).
  - Keep deterministic key listing behavior (`list` is currently sorted).
  - Keep OpenAI and Telegram config key names centralized in `src/config_keys.zig` and reuse those constants in command/chat code paths.
  - Runtime limit keys are loaded via `src/runtime_limits.zig`; invalid/missing values must fall back to defaults.
  - `ZOID.md` load size limit is config-driven via `OPENAI_MAX_WORKSPACE_INSTRUCTION_CHARS` (default `262144`).

### Lua runner changes:
  - Keep clear load/runtime error reporting.
  - Preserve current error contract (`LuaStateInitFailed`, `LuaLoadFailed`, `LuaRuntimeFailed`).
  - Keep Lua execution entrypoints tool-policy-only.
  - Tool-mode `zoid.jobs` API mirrors scheduler operations: `create/list/delete/pause/resume`.
  - `zoid.exit([code])` accepts only integer exit codes in range `0..125`; out-of-range values must fail with a Lua runtime error.

### Lua script examples (`workspace/scripts/*.lua`) changes:
  - Keep scripts compatible with the `zoid` API surface (`zoid.file`, `zoid.dir`, `zoid.uri`, `zoid.config`, `zoid.jobs`, `zoid.browser.automate`, `zoid.import`, `zoid.json`, `zoid.time`, `zoid.date`, `zoid.exit`, `zoid.eprint`) and do not rely on removed globals like `os`/`package`/`require`.
  - `zoid execute <file.lua> [args...]` exposes Lua global `arg` with `arg[0]` as script path and `arg[1..]` as forwarded positional arguments.
  - `workspace/scripts/gmail.lua` is a CLI-style utility; it supports `--query`, `--limit`, `--id`, and `--labels`, with default query `is:unread in:inbox`.
  - `workspace/scripts/counter.lua` creates `counter.txt` with `1` when missing; otherwise it reads the current integer value, increments by `1`, and writes it back.

### Public module surface:
  - Keep `src/root.zig` exports aligned with intended package API.
  - Do not export `lua_runner` from `src/root.zig`; keep Lua runner internals private to the binary/tooling modules.
