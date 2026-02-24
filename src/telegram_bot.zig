const std = @import("std");
const http_client = @import("http_client.zig");
const lua_runner = @import("lua_runner.zig");
const openai_client = @import("openai_client.zig");
const scheduler_runtime = @import("scheduler_runtime.zig");
const tool_runtime = @import("tool_runtime.zig");

pub const Settings = struct {
    bot_token: []const u8,
    openai_api_key: []const u8,
    openai_model: []const u8,
    workspace_instruction: ?[]const u8 = null,
};

const max_poll_timeout_seconds: u16 = 50;
const max_poll_response_bytes: usize = 2 * 1024 * 1024;
const max_send_response_bytes: usize = 512 * 1024;
const max_telegram_message_bytes: usize = 4000;
const poll_backoff_ns: u64 = 3 * std.time.ns_per_s;
const max_conversation_messages_per_chat: usize = 80;
const user_inactivity_reset_seconds: i64 = 8 * std.time.s_per_hour;
const max_conversation_state_file_bytes: usize = 8 * 1024 * 1024;
const conversation_state_file_name = "telegram_context.json";
const serve_lock_file_name = "telegram_serve.lock";
const typing_action_refresh_ns: u64 = 4 * std.time.ns_per_s;
const typing_action_sleep_step_ns: u64 = 200 * std.time.ns_per_ms;
const telegram_message_parse_mode = "MarkdownV2";

const InboundChatKind = enum {
    private,
    group_like,
};

const InboundMessage = struct {
    chat_id: i64,
    chat_kind: InboundChatKind,
    text: []u8,
};

const Conversation = struct {
    messages: std.ArrayList(openai_client.Message) = .empty,
    last_user_message_at: ?i64 = null,

    fn deinit(self: *Conversation, allocator: std.mem.Allocator) void {
        for (self.messages.items) |message| allocator.free(message.content);
        self.messages.deinit(allocator);
    }

    fn appendMessage(
        self: *Conversation,
        allocator: std.mem.Allocator,
        role: openai_client.Role,
        content: []const u8,
    ) !void {
        const copy = try allocator.dupe(u8, content);
        errdefer allocator.free(copy);
        try self.messages.append(allocator, .{
            .role = role,
            .content = copy,
        });
    }

    fn popLastMessage(self: *Conversation, allocator: std.mem.Allocator) void {
        if (self.messages.items.len == 0) return;
        const message = self.messages.pop().?;
        allocator.free(message.content);
    }
};

const ConversationStore = std.AutoHashMap(i64, Conversation);

const PollBatch = struct {
    messages: []InboundMessage,
    next_offset: i64,

    fn deinit(self: *PollBatch, allocator: std.mem.Allocator) void {
        for (self.messages) |message| allocator.free(message.text);
        if (self.messages.len > 0) allocator.free(self.messages);
        self.* = undefined;
    }
};

