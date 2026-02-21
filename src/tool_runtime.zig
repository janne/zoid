const std = @import("std");
const config_runtime = @import("config_runtime.zig");
const http_client = @import("http_client.zig");
const lua_runner = @import("lua_runner.zig");
const workspace_fs = @import("workspace_fs.zig");

pub const sandbox_mode: []const u8 = "workspace-write";
pub const enabled_tools = [_][]const u8{
    "filesystem_read",
    "filesystem_write",
    "filesystem_delete",
    "lua_execute",
    "config",
    "http_get",
    "http_post",
    "http_put",
    "http_delete",
};
pub const disabled_tools = [_][]const u8{};
pub const default_max_read_bytes: usize = 128 * 1024;
pub const max_allowed_read_bytes: usize = 1024 * 1024;
pub const max_allowed_http_response_bytes: usize = 1024 * 1024;

pub const Policy = struct {
    workspace_root: []u8,
    config_path_override: ?[]const u8 = null,

    pub fn initForCurrentWorkspace(allocator: std.mem.Allocator) !Policy {
        const cwd = try std.process.getCwdAlloc(allocator);
        defer allocator.free(cwd);
        return initForWorkspaceRoot(allocator, cwd);
    }

    pub fn initForWorkspaceRoot(allocator: std.mem.Allocator, workspace_root: []const u8) !Policy {
        const canonical_root = try std.fs.cwd().realpathAlloc(allocator, workspace_root);
        return .{
            .workspace_root = canonical_root,
        };
    }

    pub fn deinit(self: *Policy, allocator: std.mem.Allocator) void {
        allocator.free(self.workspace_root);
    }
};

pub fn buildPolicyJson(allocator: std.mem.Allocator, policy: *const Policy) ![]u8 {
    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();

    const writer = &output.writer;
    try writer.writeAll("{\"sandbox_mode\":");
    try writeJsonString(allocator, writer, sandbox_mode);
    try writer.writeAll(",\"writable_roots\":[");
    try writeJsonString(allocator, writer, policy.workspace_root);
    try writer.writeAll("],\"tools_enabled\":[");
    for (enabled_tools, 0..) |tool_name, index| {
        if (index != 0) try writer.writeAll(",");
        try writeJsonString(allocator, writer, tool_name);
    }
    try writer.writeAll("],\"tools_disabled\":[");
    for (disabled_tools, 0..) |tool_name, index| {
        if (index != 0) try writer.writeAll(",");
        try writeJsonString(allocator, writer, tool_name);
    }
    try writer.writeAll("]}");

    return output.toOwnedSlice();
}

pub fn executeToolCall(
    allocator: std.mem.Allocator,
    policy: *const Policy,
    tool_name: []const u8,
    arguments_json: []const u8,
) ![]u8 {
    if (std.mem.eql(u8, tool_name, "filesystem_read")) {
        return executeFilesystemRead(allocator, policy, arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "filesystem_write")) {
        return executeFilesystemWrite(allocator, policy, arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "filesystem_delete")) {
        return executeFilesystemDelete(allocator, policy, arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "lua_execute")) {
        return executeLuaExecute(allocator, policy, arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "config")) {
        return executeConfig(allocator, policy, arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "http_get")) {
        return executeHttpGet(allocator, arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "http_post")) {
        return executeHttpPost(allocator, arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "http_put")) {
        return executeHttpPut(allocator, arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "http_delete")) {
        return executeHttpDelete(allocator, arguments_json);
    }
    return error.ToolDisabled;
}

pub fn buildErrorResult(allocator: std.mem.Allocator, error_name: []const u8) ![]u8 {
    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();

    const writer = &output.writer;
    try writer.writeAll("{\"ok\":false,\"error\":");
    try writeJsonString(allocator, writer, error_name);
    try writer.writeAll("}");

    return output.toOwnedSlice();
}

fn executeFilesystemRead(
    allocator: std.mem.Allocator,
    policy: *const Policy,
    arguments_json: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{});
    defer parsed.deinit();

    const root_object = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidToolArguments,
    };

    const requested_path = switch (root_object.get("path") orelse return error.InvalidToolArguments) {
        .string => |value| value,
        else => return error.InvalidToolArguments,
    };

    var max_bytes: usize = default_max_read_bytes;
    if (root_object.get("max_bytes")) |max_bytes_value| {
        max_bytes = switch (max_bytes_value) {
            .integer => |value| blk: {
                if (value <= 0) return error.InvalidToolArguments;
                const converted = std.math.cast(usize, value) orelse return error.InvalidToolArguments;
                break :blk converted;
            },
            else => return error.InvalidToolArguments,
        };
        if (max_bytes > max_allowed_read_bytes) return error.InvalidToolArguments;
    }

    const read_result = try workspace_fs.readFileAlloc(
        allocator,
        policy.workspace_root,
        requested_path,
        max_bytes,
    );
    defer read_result.deinit(allocator);

    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();

    const writer = &output.writer;
    try writer.writeAll("{\"ok\":true,\"tool\":\"filesystem_read\",\"path\":");
    try writeJsonString(allocator, writer, read_result.path);
    try writer.writeAll(",\"content\":");
    try writeJsonString(allocator, writer, read_result.content);
    try writer.writeAll("}");

    return output.toOwnedSlice();
}

