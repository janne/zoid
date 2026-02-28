const std = @import("std");
const config_keys = @import("config_keys.zig");
const config_store = @import("config_store.zig");
const openai_client = @import("openai_client.zig");

pub const default_telegram_max_conversation_messages: usize = 20;
pub const min_telegram_max_conversation_messages: usize = 2;
pub const max_telegram_max_conversation_messages: usize = 500;

pub const default_telegram_user_inactivity_reset_seconds: i64 = 8 * std.time.s_per_hour;
pub const min_telegram_user_inactivity_reset_seconds: i64 = 60;
pub const max_telegram_user_inactivity_reset_seconds: i64 = 7 * 24 * std.time.s_per_hour;

pub const default_telegram_inbound_worker_count: usize = 4;
pub const min_telegram_inbound_worker_count: usize = 1;
pub const max_telegram_inbound_worker_count: usize = 32;

pub const default_openai_max_workspace_instruction_chars: usize = 256 * 1024;
pub const min_openai_max_workspace_instruction_chars: usize = 1_024;
pub const max_openai_max_workspace_instruction_chars: usize = 1_048_576;

pub const Context = struct {
    config_path_override: ?[]const u8 = null,
};

pub const Limits = struct {
    openai: openai_client.Limits = .{},
    telegram_max_conversation_messages: usize = default_telegram_max_conversation_messages,
    telegram_user_inactivity_reset_seconds: i64 = default_telegram_user_inactivity_reset_seconds,
    telegram_inbound_worker_count: usize = default_telegram_inbound_worker_count,
    openai_max_workspace_instruction_chars: usize = default_openai_max_workspace_instruction_chars,
};

pub fn load(allocator: std.mem.Allocator) !Limits {
    return loadWithContext(allocator, .{});
}

pub fn loadWithContext(
    allocator: std.mem.Allocator,
    context: Context,
) !Limits {
    return .{
        .openai = .{
            .max_input_tokens = try readBoundedUsize(
                allocator,
                context,
                config_keys.openai_max_input_tokens,
                openai_client.default_max_input_tokens,
                openai_client.min_max_input_tokens,
                openai_client.max_max_input_tokens,
            ),
            .max_message_chars = try readBoundedUsize(
                allocator,
                context,
                config_keys.openai_max_message_chars,
                openai_client.default_max_message_chars,
                openai_client.min_max_message_chars,
                openai_client.max_max_message_chars,
            ),
            .max_tool_rounds = try readBoundedUsize(
                allocator,
                context,
                config_keys.openai_max_tool_rounds,
                openai_client.default_max_tool_rounds,
                openai_client.min_max_tool_rounds,
                openai_client.max_max_tool_rounds,
            ),
            .max_tool_result_chars = try readBoundedUsize(
                allocator,
                context,
                config_keys.openai_max_tool_result_chars,
                openai_client.default_max_tool_result_chars,
                openai_client.min_max_tool_result_chars,
                openai_client.max_max_tool_result_chars,
            ),
        },
        .telegram_max_conversation_messages = try readBoundedUsize(
            allocator,
            context,
            config_keys.telegram_max_conversation_messages,
            default_telegram_max_conversation_messages,
            min_telegram_max_conversation_messages,
            max_telegram_max_conversation_messages,
        ),
        .telegram_user_inactivity_reset_seconds = try readBoundedI64(
            allocator,
            context,
            config_keys.telegram_user_inactivity_reset_seconds,
            default_telegram_user_inactivity_reset_seconds,
            min_telegram_user_inactivity_reset_seconds,
            max_telegram_user_inactivity_reset_seconds,
        ),
        .telegram_inbound_worker_count = try readBoundedUsize(
            allocator,
            context,
            config_keys.telegram_inbound_worker_count,
            default_telegram_inbound_worker_count,
            min_telegram_inbound_worker_count,
            max_telegram_inbound_worker_count,
        ),
        .openai_max_workspace_instruction_chars = try readBoundedUsize(
            allocator,
            context,
            config_keys.openai_max_workspace_instruction_chars,
            default_openai_max_workspace_instruction_chars,
            min_openai_max_workspace_instruction_chars,
            max_openai_max_workspace_instruction_chars,
        ),
    };
}

fn readBoundedUsize(
    allocator: std.mem.Allocator,
    context: Context,
    key: []const u8,
    fallback: usize,
    min_value: usize,
    max_value: usize,
) !usize {
    const maybe_value = try getConfigValue(allocator, context, key);
    defer if (maybe_value) |value| allocator.free(value);
    const raw_value = maybe_value orelse return fallback;
    const trimmed_value = std.mem.trim(u8, raw_value, " \t\r\n");
    if (trimmed_value.len == 0) return fallback;

    const parsed = std.fmt.parseInt(u64, trimmed_value, 10) catch return fallback;
    const parsed_value = std.math.cast(usize, parsed) orelse return fallback;
    if (parsed_value < min_value or parsed_value > max_value) return fallback;
    return parsed_value;
}

fn readBoundedI64(
    allocator: std.mem.Allocator,
    context: Context,
    key: []const u8,
    fallback: i64,
    min_value: i64,
    max_value: i64,
) !i64 {
    const maybe_value = try getConfigValue(allocator, context, key);
    defer if (maybe_value) |value| allocator.free(value);
    const raw_value = maybe_value orelse return fallback;
    const trimmed_value = std.mem.trim(u8, raw_value, " \t\r\n");
    if (trimmed_value.len == 0) return fallback;

    const parsed = std.fmt.parseInt(i64, trimmed_value, 10) catch return fallback;
    if (parsed < min_value or parsed > max_value) return fallback;
    return parsed;
}

