const std = @import("std");
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
const max_captured_stream_bytes: usize = 256 * 1024;

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

fn installOutputCapture(lua_state: *c.lua_State, capture: *LuaOutputCapture) void {
    c.lua_pushlightuserdata(lua_state, capture);
    _ = c.lua_setglobal(lua_state, capture_registry_key);

    c.lua_pushcclosure(lua_state, luaCapturedPrint, 0);
    _ = c.lua_setglobal(lua_state, "print");

    _ = c.lua_getglobal(lua_state, "io");
    if (c.lua_type(lua_state, -1) == c.LUA_TTABLE) {
        c.lua_pushcclosure(lua_state, luaCapturedIoWrite, 0);
        c.lua_setfield(lua_state, -2, "write");

        c.lua_newtable(lua_state);
        c.lua_pushcclosure(lua_state, luaCapturedIoStderrWrite, 0);
        c.lua_setfield(lua_state, -2, "write");
        c.lua_setfield(lua_state, -2, "stderr");
    }
    luaPop(lua_state, 1);
}

fn restrictToolLuaEnvironment(lua_state: *c.lua_State) void {
    // Disable OS library in tool-mode to prevent process-level side effects
    // such as os.exit/execute/remove/rename.
    c.lua_pushnil(lua_state);
    _ = c.lua_setglobal(lua_state, "os");
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
    restrictToolLuaEnvironment(lua_state);

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

test "executeLuaFileCaptureOutput blocks os library" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file_path = "no_os.lua";
    const file = try tmp.dir.createFile(file_path, .{});
    defer file.close();
    try file.writeAll(
        \\print(type(os))
        \\os.exit(0)
        \\
    );

    const abs_path = try tmp.dir.realpathAlloc(std.testing.allocator, file_path);
    defer std.testing.allocator.free(abs_path);

    var output = try executeLuaFileCaptureOutput(std.testing.allocator, abs_path);
    defer output.deinit(std.testing.allocator);

    try std.testing.expect(output.status == .runtime_failed);
    try std.testing.expectEqualStrings("nil\n", output.stdout);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "nil value") != null);
}
