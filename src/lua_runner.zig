const std = @import("std");
const config_runtime = @import("config_runtime.zig");
const config_store = @import("config_store.zig");
const http_client = @import("http_client.zig");
const scheduler_runtime = @import("scheduler_runtime.zig");
const scheduler_store = @import("scheduler_store.zig");
const workspace_fs = @import("workspace_fs.zig");
const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
    @cInclude("time.h");
});

pub const CaptureError = std.mem.Allocator.Error;
pub const default_tool_max_read_bytes: usize = 128 * 1024;
pub const default_tool_max_http_response_bytes: usize = 1024 * 1024;
pub const default_tool_execution_timeout_seconds: u32 = 10;
pub const max_tool_execution_timeout_seconds: u32 = 600;

pub const CapturedExecutionStatus = enum {
    ok,
    exited,
    timed_out,
    state_init_failed,
    load_failed,
    runtime_failed,
};

pub const CapturedExecution = struct {
    status: CapturedExecutionStatus,
    exit_code: ?i64,
    stdout: []u8,
    stderr: []u8,
    stdout_truncated: bool,
    stderr_truncated: bool,

    pub fn deinit(self: *CapturedExecution, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

fn luaErrorMessage(state: *c.lua_State) []const u8 {
    const message = c.lua_tolstring(state, -1, null) orelse return "unknown Lua error";
    return std.mem.span(message);
}

const capture_registry_key = "__zoid_output_capture";
const tool_sandbox_registry_key = "__zoid_tool_sandbox";
const timeout_registry_key = "__zoid_execution_timeout";
const max_captured_stream_bytes: usize = 256 * 1024;
const max_json_decode_depth: usize = 64;
const timeout_error_token = "__zoid_timeout_seconds__:";
var json_null_sentinel: u8 = 0;

pub const ToolSandbox = struct {
    workspace_root: []const u8,
    max_read_bytes: usize = default_tool_max_read_bytes,
    max_http_response_bytes: usize = default_tool_max_http_response_bytes,
    execution_timeout_ns: ?u64 = timeoutSecondsToNanoseconds(default_tool_execution_timeout_seconds),
    config_path_override: ?[]const u8 = null,
};

const LuaOutputCapture = struct {
    allocator: std.mem.Allocator,
    stdout: std.ArrayList(u8) = .empty,
    stderr: std.ArrayList(u8) = .empty,
    stdout_truncated: bool = false,
    stderr_truncated: bool = false,

    fn deinit(self: *LuaOutputCapture) void {
        self.stdout.deinit(self.allocator);
        self.stderr.deinit(self.allocator);
    }

    fn appendStdoutByte(self: *LuaOutputCapture, byte: u8) void {
        appendByte(&self.stdout, &self.stdout_truncated, self.allocator, byte);
    }

    fn appendStdoutSlice(self: *LuaOutputCapture, slice: []const u8) void {
        appendSlice(&self.stdout, &self.stdout_truncated, self.allocator, slice);
    }

    fn appendStderrSlice(self: *LuaOutputCapture, slice: []const u8) void {
        appendSlice(&self.stderr, &self.stderr_truncated, self.allocator, slice);
    }
};

const ToolLuaEnvironment = struct {
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    max_read_bytes: usize,
    max_http_response_bytes: usize,
    config_path_override: ?[]const u8,
    module_cache: std.StringHashMapUnmanaged(c_int) = .{},
    module_stack: std.ArrayList([]u8) = .empty,

    fn pushModuleStackPath(self: *ToolLuaEnvironment, path: []const u8) !void {
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        try self.module_stack.append(self.allocator, owned_path);
    }

    fn popModuleStackPath(self: *ToolLuaEnvironment) void {
        const owned_path = self.module_stack.pop().?;
        self.allocator.free(owned_path);
    }

    fn deinit(self: *ToolLuaEnvironment, lua_state: *c.lua_State) void {
        while (self.module_stack.items.len > 0) {
            self.popModuleStackPath();
        }
        var cache_iterator = self.module_cache.iterator();
        while (cache_iterator.next()) |entry| {
            c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, entry.value_ptr.*);
            self.allocator.free(@constCast(entry.key_ptr.*));
        }
        self.module_cache.deinit(self.allocator);
        self.module_stack.deinit(self.allocator);
    }
};

const LuaExecutionTimeout = struct {
    deadline_ns: i128,
    timeout_seconds: u32,
};

const OwnedRequestHeader = struct {
    name: []u8,
    value: []u8,
};

fn appendByte(
    buffer: *std.ArrayList(u8),
    truncated: *bool,
    allocator: std.mem.Allocator,
    byte: u8,
) void {
    if (truncated.*) return;
    if (buffer.items.len >= max_captured_stream_bytes) {
        truncated.* = true;
        return;
    }
    buffer.append(allocator, byte) catch {
        truncated.* = true;
    };
}

fn appendSlice(
    buffer: *std.ArrayList(u8),
    truncated: *bool,
    allocator: std.mem.Allocator,
    slice: []const u8,
) void {
    if (truncated.* or slice.len == 0) return;

    const remaining = max_captured_stream_bytes -| buffer.items.len;
    if (remaining == 0) {
        truncated.* = true;
        return;
    }

    const count = @min(remaining, slice.len);
    buffer.appendSlice(allocator, slice[0..count]) catch {
        truncated.* = true;
        return;
    };
    if (count < slice.len) truncated.* = true;
}

fn luaPop(state: *c.lua_State, count: c_int) void {
    c.lua_settop(state, -count - 1);
}

fn captureFromLuaState(state: *c.lua_State) ?*LuaOutputCapture {
    _ = c.lua_getglobal(state, capture_registry_key);
    defer luaPop(state, 1);

    const ptr = c.lua_touserdata(state, -1) orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn luaCapturedPrint(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;
    const capture = captureFromLuaState(state) orelse return 0;

    const nargs = c.lua_gettop(state);
    var arg_idx: c_int = 1;
    while (arg_idx <= nargs) : (arg_idx += 1) {
        if (arg_idx > 1) capture.appendStdoutByte('\t');

        var str_len: usize = 0;
        if (c.luaL_tolstring(state, arg_idx, &str_len)) |text_ptr| {
            capture.appendStdoutSlice(text_ptr[0..str_len]);
            luaPop(state, 1);
        } else {
            capture.appendStdoutSlice("nil");
        }
    }
    capture.appendStdoutByte('\n');
    return 0;
}

fn luaCapturedStderrPrint(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;
    const capture = captureFromLuaState(state) orelse return 0;

    const nargs = c.lua_gettop(state);
    var arg_idx: c_int = 1;
    if (nargs > 0 and c.lua_type(state, 1) == c.LUA_TTABLE) {
        // Support method-style calls: zoid:eprint("message")
        arg_idx = 2;
    }

    while (arg_idx <= nargs) : (arg_idx += 1) {
        var str_len: usize = 0;
        if (c.luaL_tolstring(state, arg_idx, &str_len)) |text_ptr| {
            capture.appendStderrSlice(text_ptr[0..str_len]);
            luaPop(state, 1);
        }
    }
    return 0;
}

fn toolEnvironmentFromLuaState(state: *c.lua_State) ?*ToolLuaEnvironment {
    _ = c.lua_getglobal(state, tool_sandbox_registry_key);
    defer luaPop(state, 1);

    const ptr = c.lua_touserdata(state, -1) orelse return null;
    return @ptrCast(@alignCast(ptr));
}

pub fn timeoutSecondsToNanoseconds(timeout_seconds: u32) u64 {
    return @as(u64, timeout_seconds) * std.time.ns_per_s;
}

fn parseTimeoutToken(message: []const u8) ?u32 {
    const token_start = std.mem.indexOf(u8, message, timeout_error_token) orelse return null;
    const numeric_start = token_start + timeout_error_token.len;
    if (numeric_start >= message.len) return null;

    var end_index = numeric_start;
    while (end_index < message.len and message[end_index] >= '0' and message[end_index] <= '9') : (end_index += 1) {}
    if (end_index == numeric_start) return null;

    return std.fmt.parseInt(u32, message[numeric_start..end_index], 10) catch null;
}

fn formatTimeoutMessage(buffer: []u8, timeout_seconds: u32) []const u8 {
    return std.fmt.bufPrint(buffer, "Lua execution timed out after {d} second(s).", .{timeout_seconds}) catch "Lua execution timed out.";
}

fn timeoutFromLuaState(state: *c.lua_State) ?*LuaExecutionTimeout {
    _ = c.lua_getglobal(state, timeout_registry_key);
    defer luaPop(state, 1);

    const ptr = c.lua_touserdata(state, -1) orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn luaExecutionTimeoutHook(lua_state: ?*c.lua_State, debug: ?*c.lua_Debug) callconv(.c) void {
    _ = debug;

    const state = lua_state orelse return;
    const timeout = timeoutFromLuaState(state) orelse return;
    if (std.time.nanoTimestamp() < timeout.deadline_ns) return;

    _ = pushLuaErrorMessage(state, "{s}{d}", .{ timeout_error_token, timeout.timeout_seconds });
}

fn installExecutionTimeout(lua_state: *c.lua_State, timeout: *LuaExecutionTimeout) void {
    c.lua_pushlightuserdata(lua_state, timeout);
    _ = c.lua_setglobal(lua_state, timeout_registry_key);
    _ = c.lua_sethook(lua_state, luaExecutionTimeoutHook, c.LUA_MASKCOUNT, 10_000);
}

fn pushLuaErrorMessage(state: *c.lua_State, comptime format: []const u8, args: anytype) c_int {
    var buffer: [256]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, format, args) catch "Lua operation failed.";
    _ = c.lua_pushlstring(state, message.ptr, message.len);
    return c.lua_error(state);
}

fn deinitOwnedRequestHeaders(allocator: std.mem.Allocator, headers: *std.ArrayList(OwnedRequestHeader)) void {
    for (headers.items) |header| {
        allocator.free(header.name);
        allocator.free(header.value);
    }
    headers.deinit(allocator);
}

fn pushJsonNull(state: *c.lua_State) void {
    c.lua_pushlightuserdata(state, @ptrCast(&json_null_sentinel));
}

fn pushLuaJsonValue(state: *c.lua_State, value: std.json.Value, depth: usize) !void {
    if (depth >= max_json_decode_depth) return error.JsonNestingTooDeep;

    switch (value) {
        .null => pushJsonNull(state),
        .bool => |bool_value| c.lua_pushboolean(state, if (bool_value) 1 else 0),
        .integer => |int_value| c.lua_pushinteger(state, @intCast(int_value)),
        .float => |float_value| c.lua_pushnumber(state, float_value),
        .number_string => |number_string| {
            const float_value = try std.fmt.parseFloat(f64, number_string);
            c.lua_pushnumber(state, float_value);
        },
        .string => |string_value| {
            _ = c.lua_pushlstring(state, string_value.ptr, string_value.len);
        },
        .array => |array_value| {
            c.lua_newtable(state);
            for (array_value.items, 0..) |entry, index| {
                try pushLuaJsonValue(state, entry, depth + 1);
                c.lua_rawseti(state, -2, @intCast(index + 1));
            }
        },
        .object => |object_value| {
            c.lua_newtable(state);
            var iterator = object_value.iterator();
            while (iterator.next()) |entry| {
                const key = entry.key_ptr.*;
                _ = c.lua_pushlstring(state, key.ptr, key.len);
                try pushLuaJsonValue(state, entry.value_ptr.*, depth + 1);
                c.lua_settable(state, -3);
            }
        },
    }
}

fn setLuaMetadataFields(state: *c.lua_State, metadata: *const workspace_fs.PathMetadata, workspace_path: []const u8) void {
    _ = c.lua_pushlstring(state, metadata.name.ptr, metadata.name.len);
    c.lua_setfield(state, -2, "name");

    _ = c.lua_pushlstring(state, workspace_path.ptr, workspace_path.len);
    c.lua_setfield(state, -2, "path");

    const type_name = workspace_fs.entryTypeToString(metadata.entry_type);
    _ = c.lua_pushlstring(state, type_name.ptr, type_name.len);
    c.lua_setfield(state, -2, "type");

    if (std.math.cast(c.lua_Integer, metadata.size)) |size_value| {
        c.lua_pushinteger(state, size_value);
    } else {
        c.lua_pushnumber(state, @floatFromInt(metadata.size));
    }
    c.lua_setfield(state, -2, "size");

    _ = c.lua_pushlstring(state, metadata.mode.ptr, metadata.mode.len);
    c.lua_setfield(state, -2, "mode");

    _ = c.lua_pushlstring(state, metadata.owner.ptr, metadata.owner.len);
    c.lua_setfield(state, -2, "owner");

    _ = c.lua_pushlstring(state, metadata.group.ptr, metadata.group.len);
    c.lua_setfield(state, -2, "group");

    _ = c.lua_pushlstring(state, metadata.modified_at.ptr, metadata.modified_at.len);
    c.lua_setfield(state, -2, "modified_at");
}

fn luaZoidFileRead(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;
    const env = toolEnvironmentFromLuaState(state) orelse return pushLuaErrorMessage(state, "workspace context unavailable", .{});
    const nargs = c.lua_gettop(state);

    if (c.lua_type(state, 1) != c.LUA_TTABLE) {
        return pushLuaErrorMessage(state, "zoid.file(path):read requires file handle", .{});
    }

    _ = c.lua_getfield(state, 1, "_path");

    var path_len: usize = 0;
    const path_ptr = c.lua_tolstring(state, -1, &path_len) orelse return pushLuaErrorMessage(state, "zoid.file(path):read requires file handle", .{});
    const requested_path = path_ptr[0..path_len];
    luaPop(state, 1);

    var max_bytes = env.max_read_bytes;
    if (nargs >= 2 and c.lua_type(state, 2) != c.LUA_TNIL) {
        var isnum: c_int = 0;
        const requested_max = c.lua_tointegerx(state, 2, &isnum);
        if (isnum == 0 or requested_max <= 0) {
            return pushLuaErrorMessage(state, "zoid.file(path):read max_bytes must be a positive integer", .{});
        }
        const converted = std.math.cast(usize, requested_max) orelse {
            return pushLuaErrorMessage(state, "zoid.file(path):read max_bytes is too large", .{});
        };
        if (converted > env.max_read_bytes) {
            return pushLuaErrorMessage(state, "zoid.file(path):read max_bytes exceeds allowed limit ({d})", .{env.max_read_bytes});
        }
        max_bytes = converted;
    }

    const read_result = workspace_fs.readFileAlloc(
        env.allocator,
        env.workspace_root,
        requested_path,
        max_bytes,
    ) catch |err| {
        return pushLuaErrorMessage(state, "zoid.file(path):read failed: {s}", .{@errorName(err)});
    };
    defer read_result.deinit(env.allocator);

    _ = c.lua_pushlstring(state, read_result.content.ptr, read_result.content.len);
    return 1;
}

fn luaZoidFileWrite(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;
    const env = toolEnvironmentFromLuaState(state) orelse return pushLuaErrorMessage(state, "workspace context unavailable", .{});

    if (c.lua_type(state, 1) != c.LUA_TTABLE) {
        return pushLuaErrorMessage(state, "zoid.file(path):write requires file handle", .{});
    }

    _ = c.lua_getfield(state, 1, "_path");

    var path_len: usize = 0;
    const path_ptr = c.lua_tolstring(state, -1, &path_len) orelse return pushLuaErrorMessage(state, "zoid.file(path):write requires file handle", .{});
    const requested_path = path_ptr[0..path_len];
    luaPop(state, 1);

    var content_len: usize = 0;
    const content_ptr = c.luaL_checklstring(state, 2, &content_len) orelse return pushLuaErrorMessage(state, "zoid.file(path):write requires content", .{});
    const content = content_ptr[0..content_len];

    const write_result = workspace_fs.writeFile(
        env.allocator,
        env.workspace_root,
        requested_path,
        content,
    ) catch |err| {
        return pushLuaErrorMessage(state, "zoid.file(path):write failed: {s}", .{@errorName(err)});
    };
    defer write_result.deinit(env.allocator);

    c.lua_pushinteger(state, @intCast(write_result.bytes_written));
    return 1;
}

fn luaZoidFileDelete(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;
    const env = toolEnvironmentFromLuaState(state) orelse return pushLuaErrorMessage(state, "workspace context unavailable", .{});

    if (c.lua_type(state, 1) != c.LUA_TTABLE) {
        return pushLuaErrorMessage(state, "zoid.file(path):delete requires file handle", .{});
    }

    _ = c.lua_getfield(state, 1, "_path");

    var path_len: usize = 0;
    const path_ptr = c.lua_tolstring(state, -1, &path_len) orelse return pushLuaErrorMessage(state, "zoid.file(path):delete requires file handle", .{});
    const requested_path = path_ptr[0..path_len];
    luaPop(state, 1);

    const delete_result = workspace_fs.deleteFile(
        env.allocator,
        env.workspace_root,
        requested_path,
    ) catch |err| {
        return pushLuaErrorMessage(state, "zoid.file(path):delete failed: {s}", .{@errorName(err)});
    };
    defer delete_result.deinit(env.allocator);

    c.lua_pushboolean(state, 1);
    return 1;
}

fn luaZoidFile(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;
    const env = toolEnvironmentFromLuaState(state) orelse return pushLuaErrorMessage(state, "workspace context unavailable", .{});

    var path_len: usize = 0;
    const path_ptr = c.luaL_checklstring(state, 1, &path_len) orelse return pushLuaErrorMessage(state, "zoid.file requires path", .{});
    const requested_path = path_ptr[0..path_len];

    const metadata = workspace_fs.getPathMetadata(
        env.allocator,
        env.workspace_root,
        requested_path,
        .file,
    ) catch |err| {
        return pushLuaErrorMessage(state, "zoid.file(path) failed: {s}", .{@errorName(err)});
    };
    defer metadata.deinit(env.allocator);

    const workspace_path = workspace_fs.toWorkspaceAbsolutePath(
        env.allocator,
        env.workspace_root,
        metadata.path,
    ) catch |err| {
        return pushLuaErrorMessage(state, "zoid.file(path) failed: {s}", .{@errorName(err)});
    };
    defer env.allocator.free(workspace_path);

    c.lua_newtable(state);
    _ = c.lua_pushlstring(state, workspace_path.ptr, workspace_path.len);
    c.lua_setfield(state, -2, "_path");
    setLuaMetadataFields(state, &metadata, workspace_path);

    c.lua_pushcclosure(state, luaZoidFileRead, 0);
    c.lua_setfield(state, -2, "read");
    c.lua_pushcclosure(state, luaZoidFileWrite, 0);
    c.lua_setfield(state, -2, "write");
    c.lua_pushcclosure(state, luaZoidFileDelete, 0);
    c.lua_setfield(state, -2, "delete");
    return 1;
}

fn luaZoidDirList(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;
    const env = toolEnvironmentFromLuaState(state) orelse return pushLuaErrorMessage(state, "workspace context unavailable", .{});

    if (c.lua_type(state, 1) != c.LUA_TTABLE) {
        return pushLuaErrorMessage(state, "zoid.dir(path):list requires directory handle", .{});
    }

    _ = c.lua_getfield(state, 1, "_path");
    var path_len: usize = 0;
    const path_ptr = c.lua_tolstring(state, -1, &path_len) orelse return pushLuaErrorMessage(state, "zoid.dir(path):list requires directory handle", .{});
    const requested_path = path_ptr[0..path_len];
    luaPop(state, 1);

    const list_result = workspace_fs.listDirectory(
        env.allocator,
        env.workspace_root,
        requested_path,
    ) catch |err| {
        return pushLuaErrorMessage(state, "zoid.dir(path):list failed: {s}", .{@errorName(err)});
    };
    defer list_result.deinit(env.allocator);

    c.lua_newtable(state);
    for (list_result.entries, 0..) |entry, index| {
        const workspace_path = workspace_fs.toWorkspaceAbsolutePath(
            env.allocator,
            env.workspace_root,
            entry.path,
        ) catch |err| {
            return pushLuaErrorMessage(state, "zoid.dir(path):list failed: {s}", .{@errorName(err)});
        };
        defer env.allocator.free(workspace_path);

        c.lua_pushinteger(state, @intCast(index + 1));
        c.lua_newtable(state);
        setLuaMetadataFields(state, &entry, workspace_path);
        c.lua_settable(state, -3);
    }
    return 1;
}

fn luaZoidDirCreate(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;
    const env = toolEnvironmentFromLuaState(state) orelse return pushLuaErrorMessage(state, "workspace context unavailable", .{});

    if (c.lua_type(state, 1) != c.LUA_TTABLE) {
        return pushLuaErrorMessage(state, "zoid.dir(path):create requires directory handle", .{});
    }

    _ = c.lua_getfield(state, 1, "_path");
    var path_len: usize = 0;
    const path_ptr = c.lua_tolstring(state, -1, &path_len) orelse return pushLuaErrorMessage(state, "zoid.dir(path):create requires directory handle", .{});
    const requested_path = path_ptr[0..path_len];
    luaPop(state, 1);

    const create_result = workspace_fs.createDirectory(
        env.allocator,
        env.workspace_root,
        requested_path,
    ) catch |err| {
        return pushLuaErrorMessage(state, "zoid.dir(path):create failed: {s}", .{@errorName(err)});
    };
    defer create_result.deinit(env.allocator);

    c.lua_pushboolean(state, 1);
    return 1;
}

fn luaZoidDirRemove(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;
    const env = toolEnvironmentFromLuaState(state) orelse return pushLuaErrorMessage(state, "workspace context unavailable", .{});

    if (c.lua_type(state, 1) != c.LUA_TTABLE) {
        return pushLuaErrorMessage(state, "zoid.dir(path):remove requires directory handle", .{});
    }

    _ = c.lua_getfield(state, 1, "_path");
    var path_len: usize = 0;
    const path_ptr = c.lua_tolstring(state, -1, &path_len) orelse return pushLuaErrorMessage(state, "zoid.dir(path):remove requires directory handle", .{});
    const requested_path = path_ptr[0..path_len];
    luaPop(state, 1);

    const remove_result = workspace_fs.removeDirectory(
        env.allocator,
        env.workspace_root,
        requested_path,
    ) catch |err| {
        return pushLuaErrorMessage(state, "zoid.dir(path):remove failed: {s}", .{@errorName(err)});
    };
    defer remove_result.deinit(env.allocator);

    c.lua_pushboolean(state, 1);
    return 1;
}

fn luaZoidDirGrep(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;
    const env = toolEnvironmentFromLuaState(state) orelse return pushLuaErrorMessage(state, "workspace context unavailable", .{});
    const nargs = c.lua_gettop(state);

    if (c.lua_type(state, 1) != c.LUA_TTABLE) {
        return pushLuaErrorMessage(state, "zoid.dir(path):grep requires directory handle", .{});
    }

    _ = c.lua_getfield(state, 1, "_path");
    var path_len: usize = 0;
    const path_ptr = c.lua_tolstring(state, -1, &path_len) orelse return pushLuaErrorMessage(state, "zoid.dir(path):grep requires directory handle", .{});
    const requested_path = path_ptr[0..path_len];
    luaPop(state, 1);

    var pattern_len: usize = 0;
    const pattern_ptr = c.luaL_checklstring(state, 2, &pattern_len) orelse return pushLuaErrorMessage(state, "zoid.dir(path):grep requires pattern", .{});
    const pattern = pattern_ptr[0..pattern_len];

    var recursive = true;
    var max_matches = workspace_fs.default_max_grep_matches;

    if (nargs >= 3 and c.lua_type(state, 3) != c.LUA_TNIL) {
        if (c.lua_type(state, 3) != c.LUA_TTABLE) {
            return pushLuaErrorMessage(state, "zoid.dir(path):grep options must be a table", .{});
        }

        const options_table = c.lua_absindex(state, 3);
        c.lua_pushnil(state);
        while (c.lua_next(state, options_table) != 0) {
            if (c.lua_type(state, -2) != c.LUA_TSTRING) {
                c.lua_settop(state, options_table);
                return pushLuaErrorMessage(state, "zoid.dir(path):grep option keys must be strings", .{});
            }

            var option_key_len: usize = 0;
            const option_key_ptr = c.lua_tolstring(state, -2, &option_key_len) orelse {
                c.lua_settop(state, options_table);
                return pushLuaErrorMessage(state, "zoid.dir(path):grep option keys must be strings", .{});
            };
            const option_key = option_key_ptr[0..option_key_len];

            if (std.mem.eql(u8, option_key, "recursive")) {
                if (c.lua_type(state, -1) != c.LUA_TBOOLEAN) {
                    c.lua_settop(state, options_table);
                    return pushLuaErrorMessage(state, "zoid.dir(path):grep option recursive must be boolean", .{});
                }
                recursive = c.lua_toboolean(state, -1) != 0;
                luaPop(state, 1);
                continue;
            }

            if (std.mem.eql(u8, option_key, "max_matches")) {
                var isnum: c_int = 0;
                const value = c.lua_tointegerx(state, -1, &isnum);
                if (isnum == 0 or value <= 0) {
                    c.lua_settop(state, options_table);
                    return pushLuaErrorMessage(state, "zoid.dir(path):grep option max_matches must be a positive integer", .{});
                }
                max_matches = std.math.cast(usize, value) orelse {
                    c.lua_settop(state, options_table);
                    return pushLuaErrorMessage(state, "zoid.dir(path):grep option max_matches is too large", .{});
                };
                if (max_matches > workspace_fs.max_allowed_grep_matches) {
                    c.lua_settop(state, options_table);
                    return pushLuaErrorMessage(
                        state,
                        "zoid.dir(path):grep option max_matches exceeds allowed limit ({d})",
                        .{workspace_fs.max_allowed_grep_matches},
                    );
                }
                luaPop(state, 1);
                continue;
            }

            c.lua_settop(state, options_table);
            return pushLuaErrorMessage(state, "zoid.dir(path):grep unsupported option '{s}'", .{option_key});
        }
    }

    var grep_result = workspace_fs.grep(
        env.allocator,
        env.workspace_root,
        requested_path,
        pattern,
        recursive,
        max_matches,
    ) catch |err| {
        return pushLuaErrorMessage(state, "zoid.dir(path):grep failed: {s}", .{@errorName(err)});
    };
    defer grep_result.deinit(env.allocator);

    c.lua_newtable(state);
    for (grep_result.matches, 0..) |match, index| {
        const workspace_path = workspace_fs.toWorkspaceAbsolutePath(
            env.allocator,
            env.workspace_root,
            match.path,
        ) catch |err| {
            return pushLuaErrorMessage(state, "zoid.dir(path):grep failed: {s}", .{@errorName(err)});
        };
        defer env.allocator.free(workspace_path);

        c.lua_pushinteger(state, @intCast(index + 1));
        c.lua_newtable(state);

        _ = c.lua_pushlstring(state, workspace_path.ptr, workspace_path.len);
        c.lua_setfield(state, -2, "path");

        c.lua_pushinteger(state, @intCast(match.line));
        c.lua_setfield(state, -2, "line");

        c.lua_pushinteger(state, @intCast(match.column));
        c.lua_setfield(state, -2, "column");

        _ = c.lua_pushlstring(state, match.text.ptr, match.text.len);
        c.lua_setfield(state, -2, "text");

        c.lua_settable(state, -3);
    }

    return 1;
}

fn luaZoidDir(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;
    const env = toolEnvironmentFromLuaState(state) orelse return pushLuaErrorMessage(state, "workspace context unavailable", .{});

    var path_len: usize = 0;
    const path_ptr = c.luaL_checklstring(state, 1, &path_len) orelse return pushLuaErrorMessage(state, "zoid.dir requires path", .{});
    const requested_path = path_ptr[0..path_len];

    const metadata = workspace_fs.getPathMetadata(
        env.allocator,
        env.workspace_root,
        requested_path,
        .directory,
    ) catch |err| {
        return pushLuaErrorMessage(state, "zoid.dir(path) failed: {s}", .{@errorName(err)});
    };
    defer metadata.deinit(env.allocator);

    if (metadata.exists and metadata.entry_type != .directory) {
        return pushLuaErrorMessage(state, "zoid.dir(path) failed: NotDir", .{});
    }

    const workspace_path = workspace_fs.toWorkspaceAbsolutePath(
        env.allocator,
        env.workspace_root,
        metadata.path,
    ) catch |err| {
        return pushLuaErrorMessage(state, "zoid.dir(path) failed: {s}", .{@errorName(err)});
    };
    defer env.allocator.free(workspace_path);

    c.lua_newtable(state);
    _ = c.lua_pushlstring(state, workspace_path.ptr, workspace_path.len);
    c.lua_setfield(state, -2, "_path");
    setLuaMetadataFields(state, &metadata, workspace_path);

    c.lua_pushcclosure(state, luaZoidDirList, 0);
    c.lua_setfield(state, -2, "list");
    c.lua_pushcclosure(state, luaZoidDirCreate, 0);
    c.lua_setfield(state, -2, "create");
    c.lua_pushcclosure(state, luaZoidDirRemove, 0);
    c.lua_setfield(state, -2, "remove");
    c.lua_pushcclosure(state, luaZoidDirGrep, 0);
    c.lua_setfield(state, -2, "grep");
    return 1;
}

fn resolveImportPath(
    allocator: std.mem.Allocator,
    env: *ToolLuaEnvironment,
    requested_path: []const u8,
) ![]u8 {
    if (requested_path.len == 0) return error.InvalidToolArguments;
    if (std.fs.path.isAbsolute(requested_path)) {
        return workspace_fs.resolveAllowedReadPath(allocator, env.workspace_root, requested_path);
    }

    if (env.module_stack.items.len == 0) {
        return workspace_fs.resolveAllowedReadPath(allocator, env.workspace_root, requested_path);
    }

    const caller_path = env.module_stack.items[env.module_stack.items.len - 1];
    const caller_dir = std.fs.path.dirname(caller_path) orelse env.workspace_root;
    const candidate_path = try std.fs.path.join(allocator, &.{ caller_dir, requested_path });
    defer allocator.free(candidate_path);

    return workspace_fs.resolveAllowedReadPath(allocator, env.workspace_root, candidate_path);
}

fn moduleStackContains(module_stack: []const []u8, module_path: []const u8) bool {
    for (module_stack) |entry| {
        if (std.mem.eql(u8, entry, module_path)) return true;
    }
    return false;
}

fn luaZoidImport(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;
    const env = toolEnvironmentFromLuaState(state) orelse return pushLuaErrorMessage(state, "workspace context unavailable", .{});

    const nargs = c.lua_gettop(state);
    if (nargs != 1) {
        return pushLuaErrorMessage(state, "zoid.import requires exactly one path argument", .{});
    }

    var requested_path_len: usize = 0;
    const requested_path_ptr = c.luaL_checklstring(state, 1, &requested_path_len) orelse {
        return pushLuaErrorMessage(state, "zoid.import requires path", .{});
    };
    const requested_path = requested_path_ptr[0..requested_path_len];

    const resolved_module_path = resolveImportPath(env.allocator, env, requested_path) catch |err| {
        return pushLuaErrorMessage(state, "zoid.import(path) failed: {s}", .{@errorName(err)});
    };
    var keep_resolved_module_path = false;
    defer if (!keep_resolved_module_path) env.allocator.free(resolved_module_path);

    if (!std.mem.eql(u8, std.fs.path.extension(resolved_module_path), ".lua")) {
        return pushLuaErrorMessage(state, "zoid.import(path) requires a .lua module path", .{});
    }

    if (env.module_cache.get(resolved_module_path)) |cached_ref| {
        _ = c.lua_rawgeti(state, c.LUA_REGISTRYINDEX, cached_ref);
        return 1;
    }

    if (moduleStackContains(env.module_stack.items, resolved_module_path)) {
        return pushLuaErrorMessage(state, "zoid.import(path) cyclic import detected: {s}", .{resolved_module_path});
    }

    const c_module_path = env.allocator.dupeZ(u8, resolved_module_path) catch |err| {
        return pushLuaErrorMessage(state, "zoid.import(path) failed: {s}", .{@errorName(err)});
    };
    defer env.allocator.free(c_module_path);

    if (c.luaL_loadfilex(state, c_module_path.ptr, "t") != c.LUA_OK) {
        return pushLuaErrorMessage(state, "zoid.import(path) load failed: {s}", .{luaErrorMessage(state)});
    }

    env.pushModuleStackPath(resolved_module_path) catch |err| {
        luaPop(state, 1);
        return pushLuaErrorMessage(state, "zoid.import(path) failed: {s}", .{@errorName(err)});
    };
    defer env.popModuleStackPath();

    if (c.lua_pcallk(state, 0, 1, 0, 0, null) != c.LUA_OK) {
        return pushLuaErrorMessage(state, "zoid.import(path) runtime failed: {s}", .{luaErrorMessage(state)});
    }

    if (c.lua_type(state, -1) == c.LUA_TNIL) {
        luaPop(state, 1);
        c.lua_pushboolean(state, 1);
    }

    c.lua_pushvalue(state, -1);
    const module_ref = c.luaL_ref(state, c.LUA_REGISTRYINDEX);

    env.module_cache.put(env.allocator, resolved_module_path, module_ref) catch |err| {
        c.luaL_unref(state, c.LUA_REGISTRYINDEX, module_ref);
        return pushLuaErrorMessage(state, "zoid.import(path) failed: {s}", .{@errorName(err)});
    };
    keep_resolved_module_path = true;
    return 1;
}

fn parseUriHeaderOptions(
    state: *c.lua_State,
    method_name: []const u8,
    headers_index: c_int,
    env: *ToolLuaEnvironment,
    owned_headers: *std.ArrayList(OwnedRequestHeader),
) ?c_int {
    const headers_table = c.lua_absindex(state, headers_index);

    c.lua_pushnil(state);
    while (c.lua_next(state, headers_table) != 0) {
        if (c.lua_type(state, -2) != c.LUA_TSTRING) {
            c.lua_settop(state, headers_table);
            return pushLuaErrorMessage(state, "zoid.uri(uri):{s} option headers keys must be strings", .{method_name});
        }
        if (c.lua_type(state, -1) != c.LUA_TSTRING) {
            c.lua_settop(state, headers_table);
            return pushLuaErrorMessage(state, "zoid.uri(uri):{s} option headers values must be strings", .{method_name});
        }

        if (owned_headers.items.len >= http_client.max_request_headers) {
            c.lua_settop(state, headers_table);
            return pushLuaErrorMessage(state, "zoid.uri(uri):{s} has too many headers", .{method_name});
        }

        var header_name_len: usize = 0;
        const header_name_ptr = c.lua_tolstring(state, -2, &header_name_len) orelse {
            c.lua_settop(state, headers_table);
            return pushLuaErrorMessage(state, "zoid.uri(uri):{s} option headers keys must be strings", .{method_name});
        };
        const header_name = header_name_ptr[0..header_name_len];

        var header_value_len: usize = 0;
        const header_value_ptr = c.lua_tolstring(state, -1, &header_value_len) orelse {
            c.lua_settop(state, headers_table);
            return pushLuaErrorMessage(state, "zoid.uri(uri):{s} option headers values must be strings", .{method_name});
        };
        const header_value = header_value_ptr[0..header_value_len];

        const owned_header_name = env.allocator.dupe(u8, header_name) catch |err| {
            c.lua_settop(state, headers_table);
            return pushLuaErrorMessage(state, "zoid.uri(uri):{s} failed: {s}", .{ method_name, @errorName(err) });
        };

        const owned_header_value = env.allocator.dupe(u8, header_value) catch |err| {
            env.allocator.free(owned_header_name);
            c.lua_settop(state, headers_table);
            return pushLuaErrorMessage(state, "zoid.uri(uri):{s} failed: {s}", .{ method_name, @errorName(err) });
        };

        owned_headers.append(env.allocator, .{
            .name = owned_header_name,
            .value = owned_header_value,
        }) catch |err| {
            env.allocator.free(owned_header_name);
            env.allocator.free(owned_header_value);
            c.lua_settop(state, headers_table);
            return pushLuaErrorMessage(state, "zoid.uri(uri):{s} failed: {s}", .{ method_name, @errorName(err) });
        };
        luaPop(state, 1);
    }

    return null;
}

fn parseUriRequestOptions(
    state: *c.lua_State,
    method_name: []const u8,
    options_index: c_int,
    env: *ToolLuaEnvironment,
    owned_headers: *std.ArrayList(OwnedRequestHeader),
) ?c_int {
    if (c.lua_type(state, options_index) != c.LUA_TTABLE) {
        return pushLuaErrorMessage(state, "zoid.uri(uri):{s} options must be a table", .{method_name});
    }

    const options_table = c.lua_absindex(state, options_index);
    c.lua_pushnil(state);
    while (c.lua_next(state, options_table) != 0) {
        if (c.lua_type(state, -2) != c.LUA_TSTRING) {
            c.lua_settop(state, options_table);
            return pushLuaErrorMessage(state, "zoid.uri(uri):{s} option keys must be strings", .{method_name});
        }

        var option_key_len: usize = 0;
        const option_key_ptr = c.lua_tolstring(state, -2, &option_key_len) orelse {
            c.lua_settop(state, options_table);
            return pushLuaErrorMessage(state, "zoid.uri(uri):{s} option keys must be strings", .{method_name});
        };
        const option_key = option_key_ptr[0..option_key_len];

        if (std.mem.eql(u8, option_key, "headers")) {
            if (c.lua_type(state, -1) != c.LUA_TTABLE) {
                c.lua_settop(state, options_table);
                return pushLuaErrorMessage(state, "zoid.uri(uri):{s} option headers must be a table", .{method_name});
            }
            if (parseUriHeaderOptions(state, method_name, -1, env, owned_headers)) |lua_error| {
                c.lua_settop(state, options_table);
                return lua_error;
            }
            luaPop(state, 1);
            continue;
        }

        c.lua_settop(state, options_table);
        return pushLuaErrorMessage(state, "zoid.uri(uri):{s} unsupported option '{s}'", .{ method_name, option_key });
    }

    return null;
}

fn luaZoidUriRequest(
    state: *c.lua_State,
    method: std.http.Method,
    method_name: []const u8,
    allows_body: bool,
) c_int {
    const env = toolEnvironmentFromLuaState(state) orelse return pushLuaErrorMessage(state, "workspace context unavailable", .{});
    const nargs = c.lua_gettop(state);

    if (c.lua_type(state, 1) != c.LUA_TTABLE) {
        return pushLuaErrorMessage(state, "zoid.uri(uri):{s} requires URI handle", .{method_name});
    }

    _ = c.lua_getfield(state, 1, "_uri");
    var uri_len: usize = 0;
    const uri_ptr = c.lua_tolstring(state, -1, &uri_len) orelse return pushLuaErrorMessage(state, "zoid.uri(uri):{s} requires URI handle", .{method_name});
    const uri = uri_ptr[0..uri_len];
    luaPop(state, 1);

    var owned_headers = std.ArrayList(OwnedRequestHeader).empty;
    defer deinitOwnedRequestHeaders(env.allocator, &owned_headers);

    var payload: ?[]const u8 = null;
    var options_index: ?c_int = null;

    if (allows_body) {
        if (nargs > 3) {
            return pushLuaErrorMessage(state, "zoid.uri(uri):{s} accepts body and optional options only", .{method_name});
        }

        if (nargs >= 2 and c.lua_type(state, 2) != c.LUA_TNIL) {
            if (c.lua_type(state, 2) == c.LUA_TTABLE) {
                options_index = 2;
            } else {
                var body_len: usize = 0;
                const body_ptr = c.luaL_checklstring(state, 2, &body_len) orelse return pushLuaErrorMessage(state, "zoid.uri(uri):{s} body must be a string", .{method_name});
                payload = body_ptr[0..body_len];
            }
        }

        if (nargs >= 3 and c.lua_type(state, 3) != c.LUA_TNIL) {
            if (c.lua_type(state, 3) != c.LUA_TTABLE) {
                return pushLuaErrorMessage(state, "zoid.uri(uri):{s} options must be a table", .{method_name});
            }
            if (options_index != null) {
                return pushLuaErrorMessage(state, "zoid.uri(uri):{s} options must be provided once", .{method_name});
            }
            options_index = 3;
        }
    } else {
        if (nargs > 2) {
            return pushLuaErrorMessage(state, "zoid.uri(uri):{s} accepts optional options only", .{method_name});
        }

        if (nargs >= 2 and c.lua_type(state, 2) != c.LUA_TNIL) {
            if (c.lua_type(state, 2) != c.LUA_TTABLE) {
                return pushLuaErrorMessage(state, "zoid.uri(uri):{s} options must be a table", .{method_name});
            }
            options_index = 2;
        }
    }

    if (options_index) |index| {
        if (parseUriRequestOptions(state, method_name, index, env, &owned_headers)) |lua_error| {
            return lua_error;
        }
    }

    const request_headers = env.allocator.alloc(http_client.RequestHeader, owned_headers.items.len) catch |err| {
        return pushLuaErrorMessage(state, "zoid.uri(uri):{s} failed: {s}", .{ method_name, @errorName(err) });
    };
    defer env.allocator.free(request_headers);
    for (owned_headers.items, 0..) |header, index| {
        request_headers[index] = .{
            .name = header.name,
            .value = header.value,
        };
    }

    var result = http_client.executeRequest(
        env.allocator,
        method,
        uri,
        payload,
        request_headers,
        env.max_http_response_bytes,
    ) catch |err| {
        return pushLuaErrorMessage(state, "zoid.uri(uri):{s} failed: {s}", .{ method_name, @errorName(err) });
    };
    defer result.deinit(env.allocator);

    c.lua_newtable(state);

    c.lua_pushinteger(state, @intCast(result.status_code));
    c.lua_setfield(state, -2, "status");

    _ = c.lua_pushlstring(state, result.body.ptr, result.body.len);
    c.lua_setfield(state, -2, "body");

    c.lua_pushboolean(state, if (result.status_code >= 200 and result.status_code < 300) 1 else 0);
    c.lua_setfield(state, -2, "ok");
    return 1;
}

fn luaZoidUriGet(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;
    return luaZoidUriRequest(state, .GET, "get", false);
}

fn luaZoidUriPost(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;
    return luaZoidUriRequest(state, .POST, "post", true);
}

fn luaZoidUriPut(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;
    return luaZoidUriRequest(state, .PUT, "put", true);
}

fn luaZoidUriDelete(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;
    return luaZoidUriRequest(state, .DELETE, "delete", false);
}

fn luaZoidUri(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;

    var uri_len: usize = 0;
    const uri_ptr = c.luaL_checklstring(state, 1, &uri_len) orelse return pushLuaErrorMessage(state, "zoid.uri requires URI string", .{});
    const uri = uri_ptr[0..uri_len];

    c.lua_newtable(state);
    _ = c.lua_pushlstring(state, uri.ptr, uri.len);
    c.lua_setfield(state, -2, "_uri");

    c.lua_pushcclosure(state, luaZoidUriGet, 0);
    c.lua_setfield(state, -2, "get");
    c.lua_pushcclosure(state, luaZoidUriPost, 0);
    c.lua_setfield(state, -2, "post");
    c.lua_pushcclosure(state, luaZoidUriPut, 0);
    c.lua_setfield(state, -2, "put");
    c.lua_pushcclosure(state, luaZoidUriDelete, 0);
    c.lua_setfield(state, -2, "delete");
    return 1;
}

fn luaZoidConfigList(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;
    const env = toolEnvironmentFromLuaState(state) orelse return pushLuaErrorMessage(state, "workspace context unavailable", .{});

    if (c.lua_type(state, 1) != c.LUA_TTABLE) {
        return pushLuaErrorMessage(state, "zoid.config():list requires config handle", .{});
    }

    var result = config_runtime.execute(
        env.allocator,
        .{ .config_path_override = env.config_path_override },
        .list,
    ) catch |err| {
        return pushLuaErrorMessage(state, "zoid.config():list failed: {s}", .{@errorName(err)});
    };
    defer result.deinit(env.allocator);

    const keys = switch (result) {
        .list => |value| value,
        else => unreachable,
    };

    c.lua_newtable(state);
    for (keys, 0..) |key, index| {
        c.lua_pushinteger(state, @intCast(index + 1));
        _ = c.lua_pushlstring(state, key.ptr, key.len);
        c.lua_settable(state, -3);
    }
    return 1;
}

fn luaZoidConfigGet(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;
    const env = toolEnvironmentFromLuaState(state) orelse return pushLuaErrorMessage(state, "workspace context unavailable", .{});

    if (c.lua_type(state, 1) != c.LUA_TTABLE) {
        return pushLuaErrorMessage(state, "zoid.config():get requires config handle", .{});
    }

    var key_len: usize = 0;
    const key_ptr = c.luaL_checklstring(state, 2, &key_len) orelse return pushLuaErrorMessage(state, "zoid.config():get requires key", .{});
    const key = key_ptr[0..key_len];

    var result = config_runtime.execute(
        env.allocator,
        .{ .config_path_override = env.config_path_override },
        .{ .get = key },
    ) catch |err| {
        return pushLuaErrorMessage(state, "zoid.config():get failed: {s}", .{@errorName(err)});
    };
    defer result.deinit(env.allocator);

    switch (result) {
        .get => |maybe_value| {
            if (maybe_value) |value| {
                _ = c.lua_pushlstring(state, value.ptr, value.len);
            } else {
                c.lua_pushnil(state);
            }
        },
        else => unreachable,
    }
    return 1;
}

fn luaZoidConfigSet(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;
    const env = toolEnvironmentFromLuaState(state) orelse return pushLuaErrorMessage(state, "workspace context unavailable", .{});

    if (c.lua_type(state, 1) != c.LUA_TTABLE) {
        return pushLuaErrorMessage(state, "zoid.config():set requires config handle", .{});
    }

    var key_len: usize = 0;
    const key_ptr = c.luaL_checklstring(state, 2, &key_len) orelse return pushLuaErrorMessage(state, "zoid.config():set requires key", .{});
    const key = key_ptr[0..key_len];

    var value_len: usize = 0;
    const value_ptr = c.luaL_checklstring(state, 3, &value_len) orelse return pushLuaErrorMessage(state, "zoid.config():set requires value", .{});
    const value = value_ptr[0..value_len];

    var result = config_runtime.execute(
        env.allocator,
        .{ .config_path_override = env.config_path_override },
        .{ .set = .{ .key = key, .value = value } },
    ) catch |err| {
        return pushLuaErrorMessage(state, "zoid.config():set failed: {s}", .{@errorName(err)});
    };
    defer result.deinit(env.allocator);

    c.lua_pushboolean(state, 1);
    return 1;
}

fn luaZoidConfigUnset(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;
    const env = toolEnvironmentFromLuaState(state) orelse return pushLuaErrorMessage(state, "workspace context unavailable", .{});

    if (c.lua_type(state, 1) != c.LUA_TTABLE) {
        return pushLuaErrorMessage(state, "zoid.config():unset requires config handle", .{});
    }

    var key_len: usize = 0;
    const key_ptr = c.luaL_checklstring(state, 2, &key_len) orelse return pushLuaErrorMessage(state, "zoid.config():unset requires key", .{});
    const key = key_ptr[0..key_len];

    var result = config_runtime.execute(
        env.allocator,
        .{ .config_path_override = env.config_path_override },
        .{ .unset = key },
    ) catch |err| {
        return pushLuaErrorMessage(state, "zoid.config():unset failed: {s}", .{@errorName(err)});
    };
    defer result.deinit(env.allocator);

    const removed = switch (result) {
        .unset => |value| value,
        else => unreachable,
    };
    c.lua_pushboolean(state, if (removed) 1 else 0);
    return 1;
}

fn luaZoidConfig(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;

    c.lua_newtable(state);
    c.lua_pushcclosure(state, luaZoidConfigList, 0);
    c.lua_setfield(state, -2, "list");
    c.lua_pushcclosure(state, luaZoidConfigGet, 0);
    c.lua_setfield(state, -2, "get");
    c.lua_pushcclosure(state, luaZoidConfigSet, 0);
    c.lua_setfield(state, -2, "set");
    c.lua_pushcclosure(state, luaZoidConfigUnset, 0);
    c.lua_setfield(state, -2, "unset");
    return 1;
}

fn pushLuaSchedulerJobTable(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    state: *c.lua_State,
    job: *const scheduler_store.Job,
) !void {
    const workspace_path = try workspace_fs.toWorkspaceAbsolutePath(allocator, workspace_root, job.path);
    defer allocator.free(workspace_path);

    c.lua_newtable(state);

    _ = c.lua_pushlstring(state, job.id.ptr, job.id.len);
    c.lua_setfield(state, -2, "id");

    _ = c.lua_pushlstring(state, workspace_path.ptr, workspace_path.len);
    c.lua_setfield(state, -2, "path");

    c.lua_pushboolean(state, if (job.paused) 1 else 0);
    c.lua_setfield(state, -2, "paused");

    if (job.run_at) |run_at| {
        c.lua_pushinteger(state, @intCast(run_at));
    } else {
        c.lua_pushnil(state);
    }
    c.lua_setfield(state, -2, "run_at");

    if (job.cron) |cron| {
        _ = c.lua_pushlstring(state, cron.ptr, cron.len);
    } else {
        c.lua_pushnil(state);
    }
    c.lua_setfield(state, -2, "cron");

    c.lua_pushinteger(state, @intCast(job.next_run_at));
    c.lua_setfield(state, -2, "next_run_at");

    c.lua_pushinteger(state, @intCast(job.created_at));
    c.lua_setfield(state, -2, "created_at");

    c.lua_pushinteger(state, @intCast(job.updated_at));
    c.lua_setfield(state, -2, "updated_at");

    if (job.last_run_at) |last_run_at| {
        c.lua_pushinteger(state, @intCast(last_run_at));
    } else {
        c.lua_pushnil(state);
    }
    c.lua_setfield(state, -2, "last_run_at");
}

fn luaZoidJobsCreate(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;
    const env = toolEnvironmentFromLuaState(state) orelse return pushLuaErrorMessage(state, "workspace context unavailable", .{});

    if (c.lua_type(state, 1) != c.LUA_TTABLE) {
        return pushLuaErrorMessage(state, "zoid.jobs.create requires a table argument", .{});
    }
    const options_index = c.lua_absindex(state, 1);

    _ = c.lua_getfield(state, options_index, "path");
    var path_len: usize = 0;
    const path_ptr = c.lua_tolstring(state, -1, &path_len) orelse {
        luaPop(state, 1);
        return pushLuaErrorMessage(state, "zoid.jobs.create requires path", .{});
    };
    const path_value = env.allocator.dupe(u8, path_ptr[0..path_len]) catch |err| {
        luaPop(state, 1);
        return pushLuaErrorMessage(state, "zoid.jobs.create failed: {s}", .{@errorName(err)});
    };
    defer env.allocator.free(path_value);
    luaPop(state, 1);

    var run_at_value: ?[]u8 = null;
    defer if (run_at_value) |value| env.allocator.free(value);
    _ = c.lua_getfield(state, options_index, "run_at");
    switch (c.lua_type(state, -1)) {
        c.LUA_TNIL => {},
        c.LUA_TSTRING => {
            var run_at_len: usize = 0;
            const run_at_ptr = c.lua_tolstring(state, -1, &run_at_len) orelse unreachable;
            run_at_value = env.allocator.dupe(u8, run_at_ptr[0..run_at_len]) catch |err| {
                luaPop(state, 1);
                return pushLuaErrorMessage(state, "zoid.jobs.create failed: {s}", .{@errorName(err)});
            };
        },
        else => {
            luaPop(state, 1);
            return pushLuaErrorMessage(state, "zoid.jobs.create run_at must be a string", .{});
        },
    }
    luaPop(state, 1);

    var cron_value: ?[]u8 = null;
    defer if (cron_value) |value| env.allocator.free(value);
    _ = c.lua_getfield(state, options_index, "cron");
    switch (c.lua_type(state, -1)) {
        c.LUA_TNIL => {},
        c.LUA_TSTRING => {
            var cron_len: usize = 0;
            const cron_ptr = c.lua_tolstring(state, -1, &cron_len) orelse unreachable;
            cron_value = env.allocator.dupe(u8, cron_ptr[0..cron_len]) catch |err| {
                luaPop(state, 1);
                return pushLuaErrorMessage(state, "zoid.jobs.create failed: {s}", .{@errorName(err)});
            };
        },
        else => {
            luaPop(state, 1);
            return pushLuaErrorMessage(state, "zoid.jobs.create cron must be a string", .{});
        },
    }
    luaPop(state, 1);

    var job = scheduler_runtime.createJob(
        env.allocator,
        .{ .workspace_root = env.workspace_root },
        .{
            .path = path_value,
            .run_at = run_at_value,
            .cron = cron_value,
        },
    ) catch |err| {
        return pushLuaErrorMessage(state, "zoid.jobs.create failed: {s}", .{@errorName(err)});
    };
    defer job.deinit(env.allocator);

    pushLuaSchedulerJobTable(env.allocator, env.workspace_root, state, &job) catch |err| {
        return pushLuaErrorMessage(state, "zoid.jobs.create failed: {s}", .{@errorName(err)});
    };
    return 1;
}

fn luaZoidJobsList(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;
    const env = toolEnvironmentFromLuaState(state) orelse return pushLuaErrorMessage(state, "workspace context unavailable", .{});

    const jobs = scheduler_runtime.listJobs(
        env.allocator,
        .{ .workspace_root = env.workspace_root },
    ) catch |err| {
        return pushLuaErrorMessage(state, "zoid.jobs.list failed: {s}", .{@errorName(err)});
    };
    defer scheduler_store.deinitJobs(env.allocator, jobs);

    c.lua_newtable(state);
    for (jobs, 0..) |job, index| {
        c.lua_pushinteger(state, @intCast(index + 1));
        pushLuaSchedulerJobTable(env.allocator, env.workspace_root, state, &job) catch |err| {
            return pushLuaErrorMessage(state, "zoid.jobs.list failed: {s}", .{@errorName(err)});
        };
        c.lua_settable(state, -3);
    }
    return 1;
}

fn luaZoidJobsDelete(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;
    const env = toolEnvironmentFromLuaState(state) orelse return pushLuaErrorMessage(state, "workspace context unavailable", .{});

    var job_id_len: usize = 0;
    const job_id_ptr = c.luaL_checklstring(state, 1, &job_id_len) orelse return pushLuaErrorMessage(state, "zoid.jobs.delete requires job id", .{});
    const job_id = job_id_ptr[0..job_id_len];

    const removed = scheduler_runtime.deleteJob(
        env.allocator,
        .{ .workspace_root = env.workspace_root },
        job_id,
    ) catch |err| {
        return pushLuaErrorMessage(state, "zoid.jobs.delete failed: {s}", .{@errorName(err)});
    };

    c.lua_pushboolean(state, if (removed) 1 else 0);
    return 1;
}

fn luaZoidJobsPause(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;
    const env = toolEnvironmentFromLuaState(state) orelse return pushLuaErrorMessage(state, "workspace context unavailable", .{});

    var job_id_len: usize = 0;
    const job_id_ptr = c.luaL_checklstring(state, 1, &job_id_len) orelse return pushLuaErrorMessage(state, "zoid.jobs.pause requires job id", .{});
    const job_id = job_id_ptr[0..job_id_len];

    const updated = scheduler_runtime.pauseJob(
        env.allocator,
        .{ .workspace_root = env.workspace_root },
        job_id,
    ) catch |err| {
        return pushLuaErrorMessage(state, "zoid.jobs.pause failed: {s}", .{@errorName(err)});
    };

    c.lua_pushboolean(state, if (updated) 1 else 0);
    return 1;
}

fn luaZoidJobsResume(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;
    const env = toolEnvironmentFromLuaState(state) orelse return pushLuaErrorMessage(state, "workspace context unavailable", .{});

    var job_id_len: usize = 0;
    const job_id_ptr = c.luaL_checklstring(state, 1, &job_id_len) orelse return pushLuaErrorMessage(state, "zoid.jobs.resume requires job id", .{});
    const job_id = job_id_ptr[0..job_id_len];

    const updated = scheduler_runtime.resumeJob(
        env.allocator,
        .{ .workspace_root = env.workspace_root },
        job_id,
    ) catch |err| {
        return pushLuaErrorMessage(state, "zoid.jobs.resume failed: {s}", .{@errorName(err)});
    };

    c.lua_pushboolean(state, if (updated) 1 else 0);
    return 1;
}

fn luaZoidJobs(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;

    c.lua_newtable(state);
    c.lua_pushcclosure(state, luaZoidJobsCreate, 0);
    c.lua_setfield(state, -2, "create");
    c.lua_pushcclosure(state, luaZoidJobsList, 0);
    c.lua_setfield(state, -2, "list");
    c.lua_pushcclosure(state, luaZoidJobsDelete, 0);
    c.lua_setfield(state, -2, "delete");
    c.lua_pushcclosure(state, luaZoidJobsPause, 0);
    c.lua_setfield(state, -2, "pause");
    c.lua_pushcclosure(state, luaZoidJobsResume, 0);
    c.lua_setfield(state, -2, "resume");
    return 1;
}

fn luaZoidJsonDecode(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;
    const env = toolEnvironmentFromLuaState(state) orelse return pushLuaErrorMessage(state, "workspace context unavailable", .{});

    var json_len: usize = 0;
    const json_ptr = c.luaL_checklstring(state, 1, &json_len) orelse return pushLuaErrorMessage(state, "zoid.json.decode requires JSON string", .{});
    const json_text = json_ptr[0..json_len];

    var parsed = std.json.parseFromSlice(std.json.Value, env.allocator, json_text, .{}) catch |err| {
        return pushLuaErrorMessage(state, "zoid.json.decode failed: {s}", .{@errorName(err)});
    };
    defer parsed.deinit();

    pushLuaJsonValue(state, parsed.value, 0) catch |err| {
        return pushLuaErrorMessage(state, "zoid.json.decode failed: {s}", .{@errorName(err)});
    };
    return 1;
}

fn luaZoidJson(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;

    c.lua_newtable(state);
    c.lua_pushcclosure(state, luaZoidJsonDecode, 0);
    c.lua_setfield(state, -2, "decode");
    pushJsonNull(state);
    c.lua_setfield(state, -2, "null");
    return 1;
}

fn luaPushTimestamp(state: *c.lua_State, timestamp: c.time_t) c_int {
    if (timestamp == -1) {
        return pushLuaErrorMessage(state, "time result cannot be represented in this installation", .{});
    }
    const timestamp_int = std.math.cast(c.lua_Integer, timestamp) orelse {
        return pushLuaErrorMessage(state, "time result cannot be represented in this installation", .{});
    };
    if (std.math.cast(c.time_t, timestamp_int) != timestamp) {
        return pushLuaErrorMessage(state, "time result cannot be represented in this installation", .{});
    }
    c.lua_pushinteger(state, timestamp_int);
    return 1;
}

fn readDateTimeTableField(
    state: *c.lua_State,
    field_name: [:0]const u8,
    default_value: ?c.lua_Integer,
    delta: c.lua_Integer,
) ?c_int {
    const field_type = c.lua_getfield(state, 1, field_name.ptr);
    defer luaPop(state, 1);

    var isnum: c_int = 0;
    const value = c.lua_tointegerx(state, -1, &isnum);
    if (isnum == 0) {
        if (field_type != c.LUA_TNIL) {
            _ = pushLuaErrorMessage(state, "field '{s}' is not an integer", .{field_name});
            return null;
        }
        const fallback = default_value orelse {
            _ = pushLuaErrorMessage(state, "field '{s}' missing in date table", .{field_name});
            return null;
        };
        return std.math.cast(c_int, fallback) orelse blk: {
            _ = pushLuaErrorMessage(state, "field '{s}' is out-of-bound", .{field_name});
            break :blk null;
        };
    }

    const adjusted = @as(i128, value) - @as(i128, delta);
    if (adjusted < std.math.minInt(c_int) or adjusted > std.math.maxInt(c_int)) {
        _ = pushLuaErrorMessage(state, "field '{s}' is out-of-bound", .{field_name});
        return null;
    }
    return @intCast(adjusted);
}

fn readDateTimeIsDstField(state: *c.lua_State) c_int {
    const field_type = c.lua_getfield(state, 1, "isdst");
    defer luaPop(state, 1);

    if (field_type == c.LUA_TNIL) return -1;
    return if (c.lua_toboolean(state, -1) != 0) 1 else 0;
}

fn setDateTableField(state: *c.lua_State, key: [:0]const u8, value: c_int, delta: c_int) void {
    const adjusted = @as(i64, value) + @as(i64, delta);
    c.lua_pushinteger(state, @intCast(adjusted));
    c.lua_setfield(state, -2, key.ptr);
}

fn setDateTableBoolField(state: *c.lua_State, key: [:0]const u8, value: c_int) void {
    if (value < 0) {
        return;
    }
    c.lua_pushboolean(state, if (value != 0) 1 else 0);
    c.lua_setfield(state, -2, key.ptr);
}

fn setAllDateTableFields(state: *c.lua_State, tm_value: *const c.struct_tm) void {
    setDateTableField(state, "year", tm_value.tm_year, 1900);
    setDateTableField(state, "month", tm_value.tm_mon, 1);
    setDateTableField(state, "day", tm_value.tm_mday, 0);
    setDateTableField(state, "hour", tm_value.tm_hour, 0);
    setDateTableField(state, "min", tm_value.tm_min, 0);
    setDateTableField(state, "sec", tm_value.tm_sec, 0);
    setDateTableField(state, "yday", tm_value.tm_yday, 1);
    setDateTableField(state, "wday", tm_value.tm_wday, 1);
    setDateTableBoolField(state, "isdst", tm_value.tm_isdst);
}

fn tmFromTimestamp(timestamp: c.time_t, utc: bool, out_tm: *c.struct_tm) bool {
    var value = timestamp;
    const tm_ptr = if (utc) c.gmtime(&value) else c.localtime(&value);
    if (tm_ptr == null) return false;
    out_tm.* = tm_ptr.*;
    return true;
}

fn pushDateTable(state: *c.lua_State, tm_value: *const c.struct_tm) c_int {
    c.lua_newtable(state);
    setAllDateTableFields(state, tm_value);
    return 1;
}

fn luaZoidTime(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;
    const nargs = c.lua_gettop(state);

    if (nargs == 0 or c.lua_isnoneornil(state, 1)) {
        return luaPushTimestamp(state, c.time(null));
    }
    if (c.lua_type(state, 1) != c.LUA_TTABLE) {
        return pushLuaErrorMessage(state, "zoid.time([table]) requires table or nil", .{});
    }
    c.lua_settop(state, 1);

    var tm_value = std.mem.zeroes(c.struct_tm);
    tm_value.tm_year = readDateTimeTableField(state, "year", null, 1900) orelse return 0;
    tm_value.tm_mon = readDateTimeTableField(state, "month", null, 1) orelse return 0;
    tm_value.tm_mday = readDateTimeTableField(state, "day", null, 0) orelse return 0;
    tm_value.tm_hour = readDateTimeTableField(state, "hour", 12, 0) orelse return 0;
    tm_value.tm_min = readDateTimeTableField(state, "min", 0, 0) orelse return 0;
    tm_value.tm_sec = readDateTimeTableField(state, "sec", 0, 0) orelse return 0;
    tm_value.tm_isdst = readDateTimeIsDstField(state);

    const epoch = c.mktime(&tm_value);
    setAllDateTableFields(state, &tm_value);
    return luaPushTimestamp(state, epoch);
}

fn luaZoidDate(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;
    const nargs = c.lua_gettop(state);

    var format_text: []const u8 = "%c";
    if (nargs >= 1 and !c.lua_isnoneornil(state, 1)) {
        var format_len: usize = 0;
        const format_ptr = c.luaL_checklstring(state, 1, &format_len) orelse return pushLuaErrorMessage(state, "zoid.date([format[, epoch]]) format must be string", .{});
        format_text = format_ptr[0..format_len];
    }

    var use_utc = false;
    if (format_text.len > 0 and format_text[0] == '!') {
        use_utc = true;
        format_text = format_text[1..];
    }

    var timestamp = c.time(null);
    if (nargs >= 2 and !c.lua_isnoneornil(state, 2)) {
        var isnum: c_int = 0;
        const epoch = c.lua_tointegerx(state, 2, &isnum);
        if (isnum == 0) {
            return pushLuaErrorMessage(state, "zoid.date([format[, epoch]]) epoch must be an integer", .{});
        }
        timestamp = std.math.cast(c.time_t, epoch) orelse return pushLuaErrorMessage(state, "time out-of-bounds", .{});
        if (std.math.cast(c.lua_Integer, timestamp) != epoch) {
            return pushLuaErrorMessage(state, "time out-of-bounds", .{});
        }
    }

    var tm_value = std.mem.zeroes(c.struct_tm);
    if (!tmFromTimestamp(timestamp, use_utc, &tm_value)) {
        return pushLuaErrorMessage(state, "date result cannot be represented in this installation", .{});
    }

    if (std.mem.eql(u8, format_text, "*t")) {
        return pushDateTable(state, &tm_value);
    }

    if (format_text.len > 255) {
        return pushLuaErrorMessage(state, "zoid.date([format[, epoch]]) format is too long", .{});
    }

    var format_buffer: [256]u8 = undefined;
    @memcpy(format_buffer[0..format_text.len], format_text);
    format_buffer[format_text.len] = 0;

    var output_buffer: [1024]u8 = undefined;
    const written = c.strftime(
        output_buffer[0..].ptr,
        output_buffer.len,
        format_buffer[0..format_text.len :0].ptr,
        &tm_value,
    );
    if (written == 0) {
        return pushLuaErrorMessage(state, "zoid.date([format[, epoch]]) formatting failed", .{});
    }

    _ = c.lua_pushlstring(state, output_buffer[0..written].ptr, written);
    return 1;
}

fn luaZoidExit(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;
    const nargs = c.lua_gettop(state);

    var exit_code: c.lua_Integer = 0;
    if (nargs >= 1 and c.lua_type(state, 1) != c.LUA_TNIL) {
        var isnum: c_int = 0;
        exit_code = c.lua_tointegerx(state, 1, &isnum);
        if (isnum == 0) {
            return pushLuaErrorMessage(state, "zoid.exit([code]) code must be an integer", .{});
        }
    }

    c.lua_newtable(state);
    c.lua_pushboolean(state, 1);
    c.lua_setfield(state, -2, "__zoid_exit");
    c.lua_pushinteger(state, exit_code);
    c.lua_setfield(state, -2, "code");
    return c.lua_error(state);
}

fn parseLuaExitCode(state: *c.lua_State) ?i64 {
    if (c.lua_type(state, -1) != c.LUA_TTABLE) return null;

    _ = c.lua_getfield(state, -1, "__zoid_exit");
    const is_exit = c.lua_toboolean(state, -1) != 0;
    luaPop(state, 1);
    if (!is_exit) return null;

    _ = c.lua_getfield(state, -1, "code");
    var isnum: c_int = 0;
    const code = c.lua_tointegerx(state, -1, &isnum);
    luaPop(state, 1);
    if (isnum == 0) return null;

    return std.math.cast(i64, code) orelse return null;
}

fn installOutputCapture(lua_state: *c.lua_State, capture: *LuaOutputCapture) void {
    c.lua_pushlightuserdata(lua_state, capture);
    _ = c.lua_setglobal(lua_state, capture_registry_key);

    c.lua_pushcclosure(lua_state, luaCapturedPrint, 0);
    _ = c.lua_setglobal(lua_state, "print");
}

fn installScriptArgs(lua_state: *c.lua_State, file_path: []const u8, script_args: []const []const u8) void {
    c.lua_newtable(lua_state);

    _ = c.lua_pushlstring(lua_state, file_path.ptr, file_path.len);
    c.lua_rawseti(lua_state, -2, 0);

    for (script_args, 0..) |script_arg, script_arg_index| {
        _ = c.lua_pushlstring(lua_state, script_arg.ptr, script_arg.len);
        c.lua_rawseti(lua_state, -2, @intCast(script_arg_index + 1));
    }

    _ = c.lua_setglobal(lua_state, "arg");
}

fn installZoidTable(lua_state: *c.lua_State, sandbox: *ToolLuaEnvironment) void {
    c.lua_pushlightuserdata(lua_state, sandbox);
    _ = c.lua_setglobal(lua_state, tool_sandbox_registry_key);

    c.lua_newtable(lua_state);
    c.lua_pushcclosure(lua_state, luaZoidFile, 0);
    c.lua_setfield(lua_state, -2, "file");
    c.lua_pushcclosure(lua_state, luaZoidDir, 0);
    c.lua_setfield(lua_state, -2, "dir");
    c.lua_pushcclosure(lua_state, luaZoidUri, 0);
    c.lua_setfield(lua_state, -2, "uri");
    c.lua_pushcclosure(lua_state, luaZoidConfig, 0);
    c.lua_setfield(lua_state, -2, "config");
    c.lua_pushcclosure(lua_state, luaZoidJobs, 0);
    c.lua_setfield(lua_state, -2, "jobs");
    c.lua_pushcclosure(lua_state, luaZoidImport, 0);
    c.lua_setfield(lua_state, -2, "import");
    _ = luaZoidJson(lua_state);
    c.lua_setfield(lua_state, -2, "json");
    c.lua_pushcclosure(lua_state, luaZoidTime, 0);
    c.lua_setfield(lua_state, -2, "time");
    c.lua_pushcclosure(lua_state, luaZoidDate, 0);
    c.lua_setfield(lua_state, -2, "date");
    c.lua_pushcclosure(lua_state, luaZoidExit, 0);
    c.lua_setfield(lua_state, -2, "exit");
    c.lua_pushcclosure(lua_state, luaCapturedStderrPrint, 0);
    c.lua_setfield(lua_state, -2, "eprint");
    _ = c.lua_setglobal(lua_state, "zoid");
}

fn setGlobalNil(lua_state: *c.lua_State, name: [*:0]const u8) void {
    c.lua_pushnil(lua_state);
    _ = c.lua_setglobal(lua_state, name);
}

fn restrictToolLuaEnvironment(lua_state: *c.lua_State, sandbox: *ToolLuaEnvironment) void {
    installZoidTable(lua_state, sandbox);

    // Remove standard escape hatches; zoid.file(...), zoid.dir(...), zoid.uri(...), zoid.config(), zoid.import(...), zoid.json.decode, zoid.time, zoid.date, and zoid.eprint(...) are tool APIs.
    setGlobalNil(lua_state, "workspace");
    setGlobalNil(lua_state, "os");
    setGlobalNil(lua_state, "package");
    setGlobalNil(lua_state, "debug");
    setGlobalNil(lua_state, "require");
    setGlobalNil(lua_state, "dofile");
    setGlobalNil(lua_state, "loadfile");
    setGlobalNil(lua_state, c.LUA_IOLIBNAME);
}

fn executeLuaFileCaptureOutputInternal(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    sandbox: ToolSandbox,
    script_args: []const []const u8,
) CaptureError!CapturedExecution {
    const c_file_path = try allocator.dupeZ(u8, file_path);
    defer allocator.free(c_file_path);

    const lua_state = c.luaL_newstate() orelse return .{
        .status = .state_init_failed,
        .exit_code = null,
        .stdout = try allocator.dupe(u8, ""),
        .stderr = try allocator.dupe(u8, "Unable to initialize Lua runtime."),
        .stdout_truncated = false,
        .stderr_truncated = false,
    };
    defer c.lua_close(lua_state);

    c.luaL_openlibs(lua_state);

    var capture = LuaOutputCapture{ .allocator = allocator };
    defer capture.deinit();
    installOutputCapture(lua_state, &capture);
    installScriptArgs(lua_state, file_path, script_args);

    const allocated_tool_env = try allocator.create(ToolLuaEnvironment);
    errdefer allocator.destroy(allocated_tool_env);
    allocated_tool_env.* = .{
        .allocator = allocator,
        .workspace_root = sandbox.workspace_root,
        .max_read_bytes = sandbox.max_read_bytes,
        .max_http_response_bytes = sandbox.max_http_response_bytes,
        .config_path_override = sandbox.config_path_override,
    };
    defer {
        const env = allocated_tool_env;
        env.deinit(lua_state);
        allocator.destroy(env);
    }

    var execution_timeout: ?LuaExecutionTimeout = null;
    restrictToolLuaEnvironment(lua_state, allocated_tool_env);

    if (sandbox.execution_timeout_ns) |timeout_ns| {
        const timeout_seconds_u64 = timeout_ns / std.time.ns_per_s;
        const timeout_seconds = std.math.cast(u32, timeout_seconds_u64) orelse std.math.maxInt(u32);
        execution_timeout = .{
            .deadline_ns = std.time.nanoTimestamp() + @as(i128, @intCast(timeout_ns)),
            .timeout_seconds = if (timeout_seconds == 0) 1 else timeout_seconds,
        };
        installExecutionTimeout(lua_state, &execution_timeout.?);
    }

    try allocated_tool_env.pushModuleStackPath(file_path);

    if (c.luaL_loadfilex(lua_state, c_file_path.ptr, "t") != c.LUA_OK) {
        capture.appendStderrSlice(luaErrorMessage(lua_state));
        return finalizeCapture(allocator, &capture, .load_failed, null);
    }

    if (c.lua_pcallk(lua_state, 0, c.LUA_MULTRET, 0, 0, null) != c.LUA_OK) {
        if (parseLuaExitCode(lua_state)) |exit_code| {
            return finalizeCapture(allocator, &capture, .exited, exit_code);
        }

        const lua_error = luaErrorMessage(lua_state);
        if (parseTimeoutToken(lua_error)) |timeout_seconds| {
            var timeout_message_buffer: [96]u8 = undefined;
            capture.appendStderrSlice(formatTimeoutMessage(&timeout_message_buffer, timeout_seconds));
            return finalizeCapture(allocator, &capture, .timed_out, null);
        }

        capture.appendStderrSlice(lua_error);
        return finalizeCapture(allocator, &capture, .runtime_failed, null);
    }

    return finalizeCapture(allocator, &capture, .ok, null);
}

fn finalizeCapture(
    allocator: std.mem.Allocator,
    capture: *LuaOutputCapture,
    status: CapturedExecutionStatus,
    exit_code: ?i64,
) CaptureError!CapturedExecution {
    const stdout = try capture.stdout.toOwnedSlice(allocator);
    errdefer allocator.free(stdout);
    const stderr = try capture.stderr.toOwnedSlice(allocator);

    return .{
        .status = status,
        .exit_code = exit_code,
        .stdout = stdout,
        .stderr = stderr,
        .stdout_truncated = capture.stdout_truncated,
        .stderr_truncated = capture.stderr_truncated,
    };
}

pub fn executeLuaFileCaptureOutputTool(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    sandbox: ToolSandbox,
) CaptureError!CapturedExecution {
    return executeLuaFileCaptureOutputInternal(allocator, file_path, sandbox, &.{});
}

pub fn executeLuaFileCaptureOutputToolWithArgs(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    sandbox: ToolSandbox,
    script_args: []const []const u8,
) CaptureError!CapturedExecution {
    return executeLuaFileCaptureOutputInternal(allocator, file_path, sandbox, script_args);
}

test "executeLuaFileCaptureOutputTool runs a valid script" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file_path = "ok.lua";
    const file = try tmp.dir.createFile(file_path, .{});
    defer file.close();
    try file.writeAll(
        \\local x = 1 + 2
        \\assert(x == 3)
        \\
    );

    const abs_path = try tmp.dir.realpathAlloc(std.testing.allocator, file_path);
    defer std.testing.allocator.free(abs_path);
    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    var output = try executeLuaFileCaptureOutputTool(std.testing.allocator, abs_path, .{
        .workspace_root = workspace_root,
    });
    defer output.deinit(std.testing.allocator);

    try std.testing.expect(output.status == .ok);
    try std.testing.expectEqualStrings("", output.stdout);
    try std.testing.expectEqualStrings("", output.stderr);
}

test "executeLuaFileCaptureOutputTool returns runtime error for failing script" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file_path = "fail.lua";
    const file = try tmp.dir.createFile(file_path, .{});
    defer file.close();
    try file.writeAll(
        \\error("boom")
        \\
    );

    const abs_path = try tmp.dir.realpathAlloc(std.testing.allocator, file_path);
    defer std.testing.allocator.free(abs_path);
    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    var output = try executeLuaFileCaptureOutputTool(std.testing.allocator, abs_path, .{
        .workspace_root = workspace_root,
    });
    defer output.deinit(std.testing.allocator);

    try std.testing.expect(output.status == .runtime_failed);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "boom") != null);
}

