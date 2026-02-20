const std = @import("std");

pub const Role = enum {
    user,
    assistant,
};

pub const Message = struct {
    role: Role,
    content: []const u8,
};

pub fn fetchAvailableModels(allocator: std.mem.Allocator, api_key: []const u8) ![][]u8 {
    if (api_key.len == 0) return error.EmptyApiKey;

    const auth_header = try std.mem.concat(allocator, u8, &.{ "Bearer ", api_key });
    defer allocator.free(auth_header);

    var response_buffer = std.Io.Writer.Allocating.init(allocator);
    defer response_buffer.deinit();

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const response = try client.fetch(.{
        .location = .{ .url = "https://api.openai.com/v1/models" },
        .method = .GET,
        .extra_headers = &.{
            .{ .name = "Authorization", .value = auth_header },
        },
        .response_writer = &response_buffer.writer,
    });

    const status_code = @intFromEnum(response.status);
    const response_body = response_buffer.written();
    if (status_code != 200) {
        if (try parseApiErrorMessage(allocator, response_body)) |message| {
            defer allocator.free(message);
            std.debug.print("OpenAI model list request failed ({d}): {s}\n", .{ status_code, message });
        } else {
            std.debug.print("OpenAI model list request failed with status {d}.\n", .{status_code});
        }
        return error.ApiRequestFailed;
    }

    return parseAvailableModels(allocator, response_body);
}

pub fn fetchAssistantReply(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model: []const u8,
    messages: []const Message,
) ![]u8 {
    if (api_key.len == 0) return error.EmptyApiKey;
    if (messages.len == 0) return error.EmptyConversation;

    const payload = try buildChatCompletionsPayload(allocator, model, messages);
    defer allocator.free(payload);

    const auth_header = try std.mem.concat(allocator, u8, &.{ "Bearer ", api_key });
    defer allocator.free(auth_header);

    var response_buffer = std.Io.Writer.Allocating.init(allocator);
    defer response_buffer.deinit();

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const response = try client.fetch(.{
        .location = .{ .url = "https://api.openai.com/v1/chat/completions" },
        .method = .POST,
        .payload = payload,
        .extra_headers = &.{
            .{ .name = "Authorization", .value = auth_header },
            .{ .name = "Content-Type", .value = "application/json" },
        },
        .response_writer = &response_buffer.writer,
    });

    const status_code = @intFromEnum(response.status);
    const response_body = response_buffer.written();
    if (status_code != 200) {
        if (try parseApiErrorMessage(allocator, response_body)) |message| {
            defer allocator.free(message);
            std.debug.print("OpenAI API request failed ({d}): {s}\n", .{ status_code, message });
        } else {
            std.debug.print("OpenAI API request failed with status {d}.\n", .{status_code});
        }
        return error.ApiRequestFailed;
    }

    return parseAssistantReply(allocator, response_body);
}

fn parseAvailableModels(allocator: std.mem.Allocator, response_body: []const u8) ![][]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_body, .{});
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidApiResponse,
    };

    const data = switch (root.get("data") orelse return error.InvalidApiResponse) {
        .array => |array| array,
        else => return error.InvalidApiResponse,
    };

    var models = std.ArrayList([]u8).empty;
    errdefer {
        for (models.items) |item| allocator.free(item);
        models.deinit(allocator);
    }

    for (data.items) |entry| {
        const object = switch (entry) {
            .object => |obj| obj,
            else => continue,
        };
        const id = switch (object.get("id") orelse continue) {
            .string => |value| value,
            else => continue,
        };
        if (!isChatModelId(id)) continue;
        try models.append(allocator, try allocator.dupe(u8, id));
    }

    std.mem.sort([]u8, models.items, {}, sortModelIdsAsc);

    return try models.toOwnedSlice(allocator);
}

fn isChatModelId(model_id: []const u8) bool {
    return std.mem.startsWith(u8, model_id, "gpt-") or
        std.mem.startsWith(u8, model_id, "chatgpt-") or
        std.mem.startsWith(u8, model_id, "o1") or
        std.mem.startsWith(u8, model_id, "o3") or
        std.mem.startsWith(u8, model_id, "o4");
}

