const std = @import("std");
const model_catalog = @import("model_catalog.zig");
const tool_runtime = @import("tool_runtime.zig");

pub const Role = enum {
    user,
    assistant,
};

pub const Message = struct {
    role: Role,
    content: []const u8,
};

const ParsedToolCall = struct {
    id: []u8,
    name: []u8,
    arguments_json: []u8,
};

const ParsedAssistantTurn = struct {
    content: ?[]u8 = null,
    tool_calls: []ParsedToolCall = &.{},

    fn deinit(self: *ParsedAssistantTurn, allocator: std.mem.Allocator) void {
        if (self.content) |value| allocator.free(value);
        for (self.tool_calls) |tool_call| {
            allocator.free(tool_call.id);
            allocator.free(tool_call.name);
            allocator.free(tool_call.arguments_json);
        }
        if (self.tool_calls.len > 0) allocator.free(self.tool_calls);
    }
};

const max_tool_rounds: usize = 8;

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

    var policy = try tool_runtime.Policy.initForCurrentWorkspace(allocator);
    defer policy.deinit(allocator);

    const policy_json = try tool_runtime.buildPolicyJson(allocator, &policy);
    defer allocator.free(policy_json);
    const policy_instruction = try std.fmt.allocPrint(
        allocator,
        "Use tools only under this enforced local policy: {s}",
        .{policy_json},
    );
    defer allocator.free(policy_instruction);

    var wire_messages = std.ArrayList([]u8).empty;
    defer {
        for (wire_messages.items) |wire_message| allocator.free(wire_message);
        wire_messages.deinit(allocator);
    }

    const system_message_json = try buildRoleContentMessageJson(
        allocator,
        "system",
        policy_instruction,
    );
    try wire_messages.append(allocator, system_message_json);

    for (messages) |message| {
        const message_json = try buildRoleContentMessageJson(
            allocator,
            roleToString(message.role),
            message.content,
        );
        try wire_messages.append(allocator, message_json);
    }

    var rounds: usize = 0;
    while (rounds < max_tool_rounds) : (rounds += 1) {
        const payload = try buildChatCompletionsPayloadWithTools(
            allocator,
            model,
            wire_messages.items,
            &policy,
        );
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

        var turn = try parseAssistantTurn(allocator, response_body);
        defer turn.deinit(allocator);

        if (turn.tool_calls.len == 0) {
            const content = turn.content orelse return error.InvalidApiResponse;
            turn.content = null;
            return content;
        }

        const assistant_message_json = try buildAssistantToolCallMessageJson(
            allocator,
            turn.content,
            turn.tool_calls,
        );
        try wire_messages.append(allocator, assistant_message_json);

        for (turn.tool_calls) |tool_call| {
            const tool_result = tool_runtime.executeToolCall(
                allocator,
                &policy,
                tool_call.name,
                tool_call.arguments_json,
            ) catch |err| try tool_runtime.buildErrorResult(allocator, @errorName(err));
            defer allocator.free(tool_result);

            const tool_result_message = try buildToolResultMessageJson(
                allocator,
                tool_call.id,
                tool_result,
            );
            try wire_messages.append(allocator, tool_result_message);
        }
    }

    return error.ToolCallLimitExceeded;
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
        if (!model_catalog.isChatModelId(id)) continue;
        try models.append(allocator, try allocator.dupe(u8, id));
    }

    std.mem.sort([]u8, models.items, {}, sortModelIdsAsc);
    return try models.toOwnedSlice(allocator);
}

fn buildChatCompletionsPayload(
    allocator: std.mem.Allocator,
    model: []const u8,
    messages: []const Message,
) ![]u8 {
    var message_json = std.ArrayList([]u8).empty;
    defer {
        for (message_json.items) |entry| allocator.free(entry);
        message_json.deinit(allocator);
    }

    for (messages) |message| {
        try message_json.append(
            allocator,
            try buildRoleContentMessageJson(allocator, roleToString(message.role), message.content),
        );
    }

    const no_tools_policy = tool_runtime.Policy{ .workspace_root = "" };
    return buildChatCompletionsPayloadWithTools(allocator, model, message_json.items, &no_tools_policy);
}

