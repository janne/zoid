const std = @import("std");

pub const ConfigCommand = union(enum) {
    set: struct {
        key: []const u8,
        value: []const u8,
    },
    get: []const u8,
    unset: []const u8,
    list,
};

pub const JobsCreateCommand = struct {
    path: []const u8,
    at: ?[]const u8,
    cron: ?[]const u8,
};

pub const JobsCommand = union(enum) {
    create: JobsCreateCommand,
    list,
    delete: []const u8,
    pause: []const u8,
    @"resume": []const u8,
};

pub const InitCommand = struct {
    path: []const u8,
    force: bool,
};

pub const BrowserCommand = union(enum) {
    install,
    status,
    uninstall,
    doctor,
};

pub const Command = union(enum) {
    help,
    init: InitCommand,
    execute: struct {
        file_path: []const u8,
        timeout: ?u32,
        script_args: []const []const u8,
    },
    run: []const []const u8,
    chat,
    serve,
    config: ConfigCommand,
    jobs: JobsCommand,
    browser: BrowserCommand,
};

pub const ParseCommandError = error{
    InvalidInitArguments,
    MissingExecuteArgument,
    InvalidExecuteArguments,
    MissingRunArgument,
    MissingConfigSubcommand,
    MissingConfigKey,
    MissingConfigValue,
    MissingJobsSubcommand,
    MissingJobsArgument,
    MissingBrowserSubcommand,
    InvalidJobsArguments,
    InvalidBrowserArguments,
    UnknownConfigSubcommand,
    UnknownJobsSubcommand,
    UnknownBrowserSubcommand,
    UnknownCommand,
};

pub fn parseCommand(args: []const []const u8) ParseCommandError!Command {
    if (args.len <= 1) return .chat;

    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "help")) {
        return .help;
    }

    if (std.mem.eql(u8, cmd, "init")) {
        return .{ .init = try parseInitCommand(args[2..]) };
    }

    if (std.mem.eql(u8, cmd, "execute")) {
        if (args.len < 3) return error.MissingExecuteArgument;
        var timeout: ?u32 = null;
        var file_index: usize = 2;

        if (std.mem.eql(u8, args[2], "--timeout")) {
            if (args.len < 5) return error.MissingExecuteArgument;
            timeout = std.fmt.parseInt(u32, args[3], 10) catch return error.InvalidExecuteArguments;
            if (timeout.? == 0) return error.InvalidExecuteArguments;
            file_index = 4;
        }

        return .{ .execute = .{
            .file_path = args[file_index],
            .timeout = timeout,
            .script_args = args[file_index + 1 ..],
        } };
    }

    if (std.mem.eql(u8, cmd, "run")) {
        if (args.len < 3) return error.MissingRunArgument;
        return .{ .run = args[2..] };
    }

    if (std.mem.eql(u8, cmd, "chat")) {
        return .chat;
    }

    if (std.mem.eql(u8, cmd, "serve")) {
        return .serve;
    }

    if (std.mem.eql(u8, cmd, "config")) {
        if (args.len < 3) return error.MissingConfigSubcommand;

        const subcmd = args[2];

        if (std.mem.eql(u8, subcmd, "set")) {
            if (args.len < 4) return error.MissingConfigKey;
            if (args.len < 5) return error.MissingConfigValue;
            return .{ .config = .{ .set = .{
                .key = args[3],
                .value = args[4],
            } } };
        }

        if (std.mem.eql(u8, subcmd, "get")) {
            if (args.len < 4) return error.MissingConfigKey;
            return .{ .config = .{ .get = args[3] } };
        }

        if (std.mem.eql(u8, subcmd, "unset")) {
            if (args.len < 4) return error.MissingConfigKey;
            return .{ .config = .{ .unset = args[3] } };
        }

        if (std.mem.eql(u8, subcmd, "list")) {
            return .{ .config = .list };
        }

        return error.UnknownConfigSubcommand;
    }

    if (std.mem.eql(u8, cmd, "jobs")) {
        if (args.len < 3) return error.MissingJobsSubcommand;
        return .{ .jobs = try parseJobsCommand(args[2..]) };
    }

    if (std.mem.eql(u8, cmd, "browser")) {
        if (args.len < 3) return error.MissingBrowserSubcommand;
        return .{ .browser = try parseBrowserCommand(args[2..]) };
    }

    return error.UnknownCommand;
}