fn executeFilesystemWrite(
    allocator: std.mem.Allocator,
    policy: *const Policy,
    arguments_json: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{});
    defer parsed.deinit();

    const root_object = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidToolArguments,
    };

    const requested_path = switch (root_object.get("path") orelse return error.InvalidToolArguments) {
        .string => |value| value,
        else => return error.InvalidToolArguments,
    };

    const content = switch (root_object.get("content") orelse return error.InvalidToolArguments) {
        .string => |value| value,
        else => return error.InvalidToolArguments,
    };

    const write_result = try workspace_fs.writeFile(
        allocator,
        policy.workspace_root,
        requested_path,
        content,
    );
    defer write_result.deinit(allocator);

    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();

    const writer = &output.writer;
    try writer.writeAll("{\"ok\":true,\"tool\":\"filesystem_write\",\"path\":");
    try writeJsonString(allocator, writer, write_result.path);
    try writer.writeAll(",\"bytes_written\":");
    try writer.print("{d}", .{write_result.bytes_written});
    try writer.writeAll("}");

    return output.toOwnedSlice();
}

fn executeFilesystemDelete(
    allocator: std.mem.Allocator,
    policy: *const Policy,
    arguments_json: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{});
    defer parsed.deinit();

    const root_object = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidToolArguments,
    };

    const requested_path = switch (root_object.get("path") orelse return error.InvalidToolArguments) {
        .string => |value| value,
        else => return error.InvalidToolArguments,
    };

    const delete_result = try workspace_fs.deleteFile(
        allocator,
        policy.workspace_root,
        requested_path,
    );
    defer delete_result.deinit(allocator);

    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();

    const writer = &output.writer;
    try writer.writeAll("{\"ok\":true,\"tool\":\"filesystem_delete\",\"path\":");
    try writeJsonString(allocator, writer, delete_result.path);
    try writer.writeAll(",\"deleted\":true}");

    return output.toOwnedSlice();
}

fn executeLuaExecute(
    allocator: std.mem.Allocator,
    policy: *const Policy,
    arguments_json: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{});
    defer parsed.deinit();

    const root_object = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidToolArguments,
    };

    const requested_path = switch (root_object.get("path") orelse return error.InvalidToolArguments) {
        .string => |value| value,
        else => return error.InvalidToolArguments,
    };

    const resolved_path = try workspace_fs.resolveAllowedReadPath(
        allocator,
        policy.workspace_root,
        requested_path,
    );
    defer allocator.free(resolved_path);

    if (!std.mem.eql(u8, std.fs.path.extension(resolved_path), ".lua")) {
        return error.InvalidToolArguments;
    }

    var execution = try lua_runner.executeLuaFileCaptureOutputTool(allocator, resolved_path, .{
        .workspace_root = policy.workspace_root,
        .max_read_bytes = max_allowed_read_bytes,
        .max_http_response_bytes = max_allowed_http_response_bytes,
        .config_path_override = policy.config_path_override,
    });
    defer execution.deinit(allocator);

    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();

    const writer = &output.writer;
    const ok = execution.status == .ok;
    try writer.writeAll("{\"ok\":");
    try writer.writeAll(if (ok) "true" else "false");
    try writer.writeAll(",\"tool\":\"lua_execute\",\"path\":");
    try writeJsonString(allocator, writer, resolved_path);
    try writer.writeAll(",\"stdout\":");
    try writeJsonString(allocator, writer, execution.stdout);
    try writer.writeAll(",\"stderr\":");
    try writeJsonString(allocator, writer, execution.stderr);
    try writer.writeAll(",\"stdout_truncated\":");
    try writer.writeAll(if (execution.stdout_truncated) "true" else "false");
    try writer.writeAll(",\"stderr_truncated\":");
    try writer.writeAll(if (execution.stderr_truncated) "true" else "false");
    if (!ok) {
        const error_name = switch (execution.status) {
            .ok => unreachable,
            .state_init_failed => "LuaStateInitFailed",
            .load_failed => "LuaLoadFailed",
            .runtime_failed => "LuaRuntimeFailed",
        };
        try writer.writeAll(",\"error\":");
        try writeJsonString(allocator, writer, error_name);
    }
    try writer.writeAll("}");

    return output.toOwnedSlice();
}

