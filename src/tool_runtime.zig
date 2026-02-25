const std = @import("std");
const browser_tool = @import("browser_tool.zig");
const config_runtime = @import("config_runtime.zig");
const http_client = @import("http_client.zig");
const lua_runner = @import("lua_runner.zig");
const scheduler_runtime = @import("scheduler_runtime.zig");
const scheduler_store = @import("scheduler_store.zig");
const workspace_fs = @import("workspace_fs.zig");
const c = @cImport({
    @cInclude("time.h");
});

pub const sandbox_mode: []const u8 = "workspace-write";
pub const enabled_tools = [_][]const u8{
    "filesystem_read",
    "filesystem_list",
    "filesystem_grep",
    "filesystem_write",
    "filesystem_mkdir",
    "filesystem_rmdir",
    "filesystem_delete",
    "lua_execute",
    "config",
    "jobs",
    "http_get",
    "http_post",
    "http_put",
    "http_delete",
    "datetime_now",
    "browser_automate",
};
pub const disabled_tools = [_][]const u8{};
pub const default_max_read_bytes: usize = 128 * 1024;
pub const max_allowed_read_bytes: usize = 1024 * 1024;
pub const default_grep_max_matches: usize = workspace_fs.default_max_grep_matches;
pub const max_allowed_grep_matches: usize = workspace_fs.max_allowed_grep_matches;
pub const max_allowed_http_response_bytes: usize = 1024 * 1024;
pub const default_lua_timeout_seconds: u32 = lua_runner.default_tool_execution_timeout_seconds;
pub const max_allowed_lua_timeout_seconds: u32 = lua_runner.max_tool_execution_timeout_seconds;
pub const default_browser_timeout_seconds: u32 = browser_tool.default_timeout_seconds;
pub const max_allowed_browser_timeout_seconds: u32 = browser_tool.max_timeout_seconds;

