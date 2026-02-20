Zoid
====

# Long term plan below

A simple, lightweight, secure alternative to OpenClaw. Built on Zig and Lua.

## Simple
- One small binary, including the Lua support. No extra dependencies needed apart from Lua-scripts, that can be built by the bot itself.
- One friendly CLI command for maintaining the service - zoid.

## Lightweight
- Built to be able to run on a small cloud instance, such as the forever free GCP E2-micro, or a Raspberry Pi.

## Secure
- All chat happens with E2E encryption.
- All keys are stored in an encrypted vault. The vault key is never stored, but added when starting the gateway.
- The Lua code is run in a sandboxed environment.