fn buildChatCompletionsPayloadWithTools(
    allocator: std.mem.Allocator,
    model: []const u8,
    wire_messages: []const []const u8,
    policy: *const tool_runtime.Policy,
) ![]u8 {
    var payload_buffer = std.Io.Writer.Allocating.init(allocator);
    errdefer payload_buffer.deinit();

    const writer = &payload_buffer.writer;
    try writer.writeAll("{\"model\":");
    try writeJsonString(allocator, writer, model);
    try writer.writeAll(",\"messages\":[");

    for (wire_messages, 0..) |message_json, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.writeAll(message_json);
    }

    try writer.writeAll("],\"tools\":[");
    try writeFilesystemReadToolDefinition(allocator, writer, policy.workspace_root);
    try writer.writeAll(",");
    try writeFilesystemWriteToolDefinition(allocator, writer, policy.workspace_root);
    try writer.writeAll(",");
    try writeShellCommandToolDefinition(allocator, writer, policy.workspace_root);
    try writer.writeAll("],\"tool_choice\":\"auto\"}");

    return payload_buffer.toOwnedSlice();
}

fn writeFilesystemReadToolDefinition(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    workspace_root: []const u8,
) !void {
    const description = try std.fmt.allocPrint(
        allocator,
        "Read a UTF-8 text file under workspace root {s}. Do not read outside this root.",
        .{workspace_root},
    );
    defer allocator.free(description);

    try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":\"filesystem_read\",\"description\":");
    try writeJsonString(allocator, writer, description);
    try writer.writeAll(",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"max_bytes\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":1048576}},\"required\":[\"path\"],\"additionalProperties\":false}}}");
}

fn writeFilesystemWriteToolDefinition(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    workspace_root: []const u8,
) !void {
    const description = try std.fmt.allocPrint(
        allocator,
        "Write UTF-8 text to a file under workspace root {s}. Do not write outside this root.",
        .{workspace_root},
    );
    defer allocator.free(description);

    try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":\"filesystem_write\",\"description\":");
    try writeJsonString(allocator, writer, description);
    try writer.writeAll(",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}},\"required\":[\"path\",\"content\"],\"additionalProperties\":false}}}");
}

fn writeShellCommandToolDefinition(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    workspace_root: []const u8,
) !void {
    const description = try std.fmt.allocPrint(
        allocator,
        "Run a shell command in workspace root {s}. Use this for local commands and diagnostics.",
        .{workspace_root},
    );
    defer allocator.free(description);

    try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":\"shell_command\",\"description\":");
    try writeJsonString(allocator, writer, description);
    try writer.writeAll(",\"parameters\":{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"},\"max_output_bytes\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":1048576}},\"required\":[\"command\"],\"additionalProperties\":false}}}");
}

fn buildRoleContentMessageJson(
    allocator: std.mem.Allocator,
    role: []const u8,
    content: []const u8,
) ![]u8 {
    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();

    const writer = &output.writer;
    try writer.writeAll("{\"role\":");
    try writeJsonString(allocator, writer, role);
    try writer.writeAll(",\"content\":");
    try writeJsonString(allocator, writer, content);
    try writer.writeAll("}");

    return output.toOwnedSlice();
}

fn buildAssistantToolCallMessageJson(
    allocator: std.mem.Allocator,
    content: ?[]const u8,
    tool_calls: []const ParsedToolCall,
) ![]u8 {
    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();

    const writer = &output.writer;
    try writer.writeAll("{\"role\":\"assistant\",\"content\":");
    if (content) |value| {
        try writeJsonString(allocator, writer, value);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"tool_calls\":[");

    for (tool_calls, 0..) |tool_call, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.writeAll("{\"id\":");
        try writeJsonString(allocator, writer, tool_call.id);
        try writer.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
        try writeJsonString(allocator, writer, tool_call.name);
        try writer.writeAll(",\"arguments\":");
        try writeJsonString(allocator, writer, tool_call.arguments_json);
        try writer.writeAll("}}");
    }

    try writer.writeAll("]}");
    return output.toOwnedSlice();
}

fn buildToolResultMessageJson(
    allocator: std.mem.Allocator,
    tool_call_id: []const u8,
    tool_result: []const u8,
) ![]u8 {
    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();

    const writer = &output.writer;
    try writer.writeAll("{\"role\":\"tool\",\"tool_call_id\":");
    try writeJsonString(allocator, writer, tool_call_id);
    try writer.writeAll(",\"content\":");
    try writeJsonString(allocator, writer, tool_result);
    try writer.writeAll("}");

    return output.toOwnedSlice();
}

