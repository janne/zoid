Zoid
====

A simple, lightweight, secure alternative to OpenClaw. Built on Zig and Lua.

## Simple
- One small binary, including Lua support, and integration with AI agents and Telegram.
- No extra dependencies needed apart from Lua-scripts, that can be built by the bot itself.
- One friendly CLI command for maintaining the service - zoid.

## Lightweight
- Built to be able to run on a small cloud instance, such as the forever free GCP E2-micro, or a Raspberry Pi.

## Secure
- All keys are stored in an vault, not under version control.
- Zoid can only read and write files in its own directory.
- Zoid cannot execute any code, except through a built in Lua interpreter.