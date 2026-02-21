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
            error.MissingRunArgument => {
                std.debug.print("Missing argument for 'run'.\n\n", .{});
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
            var outcome = executeLuaAsTool(allocator, file_path, null) catch |err| {
                switch (err) {
                    error.PathNotAllowed => std.debug.print("Lua script path is outside the current workspace.\n", .{}),
                    error.InvalidToolArguments => std.debug.print("Lua script path must resolve to a .lua file inside the current workspace.\n", .{}),
                    error.FileNotFound => std.debug.print("Lua script not found: {s}\n", .{file_path}),
                    error.OutOfMemory => std.debug.print("Out of memory while preparing Lua execution.\n", .{}),
                    else => std.debug.print("Lua execution failed: {s}\n", .{@errorName(err)}),
                }
                std.process.exit(1);
            };
            defer outcome.deinit(allocator);

            if (outcome.stdout.len > 0) {
                try std.fs.File.stdout().writeAll(outcome.stdout);
            }
            if (outcome.stderr.len > 0) {
                try std.fs.File.stderr().writeAll(outcome.stderr);
            }
            if (!outcome.ok) {
                if (outcome.stderr.len == 0) {
                    if (outcome.error_name) |error_name| {
                        std.debug.print("{s}\n", .{error_name});
                    }
                }
                std.process.exit(1);
            }
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
        .run => |prompt_parts| {
            const settings = loadOpenAISettingsOrExit(allocator);
            defer settings.deinit(allocator);

            const prompt = std.mem.join(allocator, " ", prompt_parts) catch |err| {
                std.debug.print("Failed to build prompt: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
            defer allocator.free(prompt);

            const trimmed_prompt = std.mem.trim(u8, prompt, " \t\r\n");
            if (trimmed_prompt.len == 0) {
                std.debug.print("Prompt cannot be empty.\n", .{});
                std.process.exit(1);
            }

            const messages = [_]zoid.openai_client.Message{
                .{ .role = .user, .content = trimmed_prompt },
            };

            const reply = zoid.openai_client.fetchAssistantReply(
                allocator,
                settings.api_key,
                settings.model,
                &messages,
            ) catch |err| {
                std.debug.print("OpenAI request failed: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
            defer allocator.free(reply);

            try std.fs.File.stdout().writeAll(reply);
            try std.fs.File.stdout().writeAll("\n");
        },
        .serve => {
            const openai_settings = loadOpenAISettingsOrExit(allocator);
            defer openai_settings.deinit(allocator);

            const bot_token = loadTelegramBotTokenOrExit(allocator);
            defer allocator.free(bot_token);

            zoid.telegram_bot.runLongPolling(allocator, .{
                .bot_token = bot_token,
                .openai_api_key = openai_settings.api_key,
                .openai_model = openai_settings.model,
            }) catch |err| {
                std.debug.print("Telegram bot failed: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
        },
        .chat => {
            if (!std.fs.File.stdin().isTty() or !std.fs.File.stdout().isTty()) {
                std.debug.print("The 'chat' command requires a TTY. Use: zoid run <prompt...>\n", .{});
                std.process.exit(1);
            }

            const settings = loadOpenAISettingsOrExit(allocator);
            defer settings.deinit(allocator);

            zoid.chat_session.run(allocator, settings.api_key, settings.model) catch |err| {
                std.debug.print("Chat session failed: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
        },
    }
}

const LuaExecuteOutcome = struct {
    ok: bool,
    stdout: []u8,
    stderr: []u8,
    error_name: ?[]u8,

    fn deinit(self: *LuaExecuteOutcome, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        if (self.error_name) |value| allocator.free(value);
    }
};

fn executeLuaAsTool(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    workspace_root_override: ?[]const u8,
) !LuaExecuteOutcome {
    var policy = if (workspace_root_override) |workspace_root|
        try zoid.tool_runtime.Policy.initForWorkspaceRoot(allocator, workspace_root)
    else
        try zoid.tool_runtime.Policy.initForCurrentWorkspace(allocator);
    defer policy.deinit(allocator);

    const escaped_path = try std.json.Stringify.valueAlloc(allocator, file_path, .{});
    defer allocator.free(escaped_path);

    const arguments_json = try std.fmt.allocPrint(allocator, "{{\"path\":{s}}}", .{escaped_path});
    defer allocator.free(arguments_json);

    const result_json = try zoid.tool_runtime.executeToolCall(
        allocator,
        &policy,
        "lua_execute",
        arguments_json,
    );
    defer allocator.free(result_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, result_json, .{});
    defer parsed.deinit();

    const root_object = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidToolResult,
    };

    const ok = switch (root_object.get("ok") orelse return error.InvalidToolResult) {
        .bool => |value| value,
        else => return error.InvalidToolResult,
    };
    const stdout_value = switch (root_object.get("stdout") orelse return error.InvalidToolResult) {
        .string => |value| value,
        else => return error.InvalidToolResult,
    };
    const stderr_value = switch (root_object.get("stderr") orelse return error.InvalidToolResult) {
        .string => |value| value,
        else => return error.InvalidToolResult,
    };

    const stdout = try allocator.dupe(u8, stdout_value);
    errdefer allocator.free(stdout);
    const stderr = try allocator.dupe(u8, stderr_value);
    errdefer allocator.free(stderr);

    const error_name = if (root_object.get("error")) |error_value|
        switch (error_value) {
            .string => |value| try allocator.dupe(u8, value),
            else => return error.InvalidToolResult,
        }
    else
        null;
    errdefer if (error_name) |value| allocator.free(value);

    return .{
        .ok = ok,
        .stdout = stdout,
        .stderr = stderr,
        .error_name = error_name,
    };
}

const OpenAISettings = struct {
    api_key: []u8,
    model: []u8,

    fn deinit(self: OpenAISettings, allocator: std.mem.Allocator) void {
        allocator.free(self.api_key);
        allocator.free(self.model);
    }
};

fn loadOpenAISettingsOrExit(allocator: std.mem.Allocator) OpenAISettings {
    return loadOpenAISettings(allocator) catch |err| {
        switch (err) {
            error.InvalidConfigFormat => std.debug.print("Config file is invalid JSON (expected key/value string object).\n", .{}),
            error.MissingOpenAIApiKey => std.debug.print(
                "Config key {s} is missing. Use: zoid config set {s} <value>\n",
                .{ zoid.config_keys.openai_api_key, zoid.config_keys.openai_api_key },
            ),
            else => std.debug.print("Failed to load OpenAI settings: {s}\n", .{@errorName(err)}),
        }
        std.process.exit(1);
    };
}

fn loadOpenAISettings(allocator: std.mem.Allocator) !OpenAISettings {
    const api_key_value = try zoid.config_store.getValue(allocator, zoid.config_keys.openai_api_key);
    const api_key = api_key_value orelse return error.MissingOpenAIApiKey;

    const model_value = try zoid.config_store.getValue(allocator, zoid.config_keys.openai_model);
    const model = if (model_value) |value|
        value
    else
        try allocator.dupe(u8, zoid.model_catalog.default_model);

    return .{
        .api_key = api_key,
        .model = model,
    };
}

fn loadTelegramBotTokenOrExit(allocator: std.mem.Allocator) []u8 {
    return loadTelegramBotToken(allocator) catch |err| {
        switch (err) {
            error.InvalidConfigFormat => std.debug.print("Config file is invalid JSON (expected key/value string object).\n", .{}),
            error.MissingTelegramBotToken => std.debug.print(
                "Config key {s} is missing. Use: zoid config set {s} <value>\n",
                .{ zoid.config_keys.telegram_bot_token, zoid.config_keys.telegram_bot_token },
            ),
            else => std.debug.print("Failed to load Telegram bot token: {s}\n", .{@errorName(err)}),
        }
        std.process.exit(1);
    };
}

fn loadTelegramBotToken(allocator: std.mem.Allocator) ![]u8 {
    const token_value = try zoid.config_store.getValue(allocator, zoid.config_keys.telegram_bot_token);
    return token_value orelse error.MissingTelegramBotToken;
}

test "executeLuaAsTool runs script with lua_execute sandbox policy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script = try tmp.dir.createFile("ok.lua", .{});
    defer script.close();
    try script.writeAll(
        \\local note = zoid.file("note.txt")
        \\note:write("hello")
        \\print(note:read())
        \\note:delete()
        \\
    );

    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    var outcome = try executeLuaAsTool(std.testing.allocator, "ok.lua", workspace_root);
    defer outcome.deinit(std.testing.allocator);

    try std.testing.expect(outcome.ok);
    try std.testing.expectEqualStrings("hello\n", outcome.stdout);
    try std.testing.expectEqualStrings("", outcome.stderr);
    try std.testing.expect(outcome.error_name == null);

    const note_path = try std.fs.path.join(std.testing.allocator, &.{ workspace_root, "note.txt" });
    defer std.testing.allocator.free(note_path);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(note_path, .{}));
}

test "executeLuaAsTool rejects traversal outside workspace root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("workspace");
    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, "workspace");
    defer std.testing.allocator.free(workspace_root);

    const outside = try tmp.dir.createFile("outside.lua", .{});
    defer outside.close();
    try outside.writeAll("return 1\n");

    try std.testing.expectError(
        error.PathNotAllowed,
        executeLuaAsTool(std.testing.allocator, "../outside.lua", workspace_root),
    );
}

test "executeLuaAsTool requires lua extension" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script = try tmp.dir.createFile("not_lua.txt", .{});
    defer script.close();
    try script.writeAll("print('nope')\n");

    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    try std.testing.expectError(
        error.InvalidToolArguments,
        executeLuaAsTool(std.testing.allocator, "not_lua.txt", workspace_root),
    );
}