test "executeLuaFileCaptureOutputTool captures print output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file_path = "capture.lua";
    const file = try tmp.dir.createFile(file_path, .{});
    defer file.close();
    try file.writeAll(
        \\print("hello", 123)
        \\print("ab", "cd")
        \\
    );

    const abs_path = try tmp.dir.realpathAlloc(std.testing.allocator, file_path);
    defer std.testing.allocator.free(abs_path);
    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    var output = try executeLuaFileCaptureOutputTool(std.testing.allocator, abs_path, .{
        .workspace_root = workspace_root,
    });
    defer output.deinit(std.testing.allocator);

    try std.testing.expect(output.status == .ok);
    try std.testing.expectEqualStrings("hello\t123\nab\tcd\n", output.stdout);
    try std.testing.expectEqualStrings("", output.stderr);
}

test "executeLuaFileCaptureOutputTool captures runtime errors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try tmp.dir.createFile("boom.lua", .{});
        defer file.close();
        try file.writeAll("error(\"boom\")\n");
    }

    const boom_path = try tmp.dir.realpathAlloc(std.testing.allocator, "boom.lua");
    defer std.testing.allocator.free(boom_path);
    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);
    var boom_output = try executeLuaFileCaptureOutputTool(std.testing.allocator, boom_path, .{
        .workspace_root = workspace_root,
    });
    defer boom_output.deinit(std.testing.allocator);
    try std.testing.expect(boom_output.status == .runtime_failed);
    try std.testing.expect(std.mem.indexOf(u8, boom_output.stderr, "boom") != null);
}