pub const Policy = struct {
    workspace_root: []u8,
    config_path_override: ?[]const u8 = null,
    allow_private_http_destinations: bool = false,
    browser_app_data_dir_override: ?[]const u8 = null,

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

pub const RequestContext = struct {
    request_chat_id: ?i64 = null,
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
    return executeToolCallWithContext(
        allocator,
        policy,
        .{},
        tool_name,
        arguments_json,
    );
}

pub fn executeToolCallWithContext(
    allocator: std.mem.Allocator,
    policy: *const Policy,
    request_context: RequestContext,
    tool_name: []const u8,
    arguments_json: []const u8,
) ![]u8 {
    if (std.mem.eql(u8, tool_name, "filesystem_read")) {
        return executeFilesystemRead(allocator, policy, arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "filesystem_list")) {
        return executeFilesystemList(allocator, policy, arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "filesystem_grep")) {
        return executeFilesystemGrep(allocator, policy, arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "filesystem_write")) {
        return executeFilesystemWrite(allocator, policy, arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "filesystem_mkdir")) {
        return executeFilesystemMkdir(allocator, policy, arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "filesystem_rmdir")) {
        return executeFilesystemRmdir(allocator, policy, arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "filesystem_delete")) {
        return executeFilesystemDelete(allocator, policy, arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "lua_execute")) {
        return executeLuaExecute(allocator, policy, request_context, arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "config")) {
        return executeConfig(allocator, policy, arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "jobs")) {
        return executeScheduler(allocator, policy, request_context, arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "http_get")) {
        return executeHttpGet(allocator, policy, arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "http_post")) {
        return executeHttpPost(allocator, policy, arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "http_put")) {
        return executeHttpPut(allocator, policy, arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "http_delete")) {
        return executeHttpDelete(allocator, policy, arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "datetime_now")) {
        return executeDateTimeNow(allocator, arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "browser_automate")) {
        return executeBrowserAutomate(allocator, policy, arguments_json);
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
    try writeWorkspacePathJson(allocator, writer, policy.workspace_root, read_result.path);
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
    try writeWorkspacePathJson(allocator, writer, policy.workspace_root, write_result.path);
    try writer.writeAll(",\"bytes_written\":");
    try writer.print("{d}", .{write_result.bytes_written});
    try writer.writeAll("}");

    return output.toOwnedSlice();
}

fn executeFilesystemList(
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

    var requested_path: []const u8 = ".";
    if (root_object.get("path")) |path_value| {
        requested_path = switch (path_value) {
            .string => |value| value,
            else => return error.InvalidToolArguments,
        };
    }

    var list_result = try workspace_fs.listDirectory(
        allocator,
        policy.workspace_root,
        requested_path,
    );
    defer list_result.deinit(allocator);

    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();

    const writer = &output.writer;
    try writer.writeAll("{\"ok\":true,\"tool\":\"filesystem_list\",\"path\":");
    try writeWorkspacePathJson(allocator, writer, policy.workspace_root, list_result.path);
    try writer.writeAll(",\"entries\":[");
    for (list_result.entries, 0..) |entry, index| {
        if (index != 0) try writer.writeAll(",");
        try writePathMetadataJson(allocator, writer, policy.workspace_root, &entry);
    }
    try writer.writeAll("]}");

    return output.toOwnedSlice();
}

fn executeFilesystemMkdir(
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

    const mkdir_result = try workspace_fs.createDirectory(
        allocator,
        policy.workspace_root,
        requested_path,
    );
    defer mkdir_result.deinit(allocator);

    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();

    const writer = &output.writer;
    try writer.writeAll("{\"ok\":true,\"tool\":\"filesystem_mkdir\",\"path\":");
    try writeWorkspacePathJson(allocator, writer, policy.workspace_root, mkdir_result.path);
    try writer.writeAll(",\"created\":true}");

    return output.toOwnedSlice();
}

fn executeFilesystemRmdir(
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

    const rmdir_result = try workspace_fs.removeDirectory(
        allocator,
        policy.workspace_root,
        requested_path,
    );
    defer rmdir_result.deinit(allocator);

    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();

    const writer = &output.writer;
    try writer.writeAll("{\"ok\":true,\"tool\":\"filesystem_rmdir\",\"path\":");
    try writeWorkspacePathJson(allocator, writer, policy.workspace_root, rmdir_result.path);
    try writer.writeAll(",\"removed\":true}");

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
    try writeWorkspacePathJson(allocator, writer, policy.workspace_root, delete_result.path);
    try writer.writeAll(",\"deleted\":true}");

    return output.toOwnedSlice();
}

fn executeFilesystemGrep(
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

    var requested_path: []const u8 = ".";
    if (root_object.get("path")) |path_value| {
        requested_path = switch (path_value) {
            .string => |value| value,
            else => return error.InvalidToolArguments,
        };
    }

    const pattern = switch (root_object.get("pattern") orelse return error.InvalidToolArguments) {
        .string => |value| value,
        else => return error.InvalidToolArguments,
    };

    var recursive = true;
    if (root_object.get("recursive")) |recursive_value| {
        recursive = switch (recursive_value) {
            .bool => |value| value,
            else => return error.InvalidToolArguments,
        };
    }

    var max_matches: usize = default_grep_max_matches;
    if (root_object.get("max_matches")) |max_matches_value| {
        max_matches = switch (max_matches_value) {
            .integer => |value| blk: {
                if (value <= 0) return error.InvalidToolArguments;
                const converted = std.math.cast(usize, value) orelse return error.InvalidToolArguments;
                break :blk converted;
            },
            else => return error.InvalidToolArguments,
        };
        if (max_matches > max_allowed_grep_matches) return error.InvalidToolArguments;
    }

    var grep_result = try workspace_fs.grep(
        allocator,
        policy.workspace_root,
        requested_path,
        pattern,
        recursive,
        max_matches,
    );
    defer grep_result.deinit(allocator);

    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();

    const writer = &output.writer;
    try writer.writeAll("{\"ok\":true,\"tool\":\"filesystem_grep\",\"path\":");
    try writeWorkspacePathJson(allocator, writer, policy.workspace_root, grep_result.path);
    try writer.writeAll(",\"pattern\":");
    try writeJsonString(allocator, writer, pattern);
    try writer.writeAll(",\"recursive\":");
    try writer.writeAll(if (recursive) "true" else "false");
    try writer.writeAll(",\"files_scanned\":");
    try writer.print("{d}", .{grep_result.files_scanned});
    try writer.writeAll(",\"truncated\":");
    try writer.writeAll(if (grep_result.truncated) "true" else "false");
    try writer.writeAll(",\"matches\":[");
    for (grep_result.matches, 0..) |match, index| {
        if (index != 0) try writer.writeAll(",");
        try writeGrepMatchJson(allocator, writer, policy.workspace_root, &match);
    }
    try writer.writeAll("]}");

    return output.toOwnedSlice();
}

fn writePathMetadataJson(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    workspace_root: []const u8,
    metadata: *const workspace_fs.PathMetadata,
) !void {
    const workspace_path = try workspace_fs.toWorkspaceAbsolutePath(allocator, workspace_root, metadata.path);
    defer allocator.free(workspace_path);

    try writer.writeAll("{\"name\":");
    try writeJsonString(allocator, writer, metadata.name);
    try writer.writeAll(",\"path\":");
    try writeJsonString(allocator, writer, workspace_path);
    try writer.writeAll(",\"type\":");
    try writeJsonString(allocator, writer, workspace_fs.entryTypeToString(metadata.entry_type));
    try writer.writeAll(",\"size\":");
    try writer.print("{d}", .{metadata.size});
    try writer.writeAll(",\"mode\":");
    try writeJsonString(allocator, writer, metadata.mode);
    try writer.writeAll(",\"owner\":");
    try writeJsonString(allocator, writer, metadata.owner);
    try writer.writeAll(",\"group\":");
    try writeJsonString(allocator, writer, metadata.group);
    try writer.writeAll(",\"modified_at\":");
    try writeJsonString(allocator, writer, metadata.modified_at);
    try writer.writeAll("}");
}

fn writeGrepMatchJson(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    workspace_root: []const u8,
    match: *const workspace_fs.GrepMatch,
) !void {
    const workspace_path = try workspace_fs.toWorkspaceAbsolutePath(allocator, workspace_root, match.path);
    defer allocator.free(workspace_path);

    try writer.writeAll("{\"path\":");
    try writeJsonString(allocator, writer, workspace_path);
    try writer.writeAll(",\"line\":");
    try writer.print("{d}", .{match.line});
    try writer.writeAll(",\"column\":");
    try writer.print("{d}", .{match.column});
    try writer.writeAll(",\"text\":");
    try writeJsonString(allocator, writer, match.text);
    try writer.writeAll("}");
}

fn executeLuaExecute(
    allocator: std.mem.Allocator,
    policy: *const Policy,
    request_context: RequestContext,
    arguments_json: []const u8,
) ![]u8 {
    _ = request_context;
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

    var timeout: u32 = default_lua_timeout_seconds;
    if (root_object.get("timeout")) |timeout_value| {
        timeout = switch (timeout_value) {
            .integer => |value| blk: {
                if (value <= 0) return error.InvalidToolArguments;
                const converted = std.math.cast(u32, value) orelse return error.InvalidToolArguments;
                break :blk converted;
            },
            else => return error.InvalidToolArguments,
        };
        if (timeout > max_allowed_lua_timeout_seconds) return error.InvalidToolArguments;
    }

    var script_args = std.ArrayList([]const u8).empty;
    defer script_args.deinit(allocator);
    if (root_object.get("args")) |args_value| {
        const args_array = switch (args_value) {
            .array => |value| value,
            else => return error.InvalidToolArguments,
        };

        for (args_array.items) |arg_value| {
            const script_arg = switch (arg_value) {
                .string => |value| value,
                else => return error.InvalidToolArguments,
            };
            try script_args.append(allocator, script_arg);
        }
    }

    const resolved_path = try workspace_fs.resolveAllowedReadPath(
        allocator,
        policy.workspace_root,
        requested_path,
    );
    defer allocator.free(resolved_path);

    if (!std.mem.eql(u8, std.fs.path.extension(resolved_path), ".lua")) {
        return error.InvalidToolArguments;
    }

    var execution = try lua_runner.executeLuaFileCaptureOutputToolWithArgs(
        allocator,
        resolved_path,
        .{
            .workspace_root = policy.workspace_root,
            .max_read_bytes = max_allowed_read_bytes,
            .max_http_response_bytes = max_allowed_http_response_bytes,
            .execution_timeout_ns = lua_runner.timeoutSecondsToNanoseconds(timeout),
            .config_path_override = policy.config_path_override,
            .allow_private_http_destinations = policy.allow_private_http_destinations,
        },
        script_args.items,
    );
    defer execution.deinit(allocator);

    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();

    const writer = &output.writer;
    const ok = switch (execution.status) {
        .ok => true,
        .exited => (execution.exit_code orelse 0) == 0,
        .timed_out, .state_init_failed, .load_failed, .runtime_failed => false,
    };
    try writer.writeAll("{\"ok\":");
    try writer.writeAll(if (ok) "true" else "false");
    try writer.writeAll(",\"tool\":\"lua_execute\",\"path\":");
    try writeWorkspacePathJson(allocator, writer, policy.workspace_root, resolved_path);
    try writer.writeAll(",\"stdout\":");
    try writeJsonString(allocator, writer, execution.stdout);
    try writer.writeAll(",\"stderr\":");
    try writeJsonString(allocator, writer, execution.stderr);
    try writer.writeAll(",\"stdout_truncated\":");
    try writer.writeAll(if (execution.stdout_truncated) "true" else "false");
    try writer.writeAll(",\"stderr_truncated\":");
    try writer.writeAll(if (execution.stderr_truncated) "true" else "false");
    try writer.writeAll(",\"exit_code\":");
    if (execution.exit_code) |exit_code| {
        try writer.print("{d}", .{exit_code});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"timeout\":");
    try writer.print("{d}", .{timeout});
    if (!ok) {
        const error_name = switch (execution.status) {
            .ok => unreachable,
            .exited => "LuaExit",
            .timed_out => "LuaTimeout",
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

fn executeScheduler(
    allocator: std.mem.Allocator,
    policy: *const Policy,
    request_context: RequestContext,
    arguments_json: []const u8,
) ![]u8 {
    _ = request_context;
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

    const context = scheduler_runtime.Context{ .workspace_root = policy.workspace_root };

    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;

    if (std.mem.eql(u8, action, "create")) {
        const path = try requireStringProperty(root_object, "path");

        const at: ?[]const u8 = if (root_object.get("at")) |value|
            switch (value) {
                .string => |text| text,
                .null => null,
                else => return error.InvalidToolArguments,
            }
        else
            null;

        const cron: ?[]const u8 = if (root_object.get("cron")) |value|
            switch (value) {
                .string => |text| text,
                .null => null,
                else => return error.InvalidToolArguments,
            }
        else
            null;

        var created = try scheduler_runtime.createJob(
            allocator,
            context,
            .{
                .path = path,
                .at = at,
                .cron = cron,
            },
        );
        defer created.deinit(allocator);

        try writer.writeAll("{\"ok\":true,\"tool\":\"jobs\",\"action\":\"create\",\"job\":");
        try writeSchedulerJobJson(allocator, writer, policy.workspace_root, &created);
        try writer.writeAll("}");
        return output.toOwnedSlice();
    }

    if (std.mem.eql(u8, action, "list")) {
        const jobs = try scheduler_runtime.listJobs(allocator, context);
        defer scheduler_store.deinitJobs(allocator, jobs);

        try writer.writeAll("{\"ok\":true,\"tool\":\"jobs\",\"action\":\"list\",\"jobs\":[");
        for (jobs, 0..) |*job, index| {
            if (index > 0) try writer.writeAll(",");
            try writeSchedulerJobJson(allocator, writer, policy.workspace_root, job);
        }
        try writer.writeAll("]}");
        return output.toOwnedSlice();
    }

    if (std.mem.eql(u8, action, "delete")) {
        const job_id = try requireStringProperty(root_object, "job_id");
        const removed = try scheduler_runtime.deleteJob(allocator, context, job_id);
        try writer.writeAll("{\"ok\":true,\"tool\":\"jobs\",\"action\":\"delete\",\"job_id\":");
        try writeJsonString(allocator, writer, job_id);
        try writer.writeAll(",\"removed\":");
        try writer.writeAll(if (removed) "true" else "false");
        try writer.writeAll("}");
        return output.toOwnedSlice();
    }

    if (std.mem.eql(u8, action, "pause")) {
        const job_id = try requireStringProperty(root_object, "job_id");
        const paused = try scheduler_runtime.pauseJob(allocator, context, job_id);
        try writer.writeAll("{\"ok\":true,\"tool\":\"jobs\",\"action\":\"pause\",\"job_id\":");
        try writeJsonString(allocator, writer, job_id);
        try writer.writeAll(",\"updated\":");
        try writer.writeAll(if (paused) "true" else "false");
        try writer.writeAll("}");
        return output.toOwnedSlice();
    }

    if (std.mem.eql(u8, action, "resume")) {
        const job_id = try requireStringProperty(root_object, "job_id");
        const resumed = try scheduler_runtime.resumeJob(allocator, context, job_id);
        try writer.writeAll("{\"ok\":true,\"tool\":\"jobs\",\"action\":\"resume\",\"job_id\":");
        try writeJsonString(allocator, writer, job_id);
        try writer.writeAll(",\"updated\":");
        try writer.writeAll(if (resumed) "true" else "false");
        try writer.writeAll("}");
        return output.toOwnedSlice();
    }

    return error.InvalidToolArguments;
}

fn writeSchedulerJobJson(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    workspace_root: []const u8,
    job: *const scheduler_store.Job,
) !void {
    const workspace_path = try workspace_fs.toWorkspaceAbsolutePath(allocator, workspace_root, job.path);
    defer allocator.free(workspace_path);

    try writer.writeAll("{\"id\":");
    try writeJsonString(allocator, writer, job.id);
    try writer.writeAll(",\"path\":");
    try writeJsonString(allocator, writer, workspace_path);
    try writer.writeAll(",\"paused\":");
    try writer.writeAll(if (job.paused) "true" else "false");
    try writeNullableEpochTimestampJsonField(allocator, writer, "at", job.run_at);
    try writer.writeAll(",\"cron\":");
    if (job.cron) |cron| {
        try writeJsonString(allocator, writer, cron);
    } else {
        try writer.writeAll("null");
    }
    try writeEpochTimestampJsonField(allocator, writer, "next_run_at", job.next_run_at);
    try writeEpochTimestampJsonField(allocator, writer, "created_at", job.created_at);
    try writeEpochTimestampJsonField(allocator, writer, "updated_at", job.updated_at);
    try writeNullableEpochTimestampJsonField(allocator, writer, "last_run_at", job.last_run_at);
    try writer.writeAll("}");
}

fn writeEpochTimestampJsonField(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    field_name: []const u8,
    epoch_seconds: i64,
) !void {
    const formatted = try formatEpochMinuteDisplayAlloc(allocator, epoch_seconds);
    defer allocator.free(formatted);

    try writer.writeAll(",\"");
    try writer.writeAll(field_name);
    try writer.writeAll("\":");
    try writeJsonString(allocator, writer, formatted);

    try writer.writeAll(",\"");
    try writer.writeAll(field_name);
    try writer.writeAll("_epoch\":");
    try writer.print("{d}", .{epoch_seconds});
}

fn writeNullableEpochTimestampJsonField(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    field_name: []const u8,
    epoch_seconds: ?i64,
) !void {
    try writer.writeAll(",\"");
    try writer.writeAll(field_name);
    try writer.writeAll("\":");
    if (epoch_seconds) |value| {
        const formatted = try formatEpochMinuteDisplayAlloc(allocator, value);
        defer allocator.free(formatted);
        try writeJsonString(allocator, writer, formatted);
    } else {
        try writer.writeAll("null");
    }

    try writer.writeAll(",\"");
    try writer.writeAll(field_name);
    try writer.writeAll("_epoch\":");
    if (epoch_seconds) |value| {
        try writer.print("{d}", .{value});
    } else {
        try writer.writeAll("null");
    }
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

fn executeHttpGet(allocator: std.mem.Allocator, policy: *const Policy, arguments_json: []const u8) ![]u8 {
    return executeHttpRequestTool(allocator, policy, "http_get", .GET, false, arguments_json);
}

fn executeHttpPost(allocator: std.mem.Allocator, policy: *const Policy, arguments_json: []const u8) ![]u8 {
    return executeHttpRequestTool(allocator, policy, "http_post", .POST, true, arguments_json);
}

fn executeHttpPut(allocator: std.mem.Allocator, policy: *const Policy, arguments_json: []const u8) ![]u8 {
    return executeHttpRequestTool(allocator, policy, "http_put", .PUT, true, arguments_json);
}

fn executeHttpDelete(allocator: std.mem.Allocator, policy: *const Policy, arguments_json: []const u8) ![]u8 {
    return executeHttpRequestTool(allocator, policy, "http_delete", .DELETE, false, arguments_json);
}

fn executeDateTimeNow(allocator: std.mem.Allocator, arguments_json: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{});
    defer parsed.deinit();

    const root_object = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidToolArguments,
    };
    if (root_object.count() != 0) return error.InvalidToolArguments;

    const now_seconds = std.time.timestamp();
    const timestamp: c.time_t = std.math.cast(c.time_t, now_seconds) orelse return error.TimeOutOfRange;

    var utc_tm: c.struct_tm = std.mem.zeroes(c.struct_tm);
    if (!tmFromTimestamp(timestamp, true, &utc_tm)) return error.TimeConversionFailed;

    var local_tm: c.struct_tm = std.mem.zeroes(c.struct_tm);
    if (!tmFromTimestamp(timestamp, false, &local_tm)) return error.TimeConversionFailed;

    const utc_iso8601 = try formatTimestampAlloc(allocator, &utc_tm, "%Y-%m-%dT%H:%M:%SZ");
    defer allocator.free(utc_iso8601);

    const local_iso8601 = try formatTimestampAlloc(allocator, &local_tm, "%Y-%m-%dT%H:%M:%S%z");
    defer allocator.free(local_iso8601);

    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;

    try writer.writeAll("{\"ok\":true,\"tool\":\"datetime_now\",\"epoch\":");
    try writer.print("{d}", .{now_seconds});
    try writer.writeAll(",\"utc\":");
    try writeJsonString(allocator, writer, utc_iso8601);
    try writer.writeAll(",\"local\":");
    try writeJsonString(allocator, writer, local_iso8601);
    try writer.writeAll("}");

    return output.toOwnedSlice();
}

fn executeBrowserAutomate(
    allocator: std.mem.Allocator,
    policy: *const Policy,
    arguments_json: []const u8,
) ![]u8 {
    return browser_tool.execute(allocator, .{
        .workspace_root = policy.workspace_root,
        .allow_private_http_destinations = policy.allow_private_http_destinations,
        .browser_app_data_dir_override = policy.browser_app_data_dir_override,
    }, arguments_json);
}

fn executeHttpRequestTool(
    allocator: std.mem.Allocator,
    policy: *const Policy,
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
        &.{},
        max_allowed_http_response_bytes,
        policy.allow_private_http_destinations,
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

fn tmFromTimestamp(timestamp: c.time_t, utc: bool, out_tm: *c.struct_tm) bool {
    var value = timestamp;
    const tm_ptr = if (utc) c.gmtime(&value) else c.localtime(&value);
    if (tm_ptr == null) return false;
    out_tm.* = tm_ptr.*;
    return true;
}

fn formatTimestampAlloc(
    allocator: std.mem.Allocator,
    tm_value: *const c.struct_tm,
    comptime format: [:0]const u8,
) ![]u8 {
    var output_buffer: [64]u8 = undefined;
    const written = c.strftime(
        output_buffer[0..].ptr,
        output_buffer.len,
        format.ptr,
        tm_value,
    );
    if (written == 0) return error.TimeFormattingFailed;
    return allocator.dupe(u8, output_buffer[0..written]);
}

fn formatEpochMinuteDisplayAlloc(allocator: std.mem.Allocator, epoch_seconds: i64) ![]u8 {
    const timestamp: c.time_t = std.math.cast(c.time_t, epoch_seconds) orelse return error.TimeOutOfRange;
    var local_tm: c.struct_tm = std.mem.zeroes(c.struct_tm);
    if (!tmFromTimestamp(timestamp, false, &local_tm)) return error.TimeConversionFailed;
    return formatTimestampAlloc(allocator, &local_tm, "%Y-%m-%d %H:%M");
}

fn writeJsonString(allocator: std.mem.Allocator, writer: *std.Io.Writer, value: []const u8) !void {
    const escaped = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(escaped);
    try writer.writeAll(escaped);
}

fn writeWorkspacePathJson(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    workspace_root: []const u8,
    resolved_path: []const u8,
) !void {
    const workspace_path = try workspace_fs.toWorkspaceAbsolutePath(allocator, workspace_root, resolved_path);
    defer allocator.free(workspace_path);
    try writeJsonString(allocator, writer, workspace_path);
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
    try std.testing.expectEqual(@as(usize, 16), root_object.get("tools_enabled").?.array.items.len);
}

test "datetime_now returns current timestamp and formatted values" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    var policy = try Policy.initForWorkspaceRoot(std.testing.allocator, tmp_path);
    defer policy.deinit(std.testing.allocator);

    const before = std.time.timestamp();
    const result = try executeToolCall(
        std.testing.allocator,
        &policy,
        "datetime_now",
        "{}",
    );
    defer std.testing.allocator.free(result);
    const after = std.time.timestamp();

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expect(object.get("ok").?.bool);
    try std.testing.expectEqualStrings("datetime_now", object.get("tool").?.string);

    const epoch = object.get("epoch").?.integer;
    try std.testing.expect(epoch >= before);
    try std.testing.expect(epoch <= after);
    try std.testing.expect(object.get("utc").?.string.len > 0);
    try std.testing.expect(object.get("local").?.string.len > 0);
}

fn expectTimestampMinuteString(value: std.json.Value) !void {
    const text = switch (value) {
        .string => |string| string,
        else => return error.TestExpectedString,
    };
    try std.testing.expectEqual(@as(usize, 16), text.len);

    for (text, 0..) |char, index| {
        switch (index) {
            4, 7 => try std.testing.expectEqual(@as(u8, '-'), char),
            10 => try std.testing.expectEqual(@as(u8, ' '), char),
            13 => try std.testing.expectEqual(@as(u8, ':'), char),
            else => try std.testing.expect(std.ascii.isDigit(char)),
        }
    }
}

test "jobs tool can create and list jobs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    {
        const file = try tmp.dir.createFile("task.lua", .{});
        defer file.close();
        try file.writeAll("print('scheduled')\n");
    }

    var policy = try Policy.initForWorkspaceRoot(std.testing.allocator, workspace_root);
    defer policy.deinit(std.testing.allocator);

    const create_result = try executeToolCallWithContext(
        std.testing.allocator,
        &policy,
        .{ .request_chat_id = 777 },
        "jobs",
        "{\"action\":\"create\",\"path\":\"task.lua\",\"at\":\"2026-01-10T10:00:00Z\"}",
    );
    defer std.testing.allocator.free(create_result);

    var parsed_create = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, create_result, .{});
    defer parsed_create.deinit();
    const create_object = parsed_create.value.object;
    try std.testing.expect(create_object.get("ok").?.bool);
    try std.testing.expectEqualStrings("jobs", create_object.get("tool").?.string);
    try std.testing.expectEqualStrings("create", create_object.get("action").?.string);
    const created_job = create_object.get("job").?.object;
    try std.testing.expectEqualStrings("/task.lua", created_job.get("path").?.string);
    try expectTimestampMinuteString(created_job.get("at").?);
    try std.testing.expect(created_job.get("at_epoch").?.integer > 0);
    try expectTimestampMinuteString(created_job.get("next_run_at").?);
    try std.testing.expect(created_job.get("next_run_at_epoch").?.integer > 0);
    try expectTimestampMinuteString(created_job.get("created_at").?);
    try std.testing.expect(created_job.get("created_at_epoch").?.integer > 0);
    try expectTimestampMinuteString(created_job.get("updated_at").?);
    try std.testing.expect(created_job.get("updated_at_epoch").?.integer > 0);
    try std.testing.expect(created_job.get("last_run_at").? == .null);
    try std.testing.expect(created_job.get("last_run_at_epoch").? == .null);

    const list_result = try executeToolCallWithContext(
        std.testing.allocator,
        &policy,
        .{},
        "jobs",
        "{\"action\":\"list\"}",
    );
    defer std.testing.allocator.free(list_result);

    var parsed_list = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, list_result, .{});
    defer parsed_list.deinit();
    const list_object = parsed_list.value.object;
    const jobs = list_object.get("jobs").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), jobs.len);
    const listed_job = jobs[0].object;
    try std.testing.expectEqualStrings("/task.lua", listed_job.get("path").?.string);
    try expectTimestampMinuteString(listed_job.get("next_run_at").?);
    try std.testing.expect(listed_job.get("next_run_at_epoch").?.integer > 0);
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
        "{\"path\":\"/notes.txt\",\"content\":\"hello\"}",
    );
    defer std.testing.allocator.free(write_result);

    var parsed_write = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, write_result, .{});
    defer parsed_write.deinit();
    const write_object = parsed_write.value.object;
    try std.testing.expectEqualStrings("/notes.txt", write_object.get("path").?.string);

    const read_result = try executeToolCall(
        std.testing.allocator,
        &policy,
        "filesystem_read",
        "{\"path\":\"/notes.txt\"}",
    );
    defer std.testing.allocator.free(read_result);

    var parsed_read = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, read_result, .{});
    defer parsed_read.deinit();

    const read_object = parsed_read.value.object;
    try std.testing.expect(read_object.get("ok").?.bool);
    try std.testing.expectEqualStrings("hello", read_object.get("content").?.string);
}