fn executeConfig(
    allocator: std.mem.Allocator,
    policy: *const Policy,
    arguments_json: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{});
    defer parsed.deinit();

    const root_object = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidToolArguments,
    };

    const action = switch (root_object.get("action") orelse return error.InvalidToolArguments) {
        .string => |value| value,
        else => return error.InvalidToolArguments,
    };

    const request: config_runtime.Request = blk: {
        if (std.mem.eql(u8, action, "list")) {
            if (root_object.get("key") != null or root_object.get("value") != null) {
                return error.InvalidToolArguments;
            }
            break :blk .list;
        }
        if (std.mem.eql(u8, action, "get")) {
            if (root_object.get("value") != null) return error.InvalidToolArguments;
            const key = try requireStringProperty(root_object, "key");
            break :blk .{ .get = key };
        }
        if (std.mem.eql(u8, action, "set")) {
            const key = try requireStringProperty(root_object, "key");
            const value = try requireStringProperty(root_object, "value");
            break :blk .{ .set = .{ .key = key, .value = value } };
        }
        if (std.mem.eql(u8, action, "unset")) {
            if (root_object.get("value") != null) return error.InvalidToolArguments;
            const key = try requireStringProperty(root_object, "key");
            break :blk .{ .unset = key };
        }
        return error.InvalidToolArguments;
    };

    var result = try config_runtime.execute(
        allocator,
        .{ .config_path_override = policy.config_path_override },
        request,
    );
    defer result.deinit(allocator);

    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;

    try writer.writeAll("{\"ok\":true,\"tool\":\"config\",\"action\":");
    try writeJsonString(allocator, writer, action);
    switch (result) {
        .list => |keys| {
            try writer.writeAll(",\"keys\":[");
            for (keys, 0..) |key, index| {
                if (index != 0) try writer.writeAll(",");
                try writeJsonString(allocator, writer, key);
            }
            try writer.writeAll("]}");
        },
        .get => |maybe_value| {
            try writer.writeAll(",\"key\":");
            try writeJsonString(allocator, writer, switch (request) {
                .get => |key| key,
                else => unreachable,
            });
            try writer.writeAll(",\"found\":");
            try writer.writeAll(if (maybe_value != null) "true" else "false");
            try writer.writeAll(",\"value\":");
            if (maybe_value) |value| {
                try writeJsonString(allocator, writer, value);
            } else {
                try writer.writeAll("null");
            }
            try writer.writeAll("}");
        },
        .set => {
            try writer.writeAll(",\"key\":");
            try writeJsonString(allocator, writer, switch (request) {
                .set => |set_request| set_request.key,
                else => unreachable,
            });
            try writer.writeAll(",\"updated\":true}");
        },
        .unset => |removed| {
            try writer.writeAll(",\"key\":");
            try writeJsonString(allocator, writer, switch (request) {
                .unset => |key| key,
                else => unreachable,
            });
            try writer.writeAll(",\"removed\":");
            try writer.writeAll(if (removed) "true" else "false");
            try writer.writeAll("}");
        },
    }

    return output.toOwnedSlice();
}

fn requireStringProperty(
    root_object: std.json.ObjectMap,
    property_name: []const u8,
) ![]const u8 {
    return switch (root_object.get(property_name) orelse return error.InvalidToolArguments) {
        .string => |value| value,
        else => return error.InvalidToolArguments,
    };
}

fn executeHttpGet(allocator: std.mem.Allocator, arguments_json: []const u8) ![]u8 {
    return executeHttpRequestTool(allocator, "http_get", .GET, false, arguments_json);
}

fn executeHttpPost(allocator: std.mem.Allocator, arguments_json: []const u8) ![]u8 {
    return executeHttpRequestTool(allocator, "http_post", .POST, true, arguments_json);
}

fn executeHttpPut(allocator: std.mem.Allocator, arguments_json: []const u8) ![]u8 {
    return executeHttpRequestTool(allocator, "http_put", .PUT, true, arguments_json);
}

fn executeHttpDelete(allocator: std.mem.Allocator, arguments_json: []const u8) ![]u8 {
    return executeHttpRequestTool(allocator, "http_delete", .DELETE, false, arguments_json);
}

fn executeHttpRequestTool(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    method: std.http.Method,
    allows_body: bool,
    arguments_json: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{});
    defer parsed.deinit();

    const root_object = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidToolArguments,
    };

    const uri = switch (root_object.get("uri") orelse return error.InvalidToolArguments) {
        .string => |value| value,
        else => return error.InvalidToolArguments,
    };

    var payload: ?[]const u8 = null;
    if (root_object.get("body")) |body_value| {
        if (!allows_body) return error.InvalidToolArguments;
        payload = switch (body_value) {
            .string => |value| value,
            else => return error.InvalidToolArguments,
        };
    }

    var result = try http_client.executeRequest(
        allocator,
        method,
        uri,
        payload,
        max_allowed_http_response_bytes,
    );
    defer result.deinit(allocator);

    const http_ok = result.status_code >= 200 and result.status_code < 300;

    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();

    const writer = &output.writer;
    try writer.writeAll("{\"ok\":");
    try writer.writeAll(if (http_ok) "true" else "false");
    try writer.writeAll(",\"tool\":");
    try writeJsonString(allocator, writer, tool_name);
    try writer.writeAll(",\"uri\":");
    try writeJsonString(allocator, writer, uri);
    try writer.writeAll(",\"status\":");
    try writer.print("{d}", .{result.status_code});
    try writer.writeAll(",\"body\":");
    try writeJsonString(allocator, writer, result.body);
    try writer.writeAll("}");
    return output.toOwnedSlice();
}