const TypingNotifier = struct {
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    bot_token: []const u8 = "",
    chat_id: i64 = 0,

    fn start(self: *TypingNotifier, bot_token: []const u8, chat_id: i64) !void {
        if (self.thread != null) return;
        self.bot_token = bot_token;
        self.chat_id = chat_id;
        self.stop_flag.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn stop(self: *TypingNotifier) void {
        if (self.thread) |thread| {
            self.stop_flag.store(true, .release);
            thread.join();
            self.thread = null;
        }
    }

    fn run(self: *TypingNotifier) void {
        while (!self.stop_flag.load(.acquire)) {
            sendTypingAction(std.heap.page_allocator, self.bot_token, self.chat_id) catch |err| {
                std.debug.print(
                    "Telegram sendChatAction failed for chat {d}: {s}\n",
                    .{ self.chat_id, @errorName(err) },
                );
            };

            var slept_ns: u64 = 0;
            while (slept_ns < typing_action_refresh_ns and !self.stop_flag.load(.acquire)) {
                const remaining = typing_action_refresh_ns - slept_ns;
                const step = @min(typing_action_sleep_step_ns, remaining);
                std.Thread.sleep(step);
                slept_ns += step;
            }
        }
    }
};

pub fn runLongPolling(allocator: std.mem.Allocator, settings: Settings) !void {
    if (settings.bot_token.len == 0) return error.EmptyTelegramBotToken;
    if (settings.openai_api_key.len == 0) return error.EmptyApiKey;
    if (settings.openai_model.len == 0) return error.EmptyModel;

    var runtime_paths = try RuntimePaths.init(allocator);
    defer runtime_paths.deinit(allocator);

    const serve_lock = try acquireServeLock(runtime_paths.lock_path);
    defer serve_lock.close();

    const workspace_root = try resolveWorkspaceRoot(allocator);
    defer allocator.free(workspace_root);

    std.debug.print("Starting Telegram long-polling loop.\n", .{});

    var conversations = ConversationStore.init(allocator);
    defer deinitConversationStore(allocator, &conversations);

    loadConversationStoreAtPath(allocator, runtime_paths.state_path, &conversations) catch |err| {
        std.debug.print(
            "Failed to load Telegram conversation state ({s}); continuing with empty state.\n",
            .{@errorName(err)},
        );
    };

    var next_offset: i64 = 0;
    while (true) {
        processDueScheduledJobs(
            allocator,
            settings.openai_api_key,
            settings.openai_model,
            settings.bot_token,
            workspace_root,
            runtime_paths.default_dm_chat_id_path,
            settings.workspace_instruction,
        ) catch |err| {
            std.debug.print("Failed to process scheduled jobs: {s}\n", .{@errorName(err)});
        };

        const now = std.time.timestamp();
        const poll_timeout_seconds = computePollTimeoutSeconds(
            scheduler_runtime.secondsUntilNextDue(
                allocator,
                .{ .workspace_root = workspace_root },
                now,
            ) catch null,
        );

        var batch = fetchPollBatch(
            allocator,
            settings.bot_token,
            next_offset,
            poll_timeout_seconds,
        ) catch |err| {
            std.debug.print("Telegram getUpdates failed: {s}\n", .{@errorName(err)});
            std.Thread.sleep(poll_backoff_ns);
            continue;
        };
        defer batch.deinit(allocator);

        next_offset = batch.next_offset;
        for (batch.messages) |message| {
            if (message.chat_kind == .private) {
                scheduler_runtime.persistDefaultDmChatIdAtPath(
                    allocator,
                    runtime_paths.default_dm_chat_id_path,
                    message.chat_id,
                ) catch |err| {
                    std.debug.print(
                        "Failed to persist Telegram default DM chat id ({d}): {s}\n",
                        .{ message.chat_id, @errorName(err) },
                    );
                };
            }

            processInboundMessage(
                allocator,
                &conversations,
                runtime_paths.state_path,
                settings.openai_api_key,
                settings.openai_model,
                settings.bot_token,
                message.chat_id,
                message.text,
                settings.workspace_instruction,
            ) catch |err| {
                std.debug.print(
                    "Failed to process Telegram message for chat {d}: {s}\n",
                    .{ message.chat_id, @errorName(err) },
                );
                sendMessageInChunks(
                    allocator,
                    settings.bot_token,
                    message.chat_id,
                    "Failed to process your request. Please try again.",
                ) catch |send_err| {
                    std.debug.print(
                        "Failed to send Telegram error response for chat {d}: {s}\n",
                        .{ message.chat_id, @errorName(send_err) },
                    );
                };
            };
        }
    }
}

fn processInboundMessage(
    allocator: std.mem.Allocator,
    conversations: *ConversationStore,
    state_path: []const u8,
    api_key: []const u8,
    model: []const u8,
    bot_token: []const u8,
    chat_id: i64,
    raw_text: []const u8,
    workspace_instruction: ?[]const u8,
) !void {
    const prompt = std.mem.trim(u8, raw_text, " \t\r\n");
    if (prompt.len == 0) {
        try sendMessageInChunks(allocator, bot_token, chat_id, "Please send a non-empty message.");
        return;
    }

    if (isResetCommand(prompt)) {
        const had_conversation = clearConversationForChat(allocator, conversations, chat_id);
        if (had_conversation) {
            persistConversationStoreAtPath(allocator, state_path, conversations) catch |err| {
                std.debug.print("Failed to persist Telegram conversation state: {s}\n", .{@errorName(err)});
            };
        }
        try sendMessageInChunks(
            allocator,
            bot_token,
            chat_id,
            "Started a new session. Previous context cleared.",
        );
        return;
    }

    try processPromptForChat(
        allocator,
        conversations,
        state_path,
        api_key,
        model,
        bot_token,
        chat_id,
        prompt,
        workspace_instruction,
    );
}

fn deinitConversationStore(
    allocator: std.mem.Allocator,
    conversations: *ConversationStore,
) void {
    var iterator = conversations.iterator();
    while (iterator.next()) |entry| {
        entry.value_ptr.deinit(allocator);
    }
    conversations.deinit();
}

fn getOrCreateConversation(
    conversations: *ConversationStore,
    chat_id: i64,
) !*Conversation {
    const entry = try conversations.getOrPut(chat_id);
    if (!entry.found_existing) entry.value_ptr.* = .{};
    return entry.value_ptr;
}

fn clearConversationForChat(
    allocator: std.mem.Allocator,
    conversations: *ConversationStore,
    chat_id: i64,
) bool {
    if (conversations.fetchRemove(chat_id)) |entry| {
        var conversation = entry.value;
        conversation.deinit(allocator);
        return true;
    }
    return false;
}

fn isResetCommand(prompt: []const u8) bool {
    return std.mem.eql(u8, prompt, "/new") or std.mem.eql(u8, prompt, "/reset");
}

fn processPromptForChat(
    allocator: std.mem.Allocator,
    conversations: *ConversationStore,
    state_path: []const u8,
    api_key: []const u8,
    model: []const u8,
    bot_token: []const u8,
    chat_id: i64,
    prompt: []const u8,
    workspace_instruction: ?[]const u8,
) !void {
    const now = std.time.timestamp();
    if (conversations.getPtr(chat_id)) |existing| {
        if (shouldResetConversationForInactivity(existing, now)) {
            _ = clearConversationForChat(allocator, conversations, chat_id);
            persistConversationStoreAtPath(allocator, state_path, conversations) catch |err| {
                std.debug.print(
                    "Failed to persist Telegram conversation state after inactivity reset: {s}\n",
                    .{@errorName(err)},
                );
            };
        }
    }

    const conversation = try getOrCreateConversation(conversations, chat_id);
    conversation.last_user_message_at = now;
    try conversation.appendMessage(allocator, .user, prompt);

    var conversation_turn_committed = false;
    errdefer {
        if (!conversation_turn_committed) {
            conversation.popLastMessage(allocator);
        }
    }

    var typing_notifier: TypingNotifier = .{};
    typing_notifier.start(bot_token, chat_id) catch |err| {
        std.debug.print(
            "Failed to start Telegram typing notifier for chat {d}: {s}\n",
            .{ chat_id, @errorName(err) },
        );
    };
    defer typing_notifier.stop();

    const reply = try openai_client.fetchAssistantReplyWithContext(
        allocator,
        api_key,
        model,
        conversation.messages.items,
        .{
            .request_chat_id = chat_id,
            .workspace_instruction = workspace_instruction,
        },
    );
    defer allocator.free(reply);

    const trimmed_reply = std.mem.trim(u8, reply, " \t\r\n");
    if (trimmed_reply.len == 0) {
        conversation.popLastMessage(allocator);
        conversation_turn_committed = true;
        try sendMessageInChunks(
            allocator,
            bot_token,
            chat_id,
            "Assistant returned an empty response.",
        );
        return;
    }

    try sendMessageInChunks(allocator, bot_token, chat_id, trimmed_reply);
    try conversation.appendMessage(allocator, .assistant, trimmed_reply);
    enforceConversationLimit(conversation, allocator);
    conversation_turn_committed = true;

    persistConversationStoreAtPath(allocator, state_path, conversations) catch |err| {
        std.debug.print("Failed to persist Telegram conversation state: {s}\n", .{@errorName(err)});
    };
}

fn shouldResetConversationForInactivity(conversation: *const Conversation, now: i64) bool {
    const last_user_message_at = conversation.last_user_message_at orelse return false;
    if (now <= last_user_message_at) return false;
    return now - last_user_message_at >= user_inactivity_reset_seconds;
}

fn processDueScheduledJobs(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model: []const u8,
    bot_token: []const u8,
    workspace_root: []const u8,
    default_dm_chat_id_path: []const u8,
    workspace_instruction: ?[]const u8,
) !void {
    const now = std.time.timestamp();
    const due_jobs = try scheduler_runtime.takeDueJobs(
        allocator,
        .{ .workspace_root = workspace_root },
        now,
    );
    defer scheduler_runtime.deinitDueJobs(allocator, due_jobs);

    for (due_jobs) |*due_job| {
        const maybe_scheduled_prompt = buildScheduledPrompt(
            allocator,
            workspace_root,
            due_job,
            now,
        ) catch |err| {
            std.debug.print(
                "Failed to build scheduled prompt for job {s}: {s}\n",
                .{ due_job.job.id, @errorName(err) },
            );
            continue;
        };
        const scheduled_prompt = maybe_scheduled_prompt orelse continue;
        defer allocator.free(scheduled_prompt);

        const messages = [_]openai_client.Message{
            .{ .role = .user, .content = scheduled_prompt },
        };
        const reply = openai_client.fetchAssistantReplyWithContext(
            allocator,
            api_key,
            model,
            &messages,
            .{ .workspace_instruction = workspace_instruction },
        ) catch |err| {
            std.debug.print(
                "Failed to process scheduled job {s}: {s}\n",
                .{ due_job.job.id, @errorName(err) },
            );
            continue;
        };
        defer allocator.free(reply);

        const trimmed_reply = std.mem.trim(u8, reply, " \t\r\n");
        if (trimmed_reply.len == 0) continue;

        const dm_chat_id = scheduler_runtime.loadDefaultDmChatIdAtPath(
            allocator,
            default_dm_chat_id_path,
        ) catch |err| blk: {
            std.debug.print(
                "Scheduled job {s} could not resolve DM chat id: {s}\n",
                .{ due_job.job.id, @errorName(err) },
            );
            break :blk null;
        };
        if (dm_chat_id) |chat_id| {
            sendMessageInChunks(allocator, bot_token, chat_id, trimmed_reply) catch |err| {
                std.debug.print(
                    "Failed to send scheduled reply to Telegram DM {d}: {s}\n",
                    .{ chat_id, @errorName(err) },
                );
            };
            continue;
        }

        std.debug.print(
            "Scheduled job {s} produced a reply but no Telegram DM destination was available.\n",
            .{due_job.job.id},
        );
    }
}

fn enforceConversationLimit(conversation: *Conversation, allocator: std.mem.Allocator) void {
    while (conversation.messages.items.len > max_conversation_messages_per_chat) {
        const removed = conversation.messages.orderedRemove(0);
        allocator.free(removed.content);
    }
}

const RuntimePaths = struct {
    app_data_dir: []u8,
    state_path: []u8,
    lock_path: []u8,
    default_dm_chat_id_path: []u8,

    fn init(allocator: std.mem.Allocator) !RuntimePaths {
        const app_data_dir = try std.fs.getAppDataDir(allocator, "zoid");
        errdefer allocator.free(app_data_dir);

        try std.fs.cwd().makePath(app_data_dir);

        const state_path = try std.fs.path.join(allocator, &.{ app_data_dir, conversation_state_file_name });
        errdefer allocator.free(state_path);

        const lock_path = try std.fs.path.join(allocator, &.{ app_data_dir, serve_lock_file_name });
        errdefer allocator.free(lock_path);
        const default_dm_chat_id_path = try std.fs.path.join(
            allocator,
            &.{ app_data_dir, scheduler_runtime.telegram_dm_chat_id_state_file_name },
        );
        errdefer allocator.free(default_dm_chat_id_path);

        return .{
            .app_data_dir = app_data_dir,
            .state_path = state_path,
            .lock_path = lock_path,
            .default_dm_chat_id_path = default_dm_chat_id_path,
        };
    }

    fn deinit(self: *RuntimePaths, allocator: std.mem.Allocator) void {
        allocator.free(self.app_data_dir);
        allocator.free(self.state_path);
        allocator.free(self.lock_path);
        allocator.free(self.default_dm_chat_id_path);
    }
};

fn acquireServeLock(lock_path: []const u8) !std.fs.File {
    return std.fs.cwd().createFile(lock_path, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.WouldBlock => return error.ServiceAlreadyRunning,
        else => return err,
    };
}

fn persistConversationStoreAtPath(
    allocator: std.mem.Allocator,
    state_path: []const u8,
    conversations: *const ConversationStore,
) !void {
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{state_path});
    defer allocator.free(tmp_path);

    const tmp_file = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true });
    defer tmp_file.close();

    try writeConversationStoreJson(allocator, tmp_file, conversations);
    try std.fs.cwd().rename(tmp_path, state_path);
}

