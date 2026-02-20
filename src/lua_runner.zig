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

fn luaErrorMessage(state: *c.lua_State) []const u8 {
    const message = c.lua_tolstring(state, -1, null) orelse return "unknown Lua error";
    return std.mem.span(message);
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
