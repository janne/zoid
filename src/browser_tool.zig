const std = @import("std");
const browser_automation = @import("browser_automation.zig");
const browser_runtime = @import("browser_runtime.zig");
const http_client = @import("http_client.zig");
const workspace_fs = @import("workspace_fs.zig");

pub const default_timeout_seconds: u32 = browser_automation.default_timeout_seconds;
pub const max_timeout_seconds: u32 = browser_automation.max_timeout_seconds;

pub const Policy = struct {
    workspace_root: []const u8,
    allow_private_http_destinations: bool = false,
    browser_app_data_dir_override: ?[]const u8 = null,
};

pub fn execute(
    allocator: std.mem.Allocator,
    policy: Policy,
    arguments_json: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{});
    defer parsed.deinit();

    const root_object = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidToolArguments,
    };

    if (root_object.get("timeout_seconds")) |timeout_value| {
        const timeout_seconds = switch (timeout_value) {
            .integer => |value| blk: {
                if (value <= 0) return error.InvalidToolArguments;
                const converted = std.math.cast(u32, value) orelse return error.InvalidToolArguments;
                break :blk converted;
            },
            else => return error.InvalidToolArguments,
        };
        if (timeout_seconds > max_timeout_seconds) return error.InvalidToolArguments;
    }

    if (root_object.get("session_id")) |session_id_value| {
        const session_id = switch (session_id_value) {
            .string => |value| value,
            else => return error.InvalidToolArguments,
        };
        if (!isValidBrowserSessionId(session_id)) return error.InvalidToolArguments;
    }
    if (root_object.get("session_dispose")) |dispose_value| {
        _ = switch (dispose_value) {
            .bool => {},
            else => return error.InvalidToolArguments,
        };
    }

    if (root_object.get("start_url")) |start_url_value| {
        const start_url = switch (start_url_value) {
            .string => |value| value,
            else => return error.InvalidToolArguments,
        };
        try http_client.validateUriPolicy(allocator, start_url, policy.allow_private_http_destinations);
    }

    if (root_object.get("actions")) |actions_value| {
        const actions_array = switch (actions_value) {
            .array => |value| value,
            else => return error.InvalidToolArguments,
        };
        for (actions_array.items) |action_value| {
            const action_object = switch (action_value) {
                .object => |object| object,
                else => return error.InvalidToolArguments,
            };
            const action_name = switch (action_object.get("action") orelse return error.InvalidToolArguments) {
                .string => |value| value,
                else => return error.InvalidToolArguments,
            };

            if (std.mem.eql(u8, action_name, "goto") or
                std.mem.eql(u8, action_name, "open") or
                std.mem.eql(u8, action_name, "download"))
            {
                const uri = switch (action_object.get("url") orelse return error.InvalidToolArguments) {
                    .string => |value| value,
                    else => return error.InvalidToolArguments,
                };
                try http_client.validateUriPolicy(allocator, uri, policy.allow_private_http_destinations);
            }

            if (std.mem.eql(u8, action_name, "screenshot")) {
                if (action_object.get("path")) |path_value| {
                    const path_text = switch (path_value) {
                        .string => |value| value,
                        else => return error.InvalidToolArguments,
                    };
                    const resolved = try workspace_fs.resolveAllowedWritePath(
                        allocator,
                        policy.workspace_root,
                        path_text,
                    );
                    allocator.free(resolved);
                }
            }

            if (std.mem.eql(u8, action_name, "download")) {
                const save_as = switch (action_object.get("save_as") orelse return error.InvalidToolArguments) {
                    .string => |value| value,
                    else => return error.InvalidToolArguments,
                };
                const resolved = try workspace_fs.resolveAllowedWritePath(
                    allocator,
                    policy.workspace_root,
                    save_as,
                );
                allocator.free(resolved);
            }

            if (std.mem.eql(u8, action_name, "upload")) {
                var validated_any = false;
                if (action_object.get("path")) |path_value| {
                    validated_any = true;
                    try validateBrowserUploadPathValue(allocator, policy.workspace_root, path_value);
                }
                if (action_object.get("paths")) |paths_value| {
                    validated_any = true;
                    try validateBrowserUploadPathValue(allocator, policy.workspace_root, paths_value);
                }
                if (!validated_any) return error.InvalidToolArguments;
            }
        }
    }

    var status = try browser_runtime.statusWithContext(allocator, .{
        .app_data_dir_override = policy.browser_app_data_dir_override,
    });
    defer status.deinit(allocator);

    if (!status.state_valid or !status.browser_files_present) {
        return error.BrowserSupportNotReady;
    }

    const session_dir = try std.fs.path.join(
        allocator,
        &.{ status.install_root, "sessions" },
    );
    defer allocator.free(session_dir);
    try std.fs.cwd().makePath(session_dir);

    const output = try browser_automation.execute(
        allocator,
        arguments_json,
        .{
            .browsers_path = status.browsers_path,
            .workspace_root = policy.workspace_root,
            .session_dir = session_dir,
            .allow_private_destinations = policy.allow_private_http_destinations,
        },
    );
    return output;
}

fn validateBrowserUploadPathValue(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    path_value: std.json.Value,
) !void {
    switch (path_value) {
        .string => |path_text| {
            const resolved = try workspace_fs.resolveAllowedReadPath(
                allocator,
                workspace_root,
                path_text,
            );
            allocator.free(resolved);
        },
        .array => |paths_array| {
            if (paths_array.items.len == 0) return error.InvalidToolArguments;
            for (paths_array.items) |entry| {
                const path_text = switch (entry) {
                    .string => |value| value,
                    else => return error.InvalidToolArguments,
                };
                const resolved = try workspace_fs.resolveAllowedReadPath(
                    allocator,
                    workspace_root,
                    path_text,
                );
                allocator.free(resolved);
            }
        },
        else => return error.InvalidToolArguments,
    }
}

fn isValidBrowserSessionId(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    for (value) |char| {
        if ((char >= 'a' and char <= 'z') or
            (char >= 'A' and char <= 'Z') or
            (char >= '0' and char <= '9') or
            char == '_' or
            char == '-')
        {
            continue;
        }
        return false;
    }
    return true;
}