const StoredChat = struct {
    chat_id: i64,
    last_user_message_at: ?i64,
    messages: []const openai_client.Message,
};

fn writeConversationStoreJson(
    allocator: std.mem.Allocator,
    file: std.fs.File,
    conversations: *const ConversationStore,
) !void {
    var chats = std.ArrayList(StoredChat).empty;
    defer chats.deinit(allocator);

    var iterator = conversations.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.messages.items.len == 0) continue;
        try chats.append(allocator, .{
            .chat_id = entry.key_ptr.*,
            .last_user_message_at = entry.value_ptr.last_user_message_at,
            .messages = entry.value_ptr.messages.items,
        });
    }

    std.mem.sort(StoredChat, chats.items, {}, sortStoredChatsAsc);

    try file.writeAll("{\"version\":1,\"chats\":[");
    for (chats.items, 0..) |chat, chat_index| {
        if (chat_index > 0) try file.writeAll(",");

        try file.writeAll("{\"chat_id\":");
        const chat_id_text = try std.fmt.allocPrint(allocator, "{d}", .{chat.chat_id});
        defer allocator.free(chat_id_text);
        try file.writeAll(chat_id_text);
        try file.writeAll(",\"last_user_message_at\":");
        if (chat.last_user_message_at) |last_user_message_at| {
            const last_user_message_text = try std.fmt.allocPrint(allocator, "{d}", .{last_user_message_at});
            defer allocator.free(last_user_message_text);
            try file.writeAll(last_user_message_text);
        } else {
            try file.writeAll("null");
        }
        try file.writeAll(",\"messages\":[");

        for (chat.messages, 0..) |message, message_index| {
            if (message_index > 0) try file.writeAll(",");

            const role_json = try std.json.Stringify.valueAlloc(allocator, roleToString(message.role), .{});
            defer allocator.free(role_json);
            const content_json = try std.json.Stringify.valueAlloc(allocator, message.content, .{});
            defer allocator.free(content_json);

            try file.writeAll("{\"role\":");
            try file.writeAll(role_json);
            try file.writeAll(",\"content\":");
            try file.writeAll(content_json);
            try file.writeAll("}");
        }

        try file.writeAll("]}");
    }
    try file.writeAll("]}\n");
}