fn writeJsonString(allocator: std.mem.Allocator, writer: *std.Io.Writer, value: []const u8) !void {
    const escaped = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(escaped);
    try writer.writeAll(escaped);
}

test "buildPolicyJson emits required fields" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    var policy = try Policy.initForWorkspaceRoot(std.testing.allocator, tmp_path);
    defer policy.deinit(std.testing.allocator);

    const json = try buildPolicyJson(std.testing.allocator, &policy);
    defer std.testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();

    const root_object = parsed.value.object;
    try std.testing.expectEqualStrings("workspace-write", root_object.get("sandbox_mode").?.string);
    try std.testing.expectEqualStrings(policy.workspace_root, root_object.get("writable_roots").?.array.items[0].string);
    try std.testing.expectEqual(@as(usize, 9), root_object.get("tools_enabled").?.array.items.len);
}

test "filesystem write and read stay within workspace root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    var policy = try Policy.initForWorkspaceRoot(std.testing.allocator, tmp_path);
    defer policy.deinit(std.testing.allocator);

    const write_result = try executeToolCall(
        std.testing.allocator,
        &policy,
        "filesystem_write",
        "{\"path\":\"notes.txt\",\"content\":\"hello\"}",
    );
    defer std.testing.allocator.free(write_result);

    const read_result = try executeToolCall(
        std.testing.allocator,
        &policy,
        "filesystem_read",
        "{\"path\":\"notes.txt\"}",
    );
    defer std.testing.allocator.free(read_result);

    var parsed_read = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, read_result, .{});
    defer parsed_read.deinit();

    const read_object = parsed_read.value.object;
    try std.testing.expect(read_object.get("ok").?.bool);
    try std.testing.expectEqualStrings("hello", read_object.get("content").?.string);
}

test "filesystem write rejects traversal outside workspace root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    var policy = try Policy.initForWorkspaceRoot(std.testing.allocator, tmp_path);
    defer policy.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.PathNotAllowed,
        executeToolCall(
            std.testing.allocator,
            &policy,
            "filesystem_write",
            "{\"path\":\"../outside.txt\",\"content\":\"blocked\"}",
        ),
    );
}

test "filesystem delete removes file within workspace root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    var policy = try Policy.initForWorkspaceRoot(std.testing.allocator, tmp_path);
    defer policy.deinit(std.testing.allocator);

    const write_result = try executeToolCall(
        std.testing.allocator,
        &policy,
        "filesystem_write",
        "{\"path\":\"to-delete.txt\",\"content\":\"trash\"}",
    );
    defer std.testing.allocator.free(write_result);

    const delete_result = try executeToolCall(
        std.testing.allocator,
        &policy,
        "filesystem_delete",
        "{\"path\":\"to-delete.txt\"}",
    );
    defer std.testing.allocator.free(delete_result);

    var parsed_delete = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, delete_result, .{});
    defer parsed_delete.deinit();

    const delete_object = parsed_delete.value.object;
    try std.testing.expect(delete_object.get("ok").?.bool);
    try std.testing.expectEqualStrings("filesystem_delete", delete_object.get("tool").?.string);
    try std.testing.expect(delete_object.get("deleted").?.bool);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(delete_object.get("path").?.string, .{}));
}

test "filesystem delete rejects traversal outside workspace root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("workspace");

    const outside_file = try tmp.dir.createFile("outside.txt", .{});
    defer outside_file.close();
    try outside_file.writeAll("keep me");

    const workspace_path = try tmp.dir.realpathAlloc(std.testing.allocator, "workspace");
    defer std.testing.allocator.free(workspace_path);

    var policy = try Policy.initForWorkspaceRoot(std.testing.allocator, workspace_path);
    defer policy.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.PathNotAllowed,
        executeToolCall(
            std.testing.allocator,
            &policy,
            "filesystem_delete",
            "{\"path\":\"../outside.txt\"}",
        ),
    );
}

