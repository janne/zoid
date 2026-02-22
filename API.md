# Lua API

This document describes how Lua behavior in Zoid differs from stock Lua.

## Execution Modes

Zoid runs Lua in two ways:

1. `zoid execute <file.lua>` (CLI script mode)
2. `lua_execute` (agent tool mode used through tool calls)

Both modes use sandbox restrictions and Lua API surface.

When invoking `zoid execute`, extra positional arguments are forwarded to Lua global `arg`:

- `arg[0]` = script path
- `arg[1..n]` = arguments after `<file.lua>`

### Extra API Added by Zoid

Lua run through Zoid has a `zoid` global with:

- `zoid.file(path)` file handles with metadata
- `zoid.dir(path)` directory handles with metadata
- `zoid.uri(uri)` HTTP request handles
- `zoid.config()` config handles
- `zoid.jobs` scheduler handles
- `zoid.json.decode(json_text)` JSON decoder

File example:

```lua
local f = zoid.file("notes.txt")
print(f.name, f.path, f.type, f.size, f.mode, f.owner, f.group, f.modified_at)
f:write("hello")
local content = f:read()
local ok = f:delete()
```

Directory example:

```lua
local dir = zoid.dir("logs")
print(dir.name, dir.path, dir.type, dir.modified_at)
dir:create()
for _, entry in ipairs(dir:list()) do
  print(entry.name, entry.type, entry.size, entry.modified_at)
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

Scheduler example:

```lua
local created = zoid.jobs.create({
  job_type = "lua",
  path = "scripts/clean_up_docs.lua",
  cron = "0 21 * * *"
})

print(created.id, created.next_run_at)
for _, job in ipairs(zoid.jobs.list()) do
  print(job.id, job.job_type, job.path, job.paused)
end

zoid.jobs.pause(created.id)
zoid.jobs.resume(created.id)
zoid.jobs.delete(created.id)
```

Supported methods and return values:

- `zoid.file(path) -> { name, path, type, size, mode, owner, group, modified_at, read, write, delete }`
- `zoid.file(path):read([max_bytes]) -> string`
- `zoid.file(path):write(content) -> integer` (bytes written)
- `zoid.file(path):delete() -> boolean` (`true` on success)
- `zoid.dir(path) -> { name, path, type, size, mode, owner, group, modified_at, list, create, remove }`
- `zoid.dir(path):list() -> { { name, path, type, size, mode, owner, group, modified_at }, ... }`
- `zoid.dir(path):create() -> boolean` (`true` on success)
- `zoid.dir(path):remove() -> boolean` (`true` on success)
- `zoid.uri(uri):get([options]) -> { status: integer, body: string, ok: boolean }`
- `zoid.uri(uri):post([body], [options]) -> { status: integer, body: string, ok: boolean }`
- `zoid.uri(uri):put([body], [options]) -> { status: integer, body: string, ok: boolean }`
- `zoid.uri(uri):delete([options]) -> { status: integer, body: string, ok: boolean }`
- `zoid.config():list() -> { string, ... }` (sorted config keys)
- `zoid.config():get(key) -> string | nil`
- `zoid.config():set(key, value) -> boolean` (`true` on success)
- `zoid.config():unset(key) -> boolean` (`true` if key existed and was removed)
- `zoid.jobs.create({ job_type, path, run_at?, cron? }) -> job`
- `zoid.jobs.list() -> { job, ... }`
- `zoid.jobs.delete(job_id) -> boolean`
- `zoid.jobs.pause(job_id) -> boolean`
- `zoid.jobs.resume(job_id) -> boolean`
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

### `arg` Global

Lua scripts receive an `arg` table:

- `arg[0]` is the script path
- `arg[1..n]` are positional script arguments

For tool-mode `lua_execute`, positional arguments can be supplied with optional JSON `args`:

```json
{
  "path": "scripts/example.lua",
  "args": ["one", "two"]
}
```

### Filesystem Sandbox Rules

All `zoid.file(path)` and `zoid.dir(path)` operations are enforced to stay inside workspace root:

- Relative paths are resolved from workspace root
- Absolute paths are allowed only if they resolve inside workspace root
- Canonical path checks block traversal outside root (for example `../outside.txt`)

Method-specific behavior:

- `:read()` requires an existing readable file
- `:write()` creates or truncates the target file
- `:delete()` deletes an existing file and fails if it does not exist
- `zoid.dir(path):list()` requires an existing directory and returns one-level metadata entries sorted by name
- `zoid.dir(path):create()` creates a directory and fails if it already exists
- `zoid.dir(path):remove()` removes an existing empty directory and fails if it is missing or non-empty

### HTTP Request Rules

`zoid.uri(uri)` allows outbound HTTP/HTTPS requests:

- Only `http://` and `https://` URIs are accepted
- `:get([options])` and `:delete([options])` do not accept a request body
- `:post([body], [options])` and `:put([body], [options])` accept an optional string body
- `options.headers` accepts a table of string header names to string values
- Header names/values are validated (invalid bytes and dangerous headers are rejected)
- Response body size is capped by sandbox policy

### Scheduler Rules

`zoid.jobs.create` enforces:

- `job_type` must be `"lua"` or `"markdown"`
- `path` must resolve inside workspace root
- `.lua` jobs require `.lua` extension, markdown jobs require `.md` extension
- exactly one schedule input is required: `run_at` (RFC3339) or `cron` (5-field cron)
- no Telegram destination is resolved at create time
- destination is resolved when the job runs: Telegram DM (if available), otherwise the reply is dropped

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