test "filesystem mkdir creates a directory within workspace root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    var policy = try Policy.initForWorkspaceRoot(std.testing.allocator, tmp_path);
    defer policy.deinit(std.testing.allocator);

    const mkdir_result = try executeToolCall(
        std.testing.allocator,
        &policy,
        "filesystem_mkdir",
        "{\"path\":\"new-dir\"}",
    );
    defer std.testing.allocator.free(mkdir_result);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, mkdir_result, .{});
    defer parsed.deinit();

    const mkdir_object = parsed.value.object;
    try std.testing.expect(mkdir_object.get("ok").?.bool);
    try std.testing.expectEqualStrings("filesystem_mkdir", mkdir_object.get("tool").?.string);
    try std.testing.expect(mkdir_object.get("created").?.bool);
    try tmp.dir.access("new-dir", .{});
}

test "filesystem mkdir rejects traversal outside workspace root" {
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
            "filesystem_mkdir",
            "{\"path\":\"../outside-dir\"}",
        ),
    );
}

test "filesystem rmdir removes an empty directory within workspace root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    var policy = try Policy.initForWorkspaceRoot(std.testing.allocator, tmp_path);
    defer policy.deinit(std.testing.allocator);

    const mkdir_result = try executeToolCall(
        std.testing.allocator,
        &policy,
        "filesystem_mkdir",
        "{\"path\":\"empty-dir\"}",
    );
    defer std.testing.allocator.free(mkdir_result);

    const rmdir_result = try executeToolCall(
        std.testing.allocator,
        &policy,
        "filesystem_rmdir",
        "{\"path\":\"empty-dir\"}",
    );
    defer std.testing.allocator.free(rmdir_result);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, rmdir_result, .{});
    defer parsed.deinit();

    const rmdir_object = parsed.value.object;
    try std.testing.expect(rmdir_object.get("ok").?.bool);
    try std.testing.expectEqualStrings("filesystem_rmdir", rmdir_object.get("tool").?.string);
    try std.testing.expect(rmdir_object.get("removed").?.bool);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("empty-dir", .{}));
}