test "lua execute runs script inside workspace root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("ok.lua", .{});
    defer file.close();
    try file.writeAll(
        \\local x = 1 + 2
        \\assert(x == 3)
        \\print("ok")
        \\
    );

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    var policy = try Policy.initForWorkspaceRoot(std.testing.allocator, tmp_path);
    defer policy.deinit(std.testing.allocator);

    const result = try executeToolCall(
        std.testing.allocator,
        &policy,
        "lua_execute",
        "{\"path\":\"ok.lua\"}",
    );
    defer std.testing.allocator.free(result);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();

    const root_object = parsed.value.object;
    try std.testing.expect(root_object.get("ok").?.bool);
    try std.testing.expectEqualStrings("lua_execute", root_object.get("tool").?.string);
    try std.testing.expectEqualStrings("ok\n", root_object.get("stdout").?.string);
    try std.testing.expectEqualStrings("", root_object.get("stderr").?.string);
    try std.testing.expect(!root_object.get("stdout_truncated").?.bool);
    try std.testing.expect(!root_object.get("stderr_truncated").?.bool);
    try std.testing.expect(root_object.get("error") == null);
}

test "lua execute sandbox exposes zoid fs and blocks os" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("sandbox.lua", .{});
    defer file.close();
    try file.writeAll(
        \\local file = zoid.file("sandbox.txt")
        \\file:write("hello")
        \\print(file:read())
        \\file:delete()
        \\return os.getenv("HOME")
        \\
    );

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    var policy = try Policy.initForWorkspaceRoot(std.testing.allocator, tmp_path);
    defer policy.deinit(std.testing.allocator);

    const result = try executeToolCall(
        std.testing.allocator,
        &policy,
        "lua_execute",
        "{\"path\":\"sandbox.lua\"}",
    );
    defer std.testing.allocator.free(result);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();

    const root_object = parsed.value.object;
    try std.testing.expect(!root_object.get("ok").?.bool);
    try std.testing.expectEqualStrings("hello\n", root_object.get("stdout").?.string);
    try std.testing.expect(std.mem.indexOf(u8, root_object.get("stderr").?.string, "os") != null);
    try std.testing.expectEqualStrings("LuaRuntimeFailed", root_object.get("error").?.string);

    const deleted_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_path, "sandbox.txt" });
    defer std.testing.allocator.free(deleted_path);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(deleted_path, .{}));
}

test "lua execute sandbox exposes zoid uri handles" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("uri.lua", .{});
    defer file.close();
    try file.writeAll(
        \\local handle = zoid.uri("https://example.com")
        \\assert(type(handle.get) == "function")
        \\assert(type(handle.post) == "function")
        \\assert(type(handle.put) == "function")
        \\assert(type(handle.delete) == "function")
        \\print("ok")
        \\
    );

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    var policy = try Policy.initForWorkspaceRoot(std.testing.allocator, tmp_path);
    defer policy.deinit(std.testing.allocator);

    const result = try executeToolCall(
        std.testing.allocator,
        &policy,
        "lua_execute",
        "{\"path\":\"uri.lua\"}",
    );
    defer std.testing.allocator.free(result);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();

    const root_object = parsed.value.object;
    try std.testing.expect(root_object.get("ok").?.bool);
    try std.testing.expectEqualStrings("ok\n", root_object.get("stdout").?.string);
    try std.testing.expectEqualStrings("", root_object.get("stderr").?.string);
}

test "config tool supports list/get/set/unset" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);
    const config_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_path, "config.json" });
    defer std.testing.allocator.free(config_path);

    var policy = try Policy.initForWorkspaceRoot(std.testing.allocator, tmp_path);
    defer policy.deinit(std.testing.allocator);
    policy.config_path_override = config_path;

    const set_result = try executeToolCall(
        std.testing.allocator,
        &policy,
        "config",
        "{\"action\":\"set\",\"key\":\"OPENAI_API_KEY\",\"value\":\"secret\"}",
    );
    defer std.testing.allocator.free(set_result);

    const get_result = try executeToolCall(
        std.testing.allocator,
        &policy,
        "config",
        "{\"action\":\"get\",\"key\":\"OPENAI_API_KEY\"}",
    );
    defer std.testing.allocator.free(get_result);

    const list_result = try executeToolCall(
        std.testing.allocator,
        &policy,
        "config",
        "{\"action\":\"list\"}",
    );
    defer std.testing.allocator.free(list_result);

    const unset_result = try executeToolCall(
        std.testing.allocator,
        &policy,
        "config",
        "{\"action\":\"unset\",\"key\":\"OPENAI_API_KEY\"}",
    );
    defer std.testing.allocator.free(unset_result);

    var parsed_set = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, set_result, .{});
    defer parsed_set.deinit();
    const set_object = parsed_set.value.object;
    try std.testing.expect(set_object.get("ok").?.bool);
    try std.testing.expectEqualStrings("config", set_object.get("tool").?.string);
    try std.testing.expectEqualStrings("set", set_object.get("action").?.string);
    try std.testing.expect(set_object.get("updated").?.bool);

    var parsed_get = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, get_result, .{});
    defer parsed_get.deinit();
    const get_object = parsed_get.value.object;
    try std.testing.expect(get_object.get("ok").?.bool);
    try std.testing.expectEqualStrings("get", get_object.get("action").?.string);
    try std.testing.expect(get_object.get("found").?.bool);
    try std.testing.expectEqualStrings("secret", get_object.get("value").?.string);

    var parsed_list = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, list_result, .{});
    defer parsed_list.deinit();
    const list_object = parsed_list.value.object;
    try std.testing.expect(list_object.get("ok").?.bool);
    try std.testing.expectEqualStrings("list", list_object.get("action").?.string);
    const keys = list_object.get("keys").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), keys.len);
    try std.testing.expectEqualStrings("OPENAI_API_KEY", keys[0].string);

    var parsed_unset = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, unset_result, .{});
    defer parsed_unset.deinit();
    const unset_object = parsed_unset.value.object;
    try std.testing.expect(unset_object.get("ok").?.bool);
    try std.testing.expectEqualStrings("unset", unset_object.get("action").?.string);
    try std.testing.expect(unset_object.get("removed").?.bool);

    const get_missing_result = try executeToolCall(
        std.testing.allocator,
        &policy,
        "config",
        "{\"action\":\"get\",\"key\":\"OPENAI_API_KEY\"}",
    );
    defer std.testing.allocator.free(get_missing_result);

    var parsed_missing = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, get_missing_result, .{});
    defer parsed_missing.deinit();
    const missing_object = parsed_missing.value.object;
    try std.testing.expect(!missing_object.get("found").?.bool);
    try std.testing.expect(missing_object.get("value").? == .null);
}

