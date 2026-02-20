const std = @import("std");
const openai_client = @import("openai_client.zig");

pub fn run(allocator: std.mem.Allocator, api_key: []const u8, model: []const u8) !void {
    var messages = std.ArrayList(openai_client.Message).empty;
    defer {
        for (messages.items) |message| {
            allocator.free(message.content);
        }
        messages.deinit(allocator);
    }

    try std.fs.File.stdout().writeAll("Chat session started. Type /exit or /quit to stop.\n\n");

    var stdin_buffer: [16 * 1024]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);

    while (true) {
        try std.fs.File.stdout().writeAll("you> ");

        const line_or_eof = stdin_reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                _ = stdin_reader.interface.discardDelimiterExclusive('\n') catch {};
                try std.fs.File.stdout().writeAll("Input line is too long.\n\n");
                continue;
            },
            else => return err,
        };
        if (line_or_eof == null) {
            try std.fs.File.stdout().writeAll("\n");
            break;
        }

        const prompt = std.mem.trim(u8, line_or_eof.?, " \t\r");
        if (prompt.len == 0) continue;
        if (isExitCommand(prompt)) break;

        const user_prompt = try allocator.dupe(u8, prompt);
        errdefer allocator.free(user_prompt);
        try messages.append(allocator, .{
            .role = .user,
            .content = user_prompt,
        });

        const reply = try openai_client.fetchAssistantReply(allocator, api_key, model, messages.items);
        defer allocator.free(reply);

        try std.fs.File.stdout().writeAll("assistant> ");
        try std.fs.File.stdout().writeAll(reply);
        try std.fs.File.stdout().writeAll("\n\n");

        const assistant_reply = try allocator.dupe(u8, reply);
        errdefer allocator.free(assistant_reply);
        try messages.append(allocator, .{
            .role = .assistant,
            .content = assistant_reply,
        });
    }
}

fn isExitCommand(input: []const u8) bool {
    return std.mem.eql(u8, input, "/exit") or std.mem.eql(u8, input, "/quit");
}

test "isExitCommand recognizes exit commands" {
    try std.testing.expect(isExitCommand("/exit"));
    try std.testing.expect(isExitCommand("/quit"));
    try std.testing.expect(!isExitCommand("exit"));
    try std.testing.expect(!isExitCommand("hello"));
}
