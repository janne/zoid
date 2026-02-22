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

pub const ScheduleCreateCommand = struct {
    job_type: scheduler_store.JobType,
    path: []const u8,
    run_at: ?[]const u8,
    cron: ?[]const u8,
    chat_id: ?i64,
};

pub const ScheduleCommand = union(enum) {
    create: ScheduleCreateCommand,
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
    schedule: ScheduleCommand,
};

pub const ParseCommandError = error{
    MissingExecuteArgument,
    MissingRunArgument,
    MissingConfigSubcommand,
    MissingConfigKey,
    MissingConfigValue,
    MissingScheduleSubcommand,
    MissingScheduleArgument,
    InvalidScheduleArguments,
    InvalidChatId,
    UnknownConfigSubcommand,
    UnknownScheduleSubcommand,
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

    if (std.mem.eql(u8, cmd, "schedule")) {
        if (args.len < 3) return error.MissingScheduleSubcommand;
        return .{ .schedule = try parseScheduleCommand(args[2..]) };
    }

    return error.UnknownCommand;
}

fn parseScheduleCommand(args: []const []const u8) ParseCommandError!ScheduleCommand {
    const subcmd = args[0];

    if (std.mem.eql(u8, subcmd, "list")) {
        if (args.len != 1) return error.InvalidScheduleArguments;
        return .list;
    }

    if (std.mem.eql(u8, subcmd, "delete")) {
        if (args.len < 2) return error.MissingScheduleArgument;
        if (args.len > 2) return error.InvalidScheduleArguments;
        return .{ .delete = args[1] };
    }

    if (std.mem.eql(u8, subcmd, "pause")) {
        if (args.len < 2) return error.MissingScheduleArgument;
        if (args.len > 2) return error.InvalidScheduleArguments;
        return .{ .pause = args[1] };
    }

    if (std.mem.eql(u8, subcmd, "resume")) {
        if (args.len < 2) return error.MissingScheduleArgument;
        if (args.len > 2) return error.InvalidScheduleArguments;
        return .{ .@"resume" = args[1] };
    }

    if (std.mem.eql(u8, subcmd, "create")) {
        return .{ .create = try parseScheduleCreate(args[1..]) };
    }

    return error.UnknownScheduleSubcommand;
}

