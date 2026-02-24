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
            error.InvalidInitArguments => {
                std.debug.print("Invalid arguments for 'init'.\n\n", .{});
                zoid.cli.printHelp();
                return;
            },
            error.MissingExecuteArgument => {
                std.debug.print("Missing argument for 'execute'.\n\n", .{});
                zoid.cli.printHelp();
                return;
            },
            error.InvalidExecuteArguments => {
                std.debug.print("Invalid arguments for 'execute'.\n\n", .{});
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
            error.MissingJobsSubcommand => {
                std.debug.print("Missing subcommand for 'jobs'.\n\n", .{});
                zoid.cli.printHelp();
                return;
            },
            error.MissingJobsArgument => {
                std.debug.print("Missing argument for jobs command.\n\n", .{});
                zoid.cli.printHelp();
                return;
            },
            error.InvalidJobsArguments => {
                std.debug.print("Invalid arguments for jobs command.\n\n", .{});
                zoid.cli.printHelp();
                return;
            },
            error.UnknownConfigSubcommand => {
                std.debug.print("Unknown config command: {s}\n\n", .{args[2]});
                zoid.cli.printHelp();
                return;
            },
            error.UnknownJobsSubcommand => {
                std.debug.print("Unknown jobs command: {s}\n\n", .{args[2]});
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
        .init => |init_cmd| {
            var outcome = zoid.workspace_init.initWorkspace(
                allocator,
                init_cmd.path,
                init_cmd.force,
            ) catch |err| {
                switch (err) {
                    error.NotDir => std.debug.print("Init path is not a directory: {s}\n", .{init_cmd.path}),
                    else => std.debug.print("Failed to initialize workspace: {s}\n", .{@errorName(err)}),
                }
                std.process.exit(1);
            };
            defer outcome.deinit(allocator);

            if (outcome.conflict_path) |conflict_path| {
                std.debug.print(
                    "Init aborted because target file already exists: {s}. Use --force to overwrite.\n",
                    .{conflict_path},
                );
                std.process.exit(1);
            }

            const message = try std.fmt.allocPrint(
                allocator,
                "Initialized workspace in {s} ({d} files copied).\n",
                .{ init_cmd.path, outcome.copied_files },
            );
            defer allocator.free(message);
            try std.fs.File.stdout().writeAll(message);
        },
        .execute => |execute_cmd| {
            var outcome = executeLuaAsTool(
                allocator,
                execute_cmd.file_path,
                execute_cmd.script_args,
                execute_cmd.timeout,
                null,
            ) catch |err| {
                switch (err) {
                    error.PathNotAllowed => std.debug.print("Lua script path is outside the current workspace.\n", .{}),
                    error.InvalidToolArguments => std.debug.print("Lua script path must resolve to a .lua file inside the current workspace.\n", .{}),
                    error.FileNotFound => std.debug.print("Lua script not found: {s}\n", .{execute_cmd.file_path}),
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
                        if (!std.mem.eql(u8, error_name, "LuaExit")) {
                            std.debug.print("{s}\n", .{error_name});
                        }
                    }
                }
                std.process.exit(outcome.exit_code orelse 1);
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
        .jobs => |jobs_cmd| {
            const workspace_root = getWorkspaceRoot(allocator) catch |err| {
                std.debug.print("Failed to resolve workspace root: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
            defer allocator.free(workspace_root);

            const scheduler_context = zoid.scheduler_runtime.Context{
                .workspace_root = workspace_root,
            };

            switch (jobs_cmd) {
                .create => |create_cmd| {
                    var created = zoid.scheduler_runtime.createJob(
                        allocator,
                        scheduler_context,
                        .{
                            .path = create_cmd.path,
                            .at = create_cmd.at,
                            .cron = create_cmd.cron,
                        },
                    ) catch |err| {
                        reportScheduleError(err);
                        std.process.exit(1);
                    };
                    defer created.deinit(allocator);

                    try printScheduleJob(allocator, workspace_root, &created);
                },
                .list => {
                    const jobs = zoid.scheduler_runtime.listJobs(allocator, scheduler_context) catch |err| {
                        reportScheduleError(err);
                        std.process.exit(1);
                    };
                    defer zoid.scheduler_store.deinitJobs(allocator, jobs);

                    const output = formatScheduleJobList(allocator, workspace_root, jobs) catch |err| {
                        std.debug.print("Failed to format job list: {s}\n", .{@errorName(err)});
                        std.process.exit(1);
                    };
                    defer allocator.free(output);
                    try std.fs.File.stdout().writeAll(output);
                },
                .delete => |job_id| {
                    const removed = zoid.scheduler_runtime.deleteJob(allocator, scheduler_context, job_id) catch |err| {
                        reportScheduleError(err);
                        std.process.exit(1);
                    };
                    if (!removed) {
                        std.debug.print("Scheduled job not found: {s}\n", .{job_id});
                        std.process.exit(1);
                    }
                },
                .pause => |job_id| {
                    const updated = zoid.scheduler_runtime.pauseJob(allocator, scheduler_context, job_id) catch |err| {
                        reportScheduleError(err);
                        std.process.exit(1);
                    };
                    if (!updated) {
                        std.debug.print("Scheduled job not found: {s}\n", .{job_id});
                        std.process.exit(1);
                    }
                },
                .@"resume" => |job_id| {
                    const updated = zoid.scheduler_runtime.resumeJob(allocator, scheduler_context, job_id) catch |err| {
                        reportScheduleError(err);
                        std.process.exit(1);
                    };
                    if (!updated) {
                        std.debug.print("Scheduled job not found: {s}\n", .{job_id});
                        std.process.exit(1);
                    }
                },
            }
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

            const workspace_instruction = loadWorkspaceAgentInstruction(allocator) catch |err| blk: {
                std.debug.print(
                    "Warning: failed to load workspace instructions from ZOID.md: {s}\n",
                    .{@errorName(err)},
                );
                break :blk null;
            };
            defer if (workspace_instruction) |value| allocator.free(value);

            zoid.telegram_bot.runLongPolling(allocator, .{
                .bot_token = bot_token,
                .openai_api_key = openai_settings.api_key,
                .openai_model = openai_settings.model,
                .workspace_instruction = workspace_instruction,
            }) catch |err| {
                switch (err) {
                    error.ServiceAlreadyRunning => {
                        std.debug.print(
                            "Telegram service is already running for this user (lock file is held).\n",
                            .{},
                        );
                    },
                    else => std.debug.print("Telegram bot failed: {s}\n", .{@errorName(err)}),
                }
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

            const workspace_instruction = loadWorkspaceAgentInstruction(allocator) catch |err| blk: {
                std.debug.print(
                    "Warning: failed to load workspace instructions from ZOID.md: {s}\n",
                    .{@errorName(err)},
                );
                break :blk null;
            };
            defer if (workspace_instruction) |value| allocator.free(value);

            zoid.chat_session.run(allocator, settings.api_key, settings.model, workspace_instruction) catch |err| {
                std.debug.print("Chat session failed: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
        },
    }
}

const LuaExecuteOutcome = struct {
    ok: bool,
    exit_code: ?u8,
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
    script_args: []const []const u8,
    timeout: ?u32,
    workspace_root_override: ?[]const u8,
) !LuaExecuteOutcome {
    var policy = if (workspace_root_override) |workspace_root|
        try zoid.tool_runtime.Policy.initForWorkspaceRoot(allocator, workspace_root)
    else
        try zoid.tool_runtime.Policy.initForCurrentWorkspace(allocator);
    defer policy.deinit(allocator);

    const escaped_path = try std.json.Stringify.valueAlloc(allocator, file_path, .{});
    defer allocator.free(escaped_path);

    var arguments_json = std.ArrayList(u8).empty;
    defer arguments_json.deinit(allocator);
    try arguments_json.appendSlice(allocator, "{\"path\":");
    try arguments_json.appendSlice(allocator, escaped_path);
    if (script_args.len > 0) {
        try arguments_json.appendSlice(allocator, ",\"args\":[");
        for (script_args, 0..) |script_arg, arg_index| {
            if (arg_index > 0) try arguments_json.append(allocator, ',');
            const escaped_arg = try std.json.Stringify.valueAlloc(allocator, script_arg, .{});
            defer allocator.free(escaped_arg);
            try arguments_json.appendSlice(allocator, escaped_arg);
        }
        try arguments_json.append(allocator, ']');
    }
    if (timeout) |value| {
        try arguments_json.writer(allocator).print(",\"timeout\":{d}", .{value});
    }
    try arguments_json.append(allocator, '}');

    const result_json = try zoid.tool_runtime.executeToolCall(
        allocator,
        &policy,
        "lua_execute",
        arguments_json.items,
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

    const exit_code = if (root_object.get("exit_code")) |exit_value| switch (exit_value) {
        .null => null,
        .integer => |value| @as(u8, @intCast(std.math.clamp(value, 0, 255))),
        else => return error.InvalidToolResult,
    } else null;

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
        .exit_code = exit_code,
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

const workspace_agent_instruction_file_name = "ZOID.md";
const max_workspace_agent_instruction_bytes: usize = 256 * 1024;

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

fn loadWorkspaceAgentInstruction(allocator: std.mem.Allocator) !?[]u8 {
    const workspace_root = try getWorkspaceRoot(allocator);
    defer allocator.free(workspace_root);
    return loadWorkspaceAgentInstructionAtPath(allocator, workspace_root);
}

fn loadWorkspaceAgentInstructionAtPath(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
) !?[]u8 {
    const path = try std.fs.path.join(
        allocator,
        &.{ workspace_root, workspace_agent_instruction_file_name },
    );
    defer allocator.free(path);

    const content = std.fs.cwd().readFileAlloc(
        allocator,
        path,
        max_workspace_agent_instruction_bytes,
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(content);

    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

fn getWorkspaceRoot(allocator: std.mem.Allocator) ![]u8 {
    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);
    return std.fs.cwd().realpathAlloc(allocator, cwd);
}

const JobListRow = struct {
    id: []const u8,
    state: []const u8,
    next_run: []u8,
    schedule: []u8,
    last_run: []u8,
    path: []u8,

    fn deinit(self: *JobListRow, allocator: std.mem.Allocator) void {
        allocator.free(self.next_run);
        allocator.free(self.schedule);
        allocator.free(self.last_run);
        allocator.free(self.path);
    }
};

fn formatScheduleJobList(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    jobs: []zoid.scheduler_store.Job,
) ![]u8 {
    if (jobs.len == 0) return allocator.dupe(u8, "No scheduled jobs.\n");

    std.mem.sort(zoid.scheduler_store.Job, jobs, {}, sortJobsForList);

    var rows = std.ArrayList(JobListRow).empty;
    defer {
        for (rows.items) |*row| row.deinit(allocator);
        rows.deinit(allocator);
    }

    var id_width: usize = "JOB".len;
    var state_width: usize = "ST".len;
    var next_width: usize = "NEXT".len;
    var schedule_width: usize = "SCHEDULE".len;
    var last_width: usize = "LAST".len;

    for (jobs) |*job| {
        const next_run = try formatEpochDisplay(allocator, job.next_run_at);
        errdefer allocator.free(next_run);

        const schedule = try formatJobSchedule(allocator, job);
        errdefer allocator.free(schedule);

        const last_run = if (job.last_run_at) |value|
            try formatEpochDisplay(allocator, value)
        else
            try allocator.dupe(u8, "-");
        errdefer allocator.free(last_run);

        const relative_path = try std.fs.path.relative(allocator, workspace_root, job.path);
        const workspace_absolute_path = if (relative_path.len == 0 or std.mem.eql(u8, relative_path, "."))
            try allocator.dupe(u8, "/")
        else
            try std.fmt.allocPrint(allocator, "/{s}", .{relative_path});
        allocator.free(relative_path);
        errdefer allocator.free(workspace_absolute_path);

        const row: JobListRow = .{
            .id = job.id,
            .state = if (job.paused) "P" else "R",
            .next_run = next_run,
            .schedule = schedule,
            .last_run = last_run,
            .path = workspace_absolute_path,
        };

        id_width = @max(id_width, row.id.len);
        state_width = @max(state_width, row.state.len);
        next_width = @max(next_width, row.next_run.len);
        schedule_width = @max(schedule_width, row.schedule.len);
        last_width = @max(last_width, row.last_run.len);

        try rows.append(allocator, row);
    }

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    try appendScheduleListLine(
        &output,
        allocator,
        "JOB",
        id_width,
        "ST",
        state_width,
        "NEXT",
        next_width,
        "SCHEDULE",
        schedule_width,
        "LAST",
        last_width,
        "PATH",
    );

    for (rows.items) |row| {
        try appendScheduleListLine(
            &output,
            allocator,
            row.id,
            id_width,
            row.state,
            state_width,
            row.next_run,
            next_width,
            row.schedule,
            schedule_width,
            row.last_run,
            last_width,
            row.path,
        );
    }

    return output.toOwnedSlice(allocator);
}

fn appendScheduleListLine(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    id: []const u8,
    id_width: usize,
    state: []const u8,
    state_width: usize,
    next_run: []const u8,
    next_width: usize,
    schedule: []const u8,
    schedule_width: usize,
    last_run: []const u8,
    last_width: usize,
    path: []const u8,
) !void {
    try appendPaddedCell(output, allocator, id, id_width);
    try output.append(allocator, ' ');
    try appendPaddedCell(output, allocator, state, state_width);
    try output.append(allocator, ' ');
    try appendPaddedCell(output, allocator, next_run, next_width);
    try output.append(allocator, ' ');
    try appendPaddedCell(output, allocator, schedule, schedule_width);
    try output.append(allocator, ' ');
    try appendPaddedCell(output, allocator, last_run, last_width);
    try output.append(allocator, ' ');
    try output.appendSlice(allocator, path);
    try output.append(allocator, '\n');
}

fn appendPaddedCell(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: []const u8,
    width: usize,
) !void {
    try output.appendSlice(allocator, value);
    if (width <= value.len) return;

    var remaining = width - value.len;
    while (remaining > 0) : (remaining -= 1) {
        try output.append(allocator, ' ');
    }
}

fn formatJobSchedule(allocator: std.mem.Allocator, job: *const zoid.scheduler_store.Job) ![]u8 {
    if (job.run_at) |run_at| {
        const run_text = try formatEpochDisplay(allocator, run_at);
        defer allocator.free(run_text);
        return std.fmt.allocPrint(allocator, "at:{s}", .{run_text});
    }
    if (job.cron) |cron| {
        return std.fmt.allocPrint(allocator, "cron:{s}", .{cron});
    }
    return allocator.dupe(u8, "-");
}

fn formatEpochDisplay(allocator: std.mem.Allocator, epoch: i64) ![]u8 {
    if (epoch < 0) return allocator.dupe(u8, "invalid");

    const epoch_u64 = std.math.cast(u64, epoch) orelse return std.fmt.allocPrint(allocator, "{d}", .{epoch});
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = epoch_u64 };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
        },
    );
}

fn sortJobsForList(_: void, a: zoid.scheduler_store.Job, b: zoid.scheduler_store.Job) bool {
    if (a.paused != b.paused) return !a.paused and b.paused;
    if (a.next_run_at != b.next_run_at) return a.next_run_at < b.next_run_at;
    return std.mem.order(u8, a.id, b.id) == .lt;
}

fn printScheduleJob(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    job: *const zoid.scheduler_store.Job,
) !void {
    const relative_path = try std.fs.path.relative(allocator, workspace_root, job.path);
    defer allocator.free(relative_path);
    const workspace_absolute_path = if (relative_path.len == 0 or std.mem.eql(u8, relative_path, "."))
        try allocator.dupe(u8, "/")
    else
        try std.fmt.allocPrint(allocator, "/{s}", .{relative_path});
    defer allocator.free(workspace_absolute_path);

    const line1 = try std.fmt.allocPrint(allocator, "id={s} path={s} paused={}\n", .{
        job.id,
        workspace_absolute_path,
        job.paused,
    });
    defer allocator.free(line1);
    try std.fs.File.stdout().writeAll(line1);

    var tail = std.ArrayList(u8).empty;
    defer tail.deinit(allocator);

    const next_run_text = try formatEpochDisplay(allocator, job.next_run_at);
    defer allocator.free(next_run_text);
    try tail.appendSlice(allocator, "  next_run_at=");
    try tail.appendSlice(allocator, next_run_text);
    if (job.run_at) |run_at| {
        const run_at_text = try formatEpochDisplay(allocator, run_at);
        defer allocator.free(run_at_text);
        try tail.writer(allocator).print(" at={s}", .{run_at_text});
    }
    if (job.cron) |cron| {
        try tail.writer(allocator).print(" cron={s}", .{cron});
    }
    if (job.last_run_at) |last_run_at| {
        const last_run_text = try formatEpochDisplay(allocator, last_run_at);
        defer allocator.free(last_run_text);
        try tail.writer(allocator).print(" last_run_at={s}", .{last_run_text});
    }
    try tail.append(allocator, '\n');
    try std.fs.File.stdout().writeAll(tail.items);
}

fn reportScheduleError(err: anyerror) void {
    switch (err) {
        error.InvalidSchedule => std.debug.print("Invalid schedule. Provide either --at <datetime-expression> or --cron \"<min hour dom mon dow>\".\n", .{}),
        error.InvalidTimestamp => std.debug.print("Invalid --at value. Example values: 2026-02-22T21:00:00Z or \"in 5 minutes\".\n", .{}),
        error.InvalidJobPath => std.debug.print("Invalid job path. Scheduled jobs require a .lua file under workspace root.\n", .{}),
        error.InvalidExpression, error.InvalidField, error.InvalidRange, error.InvalidStep, error.InvalidValue => {
            std.debug.print("Invalid cron expression.\n", .{});
        },
        else => std.debug.print("Schedule operation failed: {s}\n", .{@errorName(err)}),
    }
}

test "formatScheduleJobList renders ps-like columns" {
    var jobs = [_]zoid.scheduler_store.Job{
        .{
            .id = try std.testing.allocator.dupe(u8, "job-aaa111"),
            .path = try std.testing.allocator.dupe(u8, "/tmp/first.lua"),
            .chat_id = 0,
            .paused = false,
            .run_at = 0,
            .cron = null,
            .next_run_at = 0,
            .created_at = 0,
            .updated_at = 0,
            .last_run_at = null,
        },
        .{
            .id = try std.testing.allocator.dupe(u8, "job-bbb111"),
            .path = try std.testing.allocator.dupe(u8, "/tmp/second.lua"),
            .chat_id = 0,
            .paused = true,
            .run_at = null,
            .cron = try std.testing.allocator.dupe(u8, "0 21 * * *"),
            .next_run_at = 120,
            .created_at = 0,
            .updated_at = 0,
            .last_run_at = -1,
        },
    };
    defer for (&jobs) |*job| job.deinit(std.testing.allocator);

    const output = try formatScheduleJobList(std.testing.allocator, "/tmp", &jobs);
    defer std.testing.allocator.free(output);

    var lines = std.mem.splitScalar(u8, output, '\n');
    const header = lines.next().?;
    try std.testing.expect(std.mem.indexOf(u8, header, "JOB") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "ST") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "NEXT") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "SCHEDULE") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "LAST") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "PATH") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "1970-01-01 00:00") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "invalid") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "cron:0 21 * * *") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "/first.lua") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "/second.lua") != null);
}