fn sortStoredChatsAsc(_: void, lhs: StoredChat, rhs: StoredChat) bool {
    return lhs.chat_id < rhs.chat_id;
}

fn loadConversationStoreAtPath(
    allocator: std.mem.Allocator,
    state_path: []const u8,
    conversations: *ConversationStore,
) !void {
    const state_file = std.fs.cwd().openFile(state_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer state_file.close();

    const contents = try state_file.readToEndAlloc(allocator, max_conversation_state_file_bytes);
    defer allocator.free(contents);
    if (contents.len == 0) return;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, contents, .{});
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidConversationStoreFormat,
    };

    const chats = switch (root.get("chats") orelse return error.InvalidConversationStoreFormat) {
        .array => |array| array,
        else => return error.InvalidConversationStoreFormat,
    };

    for (chats.items) |chat_value| {
        const chat_object = switch (chat_value) {
            .object => |object| object,
            else => continue,
        };

        const chat_id = parseJsonI64(chat_object.get("chat_id") orelse continue) orelse continue;
        const last_user_message_at = if (chat_object.get("last_user_message_at")) |value|
            parseJsonI64(value)
        else
            null;
        const messages_value = switch (chat_object.get("messages") orelse continue) {
            .array => |array| array,
            else => continue,
        };

        var loaded = Conversation{};
        errdefer loaded.deinit(allocator);

        for (messages_value.items) |message_value| {
            const message_object = switch (message_value) {
                .object => |object| object,
                else => continue,
            };

            const role_name = switch (message_object.get("role") orelse continue) {
                .string => |value| value,
                else => continue,
            };
            const role = parseRole(role_name) orelse continue;

            const content = switch (message_object.get("content") orelse continue) {
                .string => |value| value,
                else => continue,
            };

            try loaded.appendMessage(allocator, role, content);
        }

        if (loaded.messages.items.len == 0) {
            loaded.deinit(allocator);
            continue;
        }

        loaded.last_user_message_at = last_user_message_at;
        enforceConversationLimit(&loaded, allocator);

        const entry = try conversations.getOrPut(chat_id);
        if (entry.found_existing) {
            entry.value_ptr.deinit(allocator);
        }
        entry.value_ptr.* = loaded;
    }
}

fn roleToString(role: openai_client.Role) []const u8 {
    return switch (role) {
        .user => "user",
        .assistant => "assistant",
    };
}

fn parseRole(name: []const u8) ?openai_client.Role {
    if (std.mem.eql(u8, name, "user")) return .user;
    if (std.mem.eql(u8, name, "assistant")) return .assistant;
    return null;
}

