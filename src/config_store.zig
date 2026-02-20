const std = @import("std");

const ConfigMap = std.StringHashMap([]u8);
const max_config_size_bytes: usize = 1024 * 1024;

pub fn setValue(allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    const config_path = try defaultConfigPath(allocator);
    defer allocator.free(config_path);

    try setValueAtPath(allocator, config_path, key, value);
}

pub fn getValue(allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
    const config_path = try defaultConfigPath(allocator);
    defer allocator.free(config_path);

    return getValueAtPath(allocator, config_path, key);
}

pub fn unsetValue(allocator: std.mem.Allocator, key: []const u8) !bool {
    const config_path = try defaultConfigPath(allocator);
    defer allocator.free(config_path);

    return unsetValueAtPath(allocator, config_path, key);
}

pub fn listKeys(allocator: std.mem.Allocator) ![][]u8 {
    const config_path = try defaultConfigPath(allocator);
    defer allocator.free(config_path);

    return listKeysAtPath(allocator, config_path);
}

pub fn setValueAtPath(allocator: std.mem.Allocator, config_path: []const u8, key: []const u8, value: []const u8) !void {
    var config_map = try readConfigMap(allocator, config_path);
    defer freeConfigMap(allocator, &config_map);

    if (config_map.getEntry(key)) |entry| {
        allocator.free(entry.value_ptr.*);
        entry.value_ptr.* = try allocator.dupe(u8, value);
    } else {
        const key_copy = try allocator.dupe(u8, key);
        errdefer allocator.free(key_copy);

        const value_copy = try allocator.dupe(u8, value);
        errdefer allocator.free(value_copy);

        try config_map.put(key_copy, value_copy);
    }

    try writeConfigMap(allocator, config_path, &config_map);
}

pub fn getValueAtPath(allocator: std.mem.Allocator, config_path: []const u8, key: []const u8) !?[]u8 {
    var config_map = try readConfigMap(allocator, config_path);
    defer freeConfigMap(allocator, &config_map);

    if (config_map.get(key)) |value| {
        return try allocator.dupe(u8, value);
    }

    return null;
}

pub fn unsetValueAtPath(allocator: std.mem.Allocator, config_path: []const u8, key: []const u8) !bool {
    var config_map = try readConfigMap(allocator, config_path);
    defer freeConfigMap(allocator, &config_map);

    if (config_map.fetchRemove(key)) |entry| {
        allocator.free(entry.key);
        allocator.free(entry.value);
        try writeConfigMap(allocator, config_path, &config_map);
        return true;
    }

    return false;
}

pub fn listKeysAtPath(allocator: std.mem.Allocator, config_path: []const u8) ![][]u8 {
    var config_map = try readConfigMap(allocator, config_path);
    defer freeConfigMap(allocator, &config_map);

    var keys = std.ArrayList([]u8).empty;
    errdefer {
        for (keys.items) |key| {
            allocator.free(key);
        }
        keys.deinit(allocator);
    }

    var iterator = config_map.iterator();
    while (iterator.next()) |entry| {
        try keys.append(allocator, try allocator.dupe(u8, entry.key_ptr.*));
    }

    insertionSortStrings(keys.items);
    return keys.toOwnedSlice(allocator);
}

fn readConfigMap(allocator: std.mem.Allocator, config_path: []const u8) !ConfigMap {
    var map = ConfigMap.init(allocator);
    errdefer freeConfigMap(allocator, &map);

    const file = std.fs.cwd().openFile(config_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return map,
        else => return err,
    };
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, max_config_size_bytes);
    defer allocator.free(contents);

    if (contents.len == 0) return map;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, contents, .{});
    defer parsed.deinit();

    switch (parsed.value) {
        .object => |obj| {
            var iterator = obj.iterator();
            while (iterator.next()) |entry| {
                switch (entry.value_ptr.*) {
                    .string => |value| {
                        const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
                        errdefer allocator.free(key_copy);

                        const value_copy = try allocator.dupe(u8, value);
                        errdefer allocator.free(value_copy);

                        try map.put(key_copy, value_copy);
                    },
                    else => return error.InvalidConfigFormat,
                }
            }
        },
        else => return error.InvalidConfigFormat,
    }

    return map;
}