test "executeLuaAsTool runs script with lua_execute policy" {
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

    var outcome = try executeLuaAsTool(std.testing.allocator, "ok.lua", &.{}, null, workspace_root);
    defer outcome.deinit(std.testing.allocator);

    try std.testing.expect(outcome.ok);
    try std.testing.expectEqualStrings("hello\n", outcome.stdout);
    try std.testing.expectEqualStrings("", outcome.stderr);
    try std.testing.expect(outcome.error_name == null);

    const note_path = try std.fs.path.join(std.testing.allocator, &.{ workspace_root, "note.txt" });
    defer std.testing.allocator.free(note_path);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(note_path, .{}));
}

test "executeLuaAsTool accepts workspace absolute script path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script = try tmp.dir.createFile("abs.lua", .{});
    defer script.close();
    try script.writeAll("print('ok')\n");

    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    var outcome = try executeLuaAsTool(std.testing.allocator, "/abs.lua", &.{}, null, workspace_root);
    defer outcome.deinit(std.testing.allocator);

    try std.testing.expect(outcome.ok);
    try std.testing.expectEqualStrings("ok\n", outcome.stdout);
    try std.testing.expectEqualStrings("", outcome.stderr);
    try std.testing.expect(outcome.error_name == null);
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
        executeLuaAsTool(std.testing.allocator, "../outside.lua", &.{}, null, workspace_root),
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
        executeLuaAsTool(std.testing.allocator, "not_lua.txt", &.{}, null, workspace_root),
    );
}