test "filesystem rmdir rejects traversal outside workspace root" {
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
            "filesystem_rmdir",
            "{\"path\":\"../outside-dir\"}",
        ),
    );
}

test "filesystem rmdir rejects non-empty directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    var policy = try Policy.initForWorkspaceRoot(std.testing.allocator, tmp_path);
    defer policy.deinit(std.testing.allocator);

    try tmp.dir.makeDir("non-empty");
    {
        const file = try tmp.dir.createFile("non-empty/file.txt", .{});
        defer file.close();
        try file.writeAll("x");
    }

    executeToolCall(
        std.testing.allocator,
        &policy,
        "filesystem_rmdir",
        "{\"path\":\"non-empty\"}",
    ) catch |err| {
        const err_name = @errorName(err);
        const is_non_empty =
            std.mem.eql(u8, err_name, "DirNotEmpty") or
            std.mem.eql(u8, err_name, "DirectoryNotEmpty");
        try std.testing.expect(is_non_empty);
        return;
    };
    return error.TestExpectedError;
}

test "filesystem list returns metadata entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("docs");
    {
        const file = try tmp.dir.createFile("alpha.txt", .{});
        defer file.close();
        try file.writeAll("hello");
    }

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    var policy = try Policy.initForWorkspaceRoot(std.testing.allocator, tmp_path);
    defer policy.deinit(std.testing.allocator);

    const list_result = try executeToolCall(
        std.testing.allocator,
        &policy,
        "filesystem_list",
        "{\"path\":\".\"}",
    );
    defer std.testing.allocator.free(list_result);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, list_result, .{});
    defer parsed.deinit();

    const root_object = parsed.value.object;
    try std.testing.expect(root_object.get("ok").?.bool);
    try std.testing.expectEqualStrings("filesystem_list", root_object.get("tool").?.string);
    try std.testing.expectEqualStrings("/", root_object.get("path").?.string);

    const entries = root_object.get("entries").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("alpha.txt", entries[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("/alpha.txt", entries[0].object.get("path").?.string);
    try std.testing.expectEqualStrings("file", entries[0].object.get("type").?.string);
    try std.testing.expect(entries[0].object.get("size").?.integer > 0);
    try std.testing.expectEqual(@as(usize, 4), entries[0].object.get("mode").?.string.len);
    try std.testing.expect(entries[0].object.get("owner").?.string.len > 0);
    try std.testing.expect(entries[0].object.get("group").?.string.len > 0);
    try std.testing.expect(std.mem.endsWith(u8, entries[0].object.get("modified_at").?.string, "Z"));

    try std.testing.expectEqualStrings("docs", entries[1].object.get("name").?.string);
    try std.testing.expectEqualStrings("/docs", entries[1].object.get("path").?.string);
    try std.testing.expectEqualStrings("directory", entries[1].object.get("type").?.string);
}

test "filesystem list rejects traversal outside workspace root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("workspace");

    const workspace_path = try tmp.dir.realpathAlloc(std.testing.allocator, "workspace");
    defer std.testing.allocator.free(workspace_path);

    var policy = try Policy.initForWorkspaceRoot(std.testing.allocator, workspace_path);
    defer policy.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.PathNotAllowed,
        executeToolCall(
            std.testing.allocator,
            &policy,
            "filesystem_list",
            "{\"path\":\"../\"}",
        ),
    );
}

