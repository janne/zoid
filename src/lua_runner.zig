const std = @import("std");
const http_client = @import("http_client.zig");
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

pub const ToolSandbox = struct {
    workspace_root: []const u8,
    max_read_bytes: usize = default_tool_max_read_bytes,
    max_http_response_bytes: usize = default_tool_max_http_response_bytes,
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

    var path_len: usize = 0;
    const path_ptr = c.luaL_checklstring(state, 1, &path_len) orelse return pushLuaErrorMessage(state, "zoid.file requires path", .{});
    const path = path_ptr[0..path_len];

    c.lua_newtable(state);
    _ = c.lua_pushlstring(state, path.ptr, path.len);
    c.lua_setfield(state, -2, "_path");

    c.lua_pushcclosure(state, luaZoidFileRead, 0);
    c.lua_setfield(state, -2, "read");
    c.lua_pushcclosure(state, luaZoidFileWrite, 0);
    c.lua_setfield(state, -2, "write");
    c.lua_pushcclosure(state, luaZoidFileDelete, 0);
    c.lua_setfield(state, -2, "delete");
    return 1;
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

    var payload: ?[]const u8 = null;
    if (allows_body) {
        if (nargs >= 2 and c.lua_type(state, 2) != c.LUA_TNIL) {
            var body_len: usize = 0;
            const body_ptr = c.luaL_checklstring(state, 2, &body_len) orelse return pushLuaErrorMessage(state, "zoid.uri(uri):{s} body must be a string", .{method_name});
            payload = body_ptr[0..body_len];
        }
    } else if (nargs >= 2 and c.lua_type(state, 2) != c.LUA_TNIL) {
        return pushLuaErrorMessage(state, "zoid.uri(uri):{s} does not accept a body", .{method_name});
    }

    var result = http_client.executeRequest(
        env.allocator,
        method,
        uri,
        payload,
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

fn installZoidTable(lua_state: *c.lua_State, sandbox: *ToolLuaEnvironment) void {
    c.lua_pushlightuserdata(lua_state, sandbox);
    _ = c.lua_setglobal(lua_state, tool_sandbox_registry_key);

    c.lua_newtable(lua_state);
    c.lua_pushcclosure(lua_state, luaZoidFile, 0);
    c.lua_setfield(lua_state, -2, "file");
    c.lua_pushcclosure(lua_state, luaZoidUri, 0);
    c.lua_setfield(lua_state, -2, "uri");
    _ = c.lua_setglobal(lua_state, "zoid");
}

fn setGlobalNil(lua_state: *c.lua_State, name: [:0]const u8) void {
    c.lua_pushnil(lua_state);
    _ = c.lua_setglobal(lua_state, name.ptr);
}

fn restrictToolLuaEnvironment(lua_state: *c.lua_State, sandbox: *ToolLuaEnvironment) void {
    installZoidTable(lua_state, sandbox);

    // Remove standard escape hatches; zoid.file(...) and zoid.uri(...) are the only side-effect APIs.
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

    var tool_env: ToolLuaEnvironment = undefined;
    if (sandbox) |tool_sandbox| {
        tool_env = .{
            .allocator = allocator,
            .workspace_root = tool_sandbox.workspace_root,
            .max_read_bytes = tool_sandbox.max_read_bytes,
            .max_http_response_bytes = tool_sandbox.max_http_response_bytes,
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
    return executeLuaFileCaptureOutputInternal(allocator, file_path, null);
}

pub fn executeLuaFileCaptureOutputTool(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    sandbox: ToolSandbox,
) CaptureError!CapturedExecution {
    return executeLuaFileCaptureOutputInternal(allocator, file_path, sandbox);
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

const TestHttpExpectation = struct {
    method: []const u8,
    target: []const u8,
    body: []const u8,
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
        .body = body,
    };
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
        .{ .method = "GET", .target = "/get", .body = "", .status_code = 200, .response_body = "g" },
        .{ .method = "POST", .target = "/post", .body = "alpha=1", .status_code = 201, .response_body = "p" },
        .{ .method = "PUT", .target = "/put", .body = "update-me", .status_code = 202, .response_body = "u" },
        .{ .method = "DELETE", .target = "/delete", .body = "", .status_code = 200, .response_body = "d" },
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
        \\local r1 = zoid.uri(base .. "/get"):get()
        \\local r2 = zoid.uri(base .. "/post"):post("alpha=1")
        \\local r3 = zoid.uri(base .. "/put"):put("update-me")
        \\local r4 = zoid.uri(base .. "/delete"):delete()
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
