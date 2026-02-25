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

pub const RequestContext = struct {
    request_chat_id: ?i64 = null,
    workspace_instruction: ?[]const u8 = null,
    limits: Limits = .{},
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

pub const default_max_input_tokens: usize = 180_000;
pub const min_max_input_tokens: usize = 1_000;
pub const max_max_input_tokens: usize = 500_000;

pub const default_max_message_chars: usize = 12_000;
pub const min_max_message_chars: usize = 256;
pub const max_max_message_chars: usize = 200_000;

pub const default_max_tool_rounds: usize = 16;
pub const min_max_tool_rounds: usize = 1;
pub const max_max_tool_rounds: usize = 64;

pub const default_max_tool_result_chars: usize = 12_000;
pub const min_max_tool_result_chars: usize = 256;
pub const max_max_tool_result_chars: usize = 200_000;

pub const Limits = struct {
    max_input_tokens: usize = default_max_input_tokens,
    max_message_chars: usize = default_max_message_chars,
    max_tool_rounds: usize = default_max_tool_rounds,
    max_tool_result_chars: usize = default_max_tool_result_chars,
};

const estimated_tokens_per_byte_divisor: usize = 3;
const estimated_token_overhead: usize = 2_048;

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
    return fetchAssistantReplyWithContext(
        allocator,
        api_key,
        model,
        messages,
        .{},
    );
}

pub fn fetchAssistantReplyWithContext(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model: []const u8,
    messages: []const Message,
    request_context: RequestContext,
) ![]u8 {
    if (api_key.len == 0) return error.EmptyApiKey;
    if (messages.len == 0) return error.EmptyConversation;
    const limits = sanitizeLimits(request_context.limits);

    var policy = try tool_runtime.Policy.initForCurrentWorkspace(allocator);
    defer policy.deinit(allocator);

    const policy_json = try tool_runtime.buildPolicyJson(allocator, &policy);
    defer allocator.free(policy_json);
    const system_instruction = try buildSystemInstruction(
        allocator,
        policy_json,
        request_context.workspace_instruction,
    );
    defer allocator.free(system_instruction);

    var wire_messages = std.ArrayList([]u8).empty;
    defer {
        for (wire_messages.items) |wire_message| allocator.free(wire_message);
        wire_messages.deinit(allocator);
    }

    const system_message_json = try buildRoleContentMessageJson(
        allocator,
        "system",
        system_instruction,
    );
    try wire_messages.append(allocator, system_message_json);

    for (messages) |message| {
        const message_json = try buildRoleContentMessageJsonCapped(
            allocator,
            roleToString(message.role),
            message.content,
            limits.max_message_chars,
        );
        try wire_messages.append(allocator, message_json);
    }

    var rounds: usize = 0;
    while (rounds < limits.max_tool_rounds) : (rounds += 1) {
        const payload = try buildPayloadWithinTokenBudget(
            allocator,
            model,
            &wire_messages,
            &policy,
            "auto",
            limits.max_input_tokens,
        );
        defer allocator.free(payload);
        const response_body = try sendChatCompletionsRequest(allocator, api_key, payload);
        defer allocator.free(response_body);

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
            limits.max_message_chars,
        );
        try wire_messages.append(allocator, assistant_message_json);

        for (turn.tool_calls) |tool_call| {
            const tool_result = tool_runtime.executeToolCallWithContext(
                allocator,
                &policy,
                .{ .request_chat_id = request_context.request_chat_id },
                tool_call.name,
                tool_call.arguments_json,
            ) catch |err| try tool_runtime.buildErrorResult(allocator, @errorName(err));
            defer allocator.free(tool_result);

            const capped_tool_result = try capTextToLimit(
                allocator,
                tool_result,
                limits.max_tool_result_chars,
            );
            defer capped_tool_result.deinit(allocator);

            const tool_result_message = try buildToolResultMessageJson(
                allocator,
                tool_call.id,
                capped_tool_result.value,
            );
            try wire_messages.append(allocator, tool_result_message);
        }
    }

    const final_payload = try buildPayloadWithinTokenBudget(
        allocator,
        model,
        &wire_messages,
        &policy,
        "none",
        limits.max_input_tokens,
    );
    defer allocator.free(final_payload);

    const final_response_body = try sendChatCompletionsRequest(allocator, api_key, final_payload);
    defer allocator.free(final_response_body);

    var final_turn = try parseAssistantTurn(allocator, final_response_body);
    defer final_turn.deinit(allocator);
    if (final_turn.tool_calls.len != 0) return error.ToolCallLimitExceeded;
    const final_content = final_turn.content orelse return error.ToolCallLimitExceeded;
    final_turn.content = null;
    return final_content;
}