test "executeLuaAsTool forwards script args to Lua arg table" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script = try tmp.dir.createFile("argv.lua", .{});
    defer script.close();
    try script.writeAll(
        \\print(arg[1])
        \\print(arg[2])
        \\
    );

    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    const script_args = [_][]const u8{ "alpha", "beta" };
    var outcome = try executeLuaAsTool(std.testing.allocator, "argv.lua", &script_args, null, workspace_root);
    defer outcome.deinit(std.testing.allocator);

    try std.testing.expect(outcome.ok);
    try std.testing.expectEqualStrings("alpha\nbeta\n", outcome.stdout);
    try std.testing.expectEqualStrings("", outcome.stderr);
    try std.testing.expect(outcome.exit_code == null);
    try std.testing.expect(outcome.error_name == null);
}

test "executeLuaAsTool surfaces zoid exit code" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script = try tmp.dir.createFile("exit.lua", .{});
    defer script.close();
    try script.writeAll(
        \\print("before")
        \\zoid.exit(7)
        \\print("after")
        \\
    );

    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    var outcome = try executeLuaAsTool(std.testing.allocator, "exit.lua", &.{}, null, workspace_root);
    defer outcome.deinit(std.testing.allocator);

    try std.testing.expect(!outcome.ok);
    try std.testing.expectEqual(@as(?u8, 7), outcome.exit_code);
    try std.testing.expectEqualStrings("before\n", outcome.stdout);
    try std.testing.expectEqualStrings("", outcome.stderr);
    try std.testing.expectEqualStrings("LuaExit", outcome.error_name.?);
}