test "filesystem grep returns recursive matches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("logs/nested");
    {
        const top_file = try tmp.dir.createFile("logs/top.txt", .{});
        defer top_file.close();
        try top_file.writeAll("needle top\n");
    }
    {
        const nested_file = try tmp.dir.createFile("logs/nested/deep.txt", .{});
        defer nested_file.close();
        try nested_file.writeAll("needle deep\n");
    }
    {
        const unrelated = try tmp.dir.createFile("logs/nested/skip.txt", .{});
        defer unrelated.close();
        try unrelated.writeAll("unrelated\n");
    }

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    var policy = try Policy.initForWorkspaceRoot(std.testing.allocator, tmp_path);
    defer policy.deinit(std.testing.allocator);

    const grep_result = try executeToolCall(
        std.testing.allocator,
        &policy,
        "filesystem_grep",
        "{\"path\":\"logs\",\"pattern\":\"needle\",\"recursive\":true}",
    );
    defer std.testing.allocator.free(grep_result);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, grep_result, .{});
    defer parsed.deinit();

    const root_object = parsed.value.object;
    try std.testing.expect(root_object.get("ok").?.bool);
    try std.testing.expectEqualStrings("filesystem_grep", root_object.get("tool").?.string);
    try std.testing.expect(root_object.get("recursive").?.bool);
    try std.testing.expectEqual(@as(i64, 3), root_object.get("files_scanned").?.integer);
    try std.testing.expect(!root_object.get("truncated").?.bool);

    const matches = root_object.get("matches").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expectEqualStrings("/logs/nested/deep.txt", matches[0].object.get("path").?.string);
    try std.testing.expectEqualStrings("/logs/top.txt", matches[1].object.get("path").?.string);
    try std.testing.expectEqual(@as(i64, 1), matches[0].object.get("line").?.integer);
    try std.testing.expectEqualStrings("needle deep", matches[0].object.get("text").?.string);
    try std.testing.expectEqualStrings("needle top", matches[1].object.get("text").?.string);
}