fn buildScheduledPrompt(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    due_job: *const scheduler_runtime.DueJob,
    triggered_at: i64,
) !?[]u8 {
    var payload = std.ArrayList(u8).empty;
    errdefer payload.deinit(allocator);

    try payload.appendSlice(allocator, "A scheduled job has been triggered. Review the structured payload and craft a concise Telegram DM response.\n");
    try payload.appendSlice(allocator, "{\"event\":\"scheduled_job\",\"job\":{");
    try payload.appendSlice(allocator, "\"id\":");
    try appendJsonString(allocator, &payload, due_job.job.id);
    try payload.appendSlice(allocator, ",\"path\":");
    try appendJsonString(allocator, &payload, due_job.job.path);
    try payload.appendSlice(allocator, ",\"scheduled_for\":");
    try payload.writer(allocator).print("{d}", .{due_job.scheduled_for});
    try payload.appendSlice(allocator, ",\"triggered_at\":");
    try payload.writer(allocator).print("{d}", .{triggered_at});
    try payload.appendSlice(allocator, "},\"result\":{");

    var execution = try lua_runner.executeLuaFileCaptureOutputTool(
        allocator,
        due_job.job.path,
        .{
            .workspace_root = workspace_root,
            .max_read_bytes = tool_runtime.max_allowed_read_bytes,
            .max_http_response_bytes = tool_runtime.max_allowed_http_response_bytes,
        },
    );
    defer execution.deinit(allocator);

    if (std.mem.trim(u8, execution.stdout, " \t\r\n").len == 0 and
        std.mem.trim(u8, execution.stderr, " \t\r\n").len == 0)
    {
        payload.deinit(allocator);
        return null;
    }

    try payload.appendSlice(allocator, "\"kind\":\"lua\",\"status\":");
    try appendJsonString(allocator, &payload, executionStatusToString(execution.status));
    try payload.appendSlice(allocator, ",\"exit_code\":");
    if (execution.exit_code) |exit_code| {
        try payload.writer(allocator).print("{d}", .{exit_code});
    } else {
        try payload.appendSlice(allocator, "null");
    }
    try payload.appendSlice(allocator, ",\"stdout\":");
    try appendJsonString(allocator, &payload, execution.stdout);
    try payload.appendSlice(allocator, ",\"stderr\":");
    try appendJsonString(allocator, &payload, execution.stderr);
    try payload.appendSlice(allocator, ",\"stdout_truncated\":");
    try payload.appendSlice(allocator, if (execution.stdout_truncated) "true" else "false");
    try payload.appendSlice(allocator, ",\"stderr_truncated\":");
    try payload.appendSlice(allocator, if (execution.stderr_truncated) "true" else "false");

    try payload.appendSlice(allocator, "}}\n");
    return try payload.toOwnedSlice(allocator);
}

fn appendJsonString(allocator: std.mem.Allocator, payload: *std.ArrayList(u8), value: []const u8) !void {
    const escaped = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(escaped);
    try payload.appendSlice(allocator, escaped);
}

fn executionStatusToString(status: lua_runner.CapturedExecutionStatus) []const u8 {
    return switch (status) {
        .ok => "ok",
        .exited => "exited",
        .timed_out => "timed_out",
        .state_init_failed => "state_init_failed",
        .load_failed => "load_failed",
        .runtime_failed => "runtime_failed",
    };
}

fn resolveWorkspaceRoot(allocator: std.mem.Allocator) ![]u8 {
    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);
    return std.fs.cwd().realpathAlloc(allocator, cwd);
}

fn computePollTimeoutSeconds(seconds_until_next_due: ?u64) u16 {
    const fallback: u64 = max_poll_timeout_seconds;
    const value = seconds_until_next_due orelse fallback;
    if (value == 0) return 1;
    const bounded = @min(fallback, value);
    return std.math.cast(u16, bounded) orelse max_poll_timeout_seconds;
}

fn fetchPollBatch(
    allocator: std.mem.Allocator,
    bot_token: []const u8,
    current_offset: i64,
    timeout_seconds: u16,
) !PollBatch {
    const uri = try std.fmt.allocPrint(
        allocator,
        "https://api.telegram.org/bot{s}/getUpdates",
        .{bot_token},
    );
    defer allocator.free(uri);

    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"offset\":{d},\"timeout\":{d},\"allowed_updates\":[\"message\",\"channel_post\"]}}",
        .{ current_offset, timeout_seconds },
    );
    defer allocator.free(payload);

    const headers = [_]http_client.RequestHeader{
        .{ .name = "Content-Type", .value = "application/json" },
    };

    var response = try http_client.executeRequest(
        allocator,
        .POST,
        uri,
        payload,
        &headers,
        max_poll_response_bytes,
        false,
    );
    defer response.deinit(allocator);

    if (response.status_code != 200) {
        if (try parseTelegramErrorDescription(allocator, response.body)) |description| {
            defer allocator.free(description);
            std.debug.print(
                "Telegram getUpdates returned status {d}: {s}\n",
                .{ response.status_code, description },
            );
        } else {
            std.debug.print(
                "Telegram getUpdates returned status {d}.\n",
                .{response.status_code},
            );
        }
        return error.TelegramApiRequestFailed;
    }

    return parsePollBatch(allocator, response.body, current_offset);
}