fn sanitizeLimits(raw: Limits) Limits {
    var limits = raw;
    limits.max_input_tokens = std.math.clamp(
        limits.max_input_tokens,
        min_max_input_tokens,
        max_max_input_tokens,
    );
    limits.max_message_chars = std.math.clamp(
        limits.max_message_chars,
        min_max_message_chars,
        max_max_message_chars,
    );
    limits.max_tool_rounds = std.math.clamp(
        limits.max_tool_rounds,
        min_max_tool_rounds,
        max_max_tool_rounds,
    );
    limits.max_tool_result_chars = std.math.clamp(
        limits.max_tool_result_chars,
        min_max_tool_result_chars,
        max_max_tool_result_chars,
    );
    return limits;
}

const CappedText = struct {
    value: []const u8,
    owned: bool = false,

    fn deinit(self: CappedText, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.value);
    }
};

fn capTextToLimit(
    allocator: std.mem.Allocator,
    value: []const u8,
    max_chars: usize,
) !CappedText {
    if (value.len <= max_chars) {
        return .{ .value = value };
    }

    return .{
        .value = try allocator.dupe(u8, value[0..max_chars]),
        .owned = true,
    };
}

fn buildRoleContentMessageJsonCapped(
    allocator: std.mem.Allocator,
    role: []const u8,
    content: []const u8,
    max_chars: usize,
) ![]u8 {
    const capped = try capTextToLimit(allocator, content, max_chars);
    defer capped.deinit(allocator);
    return buildRoleContentMessageJson(allocator, role, capped.value);
}

fn buildPayloadWithinTokenBudget(
    allocator: std.mem.Allocator,
    model: []const u8,
    wire_messages: *std.ArrayList([]u8),
    policy: *const tool_runtime.Policy,
    tool_choice: []const u8,
    max_input_tokens: usize,
) ![]u8 {
    while (true) {
        const payload = try buildChatCompletionsPayloadWithTools(
            allocator,
            model,
            wire_messages.items,
            policy,
            tool_choice,
        );

        if (estimateInputTokens(payload.len) <= max_input_tokens) {
            return payload;
        }

        allocator.free(payload);
        if (!dropOldestWireMessage(allocator, wire_messages)) {
            return error.InputTokenBudgetExceeded;
        }
    }
}

fn estimateInputTokens(payload_bytes: usize) usize {
    return payload_bytes / estimated_tokens_per_byte_divisor + estimated_token_overhead;
}

fn dropOldestWireMessage(
    allocator: std.mem.Allocator,
    wire_messages: *std.ArrayList([]u8),
) bool {
    // Keep the system message (index 0) and always preserve at least one latest non-system message.
    if (wire_messages.items.len <= 2) return false;
    const removed = wire_messages.orderedRemove(1);
    allocator.free(removed);
    return true;
}

fn sendChatCompletionsRequest(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    payload: []const u8,
) ![]u8 {
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

    return try allocator.dupe(u8, response_body);
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
    return buildChatCompletionsPayloadWithTools(allocator, model, message_json.items, &no_tools_policy, "auto");
}

fn buildSystemInstruction(
    allocator: std.mem.Allocator,
    policy_json: []const u8,
    workspace_instruction: ?[]const u8,
) ![]u8 {
    if (workspace_instruction) |raw_workspace_instruction| {
        const trimmed_workspace_instruction = std.mem.trim(u8, raw_workspace_instruction, " \t\r\n");
        if (trimmed_workspace_instruction.len > 0) {
            return std.fmt.allocPrint(
                allocator,
                "Use tools only under this enforced local policy: {s}\n\nWorkspace instructions from ZOID.md:\n{s}\n\nFollow workspace instructions as agent guidance unless they conflict with higher-priority constraints.",
                .{ policy_json, trimmed_workspace_instruction },
            );
        }
    }

    return std.fmt.allocPrint(
        allocator,
        "Use tools only under this enforced local policy: {s}",
        .{policy_json},
    );
}

