# Lua API

This document describes how Lua behavior in Zoid differs from stock Lua.

## Execution Modes

Zoid runs Lua in two ways:

1. `zoid execute <file.lua>` (CLI script mode)
2. `lua_execute` (agent tool mode used through tool calls)

Both modes use sandbox restrictions and Lua API surface.

### Extra API Added by Zoid

Lua run through Zoid has a `zoid` global with:

- `zoid.file(path)` file handles
- `zoid.uri(uri)` HTTP request handles
- `zoid.config()` config handles
- `zoid.json.decode(json_text)` JSON decoder

File example:

```lua
local f = zoid.file("notes.txt")
f:write("hello")
local content = f:read()
local ok = f:delete()
```

URI example:

```lua
local endpoint = zoid.uri("https://httpbin.org/anything")
local res = endpoint:post(
  '{"hello":"world"}',
  { headers = { ["Content-Type"] = "application/json" } }
)
print(res.status, res.ok)
print(res.body)
```

Config example:

```lua
local cfg = zoid.config()
cfg:set("OPENAI_API_KEY", "secret")
print(cfg:get("OPENAI_API_KEY"))
for _, key in ipairs(cfg:list()) do
  print(key)
end
cfg:unset("OPENAI_API_KEY")
```

JSON example:

```lua
local payload = zoid.json.decode('{"ok":true,"count":2,"items":[1,null]}')
print(payload.ok, payload.count, payload.items[2] == zoid.json.null)
```

Supported methods and return values:

- `zoid.file(path):read([max_bytes]) -> string`
- `zoid.file(path):write(content) -> integer` (bytes written)
- `zoid.file(path):delete() -> boolean` (`true` on success)
- `zoid.uri(uri):get([options]) -> { status: integer, body: string, ok: boolean }`
- `zoid.uri(uri):post([body], [options]) -> { status: integer, body: string, ok: boolean }`
- `zoid.uri(uri):put([body], [options]) -> { status: integer, body: string, ok: boolean }`
- `zoid.uri(uri):delete([options]) -> { status: integer, body: string, ok: boolean }`
- `zoid.config():list() -> { string, ... }` (sorted config keys)
- `zoid.config():get(key) -> string | nil`
- `zoid.config():set(key, value) -> boolean` (`true` on success)
- `zoid.config():unset(key) -> boolean` (`true` if key existed and was removed)
- `zoid.json.decode(json_text) -> any`
- `zoid.json.null` sentinel value used when decoded JSON contains `null`

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

### HTTP Request Rules

`zoid.uri(uri)` allows outbound HTTP/HTTPS requests:

- Only `http://` and `https://` URIs are accepted
- `:get([options])` and `:delete([options])` do not accept a request body
- `:post([body], [options])` and `:put([body], [options])` accept an optional string body
- `options.headers` accepts a table of string header names to string values
- Header names/values are validated (invalid bytes and dangerous headers are rejected)
- Response body size is capped by sandbox policy

### Read Limits

`zoid.file(path):read([max_bytes])` is limited by sandbox policy:

- Default read limit in tool sandbox: 128 KiB
- Tool runtime policy can raise this limit (currently up to 1 MiB for `lua_execute`)

If requested `max_bytes` is invalid or above policy limit, the script receives a runtime error.

### HTTP Response Limits

`zoid.uri(...)` response bodies are limited by sandbox policy:

- Default tool sandbox HTTP response limit: 1 MiB

If a response exceeds the configured limit, the script receives a runtime error.

### Error Model in Tool Mode

Sandbox and filesystem violations surface as Lua runtime errors (for example `PathNotAllowed`, `FileNotFound`) and are included in tool `stderr`.
