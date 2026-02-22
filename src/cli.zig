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
};

pub const ParseCommandError = error{
    MissingExecuteArgument,
    MissingRunArgument,
    MissingConfigSubcommand,
    MissingConfigKey,
    MissingConfigValue,
    UnknownConfigSubcommand,
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

    return error.UnknownCommand;
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

test "help command" {
    const args = [_][]const u8{ "zoid", "help" };
    const command = try parseCommand(&args);
    try std.testing.expect(command == .help);
}

test "execute command" {
    const args = [_][]const u8{ "zoid", "execute", "foo" };
    const command = try parseCommand(&args);

    switch (command) {
        .execute => |execute_cmd| {
            try std.testing.expectEqualStrings("foo", execute_cmd.file_path);
            try std.testing.expectEqual(@as(usize, 0), execute_cmd.script_args.len);
        },
        else => return error.UnexpectedCommand,
    }
}

test "execute command with script args" {
    const args = [_][]const u8{ "zoid", "execute", "foo.lua", "one", "two" };
    const command = try parseCommand(&args);

    switch (command) {
        .execute => |execute_cmd| {
            try std.testing.expectEqualStrings("foo.lua", execute_cmd.file_path);
            try std.testing.expectEqual(@as(usize, 2), execute_cmd.script_args.len);
            try std.testing.expectEqualStrings("one", execute_cmd.script_args[0]);
            try std.testing.expectEqualStrings("two", execute_cmd.script_args[1]);
        },
        else => return error.UnexpectedCommand,
    }
}

test "execute without value returns error" {
    const args = [_][]const u8{ "zoid", "execute" };
    try std.testing.expectError(error.MissingExecuteArgument, parseCommand(&args));
}

test "chat command" {
    const args = [_][]const u8{ "zoid", "chat" };
    const command = try parseCommand(&args);
    try std.testing.expect(command == .chat);
}

test "serve command" {
    const args = [_][]const u8{ "zoid", "serve" };
    const command = try parseCommand(&args);
    try std.testing.expect(command == .serve);
}

test "run command" {
    const args = [_][]const u8{ "zoid", "run", "hello", "world" };
    const command = try parseCommand(&args);

    switch (command) {
        .run => |prompt_parts| {
            try std.testing.expectEqual(@as(usize, 2), prompt_parts.len);
            try std.testing.expectEqualStrings("hello", prompt_parts[0]);
            try std.testing.expectEqualStrings("world", prompt_parts[1]);
        },
        else => return error.UnexpectedCommand,
    }
}

test "run without value returns error" {
    const args = [_][]const u8{ "zoid", "run" };
    try std.testing.expectError(error.MissingRunArgument, parseCommand(&args));
}

test "unknown command returns error" {
    const args = [_][]const u8{ "zoid", "nope" };
    try std.testing.expectError(error.UnknownCommand, parseCommand(&args));
}

test "config set command" {
    const args = [_][]const u8{ "zoid", "config", "set", "foo", "bar" };
    const command = try parseCommand(&args);

    switch (command) {
        .config => |config_cmd| switch (config_cmd) {
            .set => |set_cmd| {
                try std.testing.expectEqualStrings("foo", set_cmd.key);
                try std.testing.expectEqualStrings("bar", set_cmd.value);
            },
            else => return error.UnexpectedCommand,
        },
        else => return error.UnexpectedCommand,
    }
}

test "config get command" {
    const args = [_][]const u8{ "zoid", "config", "get", "foo" };
    const command = try parseCommand(&args);

    switch (command) {
        .config => |config_cmd| switch (config_cmd) {
            .get => |key| try std.testing.expectEqualStrings("foo", key),
            else => return error.UnexpectedCommand,
        },
        else => return error.UnexpectedCommand,
    }
}

test "config unset command" {
    const args = [_][]const u8{ "zoid", "config", "unset", "foo" };
    const command = try parseCommand(&args);

    switch (command) {
        .config => |config_cmd| switch (config_cmd) {
            .unset => |key| try std.testing.expectEqualStrings("foo", key),
            else => return error.UnexpectedCommand,
        },
        else => return error.UnexpectedCommand,
    }
}

test "config list command" {
    const args = [_][]const u8{ "zoid", "config", "list" };
    const command = try parseCommand(&args);

    switch (command) {
        .config => |config_cmd| try std.testing.expect(config_cmd == .list),
        else => return error.UnexpectedCommand,
    }
}

test "config without subcommand returns error" {
    const args = [_][]const u8{ "zoid", "config" };
    try std.testing.expectError(error.MissingConfigSubcommand, parseCommand(&args));
}

test "config set without key returns error" {
    const args = [_][]const u8{ "zoid", "config", "set" };
    try std.testing.expectError(error.MissingConfigKey, parseCommand(&args));
}

test "config set without value returns error" {
    const args = [_][]const u8{ "zoid", "config", "set", "foo" };
    try std.testing.expectError(error.MissingConfigValue, parseCommand(&args));
}

test "config get without key returns error" {
    const args = [_][]const u8{ "zoid", "config", "get" };
    try std.testing.expectError(error.MissingConfigKey, parseCommand(&args));
}

test "config unset without key returns error" {
    const args = [_][]const u8{ "zoid", "config", "unset" };
    try std.testing.expectError(error.MissingConfigKey, parseCommand(&args));
}

test "config unknown subcommand returns error" {
    const args = [_][]const u8{ "zoid", "config", "nope" };
    try std.testing.expectError(error.UnknownConfigSubcommand, parseCommand(&args));
}