fn parsePollBatch(
    allocator: std.mem.Allocator,
    response_body: []const u8,
    fallback_offset: i64,
) !PollBatch {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_body, .{});
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidApiResponse,
    };

    const ok = switch (root.get("ok") orelse return error.InvalidApiResponse) {
        .bool => |value| value,
        else => return error.InvalidApiResponse,
    };
    if (!ok) return error.TelegramApiRequestFailed;

    const result = switch (root.get("result") orelse return error.InvalidApiResponse) {
        .array => |array| array,
        else => return error.InvalidApiResponse,
    };

    var messages = std.ArrayList(InboundMessage).empty;
    errdefer {
        for (messages.items) |message| allocator.free(message.text);
        messages.deinit(allocator);
    }

    var next_offset = fallback_offset;
    for (result.items) |entry| {
        const update = switch (entry) {
            .object => |object| object,
            else => continue,
        };

        const update_id = parseJsonI64(update.get("update_id") orelse continue) orelse continue;
        if (update_id >= next_offset) next_offset = update_id + 1;

        const message_value = update.get("message") orelse update.get("channel_post") orelse continue;
        const message = switch (message_value) {
            .object => |object| object,
            else => continue,
        };
        const text = switch (message.get("text") orelse continue) {
            .string => |value| value,
            else => continue,
        };
        const chat = switch (message.get("chat") orelse continue) {
            .object => |object| object,
            else => continue,
        };
        const chat_id = parseJsonI64(chat.get("id") orelse continue) orelse continue;
        const chat_kind = parseInboundChatKind(chat.get("type") orelse .null);

        try messages.append(allocator, .{
            .chat_id = chat_id,
            .chat_kind = chat_kind,
            .text = try allocator.dupe(u8, text),
        });
    }

    return .{
        .messages = try messages.toOwnedSlice(allocator),
        .next_offset = next_offset,
    };
}

fn sendMessageInChunks(
    allocator: std.mem.Allocator,
    bot_token: []const u8,
    chat_id: i64,
    text: []const u8,
) !void {
    if (text.len == 0) {
        try sendMessage(allocator, bot_token, chat_id, " ");
        return;
    }

    var start: usize = 0;
    while (start < text.len) {
        const end = nextChunkBoundary(text, start, max_telegram_message_bytes);
        if (end <= start) return error.InvalidUtf8;
        try sendMessage(allocator, bot_token, chat_id, text[start..end]);
        start = end;
    }
}

fn nextChunkBoundary(text: []const u8, start: usize, max_bytes: usize) usize {
    if (start >= text.len) return text.len;
    if (text.len - start <= max_bytes) return text.len;

    var index = start;
    while (index < text.len) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(text[index]) catch {
            return @min(start + max_bytes, text.len);
        };
        if (sequence_len == 0 or index + sequence_len > text.len) {
            return @min(start + max_bytes, text.len);
        }
        if (index + sequence_len - start > max_bytes) break;
        index += sequence_len;
    }

    if (index == start) return @min(start + max_bytes, text.len);
    return index;
}

fn sendMessage(
    allocator: std.mem.Allocator,
    bot_token: []const u8,
    chat_id: i64,
    text: []const u8,
) !void {
    const uri = try std.fmt.allocPrint(
        allocator,
        "https://api.telegram.org/bot{s}/sendMessage",
        .{bot_token},
    );
    defer allocator.free(uri);

    const payload = try buildSendMessagePayload(allocator, chat_id, text);
    defer allocator.free(payload);

    const headers = [_]http_client.RequestHeader{
        .{ .name = "Content-Type", .value = "application/json" },
    };

    var response = try http_client.executeRequest(
        allocator,
        .POST,
        uri,
        payload,
        &headers,
        max_send_response_bytes,
        false,
    );
    defer response.deinit(allocator);

    if (response.status_code != 200) {
        if (try parseTelegramErrorDescription(allocator, response.body)) |description| {
            defer allocator.free(description);
            std.debug.print(
                "Telegram sendMessage returned status {d}: {s}\n",
                .{ response.status_code, description },
            );
        } else {
            std.debug.print(
                "Telegram sendMessage returned status {d}.\n",
                .{response.status_code},
            );
        }
        return error.TelegramApiRequestFailed;
    }

    const ok = parseTelegramOk(allocator, response.body) catch |err| {
        std.debug.print("Telegram sendMessage invalid response: {s}\n", .{@errorName(err)});
        return err;
    };
    if (!ok) {
        if (try parseTelegramErrorDescription(allocator, response.body)) |description| {
            defer allocator.free(description);
            std.debug.print("Telegram sendMessage failed: {s}\n", .{description});
        } else {
            std.debug.print("Telegram sendMessage failed.\n", .{});
        }
        return error.TelegramApiRequestFailed;
    }
}

fn sendTypingAction(
    allocator: std.mem.Allocator,
    bot_token: []const u8,
    chat_id: i64,
) !void {
    const uri = try std.fmt.allocPrint(
        allocator,
        "https://api.telegram.org/bot{s}/sendChatAction",
        .{bot_token},
    );
    defer allocator.free(uri);

    const payload = try buildChatActionPayload(allocator, chat_id, "typing");
    defer allocator.free(payload);

    const headers = [_]http_client.RequestHeader{
        .{ .name = "Content-Type", .value = "application/json" },
    };

    var response = try http_client.executeRequest(
        allocator,
        .POST,
        uri,
        payload,
        &headers,
        max_send_response_bytes,
        false,
    );
    defer response.deinit(allocator);

    if (response.status_code != 200) {
        if (try parseTelegramErrorDescription(allocator, response.body)) |description| {
            defer allocator.free(description);
            std.debug.print(
                "Telegram sendChatAction returned status {d}: {s}\n",
                .{ response.status_code, description },
            );
        } else {
            std.debug.print(
                "Telegram sendChatAction returned status {d}.\n",
                .{response.status_code},
            );
        }
        return error.TelegramApiRequestFailed;
    }

    const ok = parseTelegramOk(allocator, response.body) catch |err| {
        std.debug.print("Telegram sendChatAction invalid response: {s}\n", .{@errorName(err)});
        return err;
    };
    if (!ok) {
        if (try parseTelegramErrorDescription(allocator, response.body)) |description| {
            defer allocator.free(description);
            std.debug.print("Telegram sendChatAction failed: {s}\n", .{description});
        } else {
            std.debug.print("Telegram sendChatAction failed.\n", .{});
        }
        return error.TelegramApiRequestFailed;
    }
}