test "filesystem grep rejects traversal outside workspace root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("workspace");

    const outside_file = try tmp.dir.createFile("outside.txt", .{});
    defer outside_file.close();
    try outside_file.writeAll("needle");

    const workspace_path = try tmp.dir.realpathAlloc(std.testing.allocator, "workspace");
    defer std.testing.allocator.free(workspace_path);

    var policy = try Policy.initForWorkspaceRoot(std.testing.allocator, workspace_path);
    defer policy.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.PathNotAllowed,
        executeToolCall(
            std.testing.allocator,
            &policy,
            "filesystem_grep",
            "{\"path\":\"../\",\"pattern\":\"needle\"}",
        ),
    );
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
    const resolved_deleted_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ tmp_path, std.mem.trimLeft(u8, delete_object.get("path").?.string, "/") },
    );
    defer std.testing.allocator.free(resolved_deleted_path);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(resolved_deleted_path, .{}));
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

test "lua execute forwards args to Lua arg table" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("args.lua", .{});
    defer file.close();
    try file.writeAll(
        \\print(arg[1])
        \\print(arg[2])
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
        "{\"path\":\"args.lua\",\"args\":[\"one\",\"two\"]}",
    );
    defer std.testing.allocator.free(result);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();

    const root_object = parsed.value.object;
    try std.testing.expect(root_object.get("ok").?.bool);
    try std.testing.expectEqualStrings("one\ntwo\n", root_object.get("stdout").?.string);
    try std.testing.expectEqualStrings("", root_object.get("stderr").?.string);
    try std.testing.expect(root_object.get("exit_code").? == .null);
}

