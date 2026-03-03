Zoid
====

A simple, lightweight, secure agent runtime built on Zig + embedded Lua.

Zoid is designed for low footprint operation: no Node.js/JVM runtime is required for core chat, tools, Lua execution, jobs, or Telegram service mode.

## Simple
- One small binary with [Lua support](workspace/API.md), OpenAI integration, scheduler, and Telegram service mode.
- One CLI command for all operations: `zoid`.
- Optional browser automation is available as an add-on (`zoid browser ...`).

## Lightweight
- Built to run on limited RAM and CPU.
- Suitable for small cloud instances such as [GCP E2-micro](https://docs.cloud.google.com/free/docs/free-cloud-features?gclsrc=aw.ds#compute) and small hosts like [Raspberry Pi](https://www.raspberrypi.com/products/raspberry-pi-5/?variant=raspberry-pi-5-1gb).

## Powerful
- A Lua interpreter is built in, and the agent can write and execute scripts.
- The same sandboxed Lua is available from CLI, scheduled jobs, and agent tools.
- Built-in tools include workspace file operations, HTTP requests, image analysis, scheduler APIs, and optional browser automation.

## Secure
- Agent filesystem access is restricted to the workspace root (current working directory when Zoid starts).
- Agent code execution is restricted to sandboxed Lua (`lua_execute` / `zoid execute`).
- Lua removes dangerous globals (`os`, `package`, `debug`, `dofile`, `loadfile`, global `require`) and exposes safe `zoid.*` APIs instead.
- Outbound HTTP/browser destinations are policy-restricted (private/local destinations are blocked by default).
- Config keys are stored in user app-data (`config.json`), outside version control by default.

## CLI quick start

Bootstrap a workspace with bundled templates:

```sh
zoid init
zoid init /path/to/workspace
zoid init /path/to/workspace --force
```

Run Lua scripts locally:

```sh
zoid execute scripts/cleanup.lua
zoid execute --timeout 30 scripts/cleanup.lua
zoid execute scripts/cleanup.lua 2026-02-23 extra-arg
```

Chat:

```sh
zoid chat
zoid run "Summarize today's TODOs from /notes/today.md"
```

Service mode:

```sh
zoid serve
```

Notes:
- `zoid` with no arguments defaults to `chat`.
- `chat` is TTY-only. Use `run` for non-interactive one-shot usage.
- If `ZOID.md` exists in the workspace root, `chat` and `serve` include it as extra system instructions.

## Scheduler

Zoid includes a shared scheduler backend that can be used from:

- `zoid jobs ...` CLI commands
- AI tool calls (`jobs`)
- Lua (`zoid.jobs.*`)

Examples:

```sh
zoid jobs create scripts/cleanup.lua --cron "0 21 * * *"
zoid jobs create reminders/pasta.lua --at "in 5 minutes"
zoid jobs list
zoid jobs pause <job_id>
zoid jobs resume <job_id>
zoid jobs delete <job_id>
```

Telegram routing for scheduled output:

- When a due job runs, Zoid passes the output to the agent and asks for a reply, then tries to DM on Telegram using the stored private-chat id.
- The DM id is updated automatically when `zoid serve` receives a private Telegram message.
- If no DM id is available at run time, the scheduled reply is ignored.
- Browser automation artifacts are delivered as Telegram media when possible: screenshots via `sendPhoto` (fallback `sendDocument`) and downloaded files via `sendDocument`.

## Optional browser support

When you need client-rendered pages (for example travel sites), install optional headless browser support:

```sh
zoid browser install
zoid browser status
zoid browser doctor
zoid browser uninstall
```

Notes:
- Browser support is installed under app-data (`.../zoid/browser`).
- Installation is distro-agnostic and does not use `apt`/`pacman`, but requires a JS runner (`npx`, `bunx`, `pnpm`, or `yarn`).
- `zoid browser doctor` exits non-zero when the setup is incomplete.
- Once installed, the agent tool `browser_automate` can drive dynamic sites with multi-step actions (navigate, click, fill/type, submit, wait, and extract content).
- `browser_automate` also supports persistent sessions (`session_id`) plus `screenshot`, `download`, and `upload` actions with workspace path restrictions.

# Setup on Linux host

## Install zig

### Arch
```sh
pacman -S zig
```

### Debian/Ubuntu
```sh
apt install zig
```

## Clone repo
```sh
git clone git@github.com:janne/zoid.git
cd zoid
zig build -Doptimize=ReleaseSafe
```

## Cross compile
```sh
zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe
gcloud compute scp zig-out/bin/zoid ... --zone=us-east1-c
```

## Connect to server
```sh
gcloud compute ssh ...
```

## Create user and workspace
```sh
sudo useradd --system --create-home --shell /usr/sbin/nologin zoid
sudo mkdir -p /srv/zoid/workspace
sudo chown -R zoid:zoid /srv/zoid
```

## Install binary
```sh
sudo install -m 0755 /path/to/zoid /usr/local/bin/zoid
```

## Setup
```sh
sudo zoid config set OPENAI_API_KEY "<...>"
sudo zoid config set TELEGRAM_BOT_TOKEN "<...>"

# Optional model override. If omitted, Zoid uses its built-in default model.
# sudo zoid config set OPENAI_MODEL "gpt-4o-mini"

# Optional runtime limits
sudo zoid config set OPENAI_MAX_INPUT_TOKENS "180000"
sudo zoid config set OPENAI_MAX_MESSAGE_CHARS "12000"
sudo zoid config set OPENAI_MAX_TOOL_ROUNDS "16"
sudo zoid config set OPENAI_MAX_TOOL_RESULT_CHARS "12000"
sudo zoid config set OPENAI_MAX_WORKSPACE_INSTRUCTION_CHARS "262144"
sudo zoid config set TELEGRAM_MAX_CONVERSATION_MESSAGES "20"
sudo zoid config set TELEGRAM_USER_INACTIVITY_RESET_SECONDS "28800"
sudo zoid config set TELEGRAM_INBOUND_WORKER_COUNT "4"
```

## Create `/etc/systemd/system/zoid.service`
```sh
[Unit]
Description=Zoid
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=zoid
Group=zoid
WorkingDirectory=/srv/zoid/workspace
ExecStart=/usr/local/bin/zoid serve
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

## Activate and run
```sh
sudo systemctl daemon-reload
sudo systemctl enable --now zoid
```

## Validate setup
```sh
sudo systemctl status zoid --no-pager
sudo journalctl -u zoid -f
```