fn parseAssistantTurn(allocator: std.mem.Allocator, response_body: []const u8) !ParsedAssistantTurn {
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

    var turn: ParsedAssistantTurn = .{};

    if (message.get("content")) |content_value| {
        switch (content_value) {
            .string => |string| turn.content = try allocator.dupe(u8, string),
            .null => {},
            else => return error.InvalidApiResponse,
        }
    }

    if (message.get("tool_calls")) |tool_calls_value| {
        const tool_calls_array = switch (tool_calls_value) {
            .array => |array| array,
            .null => return turn,
            else => return error.InvalidApiResponse,
        };

        if (tool_calls_array.items.len == 0) return turn;

        var calls = std.ArrayList(ParsedToolCall).empty;
        errdefer {
            for (calls.items) |call| {
                allocator.free(call.id);
                allocator.free(call.name);
                allocator.free(call.arguments_json);
            }
            calls.deinit(allocator);
        }

        for (tool_calls_array.items) |entry| {
            const call_object = switch (entry) {
                .object => |object| object,
                else => return error.InvalidApiResponse,
            };

            const id = switch (call_object.get("id") orelse return error.InvalidApiResponse) {
                .string => |value| value,
                else => return error.InvalidApiResponse,
            };

            const function_object = switch (call_object.get("function") orelse return error.InvalidApiResponse) {
                .object => |object| object,
                else => return error.InvalidApiResponse,
            };

            const name = switch (function_object.get("name") orelse return error.InvalidApiResponse) {
                .string => |value| value,
                else => return error.InvalidApiResponse,
            };

            const arguments_json = switch (function_object.get("arguments") orelse return error.InvalidApiResponse) {
                .string => |value| value,
                else => return error.InvalidApiResponse,
            };

            try calls.append(allocator, .{
                .id = try allocator.dupe(u8, id),
                .name = try allocator.dupe(u8, name),
                .arguments_json = try allocator.dupe(u8, arguments_json),
            });
        }

        turn.tool_calls = try calls.toOwnedSlice(allocator);
    }

    return turn;
}

fn parseAssistantReply(allocator: std.mem.Allocator, response_body: []const u8) ![]u8 {
    var turn = try parseAssistantTurn(allocator, response_body);
    errdefer turn.deinit(allocator);

    if (turn.tool_calls.len != 0) return error.InvalidApiResponse;

    const content = turn.content orelse return error.InvalidApiResponse;
    turn.content = null;
    turn.deinit(allocator);
    return content;
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

    return try allocator.dupe(u8, message);
}

fn writeJsonString(allocator: std.mem.Allocator, writer: *std.Io.Writer, value: []const u8) !void {
    const escaped = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(escaped);
    try writer.writeAll(escaped);
}

fn sortModelIdsAsc(_: void, a: []u8, b: []u8) bool {
    return std.mem.order(u8, a, b) == .lt;
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

    const tools = root.get("tools").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), tools.len);
    try std.testing.expectEqualStrings("shell_command", tools[2].object.get("function").?.object.get("name").?.string);
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

test "parseAssistantTurn extracts tool calls" {
    const response_body =
        \\{
        \\  "choices": [
        \\    {
        \\      "message": {
        \\        "role": "assistant",
        \\        "content": null,
        \\        "tool_calls": [
        \\          {
        \\            "id": "call_1",
        \\            "type": "function",
        \\            "function": {
        \\              "name": "filesystem_read",
        \\              "arguments": "{\"path\":\"README.md\"}"
        \\            }
        \\          }
        \\        ]
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    var turn = try parseAssistantTurn(std.testing.allocator, response_body);
    defer turn.deinit(std.testing.allocator);

    try std.testing.expect(turn.content == null);
    try std.testing.expectEqual(@as(usize, 1), turn.tool_calls.len);
    try std.testing.expectEqualStrings("call_1", turn.tool_calls[0].id);
    try std.testing.expectEqualStrings("filesystem_read", turn.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"README.md\"}", turn.tool_calls[0].arguments_json);
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
