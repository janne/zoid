const std = @import("std");

pub const Command = union(enum) {
    help,
    execute: []const u8,
};

pub const ParseCommandError = error{
    MissingExecuteArgument,
    UnknownCommand,
};

pub fn parseCommand(args: []const []const u8) ParseCommandError!Command {
    if (args.len <= 1) return .help;

    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "help")) {
        return .help;
    }

    if (std.mem.eql(u8, cmd, "execute")) {
        if (args.len < 3) return error.MissingExecuteArgument;
        return .{ .execute = args[2] };
    }

    return error.UnknownCommand;
}

pub fn printHelp() void {
    std.debug.print(
        \\zoid help
        \\  Show this help message.
        \\
        \\zoid execute <file.lua>
        \\  Executes the Lua script at <file.lua>.
    , .{});
}

test "default command is help" {
    const args = [_][]const u8{"zoid"};
    const command = try parseCommand(&args);
    try std.testing.expect(command == .help);
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
        .execute => |value| try std.testing.expectEqualStrings("foo", value),
        else => return error.UnexpectedCommand,
    }
}

test "execute without value returns error" {
    const args = [_][]const u8{ "zoid", "execute" };
    try std.testing.expectError(error.MissingExecuteArgument, parseCommand(&args));
}

test "unknown command returns error" {
    const args = [_][]const u8{ "zoid", "nope" };
    try std.testing.expectError(error.UnknownCommand, parseCommand(&args));
}