test "config tool validates arguments" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);
    const config_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_path, "config.json" });
    defer std.testing.allocator.free(config_path);

    var policy = try Policy.initForWorkspaceRoot(std.testing.allocator, tmp_path);
    defer policy.deinit(std.testing.allocator);
    policy.config_path_override = config_path;

    try std.testing.expectError(
        error.InvalidToolArguments,
        executeToolCall(
            std.testing.allocator,
            &policy,
            "config",
            "{\"action\":\"get\"}",
        ),
    );

    try std.testing.expectError(
        error.InvalidToolArguments,
        executeToolCall(
            std.testing.allocator,
            &policy,
            "config",
            "{\"action\":\"list\",\"key\":\"unexpected\"}",
        ),
    );
}

test "lua execute reports runtime failure and stderr output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("fail.lua", .{});
    defer file.close();
    try file.writeAll(
        \\io.stderr:write("before boom\n")
        \\error("boom")
        \\
    );

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    var policy = try Policy.initForWorkspaceRoot(std.testing.allocator, tmp_path);
    defer policy.deinit(std.testing.allocator);

    const result = try executeToolCall(
        std.testing.allocator,
        &policy,
        "lua_execute",
        "{\"path\":\"fail.lua\"}",
    );
    defer std.testing.allocator.free(result);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();

    const root_object = parsed.value.object;
    try std.testing.expect(!root_object.get("ok").?.bool);
    try std.testing.expectEqualStrings("LuaRuntimeFailed", root_object.get("error").?.string);
    try std.testing.expect(std.mem.indexOf(u8, root_object.get("stderr").?.string, "before boom") != null);
    try std.testing.expect(std.mem.indexOf(u8, root_object.get("stderr").?.string, "boom") != null);
}

test "lua execute rejects traversal outside workspace root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("workspace");

    const outside_file = try tmp.dir.createFile("outside.lua", .{});
    defer outside_file.close();
    try outside_file.writeAll("return 1\n");

    const workspace_path = try tmp.dir.realpathAlloc(std.testing.allocator, "workspace");
    defer std.testing.allocator.free(workspace_path);

    var policy = try Policy.initForWorkspaceRoot(std.testing.allocator, workspace_path);
    defer policy.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.PathNotAllowed,
        executeToolCall(
            std.testing.allocator,
            &policy,
            "lua_execute",
            "{\"path\":\"../outside.lua\"}",
        ),
    );
}

const ToolRuntimeHttpExpectation = struct {
    method: []const u8,
    target: []const u8,
    body: []const u8,
    status_code: u16,
    response_body: []const u8,
};

const ToolRuntimeHttpServerContext = struct {
    server: std.net.Server,
    expected: []const ToolRuntimeHttpExpectation,
    completed_requests: usize = 0,
    failure: ?anyerror = null,
};

const ParsedToolRuntimeHttpRequest = struct {
    method: []const u8,
    target: []const u8,
    body: []const u8,
};

fn parseToolRuntimeHttpRequest(request_bytes: []const u8) !ParsedToolRuntimeHttpRequest {
    const header_end = std.mem.indexOf(u8, request_bytes, "\r\n\r\n") orelse return error.InvalidHttpRequest;
    const headers = request_bytes[0..header_end];
    const body = request_bytes[header_end + 4 ..];

    const request_line_end = std.mem.indexOf(u8, headers, "\r\n") orelse return error.InvalidHttpRequest;
    const request_line = headers[0..request_line_end];

    var parts = std.mem.splitScalar(u8, request_line, ' ');
    const method = parts.next() orelse return error.InvalidHttpRequest;
    const target = parts.next() orelse return error.InvalidHttpRequest;
    _ = parts.next() orelse return error.InvalidHttpRequest;

    return .{
        .method = method,
        .target = target,
        .body = body,
    };
}

