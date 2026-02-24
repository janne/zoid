# Lua API

This document describes how Lua behavior in Zoid differs from stock Lua.

## Execution Modes

Zoid runs Lua in two ways:

1. `zoid execute [--timeout <seconds>] <file.lua> [args...]` (CLI script mode)
2. `lua_execute` (agent tool mode used through tool calls)

Both modes use sandbox restrictions and Lua API surface.
`zoid execute` uses the same `lua_execute` policy path, then writes captured `stdout`/`stderr` back to the process streams.

### Extra API Added by Zoid

Lua run through Zoid has a `zoid` global with:

- `zoid.file(path)` file handles with metadata
- `zoid.dir(path)` directory handles with metadata
- `zoid.uri(uri)` HTTP request handles
- `zoid.config()` config handles
- `zoid.jobs` scheduler handles
- `zoid.import(path)` Lua module imports
- `zoid.json.decode(json_text)` JSON decoder
- `zoid.time([table])` epoch timestamp helper
- `zoid.date([format[, epoch]])` date/time formatter helper
- `zoid.exit([code])` script exit helper
- `zoid.eprint(...)` stderr output helper

File example:

```lua
local f = zoid.file("/notes.txt")
print(f.name, f.path, f.type, f.size, f.mode, f.owner, f.group, f.modified_at)
f:write("hello")
local content = f:read()
local ok = f:delete()
```

Directory example:

```lua
local dir = zoid.dir("/logs")
print(dir.name, dir.path, dir.type, dir.modified_at)
dir:create()
for _, entry in ipairs(dir:list()) do
  print(entry.name, entry.type, entry.size, entry.modified_at)
end
for _, match in ipairs(dir:grep("error", { recursive = true })) do
  print(match.path, match.line, match.column, match.text)
end
dir:remove()
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

Time/date example:

```lua
local now = zoid.time()
print("now", now)
print(zoid.date("!%Y-%m-%dT%H:%M:%SZ", 0))
local parts = zoid.date("!*t", 0)
print(parts.year, parts.month, parts.day, parts.hour, parts.min, parts.sec)
```

Scheduler example:

```lua
local created = zoid.jobs.create({
  path = "scripts/clean_up_docs.lua",
  cron = "0 21 * * *"
})

print(created.id, created.next_run_at)
for _, job in ipairs(zoid.jobs.list()) do
  print(job.id, job.path, job.paused)
end

zoid.jobs.pause(created.id)
zoid.jobs.resume(created.id)
zoid.jobs.delete(created.id)
```

Import example:

```lua
local util = zoid.import("lib/util.lua")
local features = zoid.import("lib/features.lua")
print(util.version, features.enabled)
```

Alternative module patterns:

```lua
-- Global side-effect style (works, but less explicit)
myLib = myLib or {}

function myLib.hello(name)
  return "Hello " .. (name or "world")
end
```

```lua
-- Return-value style (recommended)
local myLib = {}

function myLib.hello(name)
  return "Hello " .. (name or "world")
end

