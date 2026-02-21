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
const script_exit_sentinel = "__zoid_tool_script_exit__";

const LuaOutputCapture = struct {
    allocator: std.mem.Allocator,
    stdout: std.ArrayList(u8) = .empty,
    stderr: std.ArrayList(u8) = .empty,
    stdout_truncated: bool = false,
    stderr_truncated: bool = false,
    exit_requested: bool = false,
    exit_code: c_int = 0,

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

fn parseLuaExitCode(state: *c.lua_State) c_int {
    if (c.lua_gettop(state) < 1) return 0;

    const arg_type = c.lua_type(state, 1);
    if (arg_type == c.LUA_TBOOLEAN) {
        return if (c.lua_toboolean(state, 1) != 0) 0 else 1;
    }
    if (arg_type == c.LUA_TNUMBER) {
        var isnum: c_int = 0;
        const raw = c.lua_tointegerx(state, 1, &isnum);
        if (isnum == 0) return 0;
        return std.math.cast(c_int, raw) orelse if (raw < 0) std.math.minInt(c_int) else std.math.maxInt(c_int);
    }
    return 0;
}

fn luaCapturedExit(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;
    const capture = captureFromLuaState(state) orelse return 0;

    capture.exit_requested = true;
    capture.exit_code = parseLuaExitCode(state);

    _ = c.lua_pushlstring(state, script_exit_sentinel.ptr, script_exit_sentinel.len);
    return c.lua_error(state);
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
    // Keep standard libraries available for benign usage (e.g. os.getenv),
    // but make exit APIs terminate only the current Lua script.
    _ = c.lua_getglobal(lua_state, "os");
    if (c.lua_type(lua_state, -1) == c.LUA_TTABLE) {
        c.lua_pushcclosure(lua_state, luaCapturedExit, 0);
        c.lua_setfield(lua_state, -2, "exit");
    }
    luaPop(lua_state, 1);
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
        if (capture.exit_requested) {
            if (capture.exit_code != 0) {
                var buf: [64]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "script exited with code {d}", .{capture.exit_code}) catch "script exited with non-zero status";
                capture.appendStderrSlice(msg);
            }
            return finalizeCapture(
                allocator,
                &capture,
                if (capture.exit_code == 0) .ok else .runtime_failed,
            );
        }
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

test "executeLuaFileCaptureOutput os.exit(0) stops script without failing host" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file_path = "exit_zero.lua";
    const file = try tmp.dir.createFile(file_path, .{});
    defer file.close();
    try file.writeAll(
        \\print("before")
        \\os.exit(0)
        \\print("after")
        \\
    );

    const abs_path = try tmp.dir.realpathAlloc(std.testing.allocator, file_path);
    defer std.testing.allocator.free(abs_path);

    var output = try executeLuaFileCaptureOutput(std.testing.allocator, abs_path);
    defer output.deinit(std.testing.allocator);

    try std.testing.expect(output.status == .ok);
    try std.testing.expectEqualStrings("before\n", output.stdout);
    try std.testing.expectEqualStrings("", output.stderr);
}

test "executeLuaFileCaptureOutput os.exit non-zero reports runtime failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("os_exit.lua", .{});
    defer file.close();
    try file.writeAll("os.exit(3)\n");

    const os_path = try tmp.dir.realpathAlloc(std.testing.allocator, "os_exit.lua");
    defer std.testing.allocator.free(os_path);
    var os_output = try executeLuaFileCaptureOutput(std.testing.allocator, os_path);
    defer os_output.deinit(std.testing.allocator);
    try std.testing.expect(os_output.status == .runtime_failed);
    try std.testing.expect(std.mem.indexOf(u8, os_output.stderr, "code 3") != null);
}
