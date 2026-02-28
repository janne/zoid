const std = @import("std");
const http_client = @import("http_client.zig");
const lua_runner = @import("lua_runner.zig");
const openai_client = @import("openai_client.zig");
const runtime_limits = @import("runtime_limits.zig");
const scheduler_runtime = @import("scheduler_runtime.zig");
const tool_runtime = @import("tool_runtime.zig");
const workspace_fs = @import("workspace_fs.zig");

pub const Settings = struct {
    bot_token: []const u8,
    openai_api_key: []const u8,
    openai_model: []const u8,
    workspace_instruction: ?[]const u8 = null,
    limits: runtime_limits.Limits = .{},
};

const max_poll_timeout_seconds: u16 = 50;
const max_poll_response_bytes: usize = 2 * 1024 * 1024;
const max_send_response_bytes: usize = 512 * 1024;
const max_telegram_message_bytes: usize = 4000;
const max_telegram_upload_file_bytes: usize = 20 * 1024 * 1024;
const poll_backoff_ns: u64 = 3 * std.time.ns_per_s;
const max_conversation_state_file_bytes: usize = 8 * 1024 * 1024;
const conversation_state_file_name = "telegram_context.json";
const serve_lock_file_name = "telegram_serve.lock";
const typing_action_refresh_ns: u64 = 4 * std.time.ns_per_s;
const typing_action_sleep_step_ns: u64 = 200 * std.time.ns_per_ms;
const telegram_message_parse_mode = "MarkdownV2";
const SanitizerError = std.mem.Allocator.Error;

const InboundChatKind = enum {
    private,
    group_like,
};

const InboundMessage = struct {
    chat_id: i64,
    thread_id: ?i64,
    chat_kind: InboundChatKind,
    text: []u8,
};