test "executeLuaFileCaptureOutputTool allows zoid file read/write/delete and captures streams" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file_path = "tool_ok.lua";
    const file = try tmp.dir.createFile(file_path, .{});
    defer file.close();
    try file.writeAll(
        \\local note = zoid.file("note.txt")
        \\note:write("hello")
        \\print(note:read())
        \\note:delete()
        \\print("tail")
        \\zoid.eprint("warn")
        \\
    );

    const abs_path = try tmp.dir.realpathAlloc(std.testing.allocator, file_path);
    defer std.testing.allocator.free(abs_path);
    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    var output = try executeLuaFileCaptureOutputTool(std.testing.allocator, abs_path, .{
        .workspace_root = workspace_root,
    });
    defer output.deinit(std.testing.allocator);

    try std.testing.expect(output.status == .ok);
    try std.testing.expectEqualStrings("hello\ntail\n", output.stdout);
    try std.testing.expectEqualStrings("warn\n", output.stderr);

    const note_path = try std.fs.path.join(std.testing.allocator, &.{ workspace_root, "note.txt" });
    defer std.testing.allocator.free(note_path);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(note_path, .{}));
}

test "executeLuaFileCaptureOutputToolWithArgs sets Lua arg table" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file_path = "argv.lua";
    const file = try tmp.dir.createFile(file_path, .{});
    defer file.close();
    try file.writeAll(
        \\print(arg[1])
        \\print(arg[2])
        \\
    );

    const abs_path = try tmp.dir.realpathAlloc(std.testing.allocator, file_path);
    defer std.testing.allocator.free(abs_path);
    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    const script_args = [_][]const u8{ "left", "right" };
    var output = try executeLuaFileCaptureOutputToolWithArgs(
        std.testing.allocator,
        abs_path,
        .{
            .workspace_root = workspace_root,
        },
        &script_args,
    );
    defer output.deinit(std.testing.allocator);

    try std.testing.expect(output.status == .ok);
    try std.testing.expect(output.exit_code == null);
    try std.testing.expectEqualStrings("left\nright\n", output.stdout);
    try std.testing.expectEqualStrings("", output.stderr);
}