test "lua execute supports zoid exit codes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try tmp.dir.createFile("exit_nonzero.lua", .{});
        defer file.close();
        try file.writeAll(
            \\print("before")
            \\zoid.exit(9)
            \\print("after")
            \\
        );
    }

    {
        const file = try tmp.dir.createFile("exit_zero.lua", .{});
        defer file.close();
        try file.writeAll(
            \\print("ok")
            \\zoid.exit(0)
            \\print("after")
            \\
        );
    }

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    var policy = try Policy.initForWorkspaceRoot(std.testing.allocator, tmp_path);
    defer policy.deinit(std.testing.allocator);

    const nonzero_result = try executeToolCall(
        std.testing.allocator,
        &policy,
        "lua_execute",
        "{\"path\":\"exit_nonzero.lua\"}",
    );
    defer std.testing.allocator.free(nonzero_result);

    var nonzero_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, nonzero_result, .{});
    defer nonzero_parsed.deinit();

    const nonzero_root = nonzero_parsed.value.object;
    try std.testing.expect(!nonzero_root.get("ok").?.bool);
    try std.testing.expectEqualStrings("before\n", nonzero_root.get("stdout").?.string);
    try std.testing.expectEqualStrings("", nonzero_root.get("stderr").?.string);
    try std.testing.expectEqualStrings("LuaExit", nonzero_root.get("error").?.string);
    try std.testing.expectEqual(@as(i64, 9), nonzero_root.get("exit_code").?.integer);

    const zero_result = try executeToolCall(
        std.testing.allocator,
        &policy,
        "lua_execute",
        "{\"path\":\"exit_zero.lua\"}",
    );
    defer std.testing.allocator.free(zero_result);

    var zero_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, zero_result, .{});
    defer zero_parsed.deinit();

    const zero_root = zero_parsed.value.object;
    try std.testing.expect(zero_root.get("ok").?.bool);
    try std.testing.expectEqualStrings("ok\n", zero_root.get("stdout").?.string);
    try std.testing.expectEqualStrings("", zero_root.get("stderr").?.string);
    try std.testing.expect(zero_root.get("error") == null);
    try std.testing.expectEqual(@as(i64, 0), zero_root.get("exit_code").?.integer);
}

test "lua execute rejects invalid args shape" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("ok.lua", .{});
    defer file.close();
    try file.writeAll("print('ok')\n");

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    var policy = try Policy.initForWorkspaceRoot(std.testing.allocator, tmp_path);
    defer policy.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.InvalidToolArguments,
        executeToolCall(
            std.testing.allocator,
            &policy,
            "lua_execute",
            "{\"path\":\"ok.lua\",\"args\":[\"ok\",123]}",
        ),
    );
}