fn parseToolRuntimeContentLength(headers: []const u8) !usize {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        const separator = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..separator], " \t");
        if (!std.ascii.eqlIgnoreCase(key, "content-length")) continue;

        const value = std.mem.trim(u8, line[separator + 1 ..], " \t");
        if (value.len == 0) return error.InvalidContentLength;
        return std.fmt.parseInt(usize, value, 10);
    }

    return 0;
}

fn runToolRuntimeHttpServer(context: *ToolRuntimeHttpServerContext) void {
    defer context.server.deinit();

    while (context.completed_requests < context.expected.len) {
        var connection = context.server.accept() catch |err| {
            context.failure = err;
            return;
        };
        defer connection.stream.close();

        var request_buffer: [8192]u8 = undefined;
        var read_len: usize = 0;
        var expected_total_len: ?usize = null;

        while (true) {
            if (read_len >= request_buffer.len) {
                context.failure = error.StreamTooLong;
                return;
            }

            const bytes_read = connection.stream.read(request_buffer[read_len..]) catch |err| {
                context.failure = err;
                return;
            };
            if (bytes_read == 0) break;
            read_len += bytes_read;

            if (expected_total_len == null) {
                if (std.mem.indexOf(u8, request_buffer[0..read_len], "\r\n\r\n")) |header_end| {
                    const content_length = parseToolRuntimeContentLength(request_buffer[0..header_end]) catch |err| {
                        context.failure = err;
                        return;
                    };
                    expected_total_len = header_end + 4 + content_length;
                }
            }

            if (expected_total_len) |total_len| {
                if (read_len >= total_len) break;
            }
        }

        const total_len = expected_total_len orelse {
            context.failure = error.InvalidHttpRequest;
            return;
        };
        if (read_len < total_len) {
            context.failure = error.UnexpectedEndOfStream;
            return;
        }

        const parsed = parseToolRuntimeHttpRequest(request_buffer[0..total_len]) catch |err| {
            context.failure = err;
            return;
        };
        const expected = context.expected[context.completed_requests];

        if (!std.mem.eql(u8, parsed.method, expected.method) or
            !std.mem.eql(u8, parsed.target, expected.target) or
            !std.mem.eql(u8, parsed.body, expected.body))
        {
            context.failure = error.UnexpectedRequest;
            return;
        }

        var response_header_buffer: [256]u8 = undefined;
        const response_header = std.fmt.bufPrint(
            &response_header_buffer,
            "HTTP/1.1 {d} OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
            .{ expected.status_code, expected.response_body.len },
        ) catch {
            context.failure = error.ResponseBuildFailed;
            return;
        };

        connection.stream.writeAll(response_header) catch |err| {
            context.failure = err;
            return;
        };
        connection.stream.writeAll(expected.response_body) catch |err| {
            context.failure = err;
            return;
        };

        context.completed_requests += 1;
    }
}