return myLib
```

Supported methods and return values:

- `zoid.file(path) -> { name, path, type, size, mode, owner, group, modified_at, read, write, delete }`
- `zoid.file(path):read([max_bytes]) -> string`
- `zoid.file(path):write(content) -> integer` (bytes written)
- `zoid.file(path):delete() -> boolean` (`true` on success)
- `zoid.dir(path) -> { name, path, type, size, mode, owner, group, modified_at, list, create, remove, grep }`
- `zoid.dir(path):list() -> { { name, path, type, size, mode, owner, group, modified_at }, ... }`
- `zoid.dir(path):create() -> boolean` (`true` on success)
- `zoid.dir(path):remove() -> boolean` (`true` on success)
- `zoid.dir(path):grep(pattern, [options]) -> { { path, line, column, text }, ... }`
  - `options.recursive` (boolean, default `true`)
  - `options.max_matches` (integer, default `200`, max `5000`)
- `zoid.uri(uri):get([options]) -> { status: integer, body: string, ok: boolean }`
- `zoid.uri(uri):post([body], [options]) -> { status: integer, body: string, ok: boolean }`
- `zoid.uri(uri):put([body], [options]) -> { status: integer, body: string, ok: boolean }`
- `zoid.uri(uri):delete([options]) -> { status: integer, body: string, ok: boolean }`
- `zoid.config():list() -> { string, ... }` (sorted config keys)
- `zoid.config():get(key) -> string | nil`
- `zoid.config():set(key, value) -> boolean` (`true` on success)
- `zoid.config():unset(key) -> boolean` (`true` if key existed and was removed)
- `zoid.jobs.create({ path, run_at?, cron? }) -> job`
- `zoid.jobs.list() -> { job, ... }`
- `zoid.jobs.delete(job_id) -> boolean`
- `zoid.jobs.pause(job_id) -> boolean`
- `zoid.jobs.resume(job_id) -> boolean`
- `zoid.import(path) -> any` (module return value; repeated imports return the cached module value; if module returns `nil`, import returns `true`)
- `zoid.json.decode(json_text) -> any`
- `zoid.json.null` sentinel value used when decoded JSON contains `null`
- `zoid.time([table]) -> integer` (Lua-compatible with `os.time`: `year`/`month`/`day` required, optional `hour`/`min`/`sec`/`isdst`; numeric fields are normalized by `mktime`, and table fields are updated with normalized values)
- `zoid.date([format[, epoch]]) -> string | table` (`*t` format returns table fields `year`, `month`, `day`, `hour`, `min`, `sec`, `wday`, `yday`, optional `isdst`; `!` prefix forces UTC)
- `zoid.exit([code]) -> never` (stops Lua script execution; defaults to exit code `0`)
- `zoid.eprint(...)` writes to captured `stderr` (arguments are stringified and concatenated; no automatic tab/newline)

### `error(...)` vs `zoid.exit([code])`

- `error(message[, level])` is the standard Lua error function and remains available.
- Use `error(...)` for unexpected failures. In tool-mode this is reported as `error: "LuaRuntimeFailed"`.
- Use `zoid.exit([code])` for intentional early termination with an explicit exit code.
- `zoid.exit(0)` is treated as a successful tool result (`ok: true`), while non-zero codes are reported as `error: "LuaExit"` with `exit_code` set.
- Neither function crashes the host process. They only stop the current Lua script execution.

### APIs Removed or Disabled

The following standard Lua escape hatches are removed:

- `os`
- `package`
- `debug`
- `require`
- `dofile`
- `loadfile`
- `io`

Use `zoid.import(path)` for sandboxed module loading instead.

### `print` and `zoid.eprint` Behavior

The output APIs are replaced to capture script output safely:

- `print(...)` is captured to `stdout` (tab-separated arguments, newline appended)
- `zoid.eprint(...)` is captured to `stderr` (arguments are stringified and concatenated; no automatic tab/newline)

Captured streams are returned in tool JSON fields (`stdout`, `stderr`) instead of writing directly to terminal stdout/stderr. Tool-mode results also include `exit_code` (`null` unless the script called `zoid.exit`).

### Execution Timeout

Sandboxed Lua execution has a runtime timeout:

- Default timeout: 10 seconds
- Tool override: optional `timeout` in `lua_execute` input (seconds)
- CLI override: `zoid execute --timeout <seconds> ...`
- Accepted range for overrides: `1..600` seconds

Tool-mode results include `timeout` (seconds) and, when timeout is reached, report `error: "LuaTimeout"` with timeout details in `stderr`.

### `arg` Global

Lua scripts receive an `arg` table:

- `arg[0]` is the script path
- `arg[1..n]` are positional script arguments

For tool-mode `lua_execute`, positional arguments can be supplied with optional JSON `args`:

```json
{
  "path": "/scripts/example.lua",
  "args": ["one", "two"],
  "timeout": 30
}
```

`timeout` is optional in tool mode and interpreted as seconds.

### Filesystem Sandbox Rules

All `zoid.file(path)` and `zoid.dir(path)` operations are enforced to stay inside workspace root:

- Relative paths are resolved from workspace root
- Paths beginning with `/` are resolved from workspace root (for example `/ZOID.md`)
- Canonical absolute filesystem paths are accepted when they already resolve inside workspace root
- Canonical path checks block traversal outside root (for example `../outside.txt`)
- Returned metadata paths (`path`) use workspace-absolute format (`/...`)

Method-specific behavior:

- `:read()` requires an existing readable file
- `:write()` creates or truncates the target file
- `:delete()` deletes an existing file and fails if it does not exist
- `zoid.dir(path):list()` requires an existing directory and returns one-level metadata entries sorted by name
- `zoid.dir(path):create()` creates a directory and fails if it already exists
- `zoid.dir(path):remove()` removes an existing empty directory and fails if it is missing or non-empty
- `zoid.dir(path):grep(pattern, [options])` searches file content under the directory and can recurse into subdirectories

### Import Rules

`zoid.import(path)` enforces sandboxed module loading rules:

- path must resolve to a `.lua` file under workspace root
- relative paths are resolved from the importing module's directory
- repeated imports use a module cache and do not re-execute module top-level code
- cyclic imports fail with a runtime error

### HTTP Request Rules

`zoid.uri(uri)` allows outbound HTTP/HTTPS requests:

- Only `http://` and `https://` URIs are accepted
- `:get([options])` and `:delete([options])` do not accept a request body
- `:post([body], [options])` and `:put([body], [options])` accept an optional string body
- `options.headers` accepts a table of string header names to string values
- Header names/values are validated (invalid bytes and dangerous headers are rejected)
- Header limits: at most 64 headers and 16 KiB total header bytes
- Blocked header names: `Host`, `Content-Length`, `Transfer-Encoding` (case-insensitive)
- Response body size is capped by sandbox policy

### Scheduler Rules

`zoid.jobs.create` enforces:

- `path` must resolve to an existing file inside workspace root
- `path` must use the `.lua` extension
- exactly one schedule input is required: `run_at` (RFC3339) or `cron` (5-field cron)
- no Telegram destination is resolved at create time
- destination is resolved when the job runs: Telegram DM (if available), otherwise the reply is dropped
- returned `job.path` values use workspace-absolute format (`/...`)

### Read Limits

`zoid.file(path):read([max_bytes])` is limited by sandbox policy:

- Base Lua tool sandbox default read limit: 128 KiB
- `lua_execute` policy currently sets read limit to 1 MiB

If requested `max_bytes` is invalid or above policy limit, the script receives a runtime error.

### HTTP Response Limits

`zoid.uri(...)` response bodies are limited by sandbox policy:

- Default tool sandbox HTTP response limit: 1 MiB

If a response exceeds the configured limit, the script receives a runtime error.

### Error Model in Tool Mode

Sandbox and filesystem violations surface as Lua runtime errors (for example `PathNotAllowed`, `FileNotFound`) and are included in tool `stderr`.
