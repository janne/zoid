const std = @import("std");
const zoid = @import("zoid");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const command = zoid.cli.parseCommand(args) catch |err| {
        switch (err) {
            error.MissingExecuteArgument => {
                std.debug.print("Missing argument for 'execute'.\n\n", .{});
                zoid.cli.printHelp();
                return;
            },
            error.MissingConfigSubcommand => {
                std.debug.print("Missing subcommand for 'config'.\n\n", .{});
                zoid.cli.printHelp();
                return;
            },
            error.MissingConfigKey => {
                std.debug.print("Missing key for config command.\n\n", .{});
                zoid.cli.printHelp();
                return;
            },
            error.MissingConfigValue => {
                std.debug.print("Missing value for 'config set'.\n\n", .{});
                zoid.cli.printHelp();
                return;
            },
            error.UnknownConfigSubcommand => {
                std.debug.print("Unknown config command: {s}\n\n", .{args[2]});
                zoid.cli.printHelp();
                return;
            },
            error.UnknownCommand => {
                std.debug.print("Unknown command: {s}\n\n", .{args[1]});
                zoid.cli.printHelp();
                return;
            },
            else => return err,
        }
    };

    switch (command) {
        .help => zoid.cli.printHelp(),
        .execute => |file_path| {
            zoid.lua_runner.executeLuaFile(allocator, file_path) catch |err| {
                switch (err) {
                    error.LuaStateInitFailed => std.debug.print("Unable to initialize Lua runtime.\n", .{}),
                    error.OutOfMemory => std.debug.print("Out of memory while preparing Lua execution.\n", .{}),
                    error.LuaLoadFailed, error.LuaRuntimeFailed => {},
                }
                std.process.exit(1);
            };
        },
        .config => |config_cmd| switch (config_cmd) {
            .set => |set_cmd| {
                zoid.config_store.setValue(allocator, set_cmd.key, set_cmd.value) catch |err| {
                    switch (err) {
                        error.InvalidConfigFormat => std.debug.print("Config file is invalid JSON (expected key/value string object).\n", .{}),
                        else => std.debug.print("Failed to set config key: {s}\n", .{@errorName(err)}),
                    }
                    std.process.exit(1);
                };
            },
            .get => |key| {
                const value = zoid.config_store.getValue(allocator, key) catch |err| {
                    switch (err) {
                        error.InvalidConfigFormat => std.debug.print("Config file is invalid JSON (expected key/value string object).\n", .{}),
                        else => std.debug.print("Failed to read config key: {s}\n", .{@errorName(err)}),
                    }
                    std.process.exit(1);
                };

                if (value) |found| {
                    defer allocator.free(found);
                    try std.fs.File.stdout().writeAll(found);
                    try std.fs.File.stdout().writeAll("\n");
                } else {
                    std.debug.print("Config key not found: {s}\n", .{key});
                    std.process.exit(1);
                }
            },
            .unset => |key| {
                const removed = zoid.config_store.unsetValue(allocator, key) catch |err| {
                    switch (err) {
                        error.InvalidConfigFormat => std.debug.print("Config file is invalid JSON (expected key/value string object).\n", .{}),
                        else => std.debug.print("Failed to unset config key: {s}\n", .{@errorName(err)}),
                    }
                    std.process.exit(1);
                };

                if (!removed) {
                    std.debug.print("Config key not found: {s}\n", .{key});
                    std.process.exit(1);
                }
            },
            .list => {
                const keys = zoid.config_store.listKeys(allocator) catch |err| {
                    switch (err) {
                        error.InvalidConfigFormat => std.debug.print("Config file is invalid JSON (expected key/value string object).\n", .{}),
                        else => std.debug.print("Failed to list config keys: {s}\n", .{@errorName(err)}),
                    }
                    std.process.exit(1);
                };
                defer {
                    for (keys) |key| {
                        allocator.free(key);
                    }
                    allocator.free(keys);
                }

                for (keys) |key| {
                    try std.fs.File.stdout().writeAll(key);
                    try std.fs.File.stdout().writeAll("\n");
                }
            },
        },
    }
}