test "lua execute supports timeout override" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("loop.lua", .{});
    defer file.close();
    try file.writeAll(
        \\while true do
        \\end
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
        "{\"path\":\"loop.lua\",\"timeout\":1}",
    );
    defer std.testing.allocator.free(result);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();

    const root_object = parsed.value.object;
    try std.testing.expect(!root_object.get("ok").?.bool);
    try std.testing.expectEqualStrings("LuaTimeout", root_object.get("error").?.string);
    try std.testing.expectEqual(@as(i64, 1), root_object.get("timeout").?.integer);
    try std.testing.expect(std.mem.indexOf(u8, root_object.get("stderr").?.string, "timed out") != null);
}

test "lua execute rejects invalid timeout" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("ok.lua", .{});
    defer file.close();
    try file.writeAll("print('ok')\n");

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    var policy = try Policy.initForWorkspaceRoot(std.testing.allocator, tmp_path);
    defer policy.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.InvalidToolArguments,
        executeToolCall(
            std.testing.allocator,
            &policy,
            "lua_execute",
            "{\"path\":\"ok.lua\",\"timeout\":0}",
        ),
    );

    try std.testing.expectError(
        error.InvalidToolArguments,
        executeToolCall(
            std.testing.allocator,
            &policy,
            "lua_execute",
            "{\"path\":\"ok.lua\",\"timeout\":601}",
        ),
    );
}

test "lua execute exposes zoid fs and blocks os" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("fs.lua", .{});
    defer file.close();
    try file.writeAll(
        \\local file = zoid.file("file.txt")
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
        "{\"path\":\"fs.lua\"}",
    );
    defer std.testing.allocator.free(result);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();

    const root_object = parsed.value.object;
    try std.testing.expect(!root_object.get("ok").?.bool);
    try std.testing.expectEqualStrings("hello\n", root_object.get("stdout").?.string);
    try std.testing.expect(std.mem.indexOf(u8, root_object.get("stderr").?.string, "os") != null);
    try std.testing.expectEqualStrings("LuaRuntimeFailed", root_object.get("error").?.string);

    const deleted_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_path, "file.txt" });
    defer std.testing.allocator.free(deleted_path);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(deleted_path, .{}));
}

test "lua execute exposes zoid uri handles" {
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
        \\zoid.eprint("before boom")
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
    policy.allow_private_http_destinations = true;

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

test "http tools block localhost destinations by default" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    var policy = try Policy.initForWorkspaceRoot(std.testing.allocator, tmp_path);
    defer policy.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.DestinationNotAllowed,
        executeToolCall(
            std.testing.allocator,
            &policy,
            "http_get",
            "{\"uri\":\"http://127.0.0.1:8080\"}",
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

test "browser_automate validates URI policy for start_url and actions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    var policy = try Policy.initForWorkspaceRoot(std.testing.allocator, tmp_path);
    defer policy.deinit(std.testing.allocator);
    policy.browser_app_data_dir_override = tmp_path;

    try std.testing.expectError(
        error.UnsupportedUriScheme,
        executeToolCall(
            std.testing.allocator,
            &policy,
            "browser_automate",
            "{\"start_url\":\"ftp://example.com\"}",
        ),
    );

    try std.testing.expectError(
        error.DestinationNotAllowed,
        executeToolCall(
            std.testing.allocator,
            &policy,
            "browser_automate",
            "{\"actions\":[{\"action\":\"goto\",\"url\":\"http://127.0.0.1:8080\"}]}",
        ),
    );
}

test "browser_automate reports missing browser setup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    var policy = try Policy.initForWorkspaceRoot(std.testing.allocator, tmp_path);
    defer policy.deinit(std.testing.allocator);
    policy.browser_app_data_dir_override = tmp_path;

    try std.testing.expectError(
        error.BrowserSupportNotReady,
        executeToolCall(
            std.testing.allocator,
            &policy,
            "browser_automate",
            "{\"actions\":[{\"action\":\"wait_for_timeout\",\"ms\":1}]}",
        ),
    );
}

test "browser_automate validates session id format" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    var policy = try Policy.initForWorkspaceRoot(std.testing.allocator, tmp_path);
    defer policy.deinit(std.testing.allocator);
    policy.browser_app_data_dir_override = tmp_path;

    try std.testing.expectError(
        error.InvalidToolArguments,
        executeToolCall(
            std.testing.allocator,
            &policy,
            "browser_automate",
            "{\"session_id\":\"../bad\"}",
        ),
    );
}

test "browser_automate enforces workspace policy for screenshot and download paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    var policy = try Policy.initForWorkspaceRoot(std.testing.allocator, tmp_path);
    defer policy.deinit(std.testing.allocator);
    policy.browser_app_data_dir_override = tmp_path;

    try std.testing.expectError(
        error.InvalidToolArguments,
        executeToolCall(
            std.testing.allocator,
            &policy,
            "browser_automate",
            "{\"actions\":[{\"action\":\"screenshot\"}]}",
        ),
    );

    try std.testing.expectError(
        error.PathNotAllowed,
        executeToolCall(
            std.testing.allocator,
            &policy,
            "browser_automate",
            "{\"actions\":[{\"action\":\"screenshot\",\"path\":\"../outside.png\"}]}",
        ),
    );

    try std.testing.expectError(
        error.PathNotAllowed,
        executeToolCall(
            std.testing.allocator,
            &policy,
            "browser_automate",
            "{\"actions\":[{\"action\":\"download\",\"url\":\"https://example.com\",\"save_as\":\"../outside.bin\"}]}",
        ),
    );
}

test "browser_automate enforces workspace policy for upload paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    var policy = try Policy.initForWorkspaceRoot(std.testing.allocator, tmp_path);
    defer policy.deinit(std.testing.allocator);
    policy.browser_app_data_dir_override = tmp_path;

    try std.testing.expectError(
        error.PathNotAllowed,
        executeToolCall(
            std.testing.allocator,
            &policy,
            "browser_automate",
            "{\"actions\":[{\"action\":\"upload\",\"selector\":\"input[type=file]\",\"path\":\"../secret.txt\"}]}",
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