test "http tools perform get/post/put/delete requests" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    var policy = try Policy.initForWorkspaceRoot(std.testing.allocator, tmp_path);
    defer policy.deinit(std.testing.allocator);

    var listen_address = try std.net.Address.parseIp4("127.0.0.1", 0);
    const server = try listen_address.listen(.{ .reuse_address = true });

    const expectations = [_]ToolRuntimeHttpExpectation{
        .{ .method = "GET", .target = "/get", .body = "", .status_code = 200, .response_body = "g" },
        .{ .method = "POST", .target = "/post", .body = "alpha=1", .status_code = 201, .response_body = "p" },
        .{ .method = "PUT", .target = "/put", .body = "update-me", .status_code = 202, .response_body = "u" },
        .{ .method = "DELETE", .target = "/delete", .body = "", .status_code = 204, .response_body = "" },
    };

    var context = ToolRuntimeHttpServerContext{
        .server = server,
        .expected = &expectations,
    };

    const server_thread = std.Thread.spawn(.{}, runToolRuntimeHttpServer, .{&context}) catch |err| {
        context.server.deinit();
        return err;
    };
    defer server_thread.join();

    const port = context.server.listen_address.getPort();
    const get_uri = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/get", .{port});
    defer std.testing.allocator.free(get_uri);
    const post_uri = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/post", .{port});
    defer std.testing.allocator.free(post_uri);
    const put_uri = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/put", .{port});
    defer std.testing.allocator.free(put_uri);
    const delete_uri = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/delete", .{port});
    defer std.testing.allocator.free(delete_uri);

    const get_args = try std.fmt.allocPrint(std.testing.allocator, "{{\"uri\":\"{s}\"}}", .{get_uri});
    defer std.testing.allocator.free(get_args);
    const post_args = try std.fmt.allocPrint(std.testing.allocator, "{{\"uri\":\"{s}\",\"body\":\"alpha=1\"}}", .{post_uri});
    defer std.testing.allocator.free(post_args);
    const put_args = try std.fmt.allocPrint(std.testing.allocator, "{{\"uri\":\"{s}\",\"body\":\"update-me\"}}", .{put_uri});
    defer std.testing.allocator.free(put_args);
    const delete_args = try std.fmt.allocPrint(std.testing.allocator, "{{\"uri\":\"{s}\"}}", .{delete_uri});
    defer std.testing.allocator.free(delete_args);

    const get_result = try executeToolCall(std.testing.allocator, &policy, "http_get", get_args);
    defer std.testing.allocator.free(get_result);
    const post_result = try executeToolCall(std.testing.allocator, &policy, "http_post", post_args);
    defer std.testing.allocator.free(post_result);
    const put_result = try executeToolCall(std.testing.allocator, &policy, "http_put", put_args);
    defer std.testing.allocator.free(put_result);
    const delete_result = try executeToolCall(std.testing.allocator, &policy, "http_delete", delete_args);
    defer std.testing.allocator.free(delete_result);

    var parsed_get = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, get_result, .{});
    defer parsed_get.deinit();
    const get_object = parsed_get.value.object;
    try std.testing.expect(get_object.get("ok").?.bool);
    try std.testing.expectEqualStrings("http_get", get_object.get("tool").?.string);
    try std.testing.expectEqualStrings(get_uri, get_object.get("uri").?.string);
    try std.testing.expectEqual(@as(i64, 200), get_object.get("status").?.integer);
    try std.testing.expectEqualStrings("g", get_object.get("body").?.string);

    var parsed_post = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, post_result, .{});
    defer parsed_post.deinit();
    const post_object = parsed_post.value.object;
    try std.testing.expect(post_object.get("ok").?.bool);
    try std.testing.expectEqualStrings("http_post", post_object.get("tool").?.string);
    try std.testing.expectEqualStrings(post_uri, post_object.get("uri").?.string);
    try std.testing.expectEqual(@as(i64, 201), post_object.get("status").?.integer);
    try std.testing.expectEqualStrings("p", post_object.get("body").?.string);

    var parsed_put = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, put_result, .{});
    defer parsed_put.deinit();
    const put_object = parsed_put.value.object;
    try std.testing.expect(put_object.get("ok").?.bool);
    try std.testing.expectEqualStrings("http_put", put_object.get("tool").?.string);
    try std.testing.expectEqualStrings(put_uri, put_object.get("uri").?.string);
    try std.testing.expectEqual(@as(i64, 202), put_object.get("status").?.integer);
    try std.testing.expectEqualStrings("u", put_object.get("body").?.string);

    var parsed_delete = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, delete_result, .{});
    defer parsed_delete.deinit();
    const delete_object = parsed_delete.value.object;
    try std.testing.expect(delete_object.get("ok").?.bool);
    try std.testing.expectEqualStrings("http_delete", delete_object.get("tool").?.string);
    try std.testing.expectEqualStrings(delete_uri, delete_object.get("uri").?.string);
    try std.testing.expectEqual(@as(i64, 204), delete_object.get("status").?.integer);
    try std.testing.expectEqualStrings("", delete_object.get("body").?.string);

    try std.testing.expect(context.failure == null);
    try std.testing.expectEqual(expectations.len, context.completed_requests);
}

test "http tools reject unsupported uri scheme" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    var policy = try Policy.initForWorkspaceRoot(std.testing.allocator, tmp_path);
    defer policy.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.UnsupportedUriScheme,
        executeToolCall(
            std.testing.allocator,
            &policy,
            "http_get",
            "{\"uri\":\"ftp://example.com/file.txt\"}",
        ),
    );
}

test "http get and delete reject body argument" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    var policy = try Policy.initForWorkspaceRoot(std.testing.allocator, tmp_path);
    defer policy.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.InvalidToolArguments,
        executeToolCall(
            std.testing.allocator,
            &policy,
            "http_get",
            "{\"uri\":\"https://example.com\",\"body\":\"unexpected\"}",
        ),
    );

    try std.testing.expectError(
        error.InvalidToolArguments,
        executeToolCall(
            std.testing.allocator,
            &policy,
            "http_delete",
            "{\"uri\":\"https://example.com\",\"body\":\"unexpected\"}",
        ),
    );
}

test "shell command tools are disabled" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    var policy = try Policy.initForWorkspaceRoot(std.testing.allocator, tmp_path);
    defer policy.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.ToolDisabled,
        executeToolCall(
            std.testing.allocator,
            &policy,
            "shell_command",
            "{\"command\":\"pwd\"}",
        ),
    );

    try std.testing.expectError(
        error.ToolDisabled,
        executeToolCall(
            std.testing.allocator,
            &policy,
            "exec",
            "{\"command\":\"pwd\"}",
        ),
    );
}
