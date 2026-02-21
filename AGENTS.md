# Zoid Agent Guide

## Purpose
Zoid is a Zig CLI project with embedded Lua support.

`README.md` describes the long-term product vision (simple, lightweight, secure OpenClaw alternative). Treat that vision as direction, not as a statement of already shipped features.

## Current Implementation (Source of Truth: `src/`)
Today the project provides:
- A CLI binary (`zoid`) with command parsing in `src/cli.zig` and app entrypoint in `src/main.zig`.
- Lua script execution via `zoid execute <file.lua>` in `src/lua_runner.zig`.
- JSON config key/value storage via `zoid config set|get|unset|list` in `src/config_store.zig`.
- OpenAI chat + one-shot run flows in `src/openai_client.zig` and `src/chat_session.zig`, including local tools (`filesystem_read`, `filesystem_write`, `shell_command`) with workspace-root policy handling via `src/tool_runtime.zig`.
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
  - Default command is `chat` when running `zoid` with no arguments.
- Chat interface changes:
  - `src/chat_session.zig` now uses fullscreen `libvaxis` UI in the alternate screen when running on a TTY, with `vaxis.widgets.TextInput` handling readline-style editing (`Ctrl+A`, `Ctrl+E`, arrows, backspace/delete).
  - `chat` is TTY-only; non-interactive one-shot usage should go through `zoid run <prompt...>` and write only the agent output to stdout.
  - Keep the input box anchored at the bottom of the screen.
  - Input rendering is manual soft word-wrap, and the input box grows vertically upward as lines increase.
  - `build.zig` must import the `vaxis` module into the `zoid` module for `@import("vaxis")` usage inside `src/`.
  - Model picker fallback models come from `src/model_catalog.zig` (`fallback_models`).
- OpenAI model policy changes:
  - Keep `src/model_catalog.zig` as the single source of truth for `default_model`, `fallback_models`, and `isChatModelId`.
  - `src/openai_client.zig` should use `model_catalog.isChatModelId` when filtering `/v1/models` results.
- Tool runtime changes:
  - `src/tool_runtime.zig` enforces `workspace-write` policy rooted at current working directory and exposes `filesystem_read`, `filesystem_write`, and `shell_command`.
  - `shell_command` runs via `/bin/sh -lc` with `cwd` set to workspace root and bounded output size.
  - Keep path checks strict: resolve to canonical paths and reject access outside workspace root.
- Config changes:
  - Preserve valid JSON object format (string keys and string values).
  - Keep deterministic key listing behavior (`list` is currently sorted).
- Lua runner changes:
  - Keep clear load/runtime error reporting.
  - Preserve current error contract (`LuaStateInitFailed`, `LuaLoadFailed`, `LuaRuntimeFailed`).
- Public module surface:
  - Keep `src/root.zig` exports aligned with intended package API.

## Scope Discipline
For near-term tasks, prioritize incremental CLI and reliability improvements that move toward the README vision without claiming unimplemented security/daemon features as complete.
