const std = @import("std");
const lua_runner = @import("lua_runner.zig");

pub const sandbox_mode: []const u8 = "workspace-write";
pub const enabled_tools = [_][]const u8{
    "filesystem_read",
    "filesystem_write",
    "lua_execute",
};
pub const disabled_tools = [_][]const u8{};
pub const default_max_read_bytes: usize = 128 * 1024;
pub const max_allowed_read_bytes: usize = 1024 * 1024;

pub const Policy = struct {
    workspace_root: []u8,

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
    if (std.mem.eql(u8, tool_name, "lua_execute")) {
        return executeLuaExecute(allocator, policy, arguments_json);
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

    const resolved_path = try resolveAllowedReadPath(allocator, policy, requested_path);
    defer allocator.free(resolved_path);

    const file = try std.fs.cwd().openFile(resolved_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, max_bytes);
    defer allocator.free(content);

    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();

    const writer = &output.writer;
    try writer.writeAll("{\"ok\":true,\"tool\":\"filesystem_read\",\"path\":");
    try writeJsonString(allocator, writer, resolved_path);
    try writer.writeAll(",\"content\":");
    try writeJsonString(allocator, writer, content);
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

    const resolved_path = try resolveAllowedWritePath(allocator, policy, requested_path);
    defer allocator.free(resolved_path);

    const file = try std.fs.cwd().createFile(resolved_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);

    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();

    const writer = &output.writer;
    try writer.writeAll("{\"ok\":true,\"tool\":\"filesystem_write\",\"path\":");
    try writeJsonString(allocator, writer, resolved_path);
    try writer.writeAll(",\"bytes_written\":");
    try writer.print("{d}", .{content.len});
    try writer.writeAll("}");

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

    const resolved_path = try resolveAllowedReadPath(allocator, policy, requested_path);
    defer allocator.free(resolved_path);

    if (!std.mem.eql(u8, std.fs.path.extension(resolved_path), ".lua")) {
        return error.InvalidToolArguments;
    }

    var execution = try lua_runner.executeLuaFileCaptureOutputTool(allocator, resolved_path, .{
        .workspace_root = policy.workspace_root,
        .max_read_bytes = max_allowed_read_bytes,
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

fn resolveAllowedReadPath(
    allocator: std.mem.Allocator,
    policy: *const Policy,
    requested_path: []const u8,
) ![]u8 {
    const candidate = try toCandidatePath(allocator, policy.workspace_root, requested_path);
    defer allocator.free(candidate);

    const canonical = try std.fs.cwd().realpathAlloc(allocator, candidate);
    errdefer allocator.free(canonical);

    if (!isPathInsideWorkspace(policy.workspace_root, canonical)) {
        return error.PathNotAllowed;
    }
    return canonical;
}

fn resolveAllowedWritePath(
    allocator: std.mem.Allocator,
    policy: *const Policy,
    requested_path: []const u8,
) ![]u8 {
    const candidate = try toCandidatePath(allocator, policy.workspace_root, requested_path);
    defer allocator.free(candidate);

    const parent_path = std.fs.path.dirname(candidate) orelse return error.InvalidToolArguments;
    const parent_realpath = try std.fs.cwd().realpathAlloc(allocator, parent_path);
    defer allocator.free(parent_realpath);

    if (!isPathInsideWorkspace(policy.workspace_root, parent_realpath)) {
        return error.PathNotAllowed;
    }

    const file_name = std.fs.path.basename(candidate);
    if (file_name.len == 0 or std.mem.eql(u8, file_name, ".") or std.mem.eql(u8, file_name, "..")) {
        return error.InvalidToolArguments;
    }

    const resolved = try std.fs.path.join(allocator, &.{ parent_realpath, file_name });
    errdefer allocator.free(resolved);

    if (!isPathInsideWorkspace(policy.workspace_root, resolved)) {
        return error.PathNotAllowed;
    }

    const existing_realpath = std.fs.cwd().realpathAlloc(allocator, resolved) catch null;
    if (existing_realpath) |path_value| {
        defer allocator.free(path_value);
        if (!isPathInsideWorkspace(policy.workspace_root, path_value)) {
            return error.PathNotAllowed;
        }
    }

    return resolved;
}

fn toCandidatePath(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    requested_path: []const u8,
) ![]u8 {
    if (requested_path.len == 0) return error.InvalidToolArguments;
    if (std.fs.path.isAbsolute(requested_path)) {
        return allocator.dupe(u8, requested_path);
    }
    return std.fs.path.join(allocator, &.{ workspace_root, requested_path });
}

fn isPathInsideWorkspace(workspace_root: []const u8, candidate_path: []const u8) bool {
    if (std.mem.eql(u8, workspace_root, "/")) {
        return std.mem.startsWith(u8, candidate_path, "/");
    }
    if (!std.mem.startsWith(u8, candidate_path, workspace_root)) return false;
    if (candidate_path.len == workspace_root.len) return true;
    return candidate_path[workspace_root.len] == std.fs.path.sep;
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
    try std.testing.expectEqual(@as(usize, 3), root_object.get("tools_enabled").?.array.items.len);
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

test "lua execute sandbox exposes workspace fs and blocks os" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("sandbox.lua", .{});
    defer file.close();
    try file.writeAll(
        \\workspace.write("sandbox.txt", "hello")
        \\print(workspace.read("sandbox.txt"))
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