fn buildSendMessagePayload(
    allocator: std.mem.Allocator,
    chat_id: i64,
    text: []const u8,
) ![]u8 {
    const escaped_text = try std.json.Stringify.valueAlloc(allocator, text, .{});
    defer allocator.free(escaped_text);

    return try std.fmt.allocPrint(
        allocator,
        "{{\"chat_id\":{d},\"text\":{s},\"parse_mode\":\"{s}\"}}",
        .{ chat_id, escaped_text, telegram_message_parse_mode },
    );
}

fn buildChatActionPayload(
    allocator: std.mem.Allocator,
    chat_id: i64,
    action: []const u8,
) ![]u8 {
    const escaped_action = try std.json.Stringify.valueAlloc(allocator, action, .{});
    defer allocator.free(escaped_action);

    return try std.fmt.allocPrint(
        allocator,
        "{{\"chat_id\":{d},\"action\":{s}}}",
        .{ chat_id, escaped_action },
    );
}

fn parseTelegramOk(allocator: std.mem.Allocator, response_body: []const u8) !bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_body, .{});
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidApiResponse,
    };

    return switch (root.get("ok") orelse return error.InvalidApiResponse) {
        .bool => |value| value,
        else => return error.InvalidApiResponse,
    };
}

fn parseTelegramErrorDescription(
    allocator: std.mem.Allocator,
    response_body: []const u8,
) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response_body, .{}) catch {
        return null;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return null,
    };

    const description = switch (root.get("description") orelse return null) {
        .string => |value| value,
        else => return null,
    };

    return try allocator.dupe(u8, description);
}

fn parseJsonI64(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |int| int,
        else => null,
    };
}

fn parseInboundChatKind(value: std.json.Value) InboundChatKind {
    const name = switch (value) {
        .string => |text| text,
        else => return .group_like,
    };
    if (std.mem.eql(u8, name, "private")) return .private;
    return .group_like;
}

test "parsePollBatch extracts text messages and advances offset" {
    const response =
        \\{"ok":true,"result":[
        \\{"update_id":10,"message":{"chat":{"id":111,"type":"private"},"text":"hello"}},
        \\{"update_id":11,"message":{"chat":{"id":111,"type":"private"}}},
        \\{"update_id":12,"channel_post":{"chat":{"id":-222,"type":"channel"},"text":"hej"}}
        \\]}
    ;

    var batch = try parsePollBatch(std.testing.allocator, response, 0);
    defer batch.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i64, 13), batch.next_offset);
    try std.testing.expectEqual(@as(usize, 2), batch.messages.len);
    try std.testing.expectEqual(@as(i64, 111), batch.messages[0].chat_id);
    try std.testing.expectEqual(InboundChatKind.private, batch.messages[0].chat_kind);
    try std.testing.expectEqualStrings("hello", batch.messages[0].text);
    try std.testing.expectEqual(@as(i64, -222), batch.messages[1].chat_id);
    try std.testing.expectEqual(InboundChatKind.group_like, batch.messages[1].chat_kind);
    try std.testing.expectEqualStrings("hej", batch.messages[1].text);
}

test "nextChunkBoundary keeps utf-8 boundaries" {
    const text = "abcådef";

    const first = nextChunkBoundary(text, 0, 4);
    try std.testing.expectEqual(@as(usize, 3), first);

    const second = nextChunkBoundary(text, first, 4);
    try std.testing.expectEqual(@as(usize, 7), second);

    const third = nextChunkBoundary(text, second, 4);
    try std.testing.expectEqual(text.len, third);
}

test "conversation store keeps separate history per chat id" {
    var conversations = ConversationStore.init(std.testing.allocator);
    defer deinitConversationStore(std.testing.allocator, &conversations);

    const chat_1 = try getOrCreateConversation(&conversations, 111);
    try chat_1.appendMessage(std.testing.allocator, .user, "hello");

    const chat_1_again = try getOrCreateConversation(&conversations, 111);
    try std.testing.expectEqual(@as(usize, 1), chat_1_again.messages.items.len);
    try std.testing.expectEqual(openai_client.Role.user, chat_1_again.messages.items[0].role);
    try std.testing.expectEqualStrings("hello", chat_1_again.messages.items[0].content);

    const chat_2 = try getOrCreateConversation(&conversations, 222);
    try std.testing.expectEqual(@as(usize, 0), chat_2.messages.items.len);
}

test "clearConversationForChat clears only target conversation" {
    var conversations = ConversationStore.init(std.testing.allocator);
    defer deinitConversationStore(std.testing.allocator, &conversations);

    const chat_1 = try getOrCreateConversation(&conversations, 1);
    try chat_1.appendMessage(std.testing.allocator, .user, "one");
    const chat_2 = try getOrCreateConversation(&conversations, 2);
    try chat_2.appendMessage(std.testing.allocator, .user, "two");

    try std.testing.expect(clearConversationForChat(std.testing.allocator, &conversations, 1));
    try std.testing.expect(!clearConversationForChat(std.testing.allocator, &conversations, 1));

    try std.testing.expect(conversations.get(1) == null);
    const remaining = conversations.get(2) orelse unreachable;
    try std.testing.expectEqual(@as(usize, 1), remaining.messages.items.len);
    try std.testing.expectEqualStrings("two", remaining.messages.items[0].content);
}

