# Lua API

This document describes how Lua behavior in Zoid differs from stock Lua.

## Execution Modes

Zoid runs Lua in two ways:

1. `zoid execute [--timeout <seconds>] <file.lua> [args...]` (CLI script mode)
2. `lua_execute` (agent tool mode used through tool calls)

Both modes use sandbox restrictions and Lua API surface.
`zoid execute` uses the same `lua_execute` policy path, then writes captured `stdout`/`stderr` back to the process streams.

Important boundaries:

- `zoid execute ...` is a local terminal CLI command.
- Agent tool mode does not invoke shell commands and cannot run `zoid execute ...` directly.
- In chat/Telegram tool mode, script execution happens through `lua_execute`.

### Extra API Added by Zoid

Lua run through Zoid has a `zoid` global with:

- `zoid.file(path)` file handles with metadata
- `zoid.dir(path)` directory handles with metadata
- `zoid.uri(uri)` HTTP request handles
- `zoid.crypto` cryptographic helpers
- `zoid.config()` config handles
- `zoid.jobs` scheduler handles
- `zoid.browser` browser automation handles
- `zoid.import(path)` Lua module imports
- `zoid.json.decode(json_text)` JSON decoder
- `zoid.json.encode(value)` JSON encoder
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
print(res.headers["content-type"])
print(res.body)
```

Crypto + JWT example:

```lua
local private_key = [[-----BEGIN PRIVATE KEY-----
...
-----END PRIVATE KEY-----]]

local now = zoid.time()
local header = zoid.json.encode({ alg = "RS256", typ = "JWT" })
local claims = zoid.json.encode({
  iss = "svc@example.iam.gserviceaccount.com",
  scope = "https://www.googleapis.com/auth/cloud-platform",
  aud = "https://oauth2.googleapis.com/token",
  iat = now,
  exp = now + 3600,
})

local header_seg = zoid.crypto.base64url_encode(header)
local claims_seg = zoid.crypto.base64url_encode(claims)
local signing_input = header_seg .. "." .. claims_seg
local signature = zoid.crypto.sign_rs256(private_key, signing_input, "base64url")
local assertion = signing_input .. "." .. signature

local token_response = zoid.uri("https://oauth2.googleapis.com/token"):post(
  "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=" .. assertion,
  { headers = { ["Content-Type"] = "application/x-www-form-urlencoded" } }
)
local token = zoid.json.decode(token_response.body)

local projects = zoid.uri("https://cloudresourcemanager.googleapis.com/v1/projects"):get({
  headers = { Authorization = "Bearer " .. token.access_token },
})
print(projects.status, projects.ok)
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
local text = zoid.json.encode(payload)
print(text)
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
  path = "scripts/cleanup.lua",
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

Browser automation example:

```lua
local result = zoid.browser.automate({
  start_url = "https://example.com",
  actions = {
    { action = "wait_for_selector", selector = "h1" },
    { action = "extract_text", selector = "h1" }
  }
})

print(result.ok, result.tool)
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
- `zoid.uri(uri):get([options]) -> { status: integer, headers: table<string,string>, body: string, ok: boolean }`
- `zoid.uri(uri):post([body], [options]) -> { status: integer, headers: table<string,string>, body: string, ok: boolean }`
- `zoid.uri(uri):put([body], [options]) -> { status: integer, headers: table<string,string>, body: string, ok: boolean }`
- `zoid.uri(uri):delete([options]) -> { status: integer, headers: table<string,string>, body: string, ok: boolean }`
- `zoid.crypto.base64url_encode(data) -> string` (URL-safe base64 without `=` padding)
- `zoid.crypto.sign_rs256(private_key_pem, data, [encoding]) -> string`
  - signs `data` using RSASSA-PKCS1-v1_5 + SHA-256 with PEM private key
  - `private_key_pem` accepts `BEGIN PRIVATE KEY` (PKCS#8) and `BEGIN RSA PRIVATE KEY` (PKCS#1)
  - `encoding` is optional; one of `base64url` (default), `base64`, `hex`, `raw`
- `zoid.config():list() -> { string, ... }` (sorted config keys)
- `zoid.config():get(key) -> string | nil`
- `zoid.config():set(key, value) -> boolean` (`true` on success)
- `zoid.config():unset(key) -> boolean` (`true` if key existed and was removed)
- `zoid.jobs.create({ path, at?, cron? }) -> job`
- `zoid.jobs.list() -> { job, ... }`
- `zoid.jobs.delete(job_id) -> boolean`
- `zoid.jobs.pause(job_id) -> boolean`
- `zoid.jobs.resume(job_id) -> boolean`
- `zoid.browser.automate(options) -> table` (same payload shape as `browser_automate` tool output)
  - Result shape highlights:
  - `result.ok` is boolean success status
  - `result.actions` is an array of per-action execution records
  - `result.extracts` is an array of extract objects
  - `extract_page_text` output is an extract object with `kind = "page_text"` and text in `value`
  - `extract_links` output is an extract object with `kind = "links"` and link list in `items`
- `zoid.import(path) -> any` (module return value; repeated imports return the cached module value; if module returns `nil`, import returns `true`)
- `zoid.json.decode(json_text) -> any`
- `zoid.json.encode(value) -> string` (supports JSON-compatible Lua values and `zoid.json.null`)
- `zoid.json.null` sentinel value used when decoded JSON contains `null`
- `zoid.time([table]) -> integer` (Lua-compatible with `os.time`: `year`/`month`/`day` required, optional `hour`/`min`/`sec`/`isdst`; numeric fields are normalized by `mktime`, and table fields are updated with normalized values)
- `zoid.date([format[, epoch]]) -> string | table` (`*t` format returns table fields `year`, `month`, `day`, `hour`, `min`, `sec`, `wday`, `yday`, optional `isdst`; `!` prefix forces UTC)
- `zoid.exit([code]) -> never` (stops Lua script execution; defaults to exit code `0`; accepted range `0..125`)
- `zoid.eprint(...)` writes to captured `stderr` (arguments are stringified and concatenated; no automatic tab/newline)

### `error(...)` vs `zoid.exit([code])`

- `error(message[, level])` is the standard Lua error function and remains available.
- Use `error(...)` for unexpected failures. In tool-mode this is reported as `error: "LuaRuntimeFailed"`.
- Use `zoid.exit([code])` for intentional early termination with an explicit exit code.
- `zoid.exit(0)` is treated as a successful tool result (`ok: true`), while non-zero codes are reported as `error: "LuaExit"` with `exit_code` set.
- `zoid.exit(code)` values outside `0..125` are rejected as Lua runtime errors.
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

When `zoid.browser.automate(...)` produces screenshot/download files in tool mode, `lua_execute` tool JSON also includes `attachments` metadata (`[{ kind, path }, ...]`) so host integrations (for example Telegram service mode) can deliver generated media automatically.

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
- Internal destinations are blocked by default (`localhost`, loopback, private IPv4 ranges, link-local, and private IPv6 ranges)
- Redirects are not automatically followed (3xx responses are returned directly)
- Response headers are exposed on `result.headers` with lowercase header names (for example `result.headers["location"]`)
- Response body size is capped by sandbox policy

### Browser Automation Rules

`zoid.browser.automate(options)` uses the same policy and runtime as the `browser_automate` tool:

- Browser support must be installed first (`zoid browser install`)
- `start_url` and browser actions that take URLs follow the same outbound URI policy as HTTP tools
- Screenshot/download/upload paths are restricted to workspace paths
- `session_id` format validation matches tool behavior
- On driver-level execution failures, returns structured payload with `ok = false` (same as tool behavior)
- In tool mode, screenshot/download action outputs are surfaced in `lua_execute` attachment metadata for host-side auto-delivery

Browser extraction result contract:

- Read extracts from `result.extracts` as an array (`ipairs`), not as map fields
- `extract_text` emits `{ kind = "text", name, selector, value }`
- `extract_html` emits `{ kind = "html", name, selector, value }`
- `extract_links` emits `{ kind = "links", name, selector, items = { { href, text }, ... } }`
- `extract_page_text` emits `{ kind = "page_text", name, value }`
- `evaluate` emits `{ kind = "evaluate", name, value }`
- `screenshot` writes an image file to the required workspace `path`; action metadata includes the saved `path` and `bytes`

Supported browser `actions` (complete list):

- `goto` / `open`
  - Required: `url`
  - Optional: `wait_until`, `timeout_ms`
- `click`
  - Required: `selector`
  - Optional: `timeout_ms`
- `type`
  - Required: `selector`, `text`
  - Optional: `clear`, `delay_ms`, `timeout_ms`
- `fill`
  - Required: `selector`, `text`
  - Optional: `timeout_ms`
- `press`
  - Required: `key`
  - Optional: `selector`, `timeout_ms`
- `select_option`
  - Required: `selector`, `value` (`string` or array of strings)
  - Optional: `timeout_ms`
- `check`
  - Required: `selector`
  - Optional: `timeout_ms`
- `uncheck`
  - Required: `selector`
  - Optional: `timeout_ms`
- `wait_for_selector`
  - Required: `selector`
  - Optional: `state`, `timeout_ms`
- `wait_for_url`
  - Required: `value`
  - Optional: `match` (`contains` default, `exact`, `regex`), `timeout_ms`
- `wait_for_timeout`
  - Optional: `ms` (default `250`), `timeout_ms`
- `submit`
  - Optional: `selector` (if omitted, presses Enter), `wait_for_navigation` (default `true`), `timeout_ms`
- `extract_text`
  - Required: `selector`
  - Optional: `name`, `timeout_ms`
- `extract_html`
  - Required: `selector`
  - Optional: `name`, `timeout_ms`
- `extract_links`
  - Optional: `selector` (default `"a"`), `name`, `max_links`, `timeout_ms`
- `extract_page_text`
  - Optional: `name`, `timeout_ms`
- `evaluate`
  - Required: `script`
  - Optional: `arg`, `name`, `timeout_ms`
- `screenshot`
  - Required: `path`
  - Optional: `selector`, `type` (`png` default or `jpeg`), `quality` (jpeg), `full_page`, `timeout_ms`
  - Behavior: writes file in workspace
- `download`
  - Required: `url`, `save_as`
  - Optional: `method` (`GET` default, `POST`, `PUT`, `DELETE`), `body`, `headers`, `timeout_ms`
- `upload`
  - Required: `selector` and one of `path` or `paths` (`string` or array of strings)
  - Optional: `timeout_ms`

### Scheduler Rules

`zoid.jobs.create` enforces:

- `path` must resolve to an existing file inside workspace root
- `path` must use the `.lua` extension
- exactly one schedule input is required: `at` (natural-language date/time) or `cron` (5-field cron)
- no Telegram destination is resolved at create time
- destination is resolved when the job runs: Telegram DM (if available), otherwise the reply is dropped
- when the agent uses browser automation during a scheduled run, screenshot artifacts are sent via Telegram photo upload (fallback document upload) and download artifacts are sent as Telegram documents
- returned `job.path` values use workspace-absolute format (`/...`)

`zoid.jobs` supports `create`, `list`, `delete`, `pause`, and `resume`.
There is no immediate `run`/`test` scheduler action in the current API.

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
