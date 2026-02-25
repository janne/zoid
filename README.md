Zoid
====

A simple, lightweight, secure alternative to OpenClaw. Built on Zig and Lua.

## Simple
- One small binary, including [Lua support](workspace/API.md), and integration with AI agents and Telegram.
- No external dependencies, all built into one binary.
- One friendly CLI command for maintaining the service - zoid.

## Lightweight
- Built to be able to run on a limited RAM and CPU. OpenClaw idles on 200-400 MB RAM, Zoid on < 10 MB.
- Able to be hosted on small cloud services such as the [forever free](https://docs.cloud.google.com/free/docs/free-cloud-features?gclsrc=aw.ds#compute) GCP E2-micro, or a [Raspberry Pi](https://www.raspberrypi.com/products/raspberry-pi-5/?variant=raspberry-pi-5-1gb).

## Powerful
- A Lua interpreter is built in, and the agent can write and execute scripts.
- The same sandboxed Lua can be accessed through CLI, scheduled jobs and agent tools

## Secure
- The agents can only read and write files in the workspace directory (the same directory as it's started from).
- No code execution is allowed by agents, apart from the Lua scripts.
- The Lua interpreter is sandboxed and limited, it can only acces the workspace and  these commands and packages are removed: `os`, `package`, `debug`, `dofile`, `loadfile`, `require`.
- All keys are stored in an vault, not under version control (`~/Library/Application Support/zoid/config.json` on Mac and `~/.local/share/zoid/config.json` on Linux).

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

Bootstrap a workspace with bundled templates:

```sh
zoid init
zoid init /path/to/workspace
zoid init /path/to/workspace --force
```

Run a Lua script locally:

```sh
zoid execute scripts/cleanup.lua
zoid execute scripts/cleanup.lua 2026-02-23
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
zig build -Doptimize=
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
sudo zoid config set OPENAI_MODEL "gpt-5-mini"

# Optional runtime limits
sudo zoid config set OPENAI_MAX_INPUT_TOKENS "180000"
sudo zoid config set OPENAI_MAX_MESSAGE_CHARS "12000"
sudo zoid config set OPENAI_MAX_TOOL_ROUNDS "16"
sudo zoid config set OPENAI_MAX_TOOL_RESULT_CHARS "12000"
sudo zoid config set OPENAI_MAX_WORKSPACE_INSTRUCTION_CHARS "262144"
sudo zoid config set TELEGRAM_MAX_CONVERSATION_MESSAGES "20"
sudo zoid config set TELEGRAM_USER_INACTIVITY_RESET_SECONDS "28800"
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
