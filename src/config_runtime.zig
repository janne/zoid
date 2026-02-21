const std = @import("std");
const config_store = @import("config_store.zig");

pub const Context = struct {
    config_path_override: ?[]const u8 = null,
};

pub const SetRequest = struct {
    key: []const u8,
    value: []const u8,
};

pub const Request = union(enum) {
    list,
    get: []const u8,
    set: SetRequest,
    unset: []const u8,
};

pub const Response = union(enum) {
    list: [][]u8,
    get: ?[]u8,
    set,
    unset: bool,

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .list => |keys| {
                for (keys) |key| allocator.free(key);
                allocator.free(keys);
            },
            .get => |maybe_value| {
                if (maybe_value) |value| allocator.free(value);
            },
            .set, .unset => {},
        }
    }
};

pub fn execute(
    allocator: std.mem.Allocator,
    context: Context,
    request: Request,
) !Response {
    return switch (request) {
        .list => .{ .list = try listKeys(allocator, context) },
        .get => |key| .{ .get = try getValue(allocator, context, key) },
        .set => |set_request| blk: {
            try setValue(allocator, context, set_request.key, set_request.value);
            break :blk .set;
        },
        .unset => |key| .{ .unset = try unsetValue(allocator, context, key) },
    };
}

fn listKeys(
    allocator: std.mem.Allocator,
    context: Context,
) ![][]u8 {
    if (context.config_path_override) |path| {
        return config_store.listKeysAtPath(allocator, path);
    }
    return config_store.listKeys(allocator);
}

fn getValue(
    allocator: std.mem.Allocator,
    context: Context,
    key: []const u8,
) !?[]u8 {
    if (context.config_path_override) |path| {
        return config_store.getValueAtPath(allocator, path, key);
    }
    return config_store.getValue(allocator, key);
}

fn setValue(
    allocator: std.mem.Allocator,
    context: Context,
    key: []const u8,
    value: []const u8,
) !void {
    if (context.config_path_override) |path| {
        return config_store.setValueAtPath(allocator, path, key, value);
    }
    return config_store.setValue(allocator, key, value);
}

fn unsetValue(
    allocator: std.mem.Allocator,
    context: Context,
    key: []const u8,
) !bool {
    if (context.config_path_override) |path| {
        return config_store.unsetValueAtPath(allocator, path, key);
    }
    return config_store.unsetValue(allocator, key);
}