const ConversationKey = struct {
    chat_id: i64,
    thread_id: ?i64 = null,
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

const ConversationStore = std.AutoHashMap(ConversationKey, Conversation);

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
    thread_id: ?i64 = null,

    fn start(self: *TypingNotifier, bot_token: []const u8, chat_id: i64, thread_id: ?i64) !void {
        if (self.thread != null) return;
        self.bot_token = bot_token;
        self.chat_id = chat_id;
        self.thread_id = thread_id;
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
            sendTypingAction(std.heap.page_allocator, self.bot_token, self.chat_id, self.thread_id) catch |err| {
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

const ConversationState = struct {
    mutex: std.Thread.Mutex = .{},
    conversations: ConversationStore,
    state_path: []const u8,
    limits: runtime_limits.Limits,

    fn init(
        allocator: std.mem.Allocator,
        state_path: []const u8,
        limits: runtime_limits.Limits,
    ) ConversationState {
        return .{
            .conversations = ConversationStore.init(allocator),
            .state_path = state_path,
            .limits = limits,
        };
    }

    fn deinit(self: *ConversationState, allocator: std.mem.Allocator) void {
        deinitConversationStore(allocator, &self.conversations);
    }
};

const InboundMessageQueue = struct {
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    pending_by_key: std.AutoHashMap(ConversationKey, std.ArrayList(InboundMessage)),
    active_keys: std.AutoHashMap(ConversationKey, void),
    shutting_down: bool = false,

    fn init(allocator: std.mem.Allocator) InboundMessageQueue {
        return .{
            .pending_by_key = std.AutoHashMap(ConversationKey, std.ArrayList(InboundMessage)).init(allocator),
            .active_keys = std.AutoHashMap(ConversationKey, void).init(allocator),
        };
    }

    fn deinit(self: *InboundMessageQueue, allocator: std.mem.Allocator) void {
        var iterator = self.pending_by_key.iterator();
        while (iterator.next()) |entry| {
            for (entry.value_ptr.items) |message| allocator.free(message.text);
            entry.value_ptr.deinit(allocator);
        }
        self.pending_by_key.deinit();
        self.active_keys.deinit();
    }

    fn enqueue(self: *InboundMessageQueue, allocator: std.mem.Allocator, message: InboundMessage) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const key: ConversationKey = .{
            .chat_id = message.chat_id,
            .thread_id = message.thread_id,
        };
        const entry = try self.pending_by_key.getOrPut(key);
        if (!entry.found_existing) {
            entry.value_ptr.* = .empty;
        }
        errdefer if (!entry.found_existing and entry.value_ptr.items.len == 0) {
            _ = self.pending_by_key.remove(key);
        };
        try entry.value_ptr.append(allocator, message);
        self.condition.signal();
    }

    fn take(self: *InboundMessageQueue) !?InboundMessage {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (true) {
            if (self.shutting_down) return null;

            var iterator = self.pending_by_key.iterator();
            while (iterator.next()) |entry| {
                if (entry.value_ptr.items.len == 0) continue;
                const key = entry.key_ptr.*;
                if (self.active_keys.contains(key)) continue;
                try self.active_keys.put(key, {});
                return entry.value_ptr.orderedRemove(0);
            }

            self.condition.wait(&self.mutex);
        }
    }

    fn complete(self: *InboundMessageQueue, allocator: std.mem.Allocator, key: ConversationKey) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        _ = self.active_keys.remove(key);
        if (self.pending_by_key.getPtr(key)) |pending| {
            if (pending.items.len == 0) {
                pending.deinit(allocator);
                _ = self.pending_by_key.remove(key);
            }
        }
        self.condition.signal();
    }

    fn shutdown(self: *InboundMessageQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.shutting_down = true;
        self.condition.broadcast();
    }
};

const InboundMessageWorkerPool = struct {
    allocator: std.mem.Allocator,
    conversation_state: *ConversationState,
    workspace_root: []const u8,
    api_key: []const u8,
    model: []const u8,
    bot_token: []const u8,
    workspace_instruction: ?[]const u8,
    queue: InboundMessageQueue,
    workers: ?[]std.Thread = null,

    fn init(
        allocator: std.mem.Allocator,
        conversation_state: *ConversationState,
        workspace_root: []const u8,
        api_key: []const u8,
        model: []const u8,
        bot_token: []const u8,
        workspace_instruction: ?[]const u8,
    ) InboundMessageWorkerPool {
        return .{
            .allocator = allocator,
            .conversation_state = conversation_state,
            .workspace_root = workspace_root,
            .api_key = api_key,
            .model = model,
            .bot_token = bot_token,
            .workspace_instruction = workspace_instruction,
            .queue = InboundMessageQueue.init(allocator),
        };
    }

    fn deinit(self: *InboundMessageWorkerPool) void {
        self.queue.shutdown();
        if (self.workers) |workers| {
            for (workers) |worker| worker.join();
            self.allocator.free(workers);
            self.workers = null;
        }
        self.queue.deinit(self.allocator);
    }

    fn start(self: *InboundMessageWorkerPool, worker_count: usize) !void {
        if (self.workers != null) return;
        const workers = try self.allocator.alloc(std.Thread, worker_count);
        errdefer self.allocator.free(workers);

        var started: usize = 0;
        errdefer {
            self.queue.shutdown();
            while (started > 0) {
                started -= 1;
                workers[started].join();
            }
        }

        for (workers) |*worker| {
            worker.* = try std.Thread.spawn(.{}, runWorker, .{self});
            started += 1;
        }

        self.workers = workers;
    }

    fn enqueue(self: *InboundMessageWorkerPool, message: InboundMessage) !void {
        const text = try self.allocator.dupe(u8, message.text);
        errdefer self.allocator.free(text);

        try self.queue.enqueue(self.allocator, .{
            .chat_id = message.chat_id,
            .thread_id = message.thread_id,
            .chat_kind = message.chat_kind,
            .text = text,
        });
    }

    fn runWorker(self: *InboundMessageWorkerPool) void {
        while (true) {
            const message = self.queue.take() catch |err| {
                std.debug.print("Telegram inbound queue take failed: {s}\n", .{@errorName(err)});
                std.Thread.sleep(50 * std.time.ns_per_ms);
                continue;
            } orelse break;
            defer self.allocator.free(message.text);

            const key: ConversationKey = .{
                .chat_id = message.chat_id,
                .thread_id = message.thread_id,
            };
            defer self.queue.complete(self.allocator, key);

            processInboundMessage(
                self.allocator,
                self.conversation_state,
                self.workspace_root,
                self.api_key,
                self.model,
                self.bot_token,
                message.chat_id,
                message.thread_id,
                message.text,
                self.workspace_instruction,
            ) catch |err| {
                std.debug.print(
                    "Failed to process Telegram message for chat {d}: {s}\n",
                    .{ message.chat_id, @errorName(err) },
                );
                sendMessageInChunks(
                    self.allocator,
                    self.bot_token,
                    message.chat_id,
                    message.thread_id,
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

    std.debug.print(
        "Starting Telegram inbound worker pool with {d} workers.\n",
        .{settings.limits.telegram_inbound_worker_count},
    );

    var conversation_state = ConversationState.init(allocator, runtime_paths.state_path, settings.limits);
    defer conversation_state.deinit(allocator);

    loadConversationStoreAtPath(
        allocator,
        runtime_paths.state_path,
        &conversation_state.conversations,
        settings.limits.telegram_max_conversation_messages,
    ) catch |err| {
        std.debug.print(
            "Failed to load Telegram conversation state ({s}); continuing with empty state.\n",
            .{@errorName(err)},
        );
    };

    var inbound_workers = InboundMessageWorkerPool.init(
        allocator,
        &conversation_state,
        workspace_root,
        settings.openai_api_key,
        settings.openai_model,
        settings.bot_token,
        settings.workspace_instruction,
    );
    defer inbound_workers.deinit();
    try inbound_workers.start(settings.limits.telegram_inbound_worker_count);

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
            settings.limits.openai,
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

            inbound_workers.enqueue(message) catch |err| {
                std.debug.print(
                    "Failed to enqueue Telegram message for chat {d}: {s}\n",
                    .{ message.chat_id, @errorName(err) },
                );
                sendMessageInChunks(
                    allocator,
                    settings.bot_token,
                    message.chat_id,
                    message.thread_id,
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
    conversation_state: *ConversationState,
    workspace_root: []const u8,
    api_key: []const u8,
    model: []const u8,
    bot_token: []const u8,
    chat_id: i64,
    thread_id: ?i64,
    raw_text: []const u8,
    workspace_instruction: ?[]const u8,
) !void {
    const prompt = std.mem.trim(u8, raw_text, " \t\r\n");
    if (prompt.len == 0) {
        try sendMessageInChunks(
            allocator,
            bot_token,
            chat_id,
            thread_id,
            "Please send a non-empty message.",
        );
        return;
    }

    const conversation_key: ConversationKey = .{
        .chat_id = chat_id,
        .thread_id = thread_id,
    };

    if (isResetCommand(prompt)) {
        var had_conversation = false;
        conversation_state.mutex.lock();
        had_conversation = clearConversationForKey(
            allocator,
            &conversation_state.conversations,
            conversation_key,
        );
        if (had_conversation) {
            persistConversationStoreAtPath(
                allocator,
                conversation_state.state_path,
                &conversation_state.conversations,
            ) catch |err| {
                std.debug.print("Failed to persist Telegram conversation state: {s}\n", .{@errorName(err)});
            };
        }
        conversation_state.mutex.unlock();
        try sendMessageInChunks(
            allocator,
            bot_token,
            chat_id,
            thread_id,
            "Started a new session. Previous context cleared.",
        );
        return;
    }

    try processPromptForChat(
        allocator,
        conversation_state,
        workspace_root,
        api_key,
        model,
        bot_token,
        conversation_key,
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
    key: ConversationKey,
) !*Conversation {
    const entry = try conversations.getOrPut(key);
    if (!entry.found_existing) entry.value_ptr.* = .{};
    return entry.value_ptr;
}

fn clearConversationForKey(
    allocator: std.mem.Allocator,
    conversations: *ConversationStore,
    key: ConversationKey,
) bool {
    if (conversations.fetchRemove(key)) |entry| {
        var conversation = entry.value;
        conversation.deinit(allocator);
        return true;
    }
    return false;
}

fn isResetCommand(prompt: []const u8) bool {
    return std.mem.eql(u8, prompt, "/new") or std.mem.eql(u8, prompt, "/reset");
}

fn cloneMessageSnapshot(
    allocator: std.mem.Allocator,
    messages: []const openai_client.Message,
) ![]openai_client.Message {
    const snapshot = try allocator.alloc(openai_client.Message, messages.len);
    errdefer allocator.free(snapshot);

    var copied: usize = 0;
    errdefer {
        for (snapshot[0..copied]) |message| allocator.free(message.content);
    }

    for (messages, 0..) |message, index| {
        snapshot[index] = .{
            .role = message.role,
            .content = try allocator.dupe(u8, message.content),
        };
        copied += 1;
    }
    return snapshot;
}

fn freeMessageSnapshot(allocator: std.mem.Allocator, snapshot: []openai_client.Message) void {
    for (snapshot) |message| allocator.free(message.content);
    allocator.free(snapshot);
}

fn stageConversationPrompt(
    allocator: std.mem.Allocator,
    conversation_state: *ConversationState,
    key: ConversationKey,
    prompt: []const u8,
) ![]openai_client.Message {
    const now = std.time.timestamp();

    conversation_state.mutex.lock();
    defer conversation_state.mutex.unlock();

    if (conversation_state.conversations.getPtr(key)) |existing| {
        if (shouldResetConversationForInactivity(
            existing,
            now,
            conversation_state.limits.telegram_user_inactivity_reset_seconds,
        )) {
            _ = clearConversationForKey(allocator, &conversation_state.conversations, key);
            persistConversationStoreAtPath(
                allocator,
                conversation_state.state_path,
                &conversation_state.conversations,
            ) catch |err| {
                std.debug.print(
                    "Failed to persist Telegram conversation state after inactivity reset: {s}\n",
                    .{@errorName(err)},
                );
            };
        }
    }

    const conversation = try getOrCreateConversation(&conversation_state.conversations, key);
    conversation.last_user_message_at = now;
    try conversation.appendMessage(allocator, .user, prompt);

    return cloneMessageSnapshot(allocator, conversation.messages.items) catch |err| {
        conversation.popLastMessage(allocator);
        return err;
    };
}

fn rollbackConversationPrompt(
    allocator: std.mem.Allocator,
    conversation_state: *ConversationState,
    key: ConversationKey,
) void {
    conversation_state.mutex.lock();
    defer conversation_state.mutex.unlock();

    const conversation = conversation_state.conversations.getPtr(key) orelse return;
    conversation.popLastMessage(allocator);
    persistConversationStoreAtPath(
        allocator,
        conversation_state.state_path,
        &conversation_state.conversations,
    ) catch |err| {
        std.debug.print("Failed to persist Telegram conversation state: {s}\n", .{@errorName(err)});
    };
}

fn commitConversationReply(
    allocator: std.mem.Allocator,
    conversation_state: *ConversationState,
    key: ConversationKey,
    reply: []const u8,
) !void {
    conversation_state.mutex.lock();
    defer conversation_state.mutex.unlock();

    const conversation = conversation_state.conversations.getPtr(key) orelse return error.MissingConversation;
    try conversation.appendMessage(allocator, .assistant, reply);
    enforceConversationLimit(conversation, allocator, conversation_state.limits.telegram_max_conversation_messages);
    persistConversationStoreAtPath(
        allocator,
        conversation_state.state_path,
        &conversation_state.conversations,
    ) catch |err| {
        std.debug.print("Failed to persist Telegram conversation state: {s}\n", .{@errorName(err)});
    };
}

fn processPromptForChat(
    allocator: std.mem.Allocator,
    conversation_state: *ConversationState,
    workspace_root: []const u8,
    api_key: []const u8,
    model: []const u8,
    bot_token: []const u8,
    key: ConversationKey,
    prompt: []const u8,
    workspace_instruction: ?[]const u8,
) !void {
    const request_messages = try stageConversationPrompt(allocator, conversation_state, key, prompt);
    defer freeMessageSnapshot(allocator, request_messages);

    var should_rollback_prompt = true;
    defer if (should_rollback_prompt) rollbackConversationPrompt(allocator, conversation_state, key);

    var typing_notifier: TypingNotifier = .{};
    typing_notifier.start(bot_token, key.chat_id, key.thread_id) catch |err| {
        std.debug.print(
            "Failed to start Telegram typing notifier for chat {d}: {s}\n",
            .{ key.chat_id, @errorName(err) },
        );
    };
    defer typing_notifier.stop();

    var reply = try openai_client.fetchAssistantReplyWithContextDetailed(
        allocator,
        api_key,
        model,
        request_messages,
        .{
            .request_chat_id = key.chat_id,
            .workspace_instruction = workspace_instruction,
            .limits = conversation_state.limits.openai,
        },
    );
    defer reply.deinit(allocator);

    const trimmed_reply = std.mem.trim(u8, reply.content, " \t\r\n");
    if (trimmed_reply.len == 0 and reply.attachments.len == 0) {
        rollbackConversationPrompt(allocator, conversation_state, key);
        should_rollback_prompt = false;
        try sendMessageInChunks(
            allocator,
            bot_token,
            key.chat_id,
            key.thread_id,
            "Assistant returned an empty response.",
        );
        return;
    }

    try sendTelegramReplyWithAttachments(
        allocator,
        bot_token,
        key.chat_id,
        key.thread_id,
        workspace_root,
        trimmed_reply,
        reply.attachments,
    );

    const conversation_reply = if (trimmed_reply.len > 0) trimmed_reply else "[Attachment delivered]";
    try commitConversationReply(allocator, conversation_state, key, conversation_reply);
    should_rollback_prompt = false;
}

fn shouldResetConversationForInactivity(
    conversation: *const Conversation,
    now: i64,
    reset_after_seconds: i64,
) bool {
    const last_user_message_at = conversation.last_user_message_at orelse return false;
    if (now <= last_user_message_at) return false;
    return now - last_user_message_at >= reset_after_seconds;
}

fn processDueScheduledJobs(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model: []const u8,
    bot_token: []const u8,
    workspace_root: []const u8,
    default_dm_chat_id_path: []const u8,
    workspace_instruction: ?[]const u8,
    openai_limits: openai_client.Limits,
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
        var reply = openai_client.fetchAssistantReplyWithContextDetailed(
            allocator,
            api_key,
            model,
            &messages,
            .{
                .workspace_instruction = workspace_instruction,
                .limits = openai_limits,
            },
        ) catch |err| {
            std.debug.print(
                "Failed to process scheduled job {s}: {s}\n",
                .{ due_job.job.id, @errorName(err) },
            );
            continue;
        };
        defer reply.deinit(allocator);

        const trimmed_reply = std.mem.trim(u8, reply.content, " \t\r\n");
        if (trimmed_reply.len == 0 and reply.attachments.len == 0) continue;

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
            sendTelegramReplyWithAttachments(
                allocator,
                bot_token,
                chat_id,
                null,
                workspace_root,
                trimmed_reply,
                reply.attachments,
            ) catch |err| {
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

fn enforceConversationLimit(
    conversation: *Conversation,
    allocator: std.mem.Allocator,
    max_messages: usize,
) void {
    while (conversation.messages.items.len > max_messages) {
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
    key: ConversationKey,
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
            .key = entry.key_ptr.*,
            .last_user_message_at = entry.value_ptr.last_user_message_at,
            .messages = entry.value_ptr.messages.items,
        });
    }

    std.mem.sort(StoredChat, chats.items, {}, sortStoredChatsAsc);

    try file.writeAll("{\"version\":1,\"chats\":[");
    for (chats.items, 0..) |chat, chat_index| {
        if (chat_index > 0) try file.writeAll(",");

        try file.writeAll("{\"chat_id\":");
        const chat_id_text = try std.fmt.allocPrint(allocator, "{d}", .{chat.key.chat_id});
        defer allocator.free(chat_id_text);
        try file.writeAll(chat_id_text);
        try file.writeAll(",\"message_thread_id\":");
        if (chat.key.thread_id) |thread_id| {
            const thread_id_text = try std.fmt.allocPrint(allocator, "{d}", .{thread_id});
            defer allocator.free(thread_id_text);
            try file.writeAll(thread_id_text);
        } else {
            try file.writeAll("null");
        }
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
    if (lhs.key.chat_id != rhs.key.chat_id) return lhs.key.chat_id < rhs.key.chat_id;
    if (lhs.key.thread_id == null) return rhs.key.thread_id != null;
    if (rhs.key.thread_id == null) return false;
    return lhs.key.thread_id.? < rhs.key.thread_id.?;
}

fn loadConversationStoreAtPath(
    allocator: std.mem.Allocator,
    state_path: []const u8,
    conversations: *ConversationStore,
    max_messages_per_chat: usize,
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
        const thread_id = if (chat_object.get("message_thread_id")) |value|
            parseJsonI64(value)
        else
            null;
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
        enforceConversationLimit(&loaded, allocator, max_messages_per_chat);

        const entry = try conversations.getOrPut(.{
            .chat_id = chat_id,
            .thread_id = thread_id,
        });
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
        const text = parseInboundMessageText(message) orelse continue;
        const chat = switch (message.get("chat") orelse continue) {
            .object => |object| object,
            else => continue,
        };
        const chat_id = parseJsonI64(chat.get("id") orelse continue) orelse continue;
        const thread_id = parseJsonI64(message.get("message_thread_id") orelse .null);
        const chat_kind = parseInboundChatKind(chat.get("type") orelse .null);

        try messages.append(allocator, .{
            .chat_id = chat_id,
            .thread_id = thread_id,
            .chat_kind = chat_kind,
            .text = try allocator.dupe(u8, text),
        });
    }

    return .{
        .messages = try messages.toOwnedSlice(allocator),
        .next_offset = next_offset,
    };
}

fn sendTelegramReplyWithAttachments(
    allocator: std.mem.Allocator,
    bot_token: []const u8,
    chat_id: i64,
    thread_id: ?i64,
    workspace_root: []const u8,
    text: []const u8,
    attachments: []const openai_client.OutboundAttachment,
) !void {
    var delivered_attachment = false;
    for (attachments) |attachment| {
        sendWorkspaceAttachment(
            allocator,
            bot_token,
            chat_id,
            thread_id,
            workspace_root,
            attachment,
        ) catch |err| {
            std.debug.print(
                "Failed to send Telegram attachment {s} to chat {d}: {s}\n",
                .{ attachment.path, chat_id, @errorName(err) },
            );
            continue;
        };
        delivered_attachment = true;
    }

    if (text.len > 0) {
        try sendMessageInChunks(allocator, bot_token, chat_id, thread_id, text);
    } else if (attachments.len > 0 and !delivered_attachment) {
        try sendMessageInChunks(
            allocator,
            bot_token,
            chat_id,
            thread_id,
            "Generated attachment could not be delivered.",
        );
    }
}

fn sendWorkspaceAttachment(
    allocator: std.mem.Allocator,
    bot_token: []const u8,
    chat_id: i64,
    thread_id: ?i64,
    workspace_root: []const u8,
    attachment: openai_client.OutboundAttachment,
) !void {
    const resolved = try workspace_fs.resolveAllowedReadPath(
        allocator,
        workspace_root,
        attachment.path,
    );
    defer allocator.free(resolved);

    const file = try std.fs.cwd().openFile(resolved, .{});
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, max_telegram_upload_file_bytes);
    defer allocator.free(contents);

    const basename = std.fs.path.basename(attachment.path);
    const fallback_name = switch (attachment.kind) {
        .photo => "attachment.png",
        .document => "attachment.bin",
    };
    const filename = if (basename.len > 0) basename else fallback_name;

    const content_type = switch (attachment.kind) {
        .photo => guessPhotoContentType(filename),
        .document => guessDocumentContentType(filename),
    };

    switch (attachment.kind) {
        .photo => sendPhoto(
            allocator,
            bot_token,
            chat_id,
            thread_id,
            filename,
            content_type,
            contents,
        ) catch |err| switch (err) {
            error.TelegramApiRequestFailed => try sendDocument(
                allocator,
                bot_token,
                chat_id,
                thread_id,
                filename,
                content_type,
                contents,
            ),
            else => return err,
        },
        .document => try sendDocument(
            allocator,
            bot_token,
            chat_id,
            thread_id,
            filename,
            content_type,
            contents,
        ),
    }
}

fn guessPhotoContentType(path: []const u8) []const u8 {
    const extension = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(extension, ".jpg") or std.ascii.eqlIgnoreCase(extension, ".jpeg")) {
        return "image/jpeg";
    }
    if (std.ascii.eqlIgnoreCase(extension, ".webp")) return "image/webp";
    return "image/png";
}

fn guessDocumentContentType(path: []const u8) []const u8 {
    const extension = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(extension, ".pdf")) return "application/pdf";
    if (std.ascii.eqlIgnoreCase(extension, ".txt")) return "text/plain";
    if (std.ascii.eqlIgnoreCase(extension, ".json")) return "application/json";
    return "application/octet-stream";
}

fn sendPhoto(
    allocator: std.mem.Allocator,
    bot_token: []const u8,
    chat_id: i64,
    thread_id: ?i64,
    filename: []const u8,
    file_content_type: []const u8,
    file_contents: []const u8,
) !void {
    try sendMultipartFileRequest(
        allocator,
        bot_token,
        "sendPhoto",
        "photo",
        chat_id,
        thread_id,
        filename,
        file_content_type,
        file_contents,
    );
}

fn sendDocument(
    allocator: std.mem.Allocator,
    bot_token: []const u8,
    chat_id: i64,
    thread_id: ?i64,
    filename: []const u8,
    file_content_type: []const u8,
    file_contents: []const u8,
) !void {
    try sendMultipartFileRequest(
        allocator,
        bot_token,
        "sendDocument",
        "document",
        chat_id,
        thread_id,
        filename,
        file_content_type,
        file_contents,
    );
}

const MultipartPayload = struct {
    body: []u8,
    content_type_header: []u8,

    fn deinit(self: *MultipartPayload, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        allocator.free(self.content_type_header);
        self.* = undefined;
    }
};

fn sendMultipartFileRequest(
    allocator: std.mem.Allocator,
    bot_token: []const u8,
    method_name: []const u8,
    file_field_name: []const u8,
    chat_id: i64,
    thread_id: ?i64,
    filename: []const u8,
    file_content_type: []const u8,
    file_contents: []const u8,
) !void {
    const uri = try std.fmt.allocPrint(
        allocator,
        "https://api.telegram.org/bot{s}/{s}",
        .{ bot_token, method_name },
    );
    defer allocator.free(uri);

    var payload = try buildMultipartFilePayload(
        allocator,
        file_field_name,
        chat_id,
        thread_id,
        filename,
        file_content_type,
        file_contents,
    );
    defer payload.deinit(allocator);

    const headers = [_]http_client.RequestHeader{
        .{ .name = "Content-Type", .value = payload.content_type_header },
    };

    var response = try http_client.executeRequest(
        allocator,
        .POST,
        uri,
        payload.body,
        &headers,
        max_send_response_bytes,
        false,
    );
    defer response.deinit(allocator);

    if (response.status_code != 200) {
        if (try parseTelegramErrorDescription(allocator, response.body)) |description| {
            defer allocator.free(description);
            std.debug.print(
                "Telegram {s} returned status {d}: {s}\n",
                .{ method_name, response.status_code, description },
            );
        } else {
            std.debug.print(
                "Telegram {s} returned status {d}.\n",
                .{ method_name, response.status_code },
            );
        }
        return error.TelegramApiRequestFailed;
    }

    const ok = parseTelegramOk(allocator, response.body) catch |err| {
        std.debug.print("Telegram {s} invalid response: {s}\n", .{ method_name, @errorName(err) });
        return err;
    };
    if (!ok) {
        if (try parseTelegramErrorDescription(allocator, response.body)) |description| {
            defer allocator.free(description);
            std.debug.print("Telegram {s} failed: {s}\n", .{ method_name, description });
        } else {
            std.debug.print("Telegram {s} failed.\n", .{method_name});
        }
        return error.TelegramApiRequestFailed;
    }
}

fn buildMultipartFilePayload(
    allocator: std.mem.Allocator,
    file_field_name: []const u8,
    chat_id: i64,
    thread_id: ?i64,
    filename: []const u8,
    file_content_type: []const u8,
    file_contents: []const u8,
) !MultipartPayload {
    var boundary_random: [12]u8 = undefined;
    std.crypto.random.bytes(&boundary_random);
    const boundary_suffix = std.fmt.bytesToHex(boundary_random, .lower);
    const boundary = try std.mem.concat(allocator, u8, &.{ "zoid-", boundary_suffix[0..] });
    defer allocator.free(boundary);

    const content_type_header = try std.fmt.allocPrint(
        allocator,
        "multipart/form-data; boundary={s}",
        .{boundary},
    );

    const chat_id_text = try std.fmt.allocPrint(allocator, "{d}", .{chat_id});
    defer allocator.free(chat_id_text);

    var payload = std.ArrayList(u8).empty;
    errdefer payload.deinit(allocator);

    try appendMultipartTextField(
        allocator,
        &payload,
        boundary,
        "chat_id",
        chat_id_text,
    );
    if (thread_id) |value| {
        const thread_id_text = try std.fmt.allocPrint(allocator, "{d}", .{value});
        defer allocator.free(thread_id_text);
        try appendMultipartTextField(
            allocator,
            &payload,
            boundary,
            "message_thread_id",
            thread_id_text,
        );
    }

    const escaped_filename = try sanitizeMultipartFilename(allocator, filename);
    defer allocator.free(escaped_filename);

    const writer = payload.writer(allocator);
    try writer.print("--{s}\r\n", .{boundary});
    try writer.print(
        "Content-Disposition: form-data; name=\"{s}\"; filename=\"{s}\"\r\n",
        .{ file_field_name, escaped_filename },
    );
    try writer.print("Content-Type: {s}\r\n\r\n", .{file_content_type});
    try payload.appendSlice(allocator, file_contents);
    try payload.appendSlice(allocator, "\r\n");
    try writer.print("--{s}--\r\n", .{boundary});

    return .{
        .body = try payload.toOwnedSlice(allocator),
        .content_type_header = content_type_header,
    };
}

fn appendMultipartTextField(
    allocator: std.mem.Allocator,
    payload: *std.ArrayList(u8),
    boundary: []const u8,
    field_name: []const u8,
    value: []const u8,
) !void {
    const writer = payload.writer(allocator);
    try writer.print("--{s}\r\n", .{boundary});
    try writer.print("Content-Disposition: form-data; name=\"{s}\"\r\n\r\n", .{field_name});
    try payload.appendSlice(allocator, value);
    try payload.appendSlice(allocator, "\r\n");
}

fn sanitizeMultipartFilename(allocator: std.mem.Allocator, filename: []const u8) ![]u8 {
    var sanitized = std.ArrayList(u8).empty;
    errdefer sanitized.deinit(allocator);

    for (filename) |byte| {
        switch (byte) {
            '"', '\r', '\n' => try sanitized.append(allocator, '_'),
            else => try sanitized.append(allocator, byte),
        }
    }

    if (sanitized.items.len == 0) {
        try sanitized.appendSlice(allocator, "attachment.bin");
    }

    return sanitized.toOwnedSlice(allocator);
}

fn sendMessageInChunks(
    allocator: std.mem.Allocator,
    bot_token: []const u8,
    chat_id: i64,
    thread_id: ?i64,
    text: []const u8,
) !void {
    if (text.len == 0) {
        try sendMessage(allocator, bot_token, chat_id, thread_id, " ", telegram_message_parse_mode);
        return;
    }

    var start: usize = 0;
    while (start < text.len) {
        const end = nextMarkdownChunkBoundary(text, start, max_telegram_message_bytes);
        if (end <= start) return error.InvalidUtf8;
        const chunk = text[start..end];
        const markdown_chunk = try sanitizeTelegramMarkdownV2Chunk(allocator, chunk);
        defer allocator.free(markdown_chunk);

        sendMessage(
            allocator,
            bot_token,
            chat_id,
            thread_id,
            markdown_chunk,
            telegram_message_parse_mode,
        ) catch |err| switch (err) {
            error.TelegramApiRequestFailed => {
                const plain_chunk = try plainTelegramFallbackChunk(allocator, markdown_chunk);
                defer allocator.free(plain_chunk);
                try sendMessage(allocator, bot_token, chat_id, thread_id, plain_chunk, null);
            },
            else => return err,
        };
        start = end;
    }
}

fn nextMarkdownChunkBoundary(text: []const u8, start: usize, max_bytes: usize) usize {
    if (start >= text.len) return text.len;

    var index = start;
    var escaped_bytes: usize = 0;
    while (index < text.len) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(text[index]) catch {
            if (index == start) return @min(start + max_bytes, text.len);
            break;
        };
        if (sequence_len == 0 or index + sequence_len > text.len) {
            if (index == start) return @min(start + max_bytes, text.len);
            break;
        }

        const sequence_end = index + sequence_len;
        var escaped_sequence_len: usize = sequence_len;
        var cursor = index;
        while (cursor < sequence_end) : (cursor += 1) {
            if (shouldEscapeTelegramMarkdownV2Byte(text[cursor])) {
                escaped_sequence_len += 1;
            }
        }
        if (escaped_bytes + escaped_sequence_len > max_bytes) break;

        escaped_bytes += escaped_sequence_len;
        index = sequence_end;
    }

    if (index == start) return @min(start + max_bytes, text.len);
    return index;
}

fn sanitizeTelegramMarkdownV2Chunk(
    allocator: std.mem.Allocator,
    chunk: []const u8,
) ![]u8 {
    var escaped = std.ArrayList(u8).empty;
    errdefer escaped.deinit(allocator);

    var index: usize = 0;
    var at_line_start = true;
    while (index < chunk.len) {
        if (at_line_start) {
            if (try appendSanitizedTelegramBlockquoteLine(allocator, &escaped, chunk, index)) |consumed| {
                index += consumed;
                at_line_start = false;
                continue;
            }
            if (try appendSanitizedTelegramHeadingLine(allocator, &escaped, chunk, index)) |consumed| {
                index += consumed;
                at_line_start = false;
                continue;
            }
        }

        if (try appendSanitizedTelegramEntity(allocator, &escaped, chunk, index, false)) |consumed| {
            index += consumed;
            at_line_start = false;
            continue;
        }

        const consumed = try appendEscapedTelegramMarkdownV2SliceByte(allocator, &escaped, chunk, index, false);
        const last_byte = chunk[index + consumed - 1];
        at_line_start = last_byte == '\n' or last_byte == '\r';
        index += consumed;
    }

    return escaped.toOwnedSlice(allocator);
}

fn appendEscapedTelegramMarkdownV2SliceByte(
    allocator: std.mem.Allocator,
    escaped: *std.ArrayList(u8),
    chunk: []const u8,
    cursor: usize,
    escape_heading_star: bool,
) !usize {
    if (chunk[cursor] == '\\' and cursor + 1 < chunk.len) {
        const next = chunk[cursor + 1];
        if (shouldEscapeTelegramMarkdownV2Byte(next)) {
            try escaped.append(allocator, '\\');
            try escaped.append(allocator, next);
            return 2;
        }
    }

    if (escape_heading_star) {
        try appendEscapedTelegramHeadingByte(allocator, escaped, chunk[cursor]);
    } else {
        try appendEscapedTelegramMarkdownV2Byte(allocator, escaped, chunk[cursor]);
    }
    return 1;
}

fn appendEscapedTelegramMarkdownV2Byte(
    allocator: std.mem.Allocator,
    escaped: *std.ArrayList(u8),
    byte: u8,
) !void {
    if (shouldEscapeTelegramMarkdownV2Byte(byte)) {
        try escaped.append(allocator, '\\');
    }
    try escaped.append(allocator, byte);
}

fn appendEscapedTelegramHeadingByte(
    allocator: std.mem.Allocator,
    escaped: *std.ArrayList(u8),
    byte: u8,
) !void {
    try appendEscapedTelegramMarkdownV2Byte(allocator, escaped, byte);
}

fn appendEscapedTelegramLinkUrlSliceByte(
    allocator: std.mem.Allocator,
    escaped: *std.ArrayList(u8),
    chunk: []const u8,
    cursor: usize,
) !usize {
    if (chunk[cursor] == '\\' and cursor + 1 < chunk.len) {
        const next = chunk[cursor + 1];
        if (shouldEscapeTelegramMarkdownV2LinkUrlByte(next)) {
            try escaped.append(allocator, '\\');
            try escaped.append(allocator, next);
            return 2;
        }
    }

    const byte = chunk[cursor];
    if (shouldEscapeTelegramMarkdownV2LinkUrlByte(byte)) {
        try escaped.append(allocator, '\\');
    }
    try escaped.append(allocator, byte);
    return 1;
}

fn appendSanitizedTelegramHeadingLine(
    allocator: std.mem.Allocator,
    escaped: *std.ArrayList(u8),
    chunk: []const u8,
    start: usize,
) SanitizerError!?usize {
    if (start >= chunk.len or chunk[start] != '#') return null;

    var marker_end = start;
    while (marker_end < chunk.len and chunk[marker_end] == '#') : (marker_end += 1) {}
    if (marker_end == start) return null;
    if (marker_end >= chunk.len) return null;
    if (chunk[marker_end] != ' ' and chunk[marker_end] != '\t') return null;

    var content_start = marker_end;
    while (content_start < chunk.len and (chunk[content_start] == ' ' or chunk[content_start] == '\t')) : (content_start += 1) {}
    if (content_start >= chunk.len) return null;
    if (chunk[content_start] == '\n' or chunk[content_start] == '\r') return null;

    var line_end = content_start;
    while (line_end < chunk.len and chunk[line_end] != '\n' and chunk[line_end] != '\r') : (line_end += 1) {}

    try escaped.append(allocator, '*');
    var cursor = content_start;
    while (cursor < line_end) {
        if (try appendSanitizedTelegramEntity(allocator, escaped, chunk, cursor, true)) |consumed| {
            cursor += consumed;
            continue;
        }

        cursor += try appendEscapedTelegramMarkdownV2SliceByte(allocator, escaped, chunk, cursor, true);
    }
    try escaped.append(allocator, '*');

    return line_end - start;
}

fn appendSanitizedTelegramBlockquoteLine(
    allocator: std.mem.Allocator,
    escaped: *std.ArrayList(u8),
    chunk: []const u8,
    start: usize,
) SanitizerError!?usize {
    if (start >= chunk.len or chunk[start] != '>') return null;

    var line_end = start;
    while (line_end < chunk.len and chunk[line_end] != '\n' and chunk[line_end] != '\r') : (line_end += 1) {}

    try escaped.append(allocator, '>');
    var cursor = start + 1;
    while (cursor < line_end) {
        if (try appendSanitizedTelegramEntity(allocator, escaped, chunk, cursor, false)) |consumed| {
            cursor += consumed;
            continue;
        }
        cursor += try appendEscapedTelegramMarkdownV2SliceByte(allocator, escaped, chunk, cursor, false);
    }

    return line_end - start;
}

fn appendSanitizedTelegramEntity(
    allocator: std.mem.Allocator,
    escaped: *std.ArrayList(u8),
    chunk: []const u8,
    start: usize,
    escape_heading_star: bool,
) SanitizerError!?usize {
    if (try appendSanitizedTelegramCodeSpan(allocator, escaped, chunk, start, 3)) |consumed| {
        return consumed;
    }
    if (try appendSanitizedTelegramCodeSpan(allocator, escaped, chunk, start, 1)) |consumed| {
        return consumed;
    }
    if (try appendSanitizedTelegramInlineLink(allocator, escaped, chunk, start, escape_heading_star)) |consumed| {
        return consumed;
    }

    if (try appendSanitizedTelegramStyledSpan(allocator, escaped, chunk, start, '_', 2, 2, escape_heading_star)) |consumed| {
        return consumed;
    }
    if (try appendSanitizedTelegramStyledSpan(allocator, escaped, chunk, start, '|', 2, 2, escape_heading_star)) |consumed| {
        return consumed;
    }
    // Accept common markdown-style double-tilde and normalize it to Telegram's single-tilde strikethrough.
    if (try appendSanitizedTelegramStyledSpan(allocator, escaped, chunk, start, '~', 2, 1, escape_heading_star)) |consumed| {
        return consumed;
    }

    if (!escape_heading_star) {
        if (try appendSanitizedTelegramStyledSpan(allocator, escaped, chunk, start, '*', 1, 1, false)) |consumed| {
            return consumed;
        }
    }
    if (try appendSanitizedTelegramStyledSpan(allocator, escaped, chunk, start, '_', 1, 1, escape_heading_star)) |consumed| {
        return consumed;
    }
    if (try appendSanitizedTelegramStyledSpan(allocator, escaped, chunk, start, '~', 1, 1, escape_heading_star)) |consumed| {
        return consumed;
    }

    return null;
}

fn delimiterMatchesAt(
    chunk: []const u8,
    start: usize,
    marker_byte: u8,
    delimiter_len: usize,
) bool {
    if (delimiter_len == 0 or start + delimiter_len > chunk.len) return false;
    var index: usize = 0;
    while (index < delimiter_len) : (index += 1) {
        if (chunk[start + index] != marker_byte) return false;
    }
    return true;
}

fn appendEscapedTelegramCodeByte(
    allocator: std.mem.Allocator,
    escaped: *std.ArrayList(u8),
    byte: u8,
) !void {
    if (byte == '\\' or byte == '`') {
        try escaped.append(allocator, '\\');
    }
    try escaped.append(allocator, byte);
}

fn appendSanitizedTelegramCodeSpan(
    allocator: std.mem.Allocator,
    escaped: *std.ArrayList(u8),
    chunk: []const u8,
    start: usize,
    delimiter_len: usize,
) SanitizerError!?usize {
    if (!delimiterMatchesAt(chunk, start, '`', delimiter_len)) return null;
    const content_start = start + delimiter_len;
    if (content_start >= chunk.len) return null;

    const allow_newlines = delimiter_len == 3;
    var cursor = content_start;
    var close_start: ?usize = null;
    while (cursor < chunk.len) {
        const byte = chunk[cursor];
        if (!allow_newlines and (byte == '\n' or byte == '\r')) return null;
        if (byte == '\\') {
            if (cursor + 1 >= chunk.len) return null;
            cursor += 2;
            continue;
        }
        if (delimiterMatchesAt(chunk, cursor, '`', delimiter_len)) {
            close_start = cursor;
            break;
        }
        cursor += 1;
    }

    const resolved_close_start = close_start orelse return null;
    if (resolved_close_start == content_start) return null;

    var index: usize = 0;
    while (index < delimiter_len) : (index += 1) {
        try escaped.append(allocator, '`');
    }

    cursor = content_start;
    while (cursor < resolved_close_start) : (cursor += 1) {
        try appendEscapedTelegramCodeByte(allocator, escaped, chunk[cursor]);
    }

    index = 0;
    while (index < delimiter_len) : (index += 1) {
        try escaped.append(allocator, '`');
    }
    return resolved_close_start + delimiter_len - start;
}

fn appendSanitizedTelegramInlineLink(
    allocator: std.mem.Allocator,
    escaped: *std.ArrayList(u8),
    chunk: []const u8,
    start: usize,
    escape_heading_star: bool,
) SanitizerError!?usize {
    if (start >= chunk.len or chunk[start] != '[') return null;

    var label_end: ?usize = null;
    var cursor = start + 1;
    while (cursor < chunk.len) {
        const byte = chunk[cursor];
        if (byte == '\n' or byte == '\r') return null;
        if (byte == '\\') {
            if (cursor + 1 >= chunk.len) return null;
            cursor += 2;
            continue;
        }
        if (byte == ']') {
            label_end = cursor;
            break;
        }
        cursor += 1;
    }

    const resolved_label_end = label_end orelse return null;
    if (resolved_label_end + 1 >= chunk.len or chunk[resolved_label_end + 1] != '(') return null;

    const url_start = resolved_label_end + 2;
    if (url_start >= chunk.len) return null;

    var depth: usize = 1;
    cursor = url_start;
    var url_end: ?usize = null;
    while (cursor < chunk.len) {
        const byte = chunk[cursor];
        if (byte == '\n' or byte == '\r') return null;
        if (byte == '\\') {
            if (cursor + 1 >= chunk.len) return null;
            cursor += 2;
            continue;
        }
        if (byte == '(') {
            depth += 1;
            cursor += 1;
            continue;
        }
        if (byte == ')') {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) {
                url_end = cursor;
                break;
            }
        }
        cursor += 1;
    }

    const resolved_url_end = url_end orelse return null;
    if (resolved_url_end == url_start) return null;

    try escaped.append(allocator, '[');
    cursor = start + 1;
    while (cursor < resolved_label_end) {
        cursor += try appendEscapedTelegramMarkdownV2SliceByte(
            allocator,
            escaped,
            chunk,
            cursor,
            escape_heading_star,
        );
    }
    try escaped.appendSlice(allocator, "](");

    cursor = url_start;
    while (cursor < resolved_url_end) {
        cursor += try appendEscapedTelegramLinkUrlSliceByte(
            allocator,
            escaped,
            chunk,
            cursor,
        );
    }
    try escaped.append(allocator, ')');

    return resolved_url_end + 1 - start;
}

fn appendSanitizedTelegramStyledSpan(
    allocator: std.mem.Allocator,
    escaped: *std.ArrayList(u8),
    chunk: []const u8,
    start: usize,
    marker_byte: u8,
    delimiter_len: usize,
    output_delimiter_len: usize,
    escape_heading_star: bool,
) SanitizerError!?usize {
    if (!delimiterMatchesAt(chunk, start, marker_byte, delimiter_len)) return null;
    const content_start = start + delimiter_len;
    if (content_start >= chunk.len) return null;

    var cursor = content_start;
    var close_start: ?usize = null;
    while (cursor < chunk.len) {
        const byte = chunk[cursor];
        if (byte == '\n' or byte == '\r') return null;
        if (byte == '\\') {
            if (cursor + 1 >= chunk.len) return null;
            cursor += 2;
            continue;
        }
        if (delimiterMatchesAt(chunk, cursor, marker_byte, delimiter_len)) {
            if (delimiter_len == 1 and marker_byte == '_' and delimiterMatchesAt(chunk, cursor, '_', 2)) {
                cursor += 1;
                continue;
            }
            if (delimiter_len == 1 and marker_byte == '~' and delimiterMatchesAt(chunk, cursor, '~', 2)) {
                cursor += 1;
                continue;
            }
            close_start = cursor;
            break;
        }
        cursor += 1;
    }

    const resolved_close_start = close_start orelse return null;
    if (resolved_close_start == content_start) return null;

    var index: usize = 0;
    while (index < output_delimiter_len) : (index += 1) {
        try escaped.append(allocator, marker_byte);
    }

    cursor = content_start;
    while (cursor < resolved_close_start) {
        if (try appendSanitizedTelegramEntity(allocator, escaped, chunk, cursor, escape_heading_star)) |consumed| {
            cursor += consumed;
            continue;
        }

        cursor += try appendEscapedTelegramMarkdownV2SliceByte(
            allocator,
            escaped,
            chunk,
            cursor,
            escape_heading_star,
        );
    }

    index = 0;
    while (index < output_delimiter_len) : (index += 1) {
        try escaped.append(allocator, marker_byte);
    }
    return resolved_close_start + delimiter_len - start;
}

fn shouldEscapeTelegramMarkdownV2LinkUrlByte(byte: u8) bool {
    return switch (byte) {
        '\\', '(', ')' => true,
        else => false,
    };
}

fn shouldEscapeTelegramMarkdownV2Byte(byte: u8) bool {
    return switch (byte) {
        '_', '*', '[', ']', '(', ')', '~', '`', '>', '#', '+', '-', '=', '|', '{', '}', '.', '!', '\\' => true,
        else => false,
    };
}

fn plainTelegramFallbackChunk(
    allocator: std.mem.Allocator,
    markdown_chunk: []const u8,
) ![]u8 {
    var plain = std.ArrayList(u8).empty;
    errdefer plain.deinit(allocator);

    var index: usize = 0;
    while (index < markdown_chunk.len) {
        if (markdown_chunk[index] == '\\' and index + 1 < markdown_chunk.len) {
            const next = markdown_chunk[index + 1];
            if (shouldEscapeTelegramMarkdownV2Byte(next)) {
                try plain.append(allocator, next);
                index += 2;
                continue;
            }
        }

        try plain.append(allocator, markdown_chunk[index]);
        index += 1;
    }

    return plain.toOwnedSlice(allocator);
}

fn sendMessage(
    allocator: std.mem.Allocator,
    bot_token: []const u8,
    chat_id: i64,
    thread_id: ?i64,
    text: []const u8,
    parse_mode: ?[]const u8,
) !void {
    const uri = try std.fmt.allocPrint(
        allocator,
        "https://api.telegram.org/bot{s}/sendMessage",
        .{bot_token},
    );
    defer allocator.free(uri);

    const payload = try buildSendMessagePayload(allocator, chat_id, thread_id, text, parse_mode);
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
    thread_id: ?i64,
) !void {
    const uri = try std.fmt.allocPrint(
        allocator,
        "https://api.telegram.org/bot{s}/sendChatAction",
        .{bot_token},
    );
    defer allocator.free(uri);

    const payload = try buildChatActionPayload(allocator, chat_id, thread_id, "typing");
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
    thread_id: ?i64,
    text: []const u8,
    parse_mode: ?[]const u8,
) ![]u8 {
    const escaped_text = try std.json.Stringify.valueAlloc(allocator, text, .{});
    defer allocator.free(escaped_text);

    var payload = std.ArrayList(u8).empty;
    errdefer payload.deinit(allocator);
    const writer = payload.writer(allocator);

    try writer.print("{{\"chat_id\":{d}", .{chat_id});
    if (thread_id) |value| {
        try writer.print(",\"message_thread_id\":{d}", .{value});
    }
    try writer.print(",\"text\":{s}", .{escaped_text});
    if (parse_mode) |value| {
        try writer.print(",\"parse_mode\":\"{s}\"", .{value});
    }
    try writer.writeAll("}");
    return payload.toOwnedSlice(allocator);
}

fn buildChatActionPayload(
    allocator: std.mem.Allocator,
    chat_id: i64,
    thread_id: ?i64,
    action: []const u8,
) ![]u8 {
    const escaped_action = try std.json.Stringify.valueAlloc(allocator, action, .{});
    defer allocator.free(escaped_action);

    var payload = std.ArrayList(u8).empty;
    errdefer payload.deinit(allocator);
    const writer = payload.writer(allocator);

    try writer.print("{{\"chat_id\":{d}", .{chat_id});
    if (thread_id) |value| {
        try writer.print(",\"message_thread_id\":{d}", .{value});
    }
    try writer.print(",\"action\":{s}}}", .{escaped_action});
    return payload.toOwnedSlice(allocator);
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

fn parseInboundMessageText(message: std.json.ObjectMap) ?[]const u8 {
    if (message.get("text")) |text_value| {
        return switch (text_value) {
            .string => |value| value,
            else => null,
        };
    }
    if (message.get("caption")) |caption_value| {
        return switch (caption_value) {
            .string => |value| value,
            else => null,
        };
    }
    return null;
}

fn parseInboundChatKind(value: std.json.Value) InboundChatKind {
    const name = switch (value) {
        .string => |text| text,
        else => return .group_like,
    };
    if (std.mem.eql(u8, name, "private")) return .private;
    return .group_like;
}

test "parsePollBatch extracts text or caption and preserves thread ids" {
    const response =
        \\{"ok":true,"result":[
        \\{"update_id":10,"message":{"chat":{"id":111,"type":"private"},"text":"hello","message_thread_id":7}},
        \\{"update_id":11,"message":{"chat":{"id":111,"type":"private"}}},
        \\{"update_id":12,"channel_post":{"chat":{"id":-222,"type":"channel"},"caption":"hej"}}
        \\]}
    ;

    var batch = try parsePollBatch(std.testing.allocator, response, 0);
    defer batch.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i64, 13), batch.next_offset);
    try std.testing.expectEqual(@as(usize, 2), batch.messages.len);
    try std.testing.expectEqual(@as(i64, 111), batch.messages[0].chat_id);
    try std.testing.expectEqual(@as(?i64, 7), batch.messages[0].thread_id);
    try std.testing.expectEqual(InboundChatKind.private, batch.messages[0].chat_kind);
    try std.testing.expectEqualStrings("hello", batch.messages[0].text);
    try std.testing.expectEqual(@as(i64, -222), batch.messages[1].chat_id);
    try std.testing.expectEqual(@as(?i64, null), batch.messages[1].thread_id);
    try std.testing.expectEqual(InboundChatKind.group_like, batch.messages[1].chat_kind);
    try std.testing.expectEqualStrings("hej", batch.messages[1].text);
}

test "inbound message queue serializes per conversation key" {
    var queue = InboundMessageQueue.init(std.testing.allocator);
    defer queue.deinit(std.testing.allocator);

    {
        const text = try std.testing.allocator.dupe(u8, "a1");
        queue.enqueue(std.testing.allocator, .{
            .chat_id = 1,
            .thread_id = 10,
            .chat_kind = .group_like,
            .text = text,
        }) catch |err| {
            std.testing.allocator.free(text);
            return err;
        };
    }
    {
        const text = try std.testing.allocator.dupe(u8, "a2");
        queue.enqueue(std.testing.allocator, .{
            .chat_id = 1,
            .thread_id = 10,
            .chat_kind = .group_like,
            .text = text,
        }) catch |err| {
            std.testing.allocator.free(text);
            return err;
        };
    }

    const first = (try queue.take()).?;
    defer std.testing.allocator.free(first.text);
    try std.testing.expectEqual(@as(i64, 1), first.chat_id);
    try std.testing.expectEqual(@as(?i64, 10), first.thread_id);
    try std.testing.expectEqualStrings("a1", first.text);

    {
        const text = try std.testing.allocator.dupe(u8, "b1");
        queue.enqueue(std.testing.allocator, .{
            .chat_id = 2,
            .thread_id = 20,
            .chat_kind = .group_like,
            .text = text,
        }) catch |err| {
            std.testing.allocator.free(text);
            return err;
        };
    }

    const second = (try queue.take()).?;
    defer std.testing.allocator.free(second.text);
    try std.testing.expectEqual(@as(i64, 2), second.chat_id);
    try std.testing.expectEqual(@as(?i64, 20), second.thread_id);
    try std.testing.expectEqualStrings("b1", second.text);

    queue.complete(std.testing.allocator, .{ .chat_id = 2, .thread_id = 20 });
    queue.complete(std.testing.allocator, .{ .chat_id = 1, .thread_id = 10 });

    const third = (try queue.take()).?;
    defer std.testing.allocator.free(third.text);
    try std.testing.expectEqual(@as(i64, 1), third.chat_id);
    try std.testing.expectEqual(@as(?i64, 10), third.thread_id);
    try std.testing.expectEqualStrings("a2", third.text);

    queue.complete(std.testing.allocator, .{ .chat_id = 1, .thread_id = 10 });
}

test "inbound message queue returns null after shutdown" {
    var queue = InboundMessageQueue.init(std.testing.allocator);
    defer queue.deinit(std.testing.allocator);

    queue.shutdown();
    const next = try queue.take();
    try std.testing.expect(next == null);
}

test "nextMarkdownChunkBoundary keeps utf-8 boundaries" {
    const text = "abcådef";

    const first = nextMarkdownChunkBoundary(text, 0, 4);
    try std.testing.expectEqual(@as(usize, 3), first);

    const second = nextMarkdownChunkBoundary(text, first, 4);
    try std.testing.expectEqual(@as(usize, 7), second);

    const third = nextMarkdownChunkBoundary(text, second, 4);
    try std.testing.expectEqual(text.len, third);
}

test "nextMarkdownChunkBoundary limits escaped markdown size" {
    const text = "..a";
    const end = nextMarkdownChunkBoundary(text, 0, 4);
    try std.testing.expectEqual(@as(usize, 2), end);

    const markdown_chunk = try sanitizeTelegramMarkdownV2Chunk(std.testing.allocator, text[0..end]);
    defer std.testing.allocator.free(markdown_chunk);
    try std.testing.expect(markdown_chunk.len <= 4);
}

test "conversation store keeps separate history per chat and thread key" {
    var conversations = ConversationStore.init(std.testing.allocator);
    defer deinitConversationStore(std.testing.allocator, &conversations);

    const key_a: ConversationKey = .{ .chat_id = 111, .thread_id = 5 };
    const key_b: ConversationKey = .{ .chat_id = 111, .thread_id = 9 };
    const chat_1 = try getOrCreateConversation(&conversations, key_a);
    try chat_1.appendMessage(std.testing.allocator, .user, "hello");

    const chat_1_again = try getOrCreateConversation(&conversations, key_a);
    try std.testing.expectEqual(@as(usize, 1), chat_1_again.messages.items.len);
    try std.testing.expectEqual(openai_client.Role.user, chat_1_again.messages.items[0].role);
    try std.testing.expectEqualStrings("hello", chat_1_again.messages.items[0].content);

    const chat_2 = try getOrCreateConversation(&conversations, key_b);
    try std.testing.expectEqual(@as(usize, 0), chat_2.messages.items.len);
}

test "clearConversationForKey clears only target conversation key" {
    var conversations = ConversationStore.init(std.testing.allocator);
    defer deinitConversationStore(std.testing.allocator, &conversations);

    const key_1: ConversationKey = .{ .chat_id = 1, .thread_id = 11 };
    const key_2: ConversationKey = .{ .chat_id = 1, .thread_id = 22 };
    const chat_1 = try getOrCreateConversation(&conversations, key_1);
    try chat_1.appendMessage(std.testing.allocator, .user, "one");
    const chat_2 = try getOrCreateConversation(&conversations, key_2);
    try chat_2.appendMessage(std.testing.allocator, .user, "two");

    try std.testing.expect(clearConversationForKey(std.testing.allocator, &conversations, key_1));
    try std.testing.expect(!clearConversationForKey(std.testing.allocator, &conversations, key_1));

    try std.testing.expect(conversations.get(key_1) == null);
    const remaining = conversations.get(key_2) orelse unreachable;
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
    const payload = try buildChatActionPayload(std.testing.allocator, 42, null, "typing");
    defer std.testing.allocator.free(payload);

    try std.testing.expectEqualStrings(
        "{\"chat_id\":42,\"action\":\"typing\"}",
        payload,
    );
}

test "buildSendMessagePayload includes markdown parse mode" {
    const payload = try buildSendMessagePayload(
        std.testing.allocator,
        42,
        null,
        "*bold*",
        telegram_message_parse_mode,
    );
    defer std.testing.allocator.free(payload);

    try std.testing.expectEqualStrings(
        "{\"chat_id\":42,\"text\":\"*bold*\",\"parse_mode\":\"MarkdownV2\"}",
        payload,
    );
}

test "sanitizeTelegramMarkdownV2Chunk escapes markdown-v2 reserved characters" {
    const sanitized = try sanitizeTelegramMarkdownV2Chunk(
        std.testing.allocator,
        "*bold* `code.with.dots` [label](https://example.com/path)! browser_automate",
    );
    defer std.testing.allocator.free(sanitized);

    try std.testing.expectEqualStrings(
        "*bold* `code.with.dots` [label](https://example.com/path)\\! browser\\_automate",
        sanitized,
    );
}

test "sanitizeTelegramMarkdownV2Chunk escapes heading markers at line start" {
    const sanitized = try sanitizeTelegramMarkdownV2Chunk(
        std.testing.allocator,
        "# title\n## subtitle\n### section",
    );
    defer std.testing.allocator.free(sanitized);

    try std.testing.expectEqualStrings(
        "*title*\n*subtitle*\n*section*",
        sanitized,
    );
}

test "sanitizeTelegramMarkdownV2Chunk keeps inline link labels and escapes url parens" {
    const sanitized = try sanitizeTelegramMarkdownV2Chunk(
        std.testing.allocator,
        "[Article](https://en.wikipedia.org/wiki/Function_(mathematics))",
    );
    defer std.testing.allocator.free(sanitized);

    try std.testing.expectEqualStrings(
        "[Article](https://en.wikipedia.org/wiki/Function_\\(mathematics\\))",
        sanitized,
    );
}

test "sanitizeTelegramMarkdownV2Chunk preserves existing parenthesis escapes" {
    const sanitized = try sanitizeTelegramMarkdownV2Chunk(
        std.testing.allocator,
        "\\(already escaped\\) and (plain)",
    );
    defer std.testing.allocator.free(sanitized);

    try std.testing.expectEqualStrings(
        "\\(already escaped\\) and \\(plain\\)",
        sanitized,
    );
}

test "sanitizeTelegramMarkdownV2Chunk preserves existing escaped link-url parens" {
    const sanitized = try sanitizeTelegramMarkdownV2Chunk(
        std.testing.allocator,
        "[Article](https://example.com/wiki/Function_\\(mathematics\\))",
    );
    defer std.testing.allocator.free(sanitized);

    try std.testing.expectEqualStrings(
        "[Article](https://example.com/wiki/Function_\\(mathematics\\))",
        sanitized,
    );
}

test "sanitizeTelegramMarkdownV2Chunk keeps markdown-v2 style markers" {
    const sanitized = try sanitizeTelegramMarkdownV2Chunk(
        std.testing.allocator,
        "*fet* _kursiv_ ~overstruken~ __understruken__ ||spoiler||",
    );
    defer std.testing.allocator.free(sanitized);

    try std.testing.expectEqualStrings(
        "*fet* _kursiv_ ~overstruken~ __understruken__ ||spoiler||",
        sanitized,
    );
}

test "sanitizeTelegramMarkdownV2Chunk normalizes markdown double-tilde to telegram strikethrough" {
    const sanitized = try sanitizeTelegramMarkdownV2Chunk(
        std.testing.allocator,
        "~~legacy~~",
    );
    defer std.testing.allocator.free(sanitized);

    try std.testing.expectEqualStrings(
        "~legacy~",
        sanitized,
    );
}

test "sanitizeTelegramMarkdownV2Chunk keeps blockquote marker at line start" {
    const sanitized = try sanitizeTelegramMarkdownV2Chunk(
        std.testing.allocator,
        "> cited\nplain > text",
    );
    defer std.testing.allocator.free(sanitized);

    try std.testing.expectEqualStrings(
        "> cited\nplain \\> text",
        sanitized,
    );
}

test "sanitizeTelegramMarkdownV2Chunk escapes unmatched style markers" {
    const sanitized = try sanitizeTelegramMarkdownV2Chunk(
        std.testing.allocator,
        "~over _under ~~legacy",
    );
    defer std.testing.allocator.free(sanitized);

    try std.testing.expectEqualStrings(
        "\\~over \\_under \\~\\~legacy",
        sanitized,
    );
}

test "plainTelegramFallbackChunk removes markdown-v2 escapes" {
    const plain = try plainTelegramFallbackChunk(
        std.testing.allocator,
        "\\- item\n\\(paren\\) \\[label\\] and \\\\",
    );
    defer std.testing.allocator.free(plain);

    try std.testing.expectEqualStrings(
        "- item\n(paren) [label] and \\",
        plain,
    );
}

test "buildSendMessagePayload includes message thread when present" {
    const payload = try buildSendMessagePayload(
        std.testing.allocator,
        -100,
        123,
        "hello",
        telegram_message_parse_mode,
    );
    defer std.testing.allocator.free(payload);

    try std.testing.expectEqualStrings(
        "{\"chat_id\":-100,\"message_thread_id\":123,\"text\":\"hello\",\"parse_mode\":\"MarkdownV2\"}",
        payload,
    );
}

test "buildSendMessagePayload omits parse mode when null" {
    const payload = try buildSendMessagePayload(std.testing.allocator, 42, null, "hello", null);
    defer std.testing.allocator.free(payload);

    try std.testing.expectEqualStrings(
        "{\"chat_id\":42,\"text\":\"hello\"}",
        payload,
    );
}

test "buildMultipartFilePayload encodes chat and thread fields with binary file part" {
    var payload = try buildMultipartFilePayload(
        std.testing.allocator,
        "photo",
        -100,
        7,
        "screen\"shot.png",
        "image/png",
        &.{ 0x89, 'P', 'N', 'G' },
    );
    defer payload.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, payload.content_type_header, "multipart/form-data; boundary=zoid-") == 0);
    try std.testing.expect(std.mem.indexOf(u8, payload.body, "name=\"chat_id\"\r\n\r\n-100\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload.body, "name=\"message_thread_id\"\r\n\r\n7\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload.body, "name=\"photo\"; filename=\"screen_shot.png\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload.body, "Content-Type: image/png\r\n\r\n") != null);
    try std.testing.expect(std.mem.indexOfPos(u8, payload.body, 0, &.{ 0x89, 'P', 'N', 'G', '\r', '\n' }) != null);
}

test "guessPhotoContentType recognizes common image extensions" {
    try std.testing.expectEqualStrings("image/jpeg", guessPhotoContentType("shot.jpg"));
    try std.testing.expectEqualStrings("image/jpeg", guessPhotoContentType("shot.jpeg"));
    try std.testing.expectEqualStrings("image/webp", guessPhotoContentType("shot.webp"));
    try std.testing.expectEqualStrings("image/png", guessPhotoContentType("shot.png"));
    try std.testing.expectEqualStrings("image/png", guessPhotoContentType("shot.unknown"));
}

test "guessDocumentContentType recognizes common document extensions" {
    try std.testing.expectEqualStrings("application/pdf", guessDocumentContentType("report.pdf"));
    try std.testing.expectEqualStrings("text/plain", guessDocumentContentType("note.txt"));
    try std.testing.expectEqualStrings("application/json", guessDocumentContentType("data.json"));
    try std.testing.expectEqualStrings("application/octet-stream", guessDocumentContentType("archive.bin"));
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

    const key_a: ConversationKey = .{ .chat_id = 101, .thread_id = 10 };
    const key_b: ConversationKey = .{ .chat_id = 202, .thread_id = null };

    const chat_a = try getOrCreateConversation(&original, key_a);
    chat_a.last_user_message_at = 1_700_000_000;
    try chat_a.appendMessage(std.testing.allocator, .user, "hello");
    try chat_a.appendMessage(std.testing.allocator, .assistant, "world");

    const chat_b = try getOrCreateConversation(&original, key_b);
    chat_b.last_user_message_at = 1_700_000_123;
    try chat_b.appendMessage(std.testing.allocator, .user, "hej");

    try persistConversationStoreAtPath(std.testing.allocator, state_path, &original);

    var restored = ConversationStore.init(std.testing.allocator);
    defer deinitConversationStore(std.testing.allocator, &restored);
    try loadConversationStoreAtPath(
        std.testing.allocator,
        state_path,
        &restored,
        runtime_limits.default_telegram_max_conversation_messages,
    );

    try std.testing.expect(restored.get(key_a) != null);
    const restored_a = restored.get(key_a).?;
    try std.testing.expectEqual(@as(usize, 2), restored_a.messages.items.len);
    try std.testing.expectEqual(openai_client.Role.user, restored_a.messages.items[0].role);
    try std.testing.expectEqualStrings("hello", restored_a.messages.items[0].content);
    try std.testing.expectEqual(openai_client.Role.assistant, restored_a.messages.items[1].role);
    try std.testing.expectEqualStrings("world", restored_a.messages.items[1].content);
    try std.testing.expectEqual(@as(?i64, 1_700_000_000), restored_a.last_user_message_at);

    try std.testing.expect(restored.get(key_b) != null);
    const restored_b = restored.get(key_b).?;
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

    const max_messages = runtime_limits.default_telegram_max_conversation_messages;
    const overflow = max_messages + 3;
    for (0..overflow) |index| {
        const text = try std.fmt.allocPrint(std.testing.allocator, "m{d}", .{index});
        defer std.testing.allocator.free(text);
        try conversation.appendMessage(std.testing.allocator, .user, text);
    }

    enforceConversationLimit(&conversation, std.testing.allocator, max_messages);

    try std.testing.expectEqual(max_messages, conversation.messages.items.len);
    try std.testing.expectEqualStrings("m3", conversation.messages.items[0].content);
    const expected_last = try std.fmt.allocPrint(std.testing.allocator, "m{d}", .{max_messages + 2});
    defer std.testing.allocator.free(expected_last);
    try std.testing.expectEqualStrings(
        expected_last,
        conversation.messages.items[conversation.messages.items.len - 1].content,
    );
}

test "shouldResetConversationForInactivity honors 8-hour threshold" {
    var conversation = Conversation{};
    defer conversation.deinit(std.testing.allocator);
    const reset_seconds = runtime_limits.default_telegram_user_inactivity_reset_seconds;

    try std.testing.expect(!shouldResetConversationForInactivity(&conversation, 1_000, reset_seconds));

    conversation.last_user_message_at = 1_000;
    try std.testing.expect(!shouldResetConversationForInactivity(&conversation, 1_000 + reset_seconds - 1, reset_seconds));
    try std.testing.expect(shouldResetConversationForInactivity(&conversation, 1_000 + reset_seconds, reset_seconds));
}