fn buildChatCompletionsPayloadWithTools(
    allocator: std.mem.Allocator,
    model: []const u8,
    wire_messages: []const []const u8,
    policy: *const tool_runtime.Policy,
    tool_choice: []const u8,
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
    try writeFilesystemListToolDefinition(allocator, writer, policy.workspace_root);
    try writer.writeAll(",");
    try writeFilesystemGrepToolDefinition(allocator, writer, policy.workspace_root);
    try writer.writeAll(",");
    try writeFilesystemWriteToolDefinition(allocator, writer, policy.workspace_root);
    try writer.writeAll(",");
    try writeFilesystemMkdirToolDefinition(allocator, writer, policy.workspace_root);
    try writer.writeAll(",");
    try writeFilesystemRmdirToolDefinition(allocator, writer, policy.workspace_root);
    try writer.writeAll(",");
    try writeFilesystemDeleteToolDefinition(allocator, writer, policy.workspace_root);
    try writer.writeAll(",");
    try writeLuaExecuteToolDefinition(allocator, writer, policy.workspace_root);
    try writer.writeAll(",");
    try writeConfigToolDefinition(allocator, writer);
    try writer.writeAll(",");
    try writeSchedulerToolDefinition(allocator, writer);
    try writer.writeAll(",");
    try writeHttpGetToolDefinition(allocator, writer);
    try writer.writeAll(",");
    try writeHttpPostToolDefinition(allocator, writer);
    try writer.writeAll(",");
    try writeHttpPutToolDefinition(allocator, writer);
    try writer.writeAll(",");
    try writeHttpDeleteToolDefinition(allocator, writer);
    try writer.writeAll(",");
    try writeDateTimeNowToolDefinition(allocator, writer);
    try writer.writeAll(",");
    try writeBrowserAutomateToolDefinition(allocator, writer);
    try writer.writeAll("],\"tool_choice\":");
    try writeJsonString(allocator, writer, tool_choice);
    try writer.writeAll("}");

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

fn writeFilesystemListToolDefinition(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    workspace_root: []const u8,
) !void {
    const description = try std.fmt.allocPrint(
        allocator,
        "List entries in a directory under workspace root {s} and return metadata (name, path, type, size, mode, owner, group, modified_at).",
        .{workspace_root},
    );
    defer allocator.free(description);

    try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":\"filesystem_list\",\"description\":");
    try writeJsonString(allocator, writer, description);
    try writer.writeAll(",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"additionalProperties\":false}}}");
}

fn writeFilesystemGrepToolDefinition(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    workspace_root: []const u8,
) !void {
    const description = try std.fmt.allocPrint(
        allocator,
        "Search for matching text in files under workspace root {s}. Supports optional path, recursive scanning, and match limit.",
        .{workspace_root},
    );
    defer allocator.free(description);

    try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":\"filesystem_grep\",\"description\":");
    try writeJsonString(allocator, writer, description);
    try writer.writeAll(",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"pattern\":{\"type\":\"string\"},\"recursive\":{\"type\":\"boolean\"},\"max_matches\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":");
    try writer.print("{d}", .{tool_runtime.max_allowed_grep_matches});
    try writer.writeAll("}},\"required\":[\"pattern\"],\"additionalProperties\":false}}}");
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

fn writeFilesystemMkdirToolDefinition(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    workspace_root: []const u8,
) !void {
    const description = try std.fmt.allocPrint(
        allocator,
        "Create a directory under workspace root {s}. Path must resolve inside this root and must not already exist.",
        .{workspace_root},
    );
    defer allocator.free(description);

    try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":\"filesystem_mkdir\",\"description\":");
    try writeJsonString(allocator, writer, description);
    try writer.writeAll(",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"],\"additionalProperties\":false}}}");
}

fn writeFilesystemRmdirToolDefinition(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    workspace_root: []const u8,
) !void {
    const description = try std.fmt.allocPrint(
        allocator,
        "Remove an empty directory under workspace root {s}. Path must resolve inside this root.",
        .{workspace_root},
    );
    defer allocator.free(description);

    try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":\"filesystem_rmdir\",\"description\":");
    try writeJsonString(allocator, writer, description);
    try writer.writeAll(",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"],\"additionalProperties\":false}}}");
}

