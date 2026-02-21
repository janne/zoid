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
pub const default_tool_max_read_bytes: usize = 128 * 1024;

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

fn resolveAllowedReadPath(
    allocator: std.mem.Allocator,
    env: *const ToolLuaEnvironment,
    requested_path: []const u8,
) ![]u8 {
    const candidate = try toCandidatePath(allocator, env.workspace_root, requested_path);
    defer allocator.free(candidate);

    const canonical = try std.fs.cwd().realpathAlloc(allocator, candidate);
    errdefer allocator.free(canonical);
    if (!isPathInsideWorkspace(env.workspace_root, canonical)) {
        return error.PathNotAllowed;
    }
    return canonical;
}

fn resolveAllowedWritePath(
    allocator: std.mem.Allocator,
    env: *const ToolLuaEnvironment,
    requested_path: []const u8,
) ![]u8 {
    const candidate = try toCandidatePath(allocator, env.workspace_root, requested_path);
    defer allocator.free(candidate);

    const parent_path = std.fs.path.dirname(candidate) orelse return error.InvalidToolArguments;
    const parent_realpath = try std.fs.cwd().realpathAlloc(allocator, parent_path);
    defer allocator.free(parent_realpath);
    if (!isPathInsideWorkspace(env.workspace_root, parent_realpath)) {
        return error.PathNotAllowed;
    }

    const file_name = std.fs.path.basename(candidate);
    if (file_name.len == 0 or std.mem.eql(u8, file_name, ".") or std.mem.eql(u8, file_name, "..")) {
        return error.InvalidToolArguments;
    }

    const resolved = try std.fs.path.join(allocator, &.{ parent_realpath, file_name });
    errdefer allocator.free(resolved);
    if (!isPathInsideWorkspace(env.workspace_root, resolved)) {
        return error.PathNotAllowed;
    }

    const existing_realpath = std.fs.cwd().realpathAlloc(allocator, resolved) catch null;
    if (existing_realpath) |path_value| {
        defer allocator.free(path_value);
        if (!isPathInsideWorkspace(env.workspace_root, path_value)) {
            return error.PathNotAllowed;
        }
    }
    return resolved;
}

fn luaWorkspaceRead(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;
    const env = toolEnvironmentFromLuaState(state) orelse return pushLuaErrorMessage(state, "workspace sandbox unavailable", .{});

    var path_len: usize = 0;
    const path_ptr = c.luaL_checklstring(state, 1, &path_len) orelse return pushLuaErrorMessage(state, "workspace.read requires path", .{});
    const requested_path = path_ptr[0..path_len];

    var max_bytes = env.max_read_bytes;
    if (c.lua_gettop(state) >= 2) {
        var isnum: c_int = 0;
        const requested_max = c.lua_tointegerx(state, 2, &isnum);
        if (isnum == 0 or requested_max <= 0) {
            return pushLuaErrorMessage(state, "workspace.read max_bytes must be a positive integer", .{});
        }
        const converted = std.math.cast(usize, requested_max) orelse {
            return pushLuaErrorMessage(state, "workspace.read max_bytes is too large", .{});
        };
        if (converted > env.max_read_bytes) {
            return pushLuaErrorMessage(state, "workspace.read max_bytes exceeds sandbox limit ({d})", .{env.max_read_bytes});
        }
        max_bytes = converted;
    }

    const resolved = resolveAllowedReadPath(env.allocator, env, requested_path) catch |err| {
        return pushLuaErrorMessage(state, "workspace.read failed: {s}", .{@errorName(err)});
    };
    defer env.allocator.free(resolved);

    const file = std.fs.cwd().openFile(resolved, .{}) catch |err| {
        return pushLuaErrorMessage(state, "workspace.read failed: {s}", .{@errorName(err)});
    };
    defer file.close();

    const content = file.readToEndAlloc(env.allocator, max_bytes) catch |err| {
        return pushLuaErrorMessage(state, "workspace.read failed: {s}", .{@errorName(err)});
    };
    defer env.allocator.free(content);

    _ = c.lua_pushlstring(state, content.ptr, content.len);
    return 1;
}

fn luaWorkspaceWrite(lua_state: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state orelse return 0;
    const env = toolEnvironmentFromLuaState(state) orelse return pushLuaErrorMessage(state, "workspace sandbox unavailable", .{});

    var path_len: usize = 0;
    const path_ptr = c.luaL_checklstring(state, 1, &path_len) orelse return pushLuaErrorMessage(state, "workspace.write requires path", .{});
    const requested_path = path_ptr[0..path_len];

    var content_len: usize = 0;
    const content_ptr = c.luaL_checklstring(state, 2, &content_len) orelse return pushLuaErrorMessage(state, "workspace.write requires content", .{});
    const content = content_ptr[0..content_len];

    const resolved = resolveAllowedWritePath(env.allocator, env, requested_path) catch |err| {
        return pushLuaErrorMessage(state, "workspace.write failed: {s}", .{@errorName(err)});
    };
    defer env.allocator.free(resolved);

    const file = std.fs.cwd().createFile(resolved, .{ .truncate = true }) catch |err| {
        return pushLuaErrorMessage(state, "workspace.write failed: {s}", .{@errorName(err)});
    };
    defer file.close();
    file.writeAll(content) catch |err| {
        return pushLuaErrorMessage(state, "workspace.write failed: {s}", .{@errorName(err)});
    };

    c.lua_pushinteger(state, @intCast(content.len));
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

fn installWorkspaceTable(lua_state: *c.lua_State, sandbox: *ToolLuaEnvironment) void {
    c.lua_pushlightuserdata(lua_state, sandbox);
    _ = c.lua_setglobal(lua_state, tool_sandbox_registry_key);

    c.lua_newtable(lua_state);
    c.lua_pushcclosure(lua_state, luaWorkspaceRead, 0);
    c.lua_setfield(lua_state, -2, "read");
    c.lua_pushcclosure(lua_state, luaWorkspaceWrite, 0);
    c.lua_setfield(lua_state, -2, "write");
    _ = c.lua_setglobal(lua_state, "workspace");
}

fn setGlobalNil(lua_state: *c.lua_State, name: [:0]const u8) void {
    c.lua_pushnil(lua_state);
    _ = c.lua_setglobal(lua_state, name.ptr);
}

fn restrictToolLuaEnvironment(lua_state: *c.lua_State, sandbox: *ToolLuaEnvironment) void {
    installWorkspaceTable(lua_state, sandbox);

    // Remove standard escape hatches; workspace.read/write are the only FS APIs.
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

test "executeLuaFileCaptureOutputTool allows workspace read/write and captures streams" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file_path = "sandbox_ok.lua";
    const file = try tmp.dir.createFile(file_path, .{});
    defer file.close();
    try file.writeAll(
        \\workspace.write("note.txt", "hello")
        \\print(workspace.read("note.txt"))
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
            \\workspace.read("../outside.txt")
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