test "executeLuaFileCaptureOutputTool supports zoid.exit with explicit exit code" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file_path = "exit_nonzero.lua";
    const file = try tmp.dir.createFile(file_path, .{});
    defer file.close();
    try file.writeAll(
        \\print("before")
        \\zoid.exit(7)
        \\print("after")
        \\
    );

    const abs_path = try tmp.dir.realpathAlloc(std.testing.allocator, file_path);
    defer std.testing.allocator.free(abs_path);
    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    var output = try executeLuaFileCaptureOutputTool(std.testing.allocator, abs_path, .{
        .workspace_root = workspace_root,
    });
    defer output.deinit(std.testing.allocator);

    try std.testing.expect(output.status == .exited);
    try std.testing.expectEqual(@as(?i64, 7), output.exit_code);
    try std.testing.expectEqualStrings("before\n", output.stdout);
    try std.testing.expectEqualStrings("", output.stderr);
}

test "executeLuaFileCaptureOutputTool supports zoid.exit default code zero" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file_path = "exit_zero.lua";
    const file = try tmp.dir.createFile(file_path, .{});
    defer file.close();
    try file.writeAll(
        \\print("start")
        \\zoid.exit()
        \\print("after")
        \\
    );

    const abs_path = try tmp.dir.realpathAlloc(std.testing.allocator, file_path);
    defer std.testing.allocator.free(abs_path);
    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    var output = try executeLuaFileCaptureOutputTool(std.testing.allocator, abs_path, .{
        .workspace_root = workspace_root,
    });
    defer output.deinit(std.testing.allocator);

    try std.testing.expect(output.status == .exited);
    try std.testing.expectEqual(@as(?i64, 0), output.exit_code);
    try std.testing.expectEqualStrings("start\n", output.stdout);
    try std.testing.expectEqualStrings("", output.stderr);
}