fn writeFilesystemDeleteToolDefinition(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    workspace_root: []const u8,
) !void {
    const description = try std.fmt.allocPrint(
        allocator,
        "Delete a file under workspace root {s}. Path must resolve inside this root.",
        .{workspace_root},
    );
    defer allocator.free(description);

    try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":\"filesystem_delete\",\"description\":");
    try writeJsonString(allocator, writer, description);
    try writer.writeAll(",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"],\"additionalProperties\":false}}}");
}

fn writeLuaExecuteToolDefinition(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    workspace_root: []const u8,
) !void {
    const description = try std.fmt.allocPrint(
        allocator,
        "Execute a Lua script file under workspace root {s}. Path must resolve inside this root and target a .lua file. Optional timeout controls maximum runtime in seconds.",
        .{workspace_root},
    );
    defer allocator.free(description);

    try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":\"lua_execute\",\"description\":");
    try writeJsonString(allocator, writer, description);
    try writer.writeAll(",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"args\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"timeout\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":");
    try writer.print("{d}", .{tool_runtime.max_allowed_lua_timeout_seconds});
    try writer.writeAll("}},\"required\":[\"path\"],\"additionalProperties\":false}}}");
}

fn writeHttpGetToolDefinition(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
) !void {
    const description = try std.fmt.allocPrint(
        allocator,
        "Perform an HTTP GET request to a http:// or https:// URI. Internal destinations (localhost/private/link-local) are blocked. Returns response status and body (max {d} bytes).",
        .{tool_runtime.max_allowed_http_response_bytes},
    );
    defer allocator.free(description);

    try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":\"http_get\",\"description\":");
    try writeJsonString(allocator, writer, description);
    try writer.writeAll(",\"parameters\":{\"type\":\"object\",\"properties\":{\"uri\":{\"type\":\"string\"}},\"required\":[\"uri\"],\"additionalProperties\":false}}}");
}

fn writeConfigToolDefinition(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
) !void {
    const description = "Read and update Zoid config key/value pairs. Use action=list|get|set|unset. Key/value are UTF-8 strings.";
    try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":\"config\",\"description\":");
    try writeJsonString(allocator, writer, description);
    try writer.writeAll(",\"parameters\":{\"type\":\"object\",\"properties\":{\"action\":{\"type\":\"string\",\"enum\":[\"list\",\"get\",\"set\",\"unset\"]},\"key\":{\"type\":\"string\"},\"value\":{\"type\":\"string\"}},\"required\":[\"action\"],\"additionalProperties\":false}}}");
}

fn writeSchedulerToolDefinition(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
) !void {
    const description =
        "Manage scheduled jobs in the current workspace. action=create|list|delete|pause|resume. " ++
        "create requires a Lua path and exactly one of at (natural-language date/time) or cron (5-field). " ++
        "Job timestamp fields are returned as local strings in YYYY-MM-DD HH:MM plus *_epoch numeric companions. " ++
        "Scheduled output is routed at execution time: Telegram DM if available, otherwise dropped.";
    try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":\"jobs\",\"description\":");
    try writeJsonString(allocator, writer, description);
    try writer.writeAll(",\"parameters\":{\"type\":\"object\",\"properties\":{\"action\":{\"type\":\"string\",\"enum\":[\"create\",\"list\",\"delete\",\"pause\",\"resume\"]},\"path\":{\"type\":\"string\"},\"at\":{\"type\":\"string\"},\"cron\":{\"type\":\"string\"},\"job_id\":{\"type\":\"string\"}},\"required\":[\"action\"],\"additionalProperties\":false}}}");
}

fn writeHttpPostToolDefinition(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
) !void {
    const description = try std.fmt.allocPrint(
        allocator,
        "Perform an HTTP POST request to a http:// or https:// URI with optional string body. Internal destinations (localhost/private/link-local) are blocked. Returns response status and body (max {d} bytes).",
        .{tool_runtime.max_allowed_http_response_bytes},
    );
    defer allocator.free(description);

    try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":\"http_post\",\"description\":");
    try writeJsonString(allocator, writer, description);
    try writer.writeAll(",\"parameters\":{\"type\":\"object\",\"properties\":{\"uri\":{\"type\":\"string\"},\"body\":{\"type\":\"string\"}},\"required\":[\"uri\"],\"additionalProperties\":false}}}");
}