fn parseInitCommand(args: []const []const u8) ParseCommandError!InitCommand {
    var path: []const u8 = ".";
    var force = false;
    var saw_path = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--force")) {
            if (force) return error.InvalidInitArguments;
            force = true;
            continue;
        }

        if (saw_path) return error.InvalidInitArguments;
        path = arg;
        saw_path = true;
    }

    return .{
        .path = path,
        .force = force,
    };
}

fn parseJobsCommand(args: []const []const u8) ParseCommandError!JobsCommand {
    const subcmd = args[0];

    if (std.mem.eql(u8, subcmd, "list")) {
        if (args.len != 1) return error.InvalidJobsArguments;
        return .list;
    }

    if (std.mem.eql(u8, subcmd, "delete")) {
        if (args.len < 2) return error.MissingJobsArgument;
        if (args.len > 2) return error.InvalidJobsArguments;
        return .{ .delete = args[1] };
    }

    if (std.mem.eql(u8, subcmd, "pause")) {
        if (args.len < 2) return error.MissingJobsArgument;
        if (args.len > 2) return error.InvalidJobsArguments;
        return .{ .pause = args[1] };
    }

    if (std.mem.eql(u8, subcmd, "resume")) {
        if (args.len < 2) return error.MissingJobsArgument;
        if (args.len > 2) return error.InvalidJobsArguments;
        return .{ .@"resume" = args[1] };
    }

    if (std.mem.eql(u8, subcmd, "create")) {
        return .{ .create = try parseJobsCreate(args[1..]) };
    }

    return error.UnknownJobsSubcommand;
}

fn parseJobsCreate(args: []const []const u8) ParseCommandError!JobsCreateCommand {
    var path: ?[]const u8 = null;
    var at: ?[]const u8 = null;
    var cron: ?[]const u8 = null;

    var index: usize = 0;
    while (index < args.len) {
        const flag = args[index];

        if (std.mem.eql(u8, flag, "--at")) {
            if (at != null) return error.InvalidJobsArguments;
            if (index + 1 >= args.len) return error.MissingJobsArgument;
            at = args[index + 1];
            index += 2;
            continue;
        }

        if (std.mem.eql(u8, flag, "--cron")) {
            if (cron != null) return error.InvalidJobsArguments;
            if (index + 1 >= args.len) return error.MissingJobsArgument;
            cron = args[index + 1];
            index += 2;
            continue;
        }

        if (path != null) return error.InvalidJobsArguments;
        path = flag;
        index += 1;
    }

    if (path == null) return error.InvalidJobsArguments;
    if ((at == null and cron == null) or (at != null and cron != null)) return error.InvalidJobsArguments;

    if (!std.mem.endsWith(u8, path.?, ".lua")) return error.InvalidJobsArguments;

    return .{
        .path = path.?,
        .at = at,
        .cron = cron,
    };
}

fn parseBrowserCommand(args: []const []const u8) ParseCommandError!BrowserCommand {
    const subcmd = args[0];

    if (std.mem.eql(u8, subcmd, "install")) {
        if (args.len != 1) return error.InvalidBrowserArguments;
        return .install;
    }

    if (std.mem.eql(u8, subcmd, "status")) {
        if (args.len != 1) return error.InvalidBrowserArguments;
        return .status;
    }

    if (std.mem.eql(u8, subcmd, "uninstall")) {
        if (args.len != 1) return error.InvalidBrowserArguments;
        return .uninstall;
    }

    if (std.mem.eql(u8, subcmd, "doctor")) {
        if (args.len != 1) return error.InvalidBrowserArguments;
        return .doctor;
    }

    return error.UnknownBrowserSubcommand;
}