fn sortModelIdsAsc(_: void, a: []u8, b: []u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn buildChatCompletionsPayload(
    allocator: std.mem.Allocator,
    model: []const u8,
    messages: []const Message,
) ![]u8 {
    var payload_buffer = std.Io.Writer.Allocating.init(allocator);
    errdefer payload_buffer.deinit();

    const writer = &payload_buffer.writer;
    try writer.writeAll("{\"model\":");
    try writeJsonString(allocator, writer, model);
    try writer.writeAll(",\"messages\":[");

    for (messages, 0..) |message, index| {
        if (index != 0) {
            try writer.writeAll(",");
        }

        try writer.writeAll("{\"role\":");
        try writeJsonString(allocator, writer, roleToString(message.role));
        try writer.writeAll(",\"content\":");
        try writeJsonString(allocator, writer, message.content);
        try writer.writeAll("}");
    }

    try writer.writeAll("]}");
    return payload_buffer.toOwnedSlice();
}

fn parseAssistantReply(allocator: std.mem.Allocator, response_body: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_body, .{});
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidApiResponse,
    };

    const choices = switch (root.get("choices") orelse return error.InvalidApiResponse) {
        .array => |array| array,
        else => return error.InvalidApiResponse,
    };
    if (choices.items.len == 0) return error.InvalidApiResponse;

    const first_choice = switch (choices.items[0]) {
        .object => |object| object,
        else => return error.InvalidApiResponse,
    };

    const message = switch (first_choice.get("message") orelse return error.InvalidApiResponse) {
        .object => |object| object,
        else => return error.InvalidApiResponse,
    };

    const content = switch (message.get("content") orelse return error.InvalidApiResponse) {
        .string => |string| string,
        else => return error.InvalidApiResponse,
    };

    return allocator.dupe(u8, content);
}

fn parseApiErrorMessage(allocator: std.mem.Allocator, response_body: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response_body, .{}) catch {
        return null;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return null,
    };

    const error_value = switch (root.get("error") orelse return null) {
        .object => |object| object,
        else => return null,
    };

    const message = switch (error_value.get("message") orelse return null) {
        .string => |string| string,
        else => return null,
    };

    const message_copy = try allocator.dupe(u8, message);
    return message_copy;
}

fn writeJsonString(allocator: std.mem.Allocator, writer: *std.Io.Writer, value: []const u8) !void {
    const escaped = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(escaped);
    try writer.writeAll(escaped);
}

fn roleToString(role: Role) []const u8 {
    return switch (role) {
        .user => "user",
        .assistant => "assistant",
    };
}

test "buildChatCompletionsPayload creates valid payload" {
    const messages = [_]Message{
        .{ .role = .user, .content = "hello \"there\"" },
        .{ .role = .assistant, .content = "general kenobi" },
    };

    const payload = try buildChatCompletionsPayload(std.testing.allocator, "gpt-4o-mini", &messages);
    defer std.testing.allocator.free(payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings("gpt-4o-mini", root.get("model").?.string);

    const payload_messages = root.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), payload_messages.len);
    try std.testing.expectEqualStrings("user", payload_messages[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("hello \"there\"", payload_messages[0].object.get("content").?.string);
    try std.testing.expectEqualStrings("assistant", payload_messages[1].object.get("role").?.string);
    try std.testing.expectEqualStrings("general kenobi", payload_messages[1].object.get("content").?.string);
}

test "parseAssistantReply extracts assistant content" {
    const response_body =
        \\{
        \\  "choices": [
        \\    {
        \\      "message": {
        \\        "role": "assistant",
        \\        "content": "Hi there!"
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    const reply = try parseAssistantReply(std.testing.allocator, response_body);
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("Hi there!", reply);
}

test "parseAssistantReply rejects unexpected payload shape" {
    const response_body = "{\"choices\":[]}";
    try std.testing.expectError(error.InvalidApiResponse, parseAssistantReply(std.testing.allocator, response_body));
}

test "parseAvailableModels filters to chat-capable models" {
    const response_body =
        \\{
        \\  "data": [
        \\    { "id": "text-embedding-3-small" },
        \\    { "id": "gpt-4o-mini" },
        \\    { "id": "o3-mini" },
        \\    { "id": "whisper-1" }
        \\  ]
        \\}
    ;

    const models = try parseAvailableModels(std.testing.allocator, response_body);
    defer {
        for (models) |model| std.testing.allocator.free(model);
        std.testing.allocator.free(models);
    }

    try std.testing.expectEqual(@as(usize, 2), models.len);
    try std.testing.expectEqualStrings("gpt-4o-mini", models[0]);
    try std.testing.expectEqualStrings("o3-mini", models[1]);
}