fn writeHttpPutToolDefinition(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
) !void {
    const description = try std.fmt.allocPrint(
        allocator,
        "Perform an HTTP PUT request to a http:// or https:// URI with optional string body. Internal destinations (localhost/private/link-local) are blocked. Returns response status and body (max {d} bytes).",
        .{tool_runtime.max_allowed_http_response_bytes},
    );
    defer allocator.free(description);

    try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":\"http_put\",\"description\":");
    try writeJsonString(allocator, writer, description);
    try writer.writeAll(",\"parameters\":{\"type\":\"object\",\"properties\":{\"uri\":{\"type\":\"string\"},\"body\":{\"type\":\"string\"}},\"required\":[\"uri\"],\"additionalProperties\":false}}}");
}

fn writeHttpDeleteToolDefinition(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
) !void {
    const description = try std.fmt.allocPrint(
        allocator,
        "Perform an HTTP DELETE request to a http:// or https:// URI. Internal destinations (localhost/private/link-local) are blocked. Returns response status and body (max {d} bytes).",
        .{tool_runtime.max_allowed_http_response_bytes},
    );
    defer allocator.free(description);

    try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":\"http_delete\",\"description\":");
    try writeJsonString(allocator, writer, description);
    try writer.writeAll(",\"parameters\":{\"type\":\"object\",\"properties\":{\"uri\":{\"type\":\"string\"}},\"required\":[\"uri\"],\"additionalProperties\":false}}}");
}

fn writeDateTimeNowToolDefinition(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
) !void {
    const description =
        "Get current date/time from the local runtime clock. " ++
        "Returns current Unix epoch seconds and both UTC/local ISO-8601 timestamps.";
    try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":\"datetime_now\",\"description\":");
    try writeJsonString(allocator, writer, description);
    try writer.writeAll(",\"parameters\":{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}}}");
}