pub fn printHelp() void {
    std.debug.print(
        \\zoid help
        \\  Show this help message.
        \\
        \\zoid init [<path>] [--force]
        \\  Copies embedded workspace template files into <path> (default: current directory). Fails when a target file already exists unless --force is provided.
        \\
        \\zoid execute [--timeout <seconds>] <file.lua> [args...]
        \\  Executes <file.lua> (relative path or /path from workspace root), forwards [args...] to Lua `arg`, and enforces timeout (default 10s) in seconds.
        \\
        \\zoid run <prompt...>
        \\  Sends a single prompt to OpenAI and writes the response to stdout.
        \\
        \\zoid chat
        \\  Starts an interactive full-screen chat session.
        \\
        \\zoid serve
        \\  Starts long-running service mode.
        \\
        \\zoid jobs create <path.lua> (--at <datetime-expression> | --cron "<min hour dom mon dow>")
        \\  Creates a scheduled Lua job from a relative path or /path under workspace root.
        \\
        \\zoid jobs list
        \\  Lists scheduled jobs with workspace-absolute paths (/...).
        \\
        \\zoid jobs delete <job_id>
        \\  Deletes a scheduled job.
        \\
        \\zoid jobs pause <job_id>
        \\  Pauses a scheduled job.
        \\
        \\zoid jobs resume <job_id>
        \\  Resumes a scheduled job.
        \\
        \\zoid config set <key> <value>
        \\  Creates or updates a config key.
        \\
        \\zoid config get <key>
        \\  Reads a config key.
        \\
        \\zoid config unset <key>
        \\  Removes a config key.
        \\
        \\zoid config list
        \\  Lists all config keys.
        \\
        \\zoid browser install
        \\  Installs optional Playwright Chromium support into app-data.
        \\
        \\zoid browser status
        \\  Shows browser support status and detected JS runtime.
        \\
        \\zoid browser doctor
        \\  Runs browser support diagnostics and reports missing pieces.
        \\
        \\zoid browser uninstall
        \\  Removes browser support files from app-data.
    , .{});
}

test "default command is chat" {
    const args = [_][]const u8{"zoid"};
    const command = try parseCommand(&args);
    try std.testing.expect(command == .chat);
}

test "init parses with default path" {
    const args = [_][]const u8{ "zoid", "init" };
    const command = try parseCommand(&args);

    switch (command) {
        .init => |init_cmd| {
            try std.testing.expectEqualStrings(".", init_cmd.path);
            try std.testing.expect(!init_cmd.force);
        },
        else => return error.UnexpectedCommand,
    }
}

test "init parses path with force" {
    const args = [_][]const u8{ "zoid", "init", "my-workspace", "--force" };
    const command = try parseCommand(&args);

    switch (command) {
        .init => |init_cmd| {
            try std.testing.expectEqualStrings("my-workspace", init_cmd.path);
            try std.testing.expect(init_cmd.force);
        },
        else => return error.UnexpectedCommand,
    }
}

test "init parses force without explicit path" {
    const args = [_][]const u8{ "zoid", "init", "--force" };
    const command = try parseCommand(&args);

    switch (command) {
        .init => |init_cmd| {
            try std.testing.expectEqualStrings(".", init_cmd.path);
            try std.testing.expect(init_cmd.force);
        },
        else => return error.UnexpectedCommand,
    }
}

test "init rejects extra path arguments" {
    const args = [_][]const u8{ "zoid", "init", "a", "b" };
    try std.testing.expectError(error.InvalidInitArguments, parseCommand(&args));
}

test "init rejects duplicate force flag" {
    const args = [_][]const u8{ "zoid", "init", "--force", "--force" };
    try std.testing.expectError(error.InvalidInitArguments, parseCommand(&args));
}

test "execute parses timeout flag" {
    const args = [_][]const u8{ "zoid", "execute", "--timeout", "12", "scripts/run.lua", "a", "b" };
    const command = try parseCommand(&args);

    switch (command) {
        .execute => |execute_cmd| {
            try std.testing.expectEqualStrings("scripts/run.lua", execute_cmd.file_path);
            try std.testing.expectEqual(@as(?u32, 12), execute_cmd.timeout);
            try std.testing.expectEqual(@as(usize, 2), execute_cmd.script_args.len);
            try std.testing.expectEqualStrings("a", execute_cmd.script_args[0]);
            try std.testing.expectEqualStrings("b", execute_cmd.script_args[1]);
        },
        else => return error.UnexpectedCommand,
    }
}

test "execute rejects invalid timeout flag value" {
    const args = [_][]const u8{ "zoid", "execute", "--timeout", "nope", "scripts/run.lua" };
    try std.testing.expectError(error.InvalidExecuteArguments, parseCommand(&args));
}

