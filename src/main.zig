const std = @import("std");

const Command = union(enum) {
    help,
    execute: []const u8,
};

fn parseCommand(args: []const []const u8) !Command {
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

fn printHelp() void {
    std.debug.print(
        \\zoid help
        \\  Show this help message.
        \\
        \\zoid execute <value>
        \\  Executes <value>
    , .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const command = parseCommand(args) catch |err| {
        switch (err) {
            error.MissingExecuteArgument => {
                std.debug.print("Missing argument for 'execute'.\n\n", .{});
                printHelp();
                return;
            },
            error.UnknownCommand => {
                std.debug.print("Unknown command: {s}\n\n", .{args[1]});
                printHelp();
                return;
            },
            else => return err,
        }
    };

    switch (command) {
        .help => printHelp(),
        .execute => |value| std.debug.print("executing {s}\n", .{value}),
    }
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