fn getConfigValue(
    allocator: std.mem.Allocator,
    context: Context,
    key: []const u8,
) !?[]u8 {
    if (context.config_path_override) |path| {
        return config_store.getValueAtPath(allocator, path, key);
    }
    return config_store.getValue(allocator, key);
}

test "loadWithContext returns defaults when keys are missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root_path);
    const config_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "config.json" });
    defer std.testing.allocator.free(config_path);

    const limits = try loadWithContext(std.testing.allocator, .{
        .config_path_override = config_path,
    });
    try std.testing.expectEqual(openai_client.default_max_input_tokens, limits.openai.max_input_tokens);
    try std.testing.expectEqual(openai_client.default_max_message_chars, limits.openai.max_message_chars);
    try std.testing.expectEqual(openai_client.default_max_tool_rounds, limits.openai.max_tool_rounds);
    try std.testing.expectEqual(openai_client.default_max_tool_result_chars, limits.openai.max_tool_result_chars);
    try std.testing.expectEqual(default_telegram_max_conversation_messages, limits.telegram_max_conversation_messages);
    try std.testing.expectEqual(default_telegram_user_inactivity_reset_seconds, limits.telegram_user_inactivity_reset_seconds);
    try std.testing.expectEqual(default_telegram_inbound_worker_count, limits.telegram_inbound_worker_count);
    try std.testing.expectEqual(default_openai_max_workspace_instruction_chars, limits.openai_max_workspace_instruction_chars);
}

test "loadWithContext applies valid numeric overrides" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root_path);
    const config_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "config.json" });
    defer std.testing.allocator.free(config_path);

    try config_store.setValueAtPath(std.testing.allocator, config_path, config_keys.openai_max_input_tokens, "150000");
    try config_store.setValueAtPath(std.testing.allocator, config_path, config_keys.openai_max_message_chars, "9000");
    try config_store.setValueAtPath(std.testing.allocator, config_path, config_keys.openai_max_tool_rounds, "10");
    try config_store.setValueAtPath(std.testing.allocator, config_path, config_keys.openai_max_tool_result_chars, "6000");
    try config_store.setValueAtPath(std.testing.allocator, config_path, config_keys.telegram_max_conversation_messages, "30");
    try config_store.setValueAtPath(std.testing.allocator, config_path, config_keys.telegram_user_inactivity_reset_seconds, "3600");
    try config_store.setValueAtPath(std.testing.allocator, config_path, config_keys.telegram_inbound_worker_count, "6");
    try config_store.setValueAtPath(std.testing.allocator, config_path, config_keys.openai_max_workspace_instruction_chars, "65536");

    const limits = try loadWithContext(std.testing.allocator, .{
        .config_path_override = config_path,
    });
    try std.testing.expectEqual(@as(usize, 150000), limits.openai.max_input_tokens);
    try std.testing.expectEqual(@as(usize, 9000), limits.openai.max_message_chars);
    try std.testing.expectEqual(@as(usize, 10), limits.openai.max_tool_rounds);
    try std.testing.expectEqual(@as(usize, 6000), limits.openai.max_tool_result_chars);
    try std.testing.expectEqual(@as(usize, 30), limits.telegram_max_conversation_messages);
    try std.testing.expectEqual(@as(i64, 3600), limits.telegram_user_inactivity_reset_seconds);
    try std.testing.expectEqual(@as(usize, 6), limits.telegram_inbound_worker_count);
    try std.testing.expectEqual(@as(usize, 65536), limits.openai_max_workspace_instruction_chars);
}

test "loadWithContext falls back when values are invalid or out of range" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root_path);
    const config_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "config.json" });
    defer std.testing.allocator.free(config_path);

    try config_store.setValueAtPath(std.testing.allocator, config_path, config_keys.openai_max_input_tokens, "abc");
    try config_store.setValueAtPath(std.testing.allocator, config_path, config_keys.openai_max_message_chars, "0");
    try config_store.setValueAtPath(std.testing.allocator, config_path, config_keys.openai_max_tool_rounds, "-1");
    try config_store.setValueAtPath(std.testing.allocator, config_path, config_keys.openai_max_tool_result_chars, "999999999");
    try config_store.setValueAtPath(std.testing.allocator, config_path, config_keys.telegram_max_conversation_messages, "1");
    try config_store.setValueAtPath(std.testing.allocator, config_path, config_keys.telegram_user_inactivity_reset_seconds, "30");
    try config_store.setValueAtPath(std.testing.allocator, config_path, config_keys.telegram_inbound_worker_count, "0");
    try config_store.setValueAtPath(std.testing.allocator, config_path, config_keys.openai_max_workspace_instruction_chars, "999999999");

    const limits = try loadWithContext(std.testing.allocator, .{
        .config_path_override = config_path,
    });
    try std.testing.expectEqual(openai_client.default_max_input_tokens, limits.openai.max_input_tokens);
    try std.testing.expectEqual(openai_client.default_max_message_chars, limits.openai.max_message_chars);
    try std.testing.expectEqual(openai_client.default_max_tool_rounds, limits.openai.max_tool_rounds);
    try std.testing.expectEqual(openai_client.default_max_tool_result_chars, limits.openai.max_tool_result_chars);
    try std.testing.expectEqual(default_telegram_max_conversation_messages, limits.telegram_max_conversation_messages);
    try std.testing.expectEqual(default_telegram_user_inactivity_reset_seconds, limits.telegram_user_inactivity_reset_seconds);
    try std.testing.expectEqual(default_telegram_inbound_worker_count, limits.telegram_inbound_worker_count);
    try std.testing.expectEqual(default_openai_max_workspace_instruction_chars, limits.openai_max_workspace_instruction_chars);
}
