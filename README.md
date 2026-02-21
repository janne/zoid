Zoid
====

A simple, lightweight, secure alternative to OpenClaw. Built on Zig and Lua.

## Simple
- One small binary, including Lua support, and integration with AI agents and Telegram.
- No external dependencies, all built into one binary.
- One friendly CLI command for maintaining the service - zoid.

## Lightweight
- Built to be able to run on a small cloud instance with limited RAM, such as the forever free GCP E2-micro, or a Raspberry Pi.

## Powerful
- A Lua interpreter is built in, and the agent can write and execute scripts.
- Lua has access to the world through `workspace.[read|write]` and `net.[get|post|put|delete|patch]`.

## Secure
- All keys are stored in an vault, not under version control (`~/Library/Application Support/zoid/config.json` on Mac and `~/.local/share/zoid/config.json` on Linux).
- The agents can only read and write files in the workspace directory (the same directory as it's started from).
- No code execution is allowed by agents, apart from the Lua scripts.
- The Lua interpreter is limited, specifically these commands and packages are removed: `os`, `package`, `debug`, `dofile`, `loadfile`, `require`.