test "executeLuaFileCaptureOutputTool enforces execution timeout" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file_path = "timeout.lua";
    const file = try tmp.dir.createFile(file_path, .{});
    defer file.close();
    try file.writeAll(
        \\while true do
        \\end
        \\
    );

    const abs_path = try tmp.dir.realpathAlloc(std.testing.allocator, file_path);
    defer std.testing.allocator.free(abs_path);
    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    var output = try executeLuaFileCaptureOutputTool(std.testing.allocator, abs_path, .{
        .workspace_root = workspace_root,
        .execution_timeout_ns = 1,
    });
    defer output.deinit(std.testing.allocator);

    try std.testing.expect(output.status == .timed_out);
    try std.testing.expectEqual(@as(?i64, null), output.exit_code);
    try std.testing.expectEqualStrings("", output.stdout);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "timed out") != null);
}

test "executeLuaFileCaptureOutputTool exposes file metadata and dir listing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("data/z-sub");
    {
        const data_file = try tmp.dir.createFile("data/a.txt", .{});
        defer data_file.close();
        try data_file.writeAll("alpha");
    }

    const file_path = "metadata.lua";
    const script = try tmp.dir.createFile(file_path, .{});
    defer script.close();
    try script.writeAll(
        \\local note = zoid.file("/data/a.txt")
        \\print("file_meta", note.path, note.name, note.type, note.size == 5, #note.mode == 4, #note.owner > 0, #note.group > 0, string.sub(note.modified_at, -1) == "Z")
        \\local dir = zoid.dir("/data")
        \\print("dir_meta", dir.path, dir.name, dir.type, #dir.mode == 4, #dir.owner > 0, #dir.group > 0)
        \\local entries = dir:list()
        \\print("entries", #entries, entries[1].path, entries[1].name, entries[1].type, entries[2].path, entries[2].name, entries[2].type)
        \\
    );

    const abs_path = try tmp.dir.realpathAlloc(std.testing.allocator, file_path);
    defer std.testing.allocator.free(abs_path);
    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    var output = try executeLuaFileCaptureOutputTool(std.testing.allocator, abs_path, .{
        .workspace_root = workspace_root,
    });
    defer output.deinit(std.testing.allocator);

    try std.testing.expect(output.status == .ok);
    try std.testing.expectEqualStrings(
        "file_meta\t/data/a.txt\ta.txt\tfile\ttrue\ttrue\ttrue\ttrue\ttrue\n" ++
            "dir_meta\t/data\tdata\tdirectory\ttrue\ttrue\ttrue\n" ++
            "entries\t2\t/data/a.txt\ta.txt\tfile\t/data/z-sub\tz-sub\tdirectory\n",
        output.stdout,
    );
    try std.testing.expectEqualStrings("", output.stderr);
}

test "executeLuaFileCaptureOutputTool supports zoid dir create/remove" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file_path = "dir_create_remove.lua";
    const script = try tmp.dir.createFile(file_path, .{});
    defer script.close();
    try script.writeAll(
        \\local dir = zoid.dir("memory")
        \\print("create", dir:create())
        \\local create_again_ok, create_again_err = pcall(function() dir:create() end)
        \\print("create_again", create_again_ok, create_again_err ~= nil)
        \\local note = zoid.file("memory/note.txt")
        \\note:write("hello")
        \\local remove_non_empty_ok, remove_non_empty_err = pcall(function() dir:remove() end)
        \\print("remove_non_empty", remove_non_empty_ok, remove_non_empty_err ~= nil)
        \\note:delete()
        \\print("remove_empty", dir:remove())
        \\
    );

    const abs_path = try tmp.dir.realpathAlloc(std.testing.allocator, file_path);
    defer std.testing.allocator.free(abs_path);
    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    var output = try executeLuaFileCaptureOutputTool(std.testing.allocator, abs_path, .{
        .workspace_root = workspace_root,
    });
    defer output.deinit(std.testing.allocator);

    try std.testing.expect(output.status == .ok);
    try std.testing.expectEqualStrings(
        "create\ttrue\n" ++
            "create_again\tfalse\ttrue\n" ++
            "remove_non_empty\tfalse\ttrue\n" ++
            "remove_empty\ttrue\n",
        output.stdout,
    );
    try std.testing.expectEqualStrings("", output.stderr);

    const removed_dir_path = try std.fs.path.join(std.testing.allocator, &.{ workspace_root, "memory" });
    defer std.testing.allocator.free(removed_dir_path);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(removed_dir_path, .{}));
}