test "jobs create lua with at parses" {
    const args = [_][]const u8{ "zoid", "jobs", "create", "scripts/a.lua", "--at", "2026-02-22T21:00:00Z" };
    const command = try parseCommand(&args);

    switch (command) {
        .jobs => |jobs_cmd| switch (jobs_cmd) {
            .create => |create| {
                try std.testing.expectEqualStrings("scripts/a.lua", create.path);
                try std.testing.expectEqualStrings("2026-02-22T21:00:00Z", create.at.?);
                try std.testing.expect(create.cron == null);
            },
            else => return error.UnexpectedCommand,
        },
        else => return error.UnexpectedCommand,
    }
}

test "jobs create lua with cron parses" {
    const args = [_][]const u8{ "zoid", "jobs", "create", "note.lua", "--cron", "0 21 * * *" };
    const command = try parseCommand(&args);

    switch (command) {
        .jobs => |jobs_cmd| switch (jobs_cmd) {
            .create => |create| {
                try std.testing.expectEqualStrings("note.lua", create.path);
                try std.testing.expect(create.at == null);
                try std.testing.expectEqualStrings("0 21 * * *", create.cron.?);
            },
            else => return error.UnexpectedCommand,
        },
        else => return error.UnexpectedCommand,
    }
}

test "jobs list parses" {
    const args = [_][]const u8{ "zoid", "jobs", "list" };
    const command = try parseCommand(&args);

    switch (command) {
        .jobs => |jobs_cmd| try std.testing.expect(jobs_cmd == .list),
        else => return error.UnexpectedCommand,
    }
}

test "jobs requires one schedule variant" {
    const args = [_][]const u8{ "zoid", "jobs", "create", "task.lua" };
    try std.testing.expectError(error.InvalidJobsArguments, parseCommand(&args));
}

test "jobs rejects duplicate schedule variants" {
    const args = [_][]const u8{ "zoid", "jobs", "create", "task.lua", "--at", "2026-01-01T00:00:00Z", "--cron", "0 * * * *" };
    try std.testing.expectError(error.InvalidJobsArguments, parseCommand(&args));
}

test "jobs rejects unsupported chat id flag" {
    const args = [_][]const u8{ "zoid", "jobs", "create", "task.lua", "--at", "2026-01-01T00:00:00Z", "--chat-id", "123" };
    try std.testing.expectError(error.InvalidJobsArguments, parseCommand(&args));
}

test "jobs rejects unsupported path extension" {
    const args = [_][]const u8{ "zoid", "jobs", "create", "task.txt", "--at", "2026-01-01T00:00:00Z" };
    try std.testing.expectError(error.InvalidJobsArguments, parseCommand(&args));
}

test "jobs rejects deprecated run-at flag" {
    const args = [_][]const u8{ "zoid", "jobs", "create", "task.lua", "--run-at", "2026-01-01T00:00:00Z" };
    try std.testing.expectError(error.InvalidJobsArguments, parseCommand(&args));
}

test "jobs rejects multiple paths" {
    const args = [_][]const u8{ "zoid", "jobs", "create", "task.lua", "note.lua", "--cron", "0 * * * *" };
    try std.testing.expectError(error.InvalidJobsArguments, parseCommand(&args));
}

test "browser install parses" {
    const args = [_][]const u8{ "zoid", "browser", "install" };
    const command = try parseCommand(&args);

    switch (command) {
        .browser => |browser_cmd| try std.testing.expect(browser_cmd == .install),
        else => return error.UnexpectedCommand,
    }
}

test "browser status parses" {
    const args = [_][]const u8{ "zoid", "browser", "status" };
    const command = try parseCommand(&args);

    switch (command) {
        .browser => |browser_cmd| try std.testing.expect(browser_cmd == .status),
        else => return error.UnexpectedCommand,
    }
}

test "browser requires subcommand" {
    const args = [_][]const u8{ "zoid", "browser" };
    try std.testing.expectError(error.MissingBrowserSubcommand, parseCommand(&args));
}

test "browser rejects unknown subcommand" {
    const args = [_][]const u8{ "zoid", "browser", "nope" };
    try std.testing.expectError(error.UnknownBrowserSubcommand, parseCommand(&args));
}

test "browser rejects extra arguments" {
    const args = [_][]const u8{ "zoid", "browser", "install", "extra" };
    try std.testing.expectError(error.InvalidBrowserArguments, parseCommand(&args));
}