test "isResetCommand matches supported telegram commands" {
    try std.testing.expect(isResetCommand("/new"));
    try std.testing.expect(isResetCommand("/reset"));
    try std.testing.expect(!isResetCommand("/help"));
    try std.testing.expect(!isResetCommand("new"));
}

test "buildChatActionPayload encodes chat action request" {
    const payload = try buildChatActionPayload(std.testing.allocator, 42, "typing");
    defer std.testing.allocator.free(payload);

    try std.testing.expectEqualStrings(
        "{\"chat_id\":42,\"action\":\"typing\"}",
        payload,
    );
}

test "buildSendMessagePayload includes markdown parse mode" {
    const payload = try buildSendMessagePayload(std.testing.allocator, 42, "*bold*");
    defer std.testing.allocator.free(payload);

    try std.testing.expectEqualStrings(
        "{\"chat_id\":42,\"text\":\"*bold*\",\"parse_mode\":\"MarkdownV2\"}",
        payload,
    );
}

test "conversation state round-trips through disk persistence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    const state_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_path, conversation_state_file_name });
    defer std.testing.allocator.free(state_path);

    var original = ConversationStore.init(std.testing.allocator);
    defer deinitConversationStore(std.testing.allocator, &original);

    const chat_a = try getOrCreateConversation(&original, 101);
    chat_a.last_user_message_at = 1_700_000_000;
    try chat_a.appendMessage(std.testing.allocator, .user, "hello");
    try chat_a.appendMessage(std.testing.allocator, .assistant, "world");

    const chat_b = try getOrCreateConversation(&original, 202);
    chat_b.last_user_message_at = 1_700_000_123;
    try chat_b.appendMessage(std.testing.allocator, .user, "hej");

    try persistConversationStoreAtPath(std.testing.allocator, state_path, &original);

    var restored = ConversationStore.init(std.testing.allocator);
    defer deinitConversationStore(std.testing.allocator, &restored);
    try loadConversationStoreAtPath(std.testing.allocator, state_path, &restored);

    try std.testing.expect(restored.get(101) != null);
    const restored_a = restored.get(101).?;
    try std.testing.expectEqual(@as(usize, 2), restored_a.messages.items.len);
    try std.testing.expectEqual(openai_client.Role.user, restored_a.messages.items[0].role);
    try std.testing.expectEqualStrings("hello", restored_a.messages.items[0].content);
    try std.testing.expectEqual(openai_client.Role.assistant, restored_a.messages.items[1].role);
    try std.testing.expectEqualStrings("world", restored_a.messages.items[1].content);
    try std.testing.expectEqual(@as(?i64, 1_700_000_000), restored_a.last_user_message_at);

    try std.testing.expect(restored.get(202) != null);
    const restored_b = restored.get(202).?;
    try std.testing.expectEqual(@as(usize, 1), restored_b.messages.items.len);
    try std.testing.expectEqual(openai_client.Role.user, restored_b.messages.items[0].role);
    try std.testing.expectEqualStrings("hej", restored_b.messages.items[0].content);
    try std.testing.expectEqual(@as(?i64, 1_700_000_123), restored_b.last_user_message_at);
}

test "buildScheduledPrompt skips empty lua output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    {
        const file = try tmp.dir.createFile("silent.lua", .{});
        defer file.close();
        try file.writeAll("-- no output\n");
    }

    const silent_lua_path = try tmp.dir.realpathAlloc(std.testing.allocator, "silent.lua");
    defer std.testing.allocator.free(silent_lua_path);

    var lua_due_job = scheduler_runtime.DueJob{
        .job = .{
            .id = try std.testing.allocator.dupe(u8, "job-lua"),
            .path = try std.testing.allocator.dupe(u8, silent_lua_path),
            .chat_id = 1,
            .paused = false,
            .run_at = 100,
            .cron = null,
            .next_run_at = 100,
            .created_at = 90,
            .updated_at = 90,
            .last_run_at = null,
        },
        .scheduled_for = 100,
    };
    defer lua_due_job.deinit(std.testing.allocator);

    const lua_prompt = try buildScheduledPrompt(
        std.testing.allocator,
        workspace_root,
        &lua_due_job,
        101,
    );
    try std.testing.expect(lua_prompt == null);
}

test "enforceConversationLimit removes oldest messages" {
    var conversation = Conversation{};
    defer conversation.deinit(std.testing.allocator);

    const overflow = max_conversation_messages_per_chat + 3;
    for (0..overflow) |index| {
        const text = try std.fmt.allocPrint(std.testing.allocator, "m{d}", .{index});
        defer std.testing.allocator.free(text);
        try conversation.appendMessage(std.testing.allocator, .user, text);
    }

    enforceConversationLimit(&conversation, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, max_conversation_messages_per_chat), conversation.messages.items.len);
    try std.testing.expectEqualStrings("m3", conversation.messages.items[0].content);
    try std.testing.expectEqualStrings(
        "m82",
        conversation.messages.items[conversation.messages.items.len - 1].content,
    );
}

test "shouldResetConversationForInactivity honors 8-hour threshold" {
    var conversation = Conversation{};
    defer conversation.deinit(std.testing.allocator);

    try std.testing.expect(!shouldResetConversationForInactivity(&conversation, 1_000));

    conversation.last_user_message_at = 1_000;
    try std.testing.expect(!shouldResetConversationForInactivity(&conversation, 1_000 + user_inactivity_reset_seconds - 1));
    try std.testing.expect(shouldResetConversationForInactivity(&conversation, 1_000 + user_inactivity_reset_seconds));
}