test "executeLuaFileCaptureOutputTool supports zoid dir grep" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("logs/nested");
    {
        const top_file = try tmp.dir.createFile("logs/top.txt", .{});
        defer top_file.close();
        try top_file.writeAll("needle-top\n");
    }
    {
        const nested_file = try tmp.dir.createFile("logs/nested/deep.txt", .{});
        defer nested_file.close();
        try nested_file.writeAll("needle-deep\n");
    }

    const file_path = "dir_grep.lua";
    const script = try tmp.dir.createFile(file_path, .{});
    defer script.close();
    try script.writeAll(
        \\local dir = zoid.dir("logs")
        \\local recursive = dir:grep("needle")
        \\print("recursive", #recursive, recursive[1].text, recursive[2].text)
        \\local top_only = dir:grep("needle", { recursive = false })
        \\print("top_only", #top_only, top_only[1].text)
        \\local limited = dir:grep("needle", { max_matches = 1 })
        \\print("limited", #limited, limited[1].text)
        \\
    );

    const abs_path = try tmp.dir.realpathAlloc(std.testing.allocator, file_path);
    defer std.testing.allocator.free(abs_path);
    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    var output = try executeLuaFileCaptureOutputTool(std.testing.allocator, abs_path, .{
        .workspace_root = workspace_root,
    });
    defer output.deinit(std.testing.allocator);

    try std.testing.expect(output.status == .ok);
    try std.testing.expectEqualStrings(
        "recursive\t2\tneedle-deep\tneedle-top\n" ++
            "top_only\t1\tneedle-top\n" ++
            "limited\t1\tneedle-deep\n",
        output.stdout,
    );
    try std.testing.expectEqualStrings("", output.stderr);
}

test "executeLuaFileCaptureOutputTool supports zoid config list/get/set/unset" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file_path = "config.lua";
    const file = try tmp.dir.createFile(file_path, .{});
    defer file.close();
    try file.writeAll(
        \\local cfg = zoid.config()
        \\cfg:set("OPENAI_API_KEY", "secret")
        \\cfg:set("ZETA", "1")
        \\local keys = cfg:list()
        \\print("keys", #keys, keys[1], keys[2])
        \\print("api", cfg:get("OPENAI_API_KEY"))
        \\print("missing", cfg:get("NOT_FOUND") == nil)
        \\print("removed", cfg:unset("ZETA"))
        \\print("removed_again", cfg:unset("ZETA"))
        \\
    );

    const abs_path = try tmp.dir.realpathAlloc(std.testing.allocator, file_path);
    defer std.testing.allocator.free(abs_path);
    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);
    const config_path = try std.fs.path.join(std.testing.allocator, &.{ workspace_root, "config.json" });
    defer std.testing.allocator.free(config_path);

    var output = try executeLuaFileCaptureOutputTool(std.testing.allocator, abs_path, .{
        .workspace_root = workspace_root,
        .config_path_override = config_path,
    });
    defer output.deinit(std.testing.allocator);

    try std.testing.expect(output.status == .ok);
    try std.testing.expectEqualStrings(
        "keys\t2\tOPENAI_API_KEY\tZETA\napi\tsecret\nmissing\ttrue\nremoved\ttrue\nremoved_again\tfalse\n",
        output.stdout,
    );
    try std.testing.expectEqualStrings("", output.stderr);

    const api_key = try config_store.getValueAtPath(std.testing.allocator, config_path, "OPENAI_API_KEY");
    defer if (api_key) |value| std.testing.allocator.free(value);
    try std.testing.expect(api_key != null);
    try std.testing.expectEqualStrings("secret", api_key.?);

    const zeta = try config_store.getValueAtPath(std.testing.allocator, config_path, "ZETA");
    defer if (zeta) |value| std.testing.allocator.free(value);
    try std.testing.expect(zeta == null);
}

test "executeLuaFileCaptureOutputTool supports zoid import with relative paths and module cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("lib/nested");
    {
        const util = try tmp.dir.createFile("lib/util.lua", .{});
        defer util.close();
        try util.writeAll(
            \\return { base = 40 }
            \\
        );
    }
    {
        const math = try tmp.dir.createFile("lib/nested/math.lua", .{});
        defer math.close();
        try math.writeAll(
            \\local util = zoid.import("../util.lua")
            \\return { value = util.base + 2 }
            \\
        );
    }
    {
        const script = try tmp.dir.createFile("import.lua", .{});
        defer script.close();
        try script.writeAll(
            \\local first = zoid.import("lib/nested/math.lua")
            \\local second = zoid.import("lib/nested/math.lua")
            \\print("value", first.value, second.value, first == second)
            \\
        );
    }

    const script_path = try tmp.dir.realpathAlloc(std.testing.allocator, "import.lua");
    defer std.testing.allocator.free(script_path);
    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    var output = try executeLuaFileCaptureOutputTool(std.testing.allocator, script_path, .{
        .workspace_root = workspace_root,
    });
    defer output.deinit(std.testing.allocator);

    try std.testing.expect(output.status == .ok);
    try std.testing.expectEqualStrings("value\t42\t42\ttrue\n", output.stdout);
    try std.testing.expectEqualStrings("", output.stderr);
}

