const std = @import("std");
const scheduler_store = @import("scheduler_store.zig");

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
    job_type: scheduler_store.JobType,
    path: []const u8,
    run_at: ?[]const u8,
    cron: ?[]const u8,
};

pub const JobsCommand = union(enum) {
    create: JobsCreateCommand,
    list,
    delete: []const u8,
    pause: []const u8,
    @"resume": []const u8,
};

pub const Command = union(enum) {
    help,
    execute: struct {
        file_path: []const u8,
        script_args: []const []const u8,
    },
    run: []const []const u8,
    chat,
    serve,
    config: ConfigCommand,
    jobs: JobsCommand,
};

pub const ParseCommandError = error{
    MissingExecuteArgument,
    MissingRunArgument,
    MissingConfigSubcommand,
    MissingConfigKey,
    MissingConfigValue,
    MissingJobsSubcommand,
    MissingJobsArgument,
    InvalidJobsArguments,
    UnknownConfigSubcommand,
    UnknownJobsSubcommand,
    UnknownCommand,
};

pub fn parseCommand(args: []const []const u8) ParseCommandError!Command {
    if (args.len <= 1) return .chat;

    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "help")) {
        return .help;
    }

    if (std.mem.eql(u8, cmd, "execute")) {
        if (args.len < 3) return error.MissingExecuteArgument;
        return .{ .execute = .{
            .file_path = args[2],
            .script_args = args[3..],
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

    return error.UnknownCommand;
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
    var job_type: ?scheduler_store.JobType = null;
    var path: ?[]const u8 = null;
    var run_at: ?[]const u8 = null;
    var cron: ?[]const u8 = null;

    var index: usize = 0;
    while (index < args.len) {
        const flag = args[index];

        if (std.mem.eql(u8, flag, "--lua")) {
            if (job_type != null or path != null) return error.InvalidJobsArguments;
            if (index + 1 >= args.len) return error.MissingJobsArgument;
            job_type = .lua;
            path = args[index + 1];
            index += 2;
            continue;
        }

        if (std.mem.eql(u8, flag, "--md")) {
            if (job_type != null or path != null) return error.InvalidJobsArguments;
            if (index + 1 >= args.len) return error.MissingJobsArgument;
            job_type = .markdown;
            path = args[index + 1];
            index += 2;
            continue;
        }

        if (std.mem.eql(u8, flag, "--run-at")) {
            if (run_at != null) return error.InvalidJobsArguments;
            if (index + 1 >= args.len) return error.MissingJobsArgument;
            run_at = args[index + 1];
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

        return error.InvalidJobsArguments;
    }

    if (job_type == null or path == null) return error.InvalidJobsArguments;
    if ((run_at == null and cron == null) or (run_at != null and cron != null)) return error.InvalidJobsArguments;

    return .{
        .job_type = job_type.?,
        .path = path.?,
        .run_at = run_at,
        .cron = cron,
    };
}

pub fn printHelp() void {
    std.debug.print(
        \\zoid help
        \\  Show this help message.
        \\
        \\zoid execute <file.lua> [args...]
        \\  Executes the Lua script at <file.lua> and forwards [args...] to Lua `arg`.
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
        \\zoid jobs create --lua <path.lua> (--run-at <rfc3339> | --cron "<min hour dom mon dow>")
        \\  Creates a scheduled Lua job.
        \\
        \\zoid jobs create --md <path.md> (--run-at <rfc3339> | --cron "<min hour dom mon dow>")
        \\  Creates a scheduled Markdown job.
        \\
        \\zoid jobs list
        \\  Lists scheduled jobs.
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
    , .{});
}

test "default command is chat" {
    const args = [_][]const u8{"zoid"};
    const command = try parseCommand(&args);
    try std.testing.expect(command == .chat);
}

test "jobs create lua with run-at parses" {
    const args = [_][]const u8{ "zoid", "jobs", "create", "--lua", "scripts/a.lua", "--run-at", "2026-02-22T21:00:00Z" };
    const command = try parseCommand(&args);

    switch (command) {
        .jobs => |jobs_cmd| switch (jobs_cmd) {
            .create => |create| {
                try std.testing.expectEqual(scheduler_store.JobType.lua, create.job_type);
                try std.testing.expectEqualStrings("scripts/a.lua", create.path);
                try std.testing.expectEqualStrings("2026-02-22T21:00:00Z", create.run_at.?);
                try std.testing.expect(create.cron == null);
            },
            else => return error.UnexpectedCommand,
        },
        else => return error.UnexpectedCommand,
    }
}

test "jobs create markdown with cron parses" {
    const args = [_][]const u8{ "zoid", "jobs", "create", "--md", "note.md", "--cron", "0 21 * * *" };
    const command = try parseCommand(&args);

    switch (command) {
        .jobs => |jobs_cmd| switch (jobs_cmd) {
            .create => |create| {
                try std.testing.expectEqual(scheduler_store.JobType.markdown, create.job_type);
                try std.testing.expectEqualStrings("note.md", create.path);
                try std.testing.expect(create.run_at == null);
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
    const args = [_][]const u8{ "zoid", "jobs", "create", "--lua", "task.lua" };
    try std.testing.expectError(error.InvalidJobsArguments, parseCommand(&args));
}

test "jobs rejects duplicate schedule variants" {
    const args = [_][]const u8{ "zoid", "jobs", "create", "--lua", "task.lua", "--run-at", "2026-01-01T00:00:00Z", "--cron", "0 * * * *" };
    try std.testing.expectError(error.InvalidJobsArguments, parseCommand(&args));
}

test "jobs rejects unsupported chat id flag" {
    const args = [_][]const u8{ "zoid", "jobs", "create", "--lua", "task.lua", "--run-at", "2026-01-01T00:00:00Z", "--chat-id", "123" };
    try std.testing.expectError(error.InvalidJobsArguments, parseCommand(&args));
}
