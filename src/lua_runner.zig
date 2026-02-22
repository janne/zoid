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
});

pub const ExecuteLuaError = std.mem.Allocator.Error || error{
    LuaStateInitFailed,
    LuaLoadFailed,
    LuaRuntimeFailed,
};

pub const CaptureError = std.mem.Allocator.Error;
pub const default_tool_max_read_bytes: usize = 128 * 1024;
pub const default_tool_max_http_response_bytes: usize = 1024 * 1024;

pub const CapturedExecutionStatus = enum {
    ok,
    state_init_failed,
    load_failed,
    runtime_failed,
};

pub const CapturedExecution = struct {
    status: CapturedExecutionStatus,
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
const max_captured_stream_bytes: usize = 256 * 1024;
const max_json_decode_depth: usize = 64;
var json_null_sentinel: u8 = 0;

pub const ToolSandbox = struct {
    workspace_root: []const u8,
    max_read_bytes: usize = default_tool_max_read_bytes,
    max_http_response_bytes: usize = default_tool_max_http_response_bytes,
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

fn luaCapturedIoWrite(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;
    const capture = captureFromLuaState(state) orelse return 0;

    const nargs = c.lua_gettop(state);
    var arg_idx: c_int = 1;
    while (arg_idx <= nargs) : (arg_idx += 1) {
        var str_len: usize = 0;
        if (c.luaL_tolstring(state, arg_idx, &str_len)) |text_ptr| {
            capture.appendStdoutSlice(text_ptr[0..str_len]);
            luaPop(state, 1);
        }
    }
    return 0;
}

fn luaCapturedIoStderrWrite(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;
    const capture = captureFromLuaState(state) orelse return 0;

    const nargs = c.lua_gettop(state);
    var arg_idx: c_int = 1;
    if (nargs > 0 and c.lua_type(state, 1) == c.LUA_TTABLE) {
        // Support method-style calls: io.stderr:write("message")
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

fn setLuaMetadataFields(state: *c.lua_State, metadata: *const workspace_fs.PathMetadata) void {
    _ = c.lua_pushlstring(state, metadata.name.ptr, metadata.name.len);
    c.lua_setfield(state, -2, "name");

    _ = c.lua_pushlstring(state, metadata.path.ptr, metadata.path.len);
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
    const env = toolEnvironmentFromLuaState(state) orelse return pushLuaErrorMessage(state, "workspace sandbox unavailable", .{});
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
            return pushLuaErrorMessage(state, "zoid.file(path):read max_bytes exceeds sandbox limit ({d})", .{env.max_read_bytes});
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
    const env = toolEnvironmentFromLuaState(state) orelse return pushLuaErrorMessage(state, "workspace sandbox unavailable", .{});

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
    const env = toolEnvironmentFromLuaState(state) orelse return pushLuaErrorMessage(state, "workspace sandbox unavailable", .{});

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
    const env = toolEnvironmentFromLuaState(state) orelse return pushLuaErrorMessage(state, "workspace sandbox unavailable", .{});

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

    c.lua_newtable(state);
    _ = c.lua_pushlstring(state, metadata.path.ptr, metadata.path.len);
    c.lua_setfield(state, -2, "_path");
    setLuaMetadataFields(state, &metadata);

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
    const env = toolEnvironmentFromLuaState(state) orelse return pushLuaErrorMessage(state, "workspace sandbox unavailable", .{});

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
        c.lua_pushinteger(state, @intCast(index + 1));
        c.lua_newtable(state);
        setLuaMetadataFields(state, &entry);
        c.lua_settable(state, -3);
    }
    return 1;
}

fn luaZoidDir(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;
    const env = toolEnvironmentFromLuaState(state) orelse return pushLuaErrorMessage(state, "workspace sandbox unavailable", .{});

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

    c.lua_newtable(state);
    _ = c.lua_pushlstring(state, metadata.path.ptr, metadata.path.len);
    c.lua_setfield(state, -2, "_path");
    setLuaMetadataFields(state, &metadata);

    c.lua_pushcclosure(state, luaZoidDirList, 0);
    c.lua_setfield(state, -2, "list");
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
    const env = toolEnvironmentFromLuaState(state) orelse return pushLuaErrorMessage(state, "workspace sandbox unavailable", .{});
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
    const env = toolEnvironmentFromLuaState(state) orelse return pushLuaErrorMessage(state, "workspace sandbox unavailable", .{});

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
    const env = toolEnvironmentFromLuaState(state) orelse return pushLuaErrorMessage(state, "workspace sandbox unavailable", .{});

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
    const env = toolEnvironmentFromLuaState(state) orelse return pushLuaErrorMessage(state, "workspace sandbox unavailable", .{});

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
    const env = toolEnvironmentFromLuaState(state) orelse return pushLuaErrorMessage(state, "workspace sandbox unavailable", .{});

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

fn pushLuaSchedulerJobTable(state: *c.lua_State, job: *const scheduler_store.Job) void {
    c.lua_newtable(state);

    _ = c.lua_pushlstring(state, job.id.ptr, job.id.len);
    c.lua_setfield(state, -2, "id");

    const job_type = scheduler_store.jobTypeToString(job.job_type);
    _ = c.lua_pushlstring(state, job_type.ptr, job_type.len);
    c.lua_setfield(state, -2, "job_type");

    _ = c.lua_pushlstring(state, job.path.ptr, job.path.len);
    c.lua_setfield(state, -2, "path");

    c.lua_pushinteger(state, @intCast(job.chat_id));
    c.lua_setfield(state, -2, "chat_id");

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

fn luaZoidScheduleCreate(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;
    const env = toolEnvironmentFromLuaState(state) orelse return pushLuaErrorMessage(state, "workspace sandbox unavailable", .{});

    if (c.lua_type(state, 1) != c.LUA_TTABLE) {
        return pushLuaErrorMessage(state, "zoid.schedule.create requires a table argument", .{});
    }
    const options_index = c.lua_absindex(state, 1);

    _ = c.lua_getfield(state, options_index, "job_type");
    var job_type_len: usize = 0;
    const job_type_ptr = c.lua_tolstring(state, -1, &job_type_len) orelse {
        luaPop(state, 1);
        return pushLuaErrorMessage(state, "zoid.schedule.create requires job_type", .{});
    };
    const job_type_value = env.allocator.dupe(u8, job_type_ptr[0..job_type_len]) catch |err| {
        luaPop(state, 1);
        return pushLuaErrorMessage(state, "zoid.schedule.create failed: {s}", .{@errorName(err)});
    };
    defer env.allocator.free(job_type_value);
    luaPop(state, 1);

    _ = c.lua_getfield(state, options_index, "path");
    var path_len: usize = 0;
    const path_ptr = c.lua_tolstring(state, -1, &path_len) orelse {
        luaPop(state, 1);
        return pushLuaErrorMessage(state, "zoid.schedule.create requires path", .{});
    };
    const path_value = env.allocator.dupe(u8, path_ptr[0..path_len]) catch |err| {
        luaPop(state, 1);
        return pushLuaErrorMessage(state, "zoid.schedule.create failed: {s}", .{@errorName(err)});
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
                return pushLuaErrorMessage(state, "zoid.schedule.create failed: {s}", .{@errorName(err)});
            };
        },
        else => {
            luaPop(state, 1);
            return pushLuaErrorMessage(state, "zoid.schedule.create run_at must be a string", .{});
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
                return pushLuaErrorMessage(state, "zoid.schedule.create failed: {s}", .{@errorName(err)});
            };
        },
        else => {
            luaPop(state, 1);
            return pushLuaErrorMessage(state, "zoid.schedule.create cron must be a string", .{});
        },
    }
    luaPop(state, 1);

    var chat_id: ?i64 = null;
    _ = c.lua_getfield(state, options_index, "chat_id");
    switch (c.lua_type(state, -1)) {
        c.LUA_TNIL => {},
        c.LUA_TNUMBER => {
            var isnum: c_int = 0;
            const value = c.lua_tointegerx(state, -1, &isnum);
            if (isnum == 0) {
                luaPop(state, 1);
                return pushLuaErrorMessage(state, "zoid.schedule.create chat_id must be an integer", .{});
            }
            chat_id = value;
        },
        else => {
            luaPop(state, 1);
            return pushLuaErrorMessage(state, "zoid.schedule.create chat_id must be an integer", .{});
        },
    }
    luaPop(state, 1);

    const job_type = scheduler_store.parseJobType(job_type_value) catch {
        return pushLuaErrorMessage(state, "zoid.schedule.create job_type must be 'lua' or 'markdown'", .{});
    };

    var job = scheduler_runtime.createJob(
        env.allocator,
        .{
            .workspace_root = env.workspace_root,
            .request_chat_id = null,
            .config_path_override = env.config_path_override,
        },
        .{
            .job_type = job_type,
            .path = path_value,
            .run_at = run_at_value,
            .cron = cron_value,
            .chat_id = chat_id,
        },
    ) catch |err| {
        return pushLuaErrorMessage(state, "zoid.schedule.create failed: {s}", .{@errorName(err)});
    };
    defer job.deinit(env.allocator);

    pushLuaSchedulerJobTable(state, &job);
    return 1;
}

fn luaZoidScheduleList(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;
    const env = toolEnvironmentFromLuaState(state) orelse return pushLuaErrorMessage(state, "workspace sandbox unavailable", .{});

    const jobs = scheduler_runtime.listJobs(
        env.allocator,
        .{
            .workspace_root = env.workspace_root,
            .request_chat_id = null,
            .config_path_override = env.config_path_override,
        },
    ) catch |err| {
        return pushLuaErrorMessage(state, "zoid.schedule.list failed: {s}", .{@errorName(err)});
    };
    defer scheduler_store.deinitJobs(env.allocator, jobs);

    c.lua_newtable(state);
    for (jobs, 0..) |job, index| {
        c.lua_pushinteger(state, @intCast(index + 1));
        pushLuaSchedulerJobTable(state, &job);
        c.lua_settable(state, -3);
    }
    return 1;
}

fn luaZoidScheduleDelete(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;
    const env = toolEnvironmentFromLuaState(state) orelse return pushLuaErrorMessage(state, "workspace sandbox unavailable", .{});

    var job_id_len: usize = 0;
    const job_id_ptr = c.luaL_checklstring(state, 1, &job_id_len) orelse return pushLuaErrorMessage(state, "zoid.schedule.delete requires job id", .{});
    const job_id = job_id_ptr[0..job_id_len];

    const removed = scheduler_runtime.deleteJob(
        env.allocator,
        .{
            .workspace_root = env.workspace_root,
            .request_chat_id = null,
            .config_path_override = env.config_path_override,
        },
        job_id,
    ) catch |err| {
        return pushLuaErrorMessage(state, "zoid.schedule.delete failed: {s}", .{@errorName(err)});
    };

    c.lua_pushboolean(state, if (removed) 1 else 0);
    return 1;
}

fn luaZoidSchedulePause(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;
    const env = toolEnvironmentFromLuaState(state) orelse return pushLuaErrorMessage(state, "workspace sandbox unavailable", .{});

    var job_id_len: usize = 0;
    const job_id_ptr = c.luaL_checklstring(state, 1, &job_id_len) orelse return pushLuaErrorMessage(state, "zoid.schedule.pause requires job id", .{});
    const job_id = job_id_ptr[0..job_id_len];

    const updated = scheduler_runtime.pauseJob(
        env.allocator,
        .{
            .workspace_root = env.workspace_root,
            .request_chat_id = null,
            .config_path_override = env.config_path_override,
        },
        job_id,
    ) catch |err| {
        return pushLuaErrorMessage(state, "zoid.schedule.pause failed: {s}", .{@errorName(err)});
    };

    c.lua_pushboolean(state, if (updated) 1 else 0);
    return 1;
}

fn luaZoidScheduleResume(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;
    const env = toolEnvironmentFromLuaState(state) orelse return pushLuaErrorMessage(state, "workspace sandbox unavailable", .{});

    var job_id_len: usize = 0;
    const job_id_ptr = c.luaL_checklstring(state, 1, &job_id_len) orelse return pushLuaErrorMessage(state, "zoid.schedule.resume requires job id", .{});
    const job_id = job_id_ptr[0..job_id_len];

    const updated = scheduler_runtime.resumeJob(
        env.allocator,
        .{
            .workspace_root = env.workspace_root,
            .request_chat_id = null,
            .config_path_override = env.config_path_override,
        },
        job_id,
    ) catch |err| {
        return pushLuaErrorMessage(state, "zoid.schedule.resume failed: {s}", .{@errorName(err)});
    };

    c.lua_pushboolean(state, if (updated) 1 else 0);
    return 1;
}

fn luaZoidSchedule(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;

    c.lua_newtable(state);
    c.lua_pushcclosure(state, luaZoidScheduleCreate, 0);
    c.lua_setfield(state, -2, "create");
    c.lua_pushcclosure(state, luaZoidScheduleList, 0);
    c.lua_setfield(state, -2, "list");
    c.lua_pushcclosure(state, luaZoidScheduleDelete, 0);
    c.lua_setfield(state, -2, "delete");
    c.lua_pushcclosure(state, luaZoidSchedulePause, 0);
    c.lua_setfield(state, -2, "pause");
    c.lua_pushcclosure(state, luaZoidScheduleResume, 0);
    c.lua_setfield(state, -2, "resume");
    return 1;
}

fn luaZoidJsonDecode(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;
    const env = toolEnvironmentFromLuaState(state) orelse return pushLuaErrorMessage(state, "workspace sandbox unavailable", .{});

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

fn installOutputCapture(lua_state: *c.lua_State, capture: *LuaOutputCapture) void {
    c.lua_pushlightuserdata(lua_state, capture);
    _ = c.lua_setglobal(lua_state, capture_registry_key);

    c.lua_pushcclosure(lua_state, luaCapturedPrint, 0);
    _ = c.lua_setglobal(lua_state, "print");

    // Keep a safe io table for stdout/stderr so scripts can still emit output
    // while all file/network/process side effects remain unavailable.
    c.lua_newtable(lua_state);
    c.lua_pushcclosure(lua_state, luaCapturedIoWrite, 0);
    c.lua_setfield(lua_state, -2, "write");

    c.lua_newtable(lua_state);
    c.lua_pushcclosure(lua_state, luaCapturedIoStderrWrite, 0);
    c.lua_setfield(lua_state, -2, "write");
    c.lua_setfield(lua_state, -2, "stderr");
    _ = c.lua_setglobal(lua_state, "io");
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
    c.lua_pushcclosure(lua_state, luaZoidSchedule, 0);
    c.lua_setfield(lua_state, -2, "schedule");
    _ = luaZoidJson(lua_state);
    c.lua_setfield(lua_state, -2, "json");
    _ = c.lua_setglobal(lua_state, "zoid");
}

fn setGlobalNil(lua_state: *c.lua_State, name: [:0]const u8) void {
    c.lua_pushnil(lua_state);
    _ = c.lua_setglobal(lua_state, name.ptr);
}

fn restrictToolLuaEnvironment(lua_state: *c.lua_State, sandbox: *ToolLuaEnvironment) void {
    installZoidTable(lua_state, sandbox);

    // Remove standard escape hatches; zoid.file(...), zoid.dir(...), zoid.uri(...), zoid.config(), and zoid.json.decode are sandbox APIs.
    setGlobalNil(lua_state, "workspace");
    setGlobalNil(lua_state, "os");
    setGlobalNil(lua_state, "package");
    setGlobalNil(lua_state, "debug");
    setGlobalNil(lua_state, "require");
    setGlobalNil(lua_state, "dofile");
    setGlobalNil(lua_state, "loadfile");
}

fn executeLuaFileCaptureOutputInternal(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    sandbox: ?ToolSandbox,
    script_args: []const []const u8,
) CaptureError!CapturedExecution {
    const c_file_path = try allocator.dupeZ(u8, file_path);
    defer allocator.free(c_file_path);

    const lua_state = c.luaL_newstate() orelse return .{
        .status = .state_init_failed,
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

    var tool_env: ToolLuaEnvironment = undefined;
    if (sandbox) |tool_sandbox| {
        tool_env = .{
            .allocator = allocator,
            .workspace_root = tool_sandbox.workspace_root,
            .max_read_bytes = tool_sandbox.max_read_bytes,
            .max_http_response_bytes = tool_sandbox.max_http_response_bytes,
            .config_path_override = tool_sandbox.config_path_override,
        };
        restrictToolLuaEnvironment(lua_state, &tool_env);
    }

    if (c.luaL_loadfilex(lua_state, c_file_path.ptr, null) != c.LUA_OK) {
        capture.appendStderrSlice(luaErrorMessage(lua_state));
        return finalizeCapture(allocator, &capture, .load_failed);
    }

    if (c.lua_pcallk(lua_state, 0, c.LUA_MULTRET, 0, 0, null) != c.LUA_OK) {
        capture.appendStderrSlice(luaErrorMessage(lua_state));
        return finalizeCapture(allocator, &capture, .runtime_failed);
    }

    return finalizeCapture(allocator, &capture, .ok);
}

fn finalizeCapture(
    allocator: std.mem.Allocator,
    capture: *LuaOutputCapture,
    status: CapturedExecutionStatus,
) CaptureError!CapturedExecution {
    const stdout = try capture.stdout.toOwnedSlice(allocator);
    errdefer allocator.free(stdout);
    const stderr = try capture.stderr.toOwnedSlice(allocator);

    return .{
        .status = status,
        .stdout = stdout,
        .stderr = stderr,
        .stdout_truncated = capture.stdout_truncated,
        .stderr_truncated = capture.stderr_truncated,
    };
}

pub fn executeLuaFile(allocator: std.mem.Allocator, file_path: []const u8) ExecuteLuaError!void {
    const c_file_path = try allocator.dupeZ(u8, file_path);
    defer allocator.free(c_file_path);

    const lua_state = c.luaL_newstate() orelse return error.LuaStateInitFailed;
    defer c.lua_close(lua_state);

    c.luaL_openlibs(lua_state);

    if (c.luaL_loadfilex(lua_state, c_file_path.ptr, null) != c.LUA_OK) {
        std.debug.print("Lua load error in '{s}': {s}\n", .{ file_path, luaErrorMessage(lua_state) });
        return error.LuaLoadFailed;
    }

    if (c.lua_pcallk(lua_state, 0, c.LUA_MULTRET, 0, 0, null) != c.LUA_OK) {
        std.debug.print("Lua runtime error in '{s}': {s}\n", .{ file_path, luaErrorMessage(lua_state) });
        return error.LuaRuntimeFailed;
    }
}

pub fn executeLuaFileCaptureOutput(
    allocator: std.mem.Allocator,
    file_path: []const u8,
) CaptureError!CapturedExecution {
    return executeLuaFileCaptureOutputInternal(allocator, file_path, null, &.{});
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

test "executeLuaFile runs a valid script" {
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

    try executeLuaFile(std.testing.allocator, abs_path);
}

test "executeLuaFile returns runtime error for failing script" {
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

    try std.testing.expectError(error.LuaRuntimeFailed, executeLuaFile(std.testing.allocator, abs_path));
}

test "executeLuaFileCaptureOutput captures print and io.write output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file_path = "capture.lua";
    const file = try tmp.dir.createFile(file_path, .{});
    defer file.close();
    try file.writeAll(
        \\print("hello", 123)
        \\io.write("ab")
        \\io.write("cd\n")
        \\
    );

    const abs_path = try tmp.dir.realpathAlloc(std.testing.allocator, file_path);
    defer std.testing.allocator.free(abs_path);

    var output = try executeLuaFileCaptureOutput(std.testing.allocator, abs_path);
    defer output.deinit(std.testing.allocator);

    try std.testing.expect(output.status == .ok);
    try std.testing.expectEqualStrings("hello\t123\nabcd\n", output.stdout);
    try std.testing.expectEqualStrings("", output.stderr);
}

test "executeLuaFileCaptureOutput captures io.stderr writes and runtime errors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try tmp.dir.createFile("stderr.lua", .{});
        defer file.close();
        try file.writeAll(
            \\io.stderr:write("bad")
            \\io.stderr:write(" news\n")
            \\
        );
    }

    const stderr_path = try tmp.dir.realpathAlloc(std.testing.allocator, "stderr.lua");
    defer std.testing.allocator.free(stderr_path);
    var stderr_output = try executeLuaFileCaptureOutput(std.testing.allocator, stderr_path);
    defer stderr_output.deinit(std.testing.allocator);
    try std.testing.expect(stderr_output.status == .ok);
    try std.testing.expectEqualStrings("", stderr_output.stdout);
    try std.testing.expectEqualStrings("bad news\n", stderr_output.stderr);

    {
        const file = try tmp.dir.createFile("boom.lua", .{});
        defer file.close();
        try file.writeAll("error(\"boom\")\n");
    }

    const boom_path = try tmp.dir.realpathAlloc(std.testing.allocator, "boom.lua");
    defer std.testing.allocator.free(boom_path);
    var boom_output = try executeLuaFileCaptureOutput(std.testing.allocator, boom_path);
    defer boom_output.deinit(std.testing.allocator);
    try std.testing.expect(boom_output.status == .runtime_failed);
    try std.testing.expect(std.mem.indexOf(u8, boom_output.stderr, "boom") != null);
}

test "executeLuaFileCaptureOutputTool allows zoid file read/write/delete and captures streams" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file_path = "sandbox_ok.lua";
    const file = try tmp.dir.createFile(file_path, .{});
    defer file.close();
    try file.writeAll(
        \\local note = zoid.file("note.txt")
        \\note:write("hello")
        \\print(note:read())
        \\note:delete()
        \\io.write("tail")
        \\io.stderr:write("warn\n")
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
    try std.testing.expectEqualStrings("hello\ntail", output.stdout);
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
    try std.testing.expectEqualStrings("left\nright\n", output.stdout);
    try std.testing.expectEqualStrings("", output.stderr);
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
        \\local note = zoid.file("data/a.txt")
        \\print("file_meta", note.name, note.type, note.size == 5, #note.mode == 4, #note.owner > 0, #note.group > 0, string.sub(note.modified_at, -1) == "Z")
        \\local dir = zoid.dir("data")
        \\print("dir_meta", dir.name, dir.type, #dir.mode == 4, #dir.owner > 0, #dir.group > 0)
        \\local entries = dir:list()
        \\print("entries", #entries, entries[1].name, entries[1].type, entries[2].name, entries[2].type)
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
        "file_meta\ta.txt\tfile\ttrue\ttrue\ttrue\ttrue\ttrue\n" ++
            "dir_meta\tdata\tdirectory\ttrue\ttrue\ttrue\n" ++
            "entries\t2\ta.txt\tfile\tz-sub\tdirectory\n",
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

test "executeLuaFileCaptureOutputTool supports zoid schedule api" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const markdown = try tmp.dir.createFile("note.md", .{});
    defer markdown.close();
    try markdown.writeAll("# hello\n");

    const script = try tmp.dir.createFile("schedule.lua", .{});
    defer script.close();
    try script.writeAll(
        \\local created = zoid.schedule.create({
        \\  job_type = "markdown",
        \\  path = "note.md",
        \\  run_at = "2026-01-10T10:00:00Z",
        \\  chat_id = 999
        \\})
        \\print(created.job_type, created.chat_id)
        \\print(#zoid.schedule.list())
        \\print(zoid.schedule.pause(created.id))
        \\print(zoid.schedule.resume(created.id))
        \\print(zoid.schedule.delete(created.id))
        \\print(#zoid.schedule.list())
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
        "markdown\t999\n1\ntrue\ntrue\ntrue\n0\n",
        output.stdout,
    );
    try std.testing.expectEqualStrings("", output.stderr);
}