test "executeLuaFileCaptureOutputTool reports cyclic zoid import" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const module_a = try tmp.dir.createFile("a.lua", .{});
        defer module_a.close();
        try module_a.writeAll(
            \\return zoid.import("b.lua")
            \\
        );
    }
    {
        const module_b = try tmp.dir.createFile("b.lua", .{});
        defer module_b.close();
        try module_b.writeAll(
            \\return zoid.import("a.lua")
            \\
        );
    }
    {
        const script = try tmp.dir.createFile("cyclic.lua", .{});
        defer script.close();
        try script.writeAll(
            \\zoid.import("a.lua")
            \\
        );
    }

    const script_path = try tmp.dir.realpathAlloc(std.testing.allocator, "cyclic.lua");
    defer std.testing.allocator.free(script_path);
    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    var output = try executeLuaFileCaptureOutputTool(std.testing.allocator, script_path, .{
        .workspace_root = workspace_root,
    });
    defer output.deinit(std.testing.allocator);

    try std.testing.expect(output.status == .runtime_failed);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "cyclic import detected") != null);
}

test "executeLuaFileCaptureOutputTool rejects non-lua zoid import paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const non_lua = try tmp.dir.createFile("module.txt", .{});
        defer non_lua.close();
        try non_lua.writeAll("hello\n");
    }
    {
        const script = try tmp.dir.createFile("non_lua_import.lua", .{});
        defer script.close();
        try script.writeAll(
            \\zoid.import("module.txt")
            \\
        );
    }

    const script_path = try tmp.dir.realpathAlloc(std.testing.allocator, "non_lua_import.lua");
    defer std.testing.allocator.free(script_path);
    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    var output = try executeLuaFileCaptureOutputTool(std.testing.allocator, script_path, .{
        .workspace_root = workspace_root,
    });
    defer output.deinit(std.testing.allocator);

    try std.testing.expect(output.status == .runtime_failed);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, ".lua module path") != null);
}

test "executeLuaFileCaptureOutputTool enforces workspace policy for zoid import" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("workspace");
    {
        const outside = try tmp.dir.createFile("outside.lua", .{});
        defer outside.close();
        try outside.writeAll("return 7\n");
    }
    {
        const script = try tmp.dir.createFile("workspace/import_outside.lua", .{});
        defer script.close();
        try script.writeAll(
            \\zoid.import("../outside.lua")
            \\
        );
    }

    const script_path = try tmp.dir.realpathAlloc(std.testing.allocator, "workspace/import_outside.lua");
    defer std.testing.allocator.free(script_path);
    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, "workspace");
    defer std.testing.allocator.free(workspace_root);

    var output = try executeLuaFileCaptureOutputTool(std.testing.allocator, script_path, .{
        .workspace_root = workspace_root,
    });
    defer output.deinit(std.testing.allocator);

    try std.testing.expect(output.status == .runtime_failed);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "PathNotAllowed") != null);
}

test "executeLuaFileCaptureOutputTool blocks os and package access" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("blocked.lua", .{});
    defer file.close();
    try file.writeAll(
        \\print("before")
        \\return os.getenv("HOME")
        \\
    );

    const script_path = try tmp.dir.realpathAlloc(std.testing.allocator, "blocked.lua");
    defer std.testing.allocator.free(script_path);
    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    var output = try executeLuaFileCaptureOutputTool(std.testing.allocator, script_path, .{
        .workspace_root = workspace_root,
    });
    defer output.deinit(std.testing.allocator);

    try std.testing.expect(output.status == .runtime_failed);
    try std.testing.expectEqualStrings("before\n", output.stdout);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "os") != null);
}