fn parseScheduleCreate(args: []const []const u8) ParseCommandError!ScheduleCreateCommand {
    var job_type: ?scheduler_store.JobType = null;
    var path: ?[]const u8 = null;
    var run_at: ?[]const u8 = null;
    var cron: ?[]const u8 = null;
    var chat_id: ?i64 = null;

    var index: usize = 0;
    while (index < args.len) {
        const flag = args[index];

        if (std.mem.eql(u8, flag, "--lua")) {
            if (job_type != null or path != null) return error.InvalidScheduleArguments;
            if (index + 1 >= args.len) return error.MissingScheduleArgument;
            job_type = .lua;
            path = args[index + 1];
            index += 2;
            continue;
        }

        if (std.mem.eql(u8, flag, "--md")) {
            if (job_type != null or path != null) return error.InvalidScheduleArguments;
            if (index + 1 >= args.len) return error.MissingScheduleArgument;
            job_type = .markdown;
            path = args[index + 1];
            index += 2;
            continue;
        }

        if (std.mem.eql(u8, flag, "--run-at")) {
            if (run_at != null) return error.InvalidScheduleArguments;
            if (index + 1 >= args.len) return error.MissingScheduleArgument;
            run_at = args[index + 1];
            index += 2;
            continue;
        }

        if (std.mem.eql(u8, flag, "--cron")) {
            if (cron != null) return error.InvalidScheduleArguments;
            if (index + 1 >= args.len) return error.MissingScheduleArgument;
            cron = args[index + 1];
            index += 2;
            continue;
        }

        if (std.mem.eql(u8, flag, "--chat-id")) {
            if (chat_id != null) return error.InvalidScheduleArguments;
            if (index + 1 >= args.len) return error.MissingScheduleArgument;
            chat_id = std.fmt.parseInt(i64, args[index + 1], 10) catch return error.InvalidChatId;
            index += 2;
            continue;
        }

        return error.InvalidScheduleArguments;
    }

    if (job_type == null or path == null) return error.InvalidScheduleArguments;
    if ((run_at == null and cron == null) or (run_at != null and cron != null)) return error.InvalidScheduleArguments;

    return .{
        .job_type = job_type.?,
        .path = path.?,
        .run_at = run_at,
        .cron = cron,
        .chat_id = chat_id,
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
        \\zoid schedule create --lua <path.lua> (--run-at <rfc3339> | --cron "<min hour dom mon dow>") [--chat-id <id>]
        \\  Creates a scheduled Lua job.
        \\
        \\zoid schedule create --md <path.md> (--run-at <rfc3339> | --cron "<min hour dom mon dow>") [--chat-id <id>]
        \\  Creates a scheduled Markdown job.
        \\
        \\zoid schedule list
        \\  Lists scheduled jobs.
        \\
        \\zoid schedule delete <job_id>
        \\  Deletes a scheduled job.
        \\
        \\zoid schedule pause <job_id>
        \\  Pauses a scheduled job.
        \\
        \\zoid schedule resume <job_id>
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

test "schedule create lua with run-at parses" {
    const args = [_][]const u8{ "zoid", "schedule", "create", "--lua", "scripts/a.lua", "--run-at", "2026-02-22T21:00:00Z" };
    const command = try parseCommand(&args);

    switch (command) {
        .schedule => |schedule_cmd| switch (schedule_cmd) {
            .create => |create| {
                try std.testing.expectEqual(scheduler_store.JobType.lua, create.job_type);
                try std.testing.expectEqualStrings("scripts/a.lua", create.path);
                try std.testing.expectEqualStrings("2026-02-22T21:00:00Z", create.run_at.?);
                try std.testing.expect(create.cron == null);
                try std.testing.expect(create.chat_id == null);
            },
            else => return error.UnexpectedCommand,
        },
        else => return error.UnexpectedCommand,
    }
}

test "schedule create markdown with cron and chat id parses" {
    const args = [_][]const u8{ "zoid", "schedule", "create", "--md", "note.md", "--cron", "0 21 * * *", "--chat-id", "123" };
    const command = try parseCommand(&args);

    switch (command) {
        .schedule => |schedule_cmd| switch (schedule_cmd) {
            .create => |create| {
                try std.testing.expectEqual(scheduler_store.JobType.markdown, create.job_type);
                try std.testing.expectEqualStrings("note.md", create.path);
                try std.testing.expect(create.run_at == null);
                try std.testing.expectEqualStrings("0 21 * * *", create.cron.?);
                try std.testing.expectEqual(@as(i64, 123), create.chat_id.?);
            },
            else => return error.UnexpectedCommand,
        },
        else => return error.UnexpectedCommand,
    }
}

test "schedule list parses" {
    const args = [_][]const u8{ "zoid", "schedule", "list" };
    const command = try parseCommand(&args);

    switch (command) {
        .schedule => |schedule_cmd| try std.testing.expect(schedule_cmd == .list),
        else => return error.UnexpectedCommand,
    }
}

test "schedule requires one schedule variant" {
    const args = [_][]const u8{ "zoid", "schedule", "create", "--lua", "task.lua" };
    try std.testing.expectError(error.InvalidScheduleArguments, parseCommand(&args));
}

test "schedule rejects duplicate schedule variants" {
    const args = [_][]const u8{ "zoid", "schedule", "create", "--lua", "task.lua", "--run-at", "2026-01-01T00:00:00Z", "--cron", "0 * * * *" };
    try std.testing.expectError(error.InvalidScheduleArguments, parseCommand(&args));
}

test "schedule invalid chat id" {
    const args = [_][]const u8{ "zoid", "schedule", "create", "--lua", "task.lua", "--run-at", "2026-01-01T00:00:00Z", "--chat-id", "abc" };
    try std.testing.expectError(error.InvalidChatId, parseCommand(&args));
}