fn writeBrowserAutomateToolDefinition(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
) !void {
    const description =
        "Automate a real headless Chromium browser session for dynamic pages and form workflows. " ++
        "Supports multi-step actions such as goto/open, click, type/fill, press, select_option, check/uncheck, submit, wait_for_selector, wait_for_url, wait_for_timeout, " ++
        "extract_text, extract_html, extract_links, extract_page_text, evaluate JavaScript, screenshot, download, and upload. " ++
        "Screenshot actions require a workspace file path and save the image to that path. " ++
        "Use session_id to persist browser state between tool calls. " ++
        "Use this when normal HTTP fetching is insufficient due to client-side rendering.";

    try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":\"browser_automate\",\"description\":");
    try writeJsonString(allocator, writer, description);
    try writer.writeAll(",\"parameters\":{\"type\":\"object\",\"properties\":{");
    try writer.writeAll("\"session_id\":{\"type\":\"string\"},");
    try writer.writeAll("\"session_dispose\":{\"type\":\"boolean\"},");
    try writer.writeAll("\"start_url\":{\"type\":\"string\"},");
    try writer.writeAll("\"timeout_seconds\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":");
    try writer.print("{d}", .{tool_runtime.max_allowed_browser_timeout_seconds});
    try writer.writeAll("},");
    try writer.writeAll("\"action_timeout_ms\":{\"type\":\"integer\",\"minimum\":100,\"maximum\":600000},");
    try writer.writeAll("\"continue_on_error\":{\"type\":\"boolean\"},");
    try writer.writeAll("\"user_agent\":{\"type\":\"string\"},");
    try writer.writeAll("\"max_extract_items\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":500},");
    try writer.writeAll("\"max_text_chars\":{\"type\":\"integer\",\"minimum\":256,\"maximum\":200000},");
    try writer.writeAll("\"max_html_chars\":{\"type\":\"integer\",\"minimum\":256,\"maximum\":400000},");
    try writer.writeAll("\"viewport\":{\"type\":\"object\",\"properties\":{\"width\":{\"type\":\"integer\"},\"height\":{\"type\":\"integer\"}},\"additionalProperties\":false},");
    try writer.writeAll("\"actions\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{");
    try writer.writeAll("\"action\":{\"type\":\"string\"},\"url\":{\"type\":\"string\"},\"selector\":{\"type\":\"string\"},\"text\":{\"type\":\"string\"},");
    try writer.writeAll("\"key\":{\"type\":\"string\"},\"value\":{},\"arg\":{},\"script\":{\"type\":\"string\"},\"name\":{\"type\":\"string\"},");
    try writer.writeAll("\"type\":{\"type\":\"string\"},\"quality\":{\"type\":\"integer\"},\"full_page\":{\"type\":\"boolean\"},");
    try writer.writeAll("\"path\":{\"type\":\"string\"},\"paths\":{},\"save_as\":{\"type\":\"string\"},\"method\":{\"type\":\"string\"},\"body\":{\"type\":\"string\"},\"headers\":{},");
    try writer.writeAll("\"timeout_ms\":{\"type\":\"integer\"},\"delay_ms\":{\"type\":\"integer\"},\"wait_until\":{\"type\":\"string\"},");
    try writer.writeAll("\"wait_for_navigation\":{\"type\":\"boolean\"},\"state\":{\"type\":\"string\"},\"match\":{\"type\":\"string\"},\"ms\":{\"type\":\"integer\"},");
    try writer.writeAll("\"max_links\":{\"type\":\"integer\"},\"clear\":{\"type\":\"boolean\"}");
    try writer.writeAll("},\"required\":[\"action\"],\"additionalProperties\":true}}");
    try writer.writeAll("},\"additionalProperties\":false}}}");
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
    max_message_chars: usize,
) ![]u8 {
    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();

    const writer = &output.writer;
    try writer.writeAll("{\"role\":\"assistant\",\"content\":");
    if (content) |value| {
        const capped = try capTextToLimit(allocator, value, max_message_chars);
        defer capped.deinit(allocator);
        try writeJsonString(allocator, writer, capped.value);
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
    try std.testing.expectEqual(@as(usize, 16), tools.len);
    try std.testing.expectEqualStrings("filesystem_read", tools[0].object.get("function").?.object.get("name").?.string);
    try std.testing.expectEqualStrings("filesystem_list", tools[1].object.get("function").?.object.get("name").?.string);
    try std.testing.expectEqualStrings("filesystem_grep", tools[2].object.get("function").?.object.get("name").?.string);
    const grep_parameters = tools[2].object.get("function").?.object.get("parameters").?.object;
    const grep_properties = grep_parameters.get("properties").?.object;
    try std.testing.expect(grep_properties.get("pattern") != null);
    try std.testing.expectEqualStrings("boolean", grep_properties.get("recursive").?.object.get("type").?.string);
    try std.testing.expectEqual(@as(i64, tool_runtime.max_allowed_grep_matches), grep_properties.get("max_matches").?.object.get("maximum").?.integer);
    try std.testing.expectEqualStrings("filesystem_write", tools[3].object.get("function").?.object.get("name").?.string);
    try std.testing.expectEqualStrings("filesystem_mkdir", tools[4].object.get("function").?.object.get("name").?.string);
    try std.testing.expectEqualStrings("filesystem_rmdir", tools[5].object.get("function").?.object.get("name").?.string);
    try std.testing.expectEqualStrings("filesystem_delete", tools[6].object.get("function").?.object.get("name").?.string);
    try std.testing.expectEqualStrings("lua_execute", tools[7].object.get("function").?.object.get("name").?.string);
    const lua_parameters = tools[7].object.get("function").?.object.get("parameters").?.object;
    const lua_properties = lua_parameters.get("properties").?.object;
    try std.testing.expect(lua_properties.get("path") != null);
    const args_property = lua_properties.get("args").?.object;
    try std.testing.expectEqualStrings("array", args_property.get("type").?.string);
    try std.testing.expectEqualStrings("string", args_property.get("items").?.object.get("type").?.string);
    const timeout_property = lua_properties.get("timeout").?.object;
    try std.testing.expectEqualStrings("integer", timeout_property.get("type").?.string);
    try std.testing.expectEqual(@as(i64, 1), timeout_property.get("minimum").?.integer);
    try std.testing.expectEqual(@as(i64, tool_runtime.max_allowed_lua_timeout_seconds), timeout_property.get("maximum").?.integer);
    try std.testing.expectEqualStrings("config", tools[8].object.get("function").?.object.get("name").?.string);
    try std.testing.expectEqualStrings("jobs", tools[9].object.get("function").?.object.get("name").?.string);
    try std.testing.expectEqualStrings("http_get", tools[10].object.get("function").?.object.get("name").?.string);
    try std.testing.expectEqualStrings("http_post", tools[11].object.get("function").?.object.get("name").?.string);
    try std.testing.expectEqualStrings("http_put", tools[12].object.get("function").?.object.get("name").?.string);
    try std.testing.expectEqualStrings("http_delete", tools[13].object.get("function").?.object.get("name").?.string);
    try std.testing.expectEqualStrings("datetime_now", tools[14].object.get("function").?.object.get("name").?.string);
    try std.testing.expectEqualStrings("browser_automate", tools[15].object.get("function").?.object.get("name").?.string);
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

test "buildSystemInstruction includes workspace instructions when provided" {
    const instruction = try buildSystemInstruction(
        std.testing.allocator,
        "{\"workspace_root\":\"/tmp/workspace\"}",
        "Always read README.md first.",
    );
    defer std.testing.allocator.free(instruction);

    try std.testing.expect(std.mem.indexOf(u8, instruction, "Workspace instructions from ZOID.md:") != null);
    try std.testing.expect(std.mem.indexOf(u8, instruction, "Always read README.md first.") != null);
}

test "buildSystemInstruction omits workspace section for empty instructions" {
    const instruction = try buildSystemInstruction(
        std.testing.allocator,
        "{\"workspace_root\":\"/tmp/workspace\"}",
        "   \n\t",
    );
    defer std.testing.allocator.free(instruction);

    try std.testing.expect(std.mem.indexOf(u8, instruction, "Workspace instructions from ZOID.md:") == null);
}

test "sanitizeLimits clamps to supported bounds" {
    const sanitized = sanitizeLimits(.{
        .max_input_tokens = 10,
        .max_message_chars = 1_000_000,
        .max_tool_rounds = 0,
        .max_tool_result_chars = 10,
    });

    try std.testing.expectEqual(min_max_input_tokens, sanitized.max_input_tokens);
    try std.testing.expectEqual(max_max_message_chars, sanitized.max_message_chars);
    try std.testing.expectEqual(min_max_tool_rounds, sanitized.max_tool_rounds);
    try std.testing.expectEqual(min_max_tool_result_chars, sanitized.max_tool_result_chars);
}

test "buildRoleContentMessageJsonCapped truncates long content" {
    const payload = try buildRoleContentMessageJsonCapped(
        std.testing.allocator,
        "user",
        "abcdefghij",
        4,
    );
    defer std.testing.allocator.free(payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("user", root.get("role").?.string);
    try std.testing.expectEqualStrings("abcd", root.get("content").?.string);
}

test "buildPayloadWithinTokenBudget drops oldest non-system messages first" {
    var wire_messages = std.ArrayList([]u8).empty;
    defer {
        for (wire_messages.items) |item| std.testing.allocator.free(item);
        wire_messages.deinit(std.testing.allocator);
    }

    try wire_messages.append(
        std.testing.allocator,
        try buildRoleContentMessageJson(std.testing.allocator, "system", "policy"),
    );
    try wire_messages.append(
        std.testing.allocator,
        try buildRoleContentMessageJson(std.testing.allocator, "user", "11111111111111111111"),
    );
    try wire_messages.append(
        std.testing.allocator,
        try buildRoleContentMessageJson(std.testing.allocator, "assistant", "22222222222222222222"),
    );

    const no_tools_policy = tool_runtime.Policy{ .workspace_root = "" };
    const payload_with_three = try buildChatCompletionsPayloadWithTools(
        std.testing.allocator,
        "gpt-4o-mini",
        wire_messages.items,
        &no_tools_policy,
        "auto",
    );
    defer std.testing.allocator.free(payload_with_three);

    const two_messages = [_][]const u8{
        wire_messages.items[0],
        wire_messages.items[2],
    };
    const payload_with_two = try buildChatCompletionsPayloadWithTools(
        std.testing.allocator,
        "gpt-4o-mini",
        &two_messages,
        &no_tools_policy,
        "auto",
    );
    defer std.testing.allocator.free(payload_with_two);

    const estimate_three = estimateInputTokens(payload_with_three.len);
    const estimate_two = estimateInputTokens(payload_with_two.len);
    try std.testing.expect(estimate_three > estimate_two);

    const payload = try buildPayloadWithinTokenBudget(
        std.testing.allocator,
        "gpt-4o-mini",
        &wire_messages,
        &no_tools_policy,
        "auto",
        estimate_three - 1,
    );
    defer std.testing.allocator.free(payload);

    try std.testing.expectEqual(@as(usize, 2), wire_messages.items.len);
    try std.testing.expect(std.mem.indexOf(u8, payload, "22222222222222222222") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "11111111111111111111") == null);
}