test "executeLuaFileCaptureOutputTool blocks workspace traversal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("workspace");

    {
        const outside = try tmp.dir.createFile("outside.txt", .{});
        defer outside.close();
        try outside.writeAll("secret");
    }

    {
        const script = try tmp.dir.createFile("workspace/traversal.lua", .{});
        defer script.close();
        try script.writeAll(
            \\zoid.file("../outside.txt"):delete()
            \\
        );
    }

    const script_path = try tmp.dir.realpathAlloc(std.testing.allocator, "workspace/traversal.lua");
    defer std.testing.allocator.free(script_path);
    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, "workspace");
    defer std.testing.allocator.free(workspace_root);

    var output = try executeLuaFileCaptureOutputTool(std.testing.allocator, script_path, .{
        .workspace_root = workspace_root,
    });
    defer output.deinit(std.testing.allocator);

    try std.testing.expect(output.status == .runtime_failed);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "PathNotAllowed") != null);
}

const TestHttpHeaderExpectation = struct {
    name: []const u8,
    value: []const u8,
};

const TestHttpExpectation = struct {
    method: []const u8,
    target: []const u8,
    body: []const u8,
    headers: []const TestHttpHeaderExpectation = &.{},
    status_code: u16,
    response_body: []const u8,
};

const TestHttpServerContext = struct {
    server: std.net.Server,
    expected: []const TestHttpExpectation,
    completed_requests: usize = 0,
    failure: ?anyerror = null,
};

const ParsedHttpRequest = struct {
    method: []const u8,
    target: []const u8,
    headers: []const u8,
    body: []const u8,
};

fn parseHttpRequest(request_bytes: []const u8) !ParsedHttpRequest {
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
        .headers = headers[request_line_end + 2 ..],
        .body = body,
    };
}

fn hasExpectedHeader(headers_blob: []const u8, name: []const u8, expected_value: []const u8) bool {
    var lines = std.mem.splitSequence(u8, headers_blob, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        const separator = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..separator], " \t");
        if (!std.ascii.eqlIgnoreCase(key, name)) continue;

        const value = std.mem.trim(u8, line[separator + 1 ..], " \t");
        if (std.mem.eql(u8, value, expected_value)) return true;
    }
    return false;
}

fn parseHttpContentLength(headers: []const u8) !usize {
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

fn runTestHttpServer(context: *TestHttpServerContext) void {
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
                    const content_length = parseHttpContentLength(request_buffer[0..header_end]) catch |err| {
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

        const parsed = parseHttpRequest(request_buffer[0..total_len]) catch |err| {
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
        for (expected.headers) |expected_header| {
            if (!hasExpectedHeader(parsed.headers, expected_header.name, expected_header.value)) {
                context.failure = error.UnexpectedRequest;
                return;
            }
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

test "executeLuaFileCaptureOutputTool supports zoid uri get/post/put/delete" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var listen_address = try std.net.Address.parseIp4("127.0.0.1", 0);
    const server = try listen_address.listen(.{ .reuse_address = true });

    const expectations = [_]TestHttpExpectation{
        .{
            .method = "GET",
            .target = "/get",
            .body = "",
            .headers = &.{
                .{ .name = "X-Req-Id", .value = "g1" },
            },
            .status_code = 200,
            .response_body = "g",
        },
        .{
            .method = "POST",
            .target = "/post",
            .body = "alpha=1",
            .headers = &.{
                .{ .name = "Authorization", .value = "Bearer test-token" },
            },
            .status_code = 201,
            .response_body = "p",
        },
        .{
            .method = "PUT",
            .target = "/put",
            .body = "update-me",
            .headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
            .status_code = 202,
            .response_body = "u",
        },
        .{
            .method = "DELETE",
            .target = "/delete",
            .body = "",
            .headers = &.{
                .{ .name = "X-Req-Id", .value = "d1" },
            },
            .status_code = 200,
            .response_body = "d",
        },
    };

    var context = TestHttpServerContext{
        .server = server,
        .expected = &expectations,
    };

    const server_thread = std.Thread.spawn(.{}, runTestHttpServer, .{&context}) catch |err| {
        context.server.deinit();
        return err;
    };
    defer server_thread.join();

    const port = context.server.listen_address.getPort();
    const script_content = try std.fmt.allocPrint(
        std.testing.allocator,
        \\local base = "http://127.0.0.1:{d}"
        \\local r1 = zoid.uri(base .. "/get"):get({ headers = { ["X-Req-Id"] = "g1" } })
        \\local r2 = zoid.uri(base .. "/post"):post("alpha=1", { headers = { Authorization = "Bearer test-token" } })
        \\local r3 = zoid.uri(base .. "/put"):put("update-me", { headers = { ["Content-Type"] = "text/plain" } })
        \\local r4 = zoid.uri(base .. "/delete"):delete({ headers = { ["X-Req-Id"] = "d1" } })
        \\print("GET", r1.status, r1.body, r1.ok)
        \\print("POST", r2.status, r2.body, r2.ok)
        \\print("PUT", r3.status, r3.body, r3.ok)
        \\print("DELETE", r4.status, r4.body, r4.ok)
        \\
    ,
        .{port},
    );
    defer std.testing.allocator.free(script_content);

    const script = try tmp.dir.createFile("http.lua", .{});
    defer script.close();
    try script.writeAll(script_content);

    const script_path = try tmp.dir.realpathAlloc(std.testing.allocator, "http.lua");
    defer std.testing.allocator.free(script_path);
    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    var output = try executeLuaFileCaptureOutputTool(std.testing.allocator, script_path, .{
        .workspace_root = workspace_root,
    });
    defer output.deinit(std.testing.allocator);

    try std.testing.expect(output.status == .ok);
    try std.testing.expectEqualStrings("", output.stderr);
    try std.testing.expectEqualStrings(
        "GET\t200\tg\ttrue\nPOST\t201\tp\ttrue\nPUT\t202\tu\ttrue\nDELETE\t200\td\ttrue\n",
        output.stdout,
    );

    try std.testing.expect(context.failure == null);
    try std.testing.expectEqual(expectations.len, context.completed_requests);
}

test "executeLuaFileCaptureOutputTool rejects unsupported uri schemes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script = try tmp.dir.createFile("scheme.lua", .{});
    defer script.close();
    try script.writeAll(
        \\zoid.uri("ftp://example.com/file.txt"):get()
        \\
    );

    const script_path = try tmp.dir.realpathAlloc(std.testing.allocator, "scheme.lua");
    defer std.testing.allocator.free(script_path);
    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    var output = try executeLuaFileCaptureOutputTool(std.testing.allocator, script_path, .{
        .workspace_root = workspace_root,
    });
    defer output.deinit(std.testing.allocator);

    try std.testing.expect(output.status == .runtime_failed);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "UnsupportedUriScheme") != null);
}

test "executeLuaFileCaptureOutputTool rejects invalid uri header values" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script = try tmp.dir.createFile("invalid_header.lua", .{});
    defer script.close();
    try script.writeAll(
        \\zoid.uri("https://example.com"):get({ headers = { ["X-Test"] = "bad\r\nvalue" } })
        \\
    );

    const script_path = try tmp.dir.realpathAlloc(std.testing.allocator, "invalid_header.lua");
    defer std.testing.allocator.free(script_path);
    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    var output = try executeLuaFileCaptureOutputTool(std.testing.allocator, script_path, .{
        .workspace_root = workspace_root,
    });
    defer output.deinit(std.testing.allocator);

    try std.testing.expect(output.status == .runtime_failed);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "InvalidHeaderValue") != null);
}

test "executeLuaFileCaptureOutputTool supports zoid json decode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script = try tmp.dir.createFile("json_decode.lua", .{});
    defer script.close();
    try script.writeAll(
        \\local value = zoid.json.decode('{"count":3,"nested":{"ok":true},"items":[1,null,{"name":"zoid"}]}')
        \\print(value.count, value.nested.ok, value.items[1], value.items[2] == zoid.json.null, value.items[3].name)
        \\local root_null = zoid.json.decode("null")
        \\print("root_null", root_null == zoid.json.null)
        \\
    );

    const script_path = try tmp.dir.realpathAlloc(std.testing.allocator, "json_decode.lua");
    defer std.testing.allocator.free(script_path);
    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    var output = try executeLuaFileCaptureOutputTool(std.testing.allocator, script_path, .{
        .workspace_root = workspace_root,
    });
    defer output.deinit(std.testing.allocator);

    try std.testing.expect(output.status == .ok);
    try std.testing.expectEqualStrings(
        "3\ttrue\t1\ttrue\tzoid\nroot_null\ttrue\n",
        output.stdout,
    );
    try std.testing.expectEqualStrings("", output.stderr);
}

test "executeLuaFileCaptureOutputTool supports zoid time and date" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script = try tmp.dir.createFile("time_date.lua", .{});
    defer script.close();
    try script.writeAll(
        \\local now = zoid.time()
        \\print(type(now) == "number")
        \\print(zoid.date("!%Y-%m-%dT%H:%M:%SZ", 0))
        \\local utc = zoid.date("!*t", 0)
        \\print(utc.year, utc.month, utc.day, utc.hour, utc.min, utc.sec, utc.wday, utc.yday, utc.isdst == false)
        \\local local_parts = zoid.date("*t", 0)
        \\local local_epoch = zoid.time({
        \\  year = local_parts.year,
        \\  month = local_parts.month,
        \\  day = local_parts.day,
        \\  hour = local_parts.hour,
        \\  min = local_parts.min,
        \\  sec = local_parts.sec,
        \\  isdst = local_parts.isdst,
        \\})
        \\print(local_epoch == 0)
        \\local normalized = { year = 2026, month = 13, day = 40, hour = 0, min = 0, sec = 0 }
        \\local normalized_epoch = zoid.time(normalized)
        \\local normalized_back = zoid.date("*t", normalized_epoch)
        \\print(normalized.year == normalized_back.year and normalized.month == normalized_back.month and normalized.day == normalized_back.day)
        \\
    );

    const script_path = try tmp.dir.realpathAlloc(std.testing.allocator, "time_date.lua");
    defer std.testing.allocator.free(script_path);
    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    var output = try executeLuaFileCaptureOutputTool(std.testing.allocator, script_path, .{
        .workspace_root = workspace_root,
    });
    defer output.deinit(std.testing.allocator);

    try std.testing.expect(output.status == .ok);
    try std.testing.expectEqualStrings(
        "true\n1970-01-01T00:00:00Z\n1970\t1\t1\t0\t0\t0\t5\t1\ttrue\ntrue\ntrue\n",
        output.stdout,
    );
    try std.testing.expectEqualStrings("", output.stderr);
}

test "executeLuaFileCaptureOutputTool validates zoid time/date arguments" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script = try tmp.dir.createFile("time_date_invalid.lua", .{});
    defer script.close();
    try script.writeAll(
        \\zoid.time({ month = 1, day = 1 })
        \\
    );

    const script_path = try tmp.dir.realpathAlloc(std.testing.allocator, "time_date_invalid.lua");
    defer std.testing.allocator.free(script_path);
    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    var output = try executeLuaFileCaptureOutputTool(std.testing.allocator, script_path, .{
        .workspace_root = workspace_root,
    });
    defer output.deinit(std.testing.allocator);

    try std.testing.expect(output.status == .runtime_failed);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "field 'year' missing in date table") != null);
}

test "executeLuaFileCaptureOutputTool reports json decode parse errors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script = try tmp.dir.createFile("json_decode_error.lua", .{});
    defer script.close();
    try script.writeAll(
        \\zoid.json.decode("{bad json")
        \\
    );

    const script_path = try tmp.dir.realpathAlloc(std.testing.allocator, "json_decode_error.lua");
    defer std.testing.allocator.free(script_path);
    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    var output = try executeLuaFileCaptureOutputTool(std.testing.allocator, script_path, .{
        .workspace_root = workspace_root,
    });
    defer output.deinit(std.testing.allocator);

    try std.testing.expect(output.status == .runtime_failed);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "zoid.json.decode failed") != null);
}

test "executeLuaFileCaptureOutputTool supports zoid jobs api" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const scheduled = try tmp.dir.createFile("note.lua", .{});
    defer scheduled.close();
    try scheduled.writeAll("print('hello')\n");

    const script = try tmp.dir.createFile("schedule.lua", .{});
    defer script.close();
    try script.writeAll(
        \\local created = zoid.jobs.create({
        \\  path = "note.lua",
        \\  run_at = "2026-01-10T10:00:00Z"
        \\})
        \\print(created.path)
        \\print(zoid.jobs.list()[1].path)
        \\print(#zoid.jobs.list())
        \\print(zoid.jobs.pause(created.id))
        \\print(zoid.jobs.resume(created.id))
        \\print(zoid.jobs.delete(created.id))
        \\print(#zoid.jobs.list())
        \\
    );

    const script_path = try tmp.dir.realpathAlloc(std.testing.allocator, "schedule.lua");
    defer std.testing.allocator.free(script_path);
    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    var output = try executeLuaFileCaptureOutputTool(std.testing.allocator, script_path, .{
        .workspace_root = workspace_root,
    });
    defer output.deinit(std.testing.allocator);

    try std.testing.expect(output.status == .ok);
    try std.testing.expectEqualStrings(
        "/note.lua\n/note.lua\n1\ntrue\ntrue\ntrue\n0\n",
        output.stdout,
    );
    try std.testing.expectEqualStrings("", output.stderr);
}