fn writeConfigMap(allocator: std.mem.Allocator, config_path: []const u8, config_map: *const ConfigMap) !void {
    if (std.fs.path.dirname(config_path)) |parent_path| {
        try std.fs.cwd().makePath(parent_path);
    }

    const file = try std.fs.cwd().createFile(config_path, .{ .truncate = true });
    defer file.close();

    try file.writeAll("{");

    var iterator = config_map.iterator();
    var wrote_entry = false;
    while (iterator.next()) |entry| {
        if (wrote_entry) {
            try file.writeAll(",\n");
        } else {
            try file.writeAll("\n");
            wrote_entry = true;
        }

        try file.writeAll("  ");

        const key_json = try std.json.Stringify.valueAlloc(allocator, entry.key_ptr.*, .{});
        defer allocator.free(key_json);
        try file.writeAll(key_json);

        try file.writeAll(": ");

        const value_json = try std.json.Stringify.valueAlloc(allocator, entry.value_ptr.*, .{});
        defer allocator.free(value_json);
        try file.writeAll(value_json);
    }

    if (wrote_entry) {
        try file.writeAll("\n");
    }

    try file.writeAll("}\n");
}

fn freeConfigMap(allocator: std.mem.Allocator, config_map: *ConfigMap) void {
    var iterator = config_map.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }

    config_map.deinit();
}

fn defaultConfigPath(allocator: std.mem.Allocator) ![]u8 {
    const app_data_dir = try std.fs.getAppDataDir(allocator, "zoid");
    defer allocator.free(app_data_dir);

    return std.fs.path.join(allocator, &.{ app_data_dir, "config.json" });
}

fn insertionSortStrings(items: [][]u8) void {
    if (items.len < 2) return;

    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const current = items[i];
        var j = i;
        while (j > 0 and std.mem.order(u8, current, items[j - 1]) == .lt) : (j -= 1) {
            items[j] = items[j - 1];
        }
        items[j] = current;
    }
}

test "set/get/unset/list config values at path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    const config_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_path, "config.json" });
    defer std.testing.allocator.free(config_path);

    try setValueAtPath(std.testing.allocator, config_path, "foo", "bar");
    try setValueAtPath(std.testing.allocator, config_path, "baz", "qux");

    const foo_value = try getValueAtPath(std.testing.allocator, config_path, "foo");
    defer if (foo_value) |value| std.testing.allocator.free(value);
    try std.testing.expect(foo_value != null);
    try std.testing.expectEqualStrings("bar", foo_value.?);

    const keys = try listKeysAtPath(std.testing.allocator, config_path);
    defer {
        for (keys) |key| {
            std.testing.allocator.free(key);
        }
        std.testing.allocator.free(keys);
    }

    try std.testing.expectEqual(@as(usize, 2), keys.len);
    try std.testing.expectEqualStrings("baz", keys[0]);
    try std.testing.expectEqualStrings("foo", keys[1]);

    try std.testing.expect(try unsetValueAtPath(std.testing.allocator, config_path, "foo"));
    try std.testing.expect(!(try unsetValueAtPath(std.testing.allocator, config_path, "missing")));

    const missing = try getValueAtPath(std.testing.allocator, config_path, "foo");
    defer if (missing) |value| std.testing.allocator.free(value);
    try std.testing.expect(missing == null);
}

test "invalid config format returns error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    const config_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_path, "config.json" });
    defer std.testing.allocator.free(config_path);

    const file = try std.fs.cwd().createFile(config_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll("{\"foo\":123}\n");

    try std.testing.expectError(error.InvalidConfigFormat, getValueAtPath(std.testing.allocator, config_path, "foo"));
}
