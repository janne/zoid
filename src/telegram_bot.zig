const std = @import("std");
const http_client = @import("http_client.zig");
const openai_client = @import("openai_client.zig");

pub const Settings = struct {
    bot_token: []const u8,
    openai_api_key: []const u8,
    openai_model: []const u8,
};

const max_poll_timeout_seconds: u16 = 50;
const max_poll_response_bytes: usize = 2 * 1024 * 1024;
const max_send_response_bytes: usize = 512 * 1024;
const max_telegram_message_bytes: usize = 4000;
const poll_backoff_ns: u64 = 3 * std.time.ns_per_s;
const typing_action_refresh_ns: u64 = 4 * std.time.ns_per_s;
const typing_action_sleep_step_ns: u64 = 200 * std.time.ns_per_ms;

const InboundMessage = struct {
    chat_id: i64,
    text: []u8,
};

const Conversation = struct {
    messages: std.ArrayList(openai_client.Message) = .empty,

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

    std.debug.print("Starting Telegram long-polling loop.\n", .{});

    var conversations = ConversationStore.init(allocator);
    defer deinitConversationStore(allocator, &conversations);

    var next_offset: i64 = 0;
    while (true) {
        var batch = fetchPollBatch(allocator, settings.bot_token, next_offset) catch |err| {
            std.debug.print("Telegram getUpdates failed: {s}\n", .{@errorName(err)});
            std.Thread.sleep(poll_backoff_ns);
            continue;
        };
        defer batch.deinit(allocator);

        next_offset = batch.next_offset;
        for (batch.messages) |message| {
            processInboundMessage(
                allocator,
                &conversations,
                settings.openai_api_key,
                settings.openai_model,
                settings.bot_token,
                message.chat_id,
                message.text,
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
    api_key: []const u8,
    model: []const u8,
    bot_token: []const u8,
    chat_id: i64,
    raw_text: []const u8,
) !void {
    const prompt = std.mem.trim(u8, raw_text, " \t\r\n");
    if (prompt.len == 0) {
        try sendMessageInChunks(allocator, bot_token, chat_id, "Please send a non-empty message.");
        return;
    }

    if (isResetCommand(prompt)) {
        _ = clearConversationForChat(allocator, conversations, chat_id);
        try sendMessageInChunks(
            allocator,
            bot_token,
            chat_id,
            "Started a new session. Previous context cleared.",
        );
        return;
    }

    const conversation = try getOrCreateConversation(conversations, chat_id);
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

    const reply = try openai_client.fetchAssistantReply(
        allocator,
        api_key,
        model,
        conversation.messages.items,
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
    conversation_turn_committed = true;
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

fn fetchPollBatch(
    allocator: std.mem.Allocator,
    bot_token: []const u8,
    current_offset: i64,
) !PollBatch {
    const uri = try std.fmt.allocPrint(
        allocator,
        "https://api.telegram.org/bot{s}/getUpdates",
        .{bot_token},
    );
    defer allocator.free(uri);

    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"offset\":{d},\"timeout\":{d},\"allowed_updates\":[\"message\"]}}",
        .{ current_offset, max_poll_timeout_seconds },
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

        const message = switch (update.get("message") orelse continue) {
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

        try messages.append(allocator, .{
            .chat_id = chat_id,
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

    const escaped_text = try std.json.Stringify.valueAlloc(allocator, text, .{});
    defer allocator.free(escaped_text);

    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"chat_id\":{d},\"text\":{s}}}",
        .{ chat_id, escaped_text },
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
        max_send_response_bytes,
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

test "parsePollBatch extracts text messages and advances offset" {
    const response =
        \\{"ok":true,"result":[
        \\{"update_id":10,"message":{"chat":{"id":111},"text":"hello"}},
        \\{"update_id":11,"message":{"chat":{"id":111}}},
        \\{"update_id":12,"message":{"chat":{"id":222},"text":"hej"}}
        \\]}
    ;

    var batch = try parsePollBatch(std.testing.allocator, response, 0);
    defer batch.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i64, 13), batch.next_offset);
    try std.testing.expectEqual(@as(usize, 2), batch.messages.len);
    try std.testing.expectEqual(@as(i64, 111), batch.messages[0].chat_id);
    try std.testing.expectEqualStrings("hello", batch.messages[0].text);
    try std.testing.expectEqual(@as(i64, 222), batch.messages[1].chat_id);
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
