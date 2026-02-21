# Lua API

This document describes how Lua behavior in Zoid differs from stock Lua.

## Execution Modes

Zoid runs Lua in two ways:

1. `zoid execute <file.lua>` (CLI script mode)
2. `lua_execute` (agent tool mode used through tool calls)

Both modes use sandbox restrictions and Lua API surface.

### Extra API Added by Zoid

Lua run through Zoid has a `zoid` global with a file handle constructor:

```lua
local f = zoid.file("notes.txt")
f:write("hello")
local content = f:read()
local ok = f:delete()
```

Supported methods:

- `zoid.file(path):read([max_bytes]) -> string`
- `zoid.file(path):write(content) -> integer` (bytes written)
- `zoid.file(path):delete() -> boolean` (`true` on success)

### APIs Removed or Disabled

The following standard Lua escape hatches are removed:

- `os`
- `package`
- `debug`
- `require`
- `dofile`
- `loadfile`

### `io` and `print` Behavior

The output APIs are replaced to capture script output safely:

- `print(...)` is captured to `stdout` (tab-separated arguments, newline appended)
- `io.write(...)` is captured to `stdout`
- `io.stderr:write(...)` is captured to `stderr`
- Other standard `io` functions are not available

Captured streams are returned in tool JSON fields (`stdout`, `stderr`) instead of writing directly to terminal stdout/stderr.

### Filesystem Sandbox Rules

All `zoid.file(path)` operations are enforced to stay inside workspace root:

- Relative paths are resolved from workspace root
- Absolute paths are allowed only if they resolve inside workspace root
- Canonical path checks block traversal outside root (for example `../outside.txt`)

Method-specific behavior:

- `:read()` requires an existing readable file
- `:write()` creates or truncates the target file
- `:delete()` deletes an existing file and fails if it does not exist

### Read Limits

`zoid.file(path):read([max_bytes])` is limited by sandbox policy:

- Default read limit in tool sandbox: 128 KiB
- Tool runtime policy can raise this limit (currently up to 1 MiB for `lua_execute`)

If requested `max_bytes` is invalid or above policy limit, the script receives a runtime error.

### Error Model in Tool Mode

Sandbox and filesystem violations surface as Lua runtime errors (for example `PathNotAllowed`, `FileNotFound`) and are included in tool `stderr`.