test "executeLuaAsTool supports timeout override" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script = try tmp.dir.createFile("loop.lua", .{});
    defer script.close();
    try script.writeAll(
        \\while true do
        \\end
        \\
    );

    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    var outcome = try executeLuaAsTool(std.testing.allocator, "loop.lua", &.{}, 1, workspace_root);
    defer outcome.deinit(std.testing.allocator);

    try std.testing.expect(!outcome.ok);
    try std.testing.expect(outcome.exit_code == null);
    try std.testing.expectEqualStrings("", outcome.stdout);
    try std.testing.expectEqualStrings("LuaTimeout", outcome.error_name.?);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stderr, "timed out") != null);
}

test "loadWorkspaceAgentInstructionAtPath reads trimmed ZOID.md content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    const file = try tmp.dir.createFile(workspace_agent_instruction_file_name, .{});
    defer file.close();
    try file.writeAll("  agent instructions  \n");

    const content = try loadWorkspaceAgentInstructionAtPath(std.testing.allocator, workspace_root);
    defer if (content) |value| std.testing.allocator.free(value);

    try std.testing.expect(content != null);
    try std.testing.expectEqualStrings("agent instructions", content.?);
}

test "loadWorkspaceAgentInstructionAtPath returns null when ZOID.md is missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    const content = try loadWorkspaceAgentInstructionAtPath(std.testing.allocator, workspace_root);
    try std.testing.expect(content == null);
}
