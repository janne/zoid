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
    }
}
