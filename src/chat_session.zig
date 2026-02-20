const std = @import("std");
const openai_client = @import("openai_client.zig");
const vaxis = @import("vaxis");

const max_input_len: usize = 16 * 1024;

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
    tick,
};

const DisplayRole = enum {
    user,
    assistant,
    @"error",
};

const DisplayEntry = struct {
    role: DisplayRole,
    text: []u8,
};

const LineRange = struct {
    start: usize,
    end: usize,
};

const RequestState = struct {
    mutex: std.Thread.Mutex = .{},
    done: bool = false,
    reply: ?[]u8 = null,
    error_text: ?[]u8 = null,
};

const RequestWorkerArgs = struct {
    state: *RequestState,
    api_key: []const u8,
    model: []const u8,
    messages: []openai_client.Message,
};

const UiTicker = struct {
    loop: *vaxis.Loop(Event),
    stop_flag: *std.atomic.Value(bool),
    active_flag: *std.atomic.Value(bool),
};

pub fn run(allocator: std.mem.Allocator, api_key: []const u8, model: []const u8) !void {
    return runFullscreen(allocator, api_key, model);
}

fn runFullscreen(allocator: std.mem.Allocator, api_key: []const u8, model: []const u8) !void {
    var tty_buffer: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(&tty_buffer);
    defer tty.deinit();

    var vx = try vaxis.init(allocator, .{
        .kitty_keyboard_flags = .{ .report_events = true },
    });
    defer vx.deinit(allocator, tty.writer());

    var loop: vaxis.Loop(Event) = .{
        .tty = &tty,
        .vaxis = &vx,
    };
    try loop.init();
    try loop.start();
    defer loop.stop();

    var ticker_stop = std.atomic.Value(bool).init(false);
    var ticker_active = std.atomic.Value(bool).init(false);
    var ticker_ctx = UiTicker{
        .loop = &loop,
        .stop_flag = &ticker_stop,
        .active_flag = &ticker_active,
    };
    var ticker_thread = try std.Thread.spawn(.{}, tickerRun, .{&ticker_ctx});
    defer {
        ticker_stop.store(true, .release);
        ticker_thread.join();
    }

    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), 1 * std.time.ns_per_s);

    var input = vaxis.widgets.TextInput.init(allocator);
    defer input.deinit();

    var conversation = std.ArrayList(openai_client.Message).empty;
    defer {
        for (conversation.items) |message| {
            allocator.free(message.content);
        }
        conversation.deinit(allocator);
    }

    var transcript = std.ArrayList(DisplayEntry).empty;
    defer {
        for (transcript.items) |entry| {
            allocator.free(entry.text);
        }
        transcript.deinit(allocator);
    }

    var pending = false;
    var spinner_frame: usize = 0;
    var pending_thread: ?std.Thread = null;
    defer if (pending_thread) |thread| thread.join();
    var request_state: RequestState = .{};
    var status_text: ?[]const u8 = null;
    const cwd = std.process.getCwdAlloc(allocator) catch null;
    defer if (cwd) |value| allocator.free(value);
    var render_input_buffer = std.ArrayList(u8).empty;
    defer render_input_buffer.deinit(allocator);
    var wrapped_input_lines = std.ArrayList(LineRange).empty;
    defer wrapped_input_lines.deinit(allocator);

    loop: while (true) {
        if (pending and try harvestCompletedRequest(allocator, &request_state, &pending_thread, &conversation, &transcript, &pending, &status_text, &ticker_active)) {
            // Request finished, render immediately with fresh transcript state.
        }

        const event = loop.nextEvent();
        switch (event) {
            .winsize => |ws| {
                try vx.resize(allocator, tty.writer(), ws);
            },
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) break :loop;
                if (key.matches(vaxis.Key.escape, .{})) break :loop;
                if (key.matches('l', .{ .ctrl = true })) vx.queueRefresh();

                if (key.matches(vaxis.Key.enter, .{}) or key.matches('j', .{ .ctrl = true })) {
                    if (pending) continue;

                    const line_owned = try input.toOwnedSlice();
                    defer allocator.free(line_owned);

                    const prompt = std.mem.trim(u8, line_owned, " \t\r\n");
                    if (prompt.len == 0) {
                        status_text = "";
                    } else if (prompt.len > max_input_len) {
                        status_text = "Input line is too long.";
                    } else if (isExitCommand(prompt)) {
                        break :loop;
                    } else {
                        try appendConversationMessage(allocator, &conversation, .user, prompt);
                        try appendTranscriptEntry(allocator, &transcript, .user, prompt);

                        request_state.mutex.lock();
                        request_state.done = false;
                        request_state.reply = null;
                        request_state.error_text = null;
                        request_state.mutex.unlock();

                        const snapshot = try cloneMessagesForWorker(conversation.items);
                        errdefer freeWorkerMessages(snapshot);

                        const args = try std.heap.c_allocator.create(RequestWorkerArgs);
                        errdefer std.heap.c_allocator.destroy(args);
                        args.* = .{
                            .state = &request_state,
                            .api_key = api_key,
                            .model = model,
                            .messages = snapshot,
                        };

                        pending_thread = try std.Thread.spawn(.{}, requestWorkerMain, .{args});
                        pending = true;
                        spinner_frame = 0;
                        ticker_active.store(true, .unordered);
                        status_text = "Waiting for assistant response...";
                    }
                } else {
                    try input.update(.{ .key_press = key });
                }
            },
            .tick => {
                if (pending) {
                    spinner_frame +%= 1;
                    if (spinner_frame >= spinnerFrames.len) spinner_frame = 0;
                }
            },
            else => {},
        }

        if (pending and try harvestCompletedRequest(allocator, &request_state, &pending_thread, &conversation, &transcript, &pending, &status_text, &ticker_active)) {
            spinner_frame = 0;
        }

        try renderScreen(
            allocator,
            &render_input_buffer,
            &wrapped_input_lines,
            &vx,
            &input,
            transcript.items,
            model,
            pending,
            spinner_frame,
            status_text,
            cwd,
        );
        try vx.render(tty.writer());
    }

    ticker_active.store(false, .release);
    if (pending_thread) |thread| {
        thread.join();
        pending_thread = null;
    }
    request_state.mutex.lock();
    if (request_state.reply) |reply| {
        std.heap.c_allocator.free(reply);
        request_state.reply = null;
    }
    if (request_state.error_text) |err| {
        std.heap.c_allocator.free(err);
        request_state.error_text = null;
    }
    request_state.done = false;
    request_state.mutex.unlock();
}

fn appendConversationMessage(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(openai_client.Message),
    role: openai_client.Role,
    text: []const u8,
) !void {
    const copy = try allocator.dupe(u8, text);
    errdefer allocator.free(copy);
    try list.append(allocator, .{
        .role = role,
        .content = copy,
    });
}

fn appendTranscriptEntry(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(DisplayEntry),
    role: DisplayRole,
    text: []const u8,
) !void {
    const copy = try allocator.dupe(u8, text);
    errdefer allocator.free(copy);
    try list.append(allocator, .{
        .role = role,
        .text = copy,
    });
}

const spinnerFrames = [_][]const u8{
    "[=    ]",
    "[==   ]",
    "[===  ]",
    "[ === ]",
    "[  ===]",
    "[   ==]",
    "[    =]",
    "[   ==]",
    "[  ===]",
    "[ === ]",
};

fn tickerRun(ctx: *UiTicker) void {
    while (!ctx.stop_flag.load(.unordered)) {
        if (ctx.active_flag.load(.unordered)) {
            _ = ctx.loop.tryPostEvent(.tick);
        }
        std.Thread.sleep(120 * std.time.ns_per_ms);
    }
}

fn cloneMessagesForWorker(messages: []const openai_client.Message) ![]openai_client.Message {
    const alloc = std.heap.c_allocator;
    const copy = try alloc.alloc(openai_client.Message, messages.len);
    errdefer alloc.free(copy);

    var i: usize = 0;
    errdefer {
        for (copy[0..i]) |message| {
            alloc.free(message.content);
        }
    }

    for (messages, 0..) |message, idx| {
        copy[idx] = .{
            .role = message.role,
            .content = try alloc.dupe(u8, message.content),
        };
        i += 1;
    }

    return copy;
}

fn freeWorkerMessages(messages: []openai_client.Message) void {
    const alloc = std.heap.c_allocator;
    for (messages) |message| {
        alloc.free(message.content);
    }
    alloc.free(messages);
}

fn requestWorkerMain(args: *RequestWorkerArgs) void {
    defer {
        freeWorkerMessages(args.messages);
        std.heap.c_allocator.destroy(args);
    }

    const maybe_reply = openai_client.fetchAssistantReply(
        std.heap.c_allocator,
        args.api_key,
        args.model,
        args.messages,
    ) catch |err| {
        const err_text = std.fmt.allocPrint(
            std.heap.c_allocator,
            "OpenAI error: {s}",
            .{@errorName(err)},
        ) catch null;

        args.state.mutex.lock();
        args.state.reply = null;
        args.state.error_text = err_text;
        args.state.done = true;
        args.state.mutex.unlock();
        return;
    };

    args.state.mutex.lock();
    args.state.reply = maybe_reply;
    args.state.error_text = null;
    args.state.done = true;
    args.state.mutex.unlock();
}

fn harvestCompletedRequest(
    allocator: std.mem.Allocator,
    state: *RequestState,
    pending_thread: *?std.Thread,
    conversation: *std.ArrayList(openai_client.Message),
    transcript: *std.ArrayList(DisplayEntry),
    pending: *bool,
    status_text: *?[]const u8,
    ticker_active: *std.atomic.Value(bool),
) !bool {
    if (!pending.*) return false;

    var done = false;
    var reply: ?[]u8 = null;
    var error_text: ?[]u8 = null;

    state.mutex.lock();
    if (state.done) {
        done = true;
        reply = state.reply;
        error_text = state.error_text;
        state.reply = null;
        state.error_text = null;
        state.done = false;
    }
    state.mutex.unlock();

    if (!done) return false;

    if (pending_thread.*) |thread| {
        thread.join();
        pending_thread.* = null;
    }

    pending.* = false;
    ticker_active.store(false, .unordered);

    if (error_text) |err| {
        defer std.heap.c_allocator.free(err);
        try appendTranscriptEntry(allocator, transcript, .@"error", err);
        status_text.* = "Request failed. Check API key/network and try again.";
        return true;
    }

    if (reply) |assistant_reply| {
        defer std.heap.c_allocator.free(assistant_reply);
        try appendConversationMessage(allocator, conversation, .assistant, assistant_reply);
        try appendTranscriptEntry(allocator, transcript, .assistant, assistant_reply);
        status_text.* = "";
        return true;
    }

    status_text.* = "";
    return true;
}

fn renderScreen(
    allocator: std.mem.Allocator,
    render_input_buffer: *std.ArrayList(u8),
    wrapped_input_lines: *std.ArrayList(LineRange),
    vx: *vaxis.Vaxis,
    input: *vaxis.widgets.TextInput,
    transcript: []const DisplayEntry,
    model: []const u8,
    pending: bool,
    spinner_frame: usize,
    status_text: ?[]const u8,
    cwd: ?[]const u8,
) !void {
    _ = status_text;
    const bg_main: u8 = 233;
    const bg_panel: u8 = 235;
    const accent_fg: u8 = 141;

    const root = vx.window();
    root.clear();

    if (root.width == 0 or root.height == 0) return;

    const background_cell: vaxis.Cell = .{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = .{ .bg = .{ .index = bg_main } },
    };
    root.fill(background_cell);

    const input_text = try collectInputBytes(allocator, render_input_buffer, input);
    const cursor_byte = input.byteOffsetToCursor();

    const margin_x: u16 = if (root.width > 8) 2 else 0;
    const frame_width: u16 = root.width -| (margin_x * 2);

    const footer_reserved: u16 = 2;

    const input_text_cols: u16 = @max(@as(u16, 1), frame_width -| 4);
    try wrapSoftWords(allocator, wrapped_input_lines, input_text, input_text_cols);

    const total_input_rows: u16 = @intCast(wrapped_input_lines.items.len);
    const max_input_rows: u16 = 8;

    const top_content_start: u16 = 1;
    const available_rows_for_input: u16 = if (root.height > top_content_start + footer_reserved + 4)
        root.height - top_content_start - footer_reserved - 3
    else
        1;

    const visible_input_rows: u16 = @max(
        @as(u16, 1),
        @min(total_input_rows, @min(max_input_rows, available_rows_for_input)),
    );

    // Composer height = metadata row + top pad + input rows + bottom pad.
    const input_outer_height: u16 = visible_input_rows + 3;
    const input_y: u16 = root.height -| footer_reserved -| input_outer_height;

    if (input_y > top_content_start) {
        const body_box = root.child(.{
            .x_off = @intCast(margin_x),
            .y_off = @intCast(top_content_start),
            .width = frame_width,
            .height = input_y - top_content_start,
        });

        body_box.fill(.{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = .{ .bg = .{ .index = bg_main } },
        });

        const transcript_area = body_box.child(.{
            .x_off = 1,
            .y_off = 0,
            .width = body_box.width -| 1,
            .height = body_box.height,
        });
        drawTranscript(transcript_area, transcript);
    }

    const input_box = root.child(.{
        .x_off = @intCast(margin_x),
        .y_off = @intCast(input_y),
        .width = frame_width,
        .height = input_outer_height,
    });
    input_box.fill(.{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = .{ .bg = .{ .index = bg_panel } },
    });
    drawLeftAccent(input_box, bg_panel, accent_fg);

    const row_offset: u16 = if (total_input_rows > visible_input_rows) total_input_rows - visible_input_rows else 0;
    // Keep metadata on first line, then an empty padding line before input.
    const meta_row: u16 = 0;
    const input_start_row: u16 = 2;

    const meta_segments = [_]vaxis.Segment{
        .{ .text = "Build", .style = .{ .fg = .{ .index = 183 }, .bg = .{ .index = bg_panel } } },
        .{ .text = "  ", .style = .{ .bg = .{ .index = bg_panel } } },
        .{ .text = model, .style = .{ .fg = .{ .index = 189 }, .bg = .{ .index = bg_panel } } },
        .{ .text = "  OpenAI", .style = .{ .fg = .{ .index = 147 }, .bg = .{ .index = bg_panel } } },
    };
    _ = input_box.print(&meta_segments, .{ .row_offset = meta_row, .col_offset = 2, .wrap = .none });

    renderWrappedInput(
        input_box,
        wrapped_input_lines.items,
        input_text,
        row_offset,
        visible_input_rows,
        input_start_row,
        bg_panel,
    );
    const cursor = locateCursorSoftWrapped(wrapped_input_lines.items, input_text, cursor_byte);
    if (cursor.line >= row_offset and cursor.line < row_offset + visible_input_rows) {
        const cursor_row: u16 = input_start_row + @as(u16, @intCast(cursor.line - row_offset));
        const cursor_col: u16 = @min(
            2 + @as(u16, @intCast(cursor.col)),
            input_box.width -| 1,
        );
        input_box.showCursor(cursor_col, cursor_row);
    } else {
        input_box.hideCursor();
    }

    if (pending) {
        const spinner = spinnerFrames[spinner_frame % spinnerFrames.len];
        const pending_segments = [_]vaxis.Segment{
            .{ .text = spinner, .style = .{ .fg = .{ .index = 183 }, .bg = .{ .index = bg_main } } },
            .{ .text = "  waiting for reply", .style = .{ .fg = .{ .index = 180 }, .bg = .{ .index = bg_main } } },
        };
        _ = root.print(&pending_segments, .{
            .row_offset = root.height -| 2,
            .col_offset = 1,
            .wrap = .none,
        });
    }

    const shortcuts = "ctrl+t variants  tab agents  ctrl+p commands";
    const shortcuts_col: u16 = if (root.width > shortcuts.len + 2)
        @intCast(root.width - shortcuts.len - 2)
    else
        0;
    const shortcut_segments = [_]vaxis.Segment{
        .{ .text = shortcuts, .style = .{ .fg = .{ .index = 146 }, .bg = .{ .index = bg_main } } },
    };
    _ = root.print(&shortcut_segments, .{
        .row_offset = root.height -| 2,
        .col_offset = shortcuts_col,
        .wrap = .none,
    });

    if (cwd) |path| {
        const cwd_segments = [_]vaxis.Segment{
            .{ .text = path, .style = .{ .fg = .{ .index = 103 }, .bg = .{ .index = bg_main } } },
        };
        _ = root.print(&cwd_segments, .{
            .row_offset = root.height -| 1,
            .col_offset = 1,
            .wrap = .none,
        });
    }

    const version_segments = [_]vaxis.Segment{
        .{ .text = "0.1.0", .style = .{ .fg = .{ .index = 103 }, .bg = .{ .index = bg_main } } },
    };
    _ = root.print(&version_segments, .{
        .row_offset = root.height -| 1,
        .col_offset = root.width -| 6,
        .wrap = .none,
    });
}

fn collectInputBytes(
    allocator: std.mem.Allocator,
    render_input_buffer: *std.ArrayList(u8),
    input: *const vaxis.widgets.TextInput,
) ![]const u8 {
    const before = input.buf.firstHalf();
    const after = input.buf.secondHalf();

    const total_len = before.len + after.len;
    render_input_buffer.clearRetainingCapacity();
    try render_input_buffer.ensureTotalCapacity(allocator, total_len);
    try render_input_buffer.appendSlice(allocator, before);
    try render_input_buffer.appendSlice(allocator, after);
    return render_input_buffer.items;
}

fn drawLeftAccent(win: vaxis.Window, bg_index: u8, fg_index: u8) void {
    const accent: vaxis.Cell = .{
        .char = .{ .grapheme = "│", .width = 1 },
        .style = .{ .fg = .{ .index = fg_index }, .bg = .{ .index = bg_index } },
    };

    var row: u16 = 0;
    while (row < win.height) : (row += 1) {
        win.writeCell(0, row, accent);
    }
}

fn wrapSoftWords(
    allocator: std.mem.Allocator,
    lines: *std.ArrayList(LineRange),
    text: []const u8,
    width: u16,
) !void {
    lines.clearRetainingCapacity();

    if (width == 0 or text.len == 0) {
        try lines.append(allocator, .{ .start = 0, .end = 0 });
        return;
    }

    const max_cols: usize = width;

    var start: usize = 0;
    var i: usize = 0;
    var col: usize = 0;
    var last_break: ?usize = null;

    while (i < text.len) {
        const byte = text[i];
        const char_len = utf8SeqLen(text, i);

        if (byte == '\n') {
            try lines.append(allocator, .{ .start = start, .end = i });
            i += 1;
            start = i;
            col = 0;
            last_break = null;
            continue;
        }

        if (byte == ' ' or byte == '\t') {
            last_break = i + 1;
        }

        col += 1;
        if (col > max_cols) {
            if (last_break) |break_idx| {
                if (break_idx > start) {
                    try lines.append(allocator, .{ .start = start, .end = break_idx });
                    start = break_idx;
                    i = break_idx;
                    col = 0;
                    last_break = null;
                    continue;
                }
            }

            try lines.append(allocator, .{ .start = start, .end = i });
            start = i;
            col = 0;
            last_break = null;
            continue;
        }

        i += char_len;
    }

    try lines.append(allocator, .{ .start = start, .end = text.len });
    if (lines.items.len == 0) {
        try lines.append(allocator, .{ .start = 0, .end = 0 });
    }
}

const CursorLineCol = struct {
    line: usize,
    col: usize,
};

fn locateCursorSoftWrapped(lines: []const LineRange, text: []const u8, cursor_byte: usize) CursorLineCol {
    if (lines.len == 0) return .{ .line = 0, .col = 0 };
    const safe_cursor = @min(cursor_byte, text.len);

    for (lines, 0..) |line, idx| {
        if (safe_cursor >= line.start and safe_cursor <= line.end) {
            return .{
                .line = idx,
                .col = countDisplayCols(text, line.start, safe_cursor),
            };
        }
    }

    const last = lines[lines.len - 1];
    const end_col = @min(safe_cursor, last.end);
    return .{
        .line = lines.len - 1,
        .col = countDisplayCols(text, last.start, end_col),
    };
}

fn utf8SeqLen(text: []const u8, i: usize) usize {
    if (i >= text.len) return 0;
    const len = std.unicode.utf8ByteSequenceLength(text[i]) catch return 1;
    const n: usize = @intCast(len);
    if (i + n > text.len) return 1;
    return n;
}

fn countDisplayCols(text: []const u8, start: usize, end: usize) usize {
    var i = @min(start, text.len);
    const target = @min(end, text.len);
    var cols: usize = 0;

    while (i < target) {
        const n = @min(utf8SeqLen(text, i), target - i);
        i += if (n == 0) 1 else n;
        cols += 1;
    }
    return cols;
}

fn renderWrappedInput(
    input_box: vaxis.Window,
    lines: []const LineRange,
    text: []const u8,
    row_offset: u16,
    visible_rows: u16,
    start_row: u16,
    bg_index: u8,
) void {
    var vis_row: u16 = 0;
    while (vis_row < visible_rows) : (vis_row += 1) {
        const line_index: usize = @as(usize, row_offset) + @as(usize, vis_row);
        if (line_index >= lines.len) break;

        const range = lines[line_index];
        const slice = text[range.start..range.end];
        const segments = [_]vaxis.Segment{
            .{ .text = slice, .style = .{ .fg = .{ .index = 255 }, .bg = .{ .index = bg_index } } },
        };
        _ = input_box.print(&segments, .{
            .row_offset = start_row + vis_row,
            .col_offset = 2,
            .wrap = .none,
        });
    }
}

fn drawTranscript(win: vaxis.Window, transcript: []const DisplayEntry) void {
    if (win.width == 0 or win.height == 0) return;

    const start = visibleTranscriptStart(transcript, win.width, win.height);
    var row: u16 = 0;
    const bg_main: u8 = 233;
    const bg_panel: u8 = 235;
    const accent_fg: u8 = 141;

    for (transcript[start..]) |entry| {
        if (row >= win.height) break;

        if (entry.role == .user) {
            const text_width: u16 = if (win.width > 3) win.width - 3 else 1;
            const text_rows = @as(u16, @intCast(estimateRows(text_width, "", entry.text)));
            const block_height: u16 = text_rows + 2;
            if (row + block_height > win.height) break;

            const block = win.child(.{
                .x_off = 0,
                .y_off = row,
                .width = win.width,
                .height = block_height,
            });
            block.fill(.{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = .{ .bg = .{ .index = bg_panel } },
            });
            drawLeftAccent(block, bg_panel, accent_fg);

            const text_win = block.child(.{
                .x_off = 2,
                .y_off = 1,
                .width = text_width,
                .height = text_rows,
            });
            const user_segments = [_]vaxis.Segment{
                .{ .text = entry.text, .style = .{ .fg = .{ .index = 251 }, .bg = .{ .index = bg_panel } } },
            };
            _ = text_win.print(&user_segments, .{
                .row_offset = 0,
                .col_offset = 0,
                .wrap = .word,
            });

            row += block_height;
            if (row < win.height) row +|= 1;
            continue;
        }

        const role_style: vaxis.Style = switch (entry.role) {
            .user => unreachable,
            .assistant => .{ .fg = .{ .index = 116 }, .bg = .{ .index = bg_main } },
            .@"error" => .{ .fg = .{ .index = 203 }, .bg = .{ .index = bg_main } },
        };

        const body_style: vaxis.Style = switch (entry.role) {
            .@"error" => .{ .fg = .{ .index = 203 }, .bg = .{ .index = bg_main } },
            else => .{ .fg = .{ .index = 251 }, .bg = .{ .index = bg_main } },
        };

        const segments = [_]vaxis.Segment{
            .{ .text = rolePrefix(entry.role), .style = role_style },
            .{ .text = entry.text, .style = body_style },
        };

        const result = win.print(&segments, .{
            .row_offset = row,
            .col_offset = 0,
            .wrap = .word,
        });

        row = result.row;
        if (result.col > 0) row +|= 1;
        if (row < win.height) row +|= 1;
    }
}

fn rolePrefix(role: DisplayRole) []const u8 {
    return switch (role) {
        .user => "",
        .assistant => "",
        .@"error" => "error> ",
    };
}

fn visibleTranscriptStart(entries: []const DisplayEntry, width: u16, height: u16) usize {
    if (entries.len == 0 or width == 0 or height == 0) return entries.len;

    var used_rows: u32 = 0;
    var i = entries.len;

    while (i > 0) {
        i -= 1;

        const rows_needed = estimateEntryRows(entries[i], width) + 1;
        if (used_rows + rows_needed > height) return i + 1;

        used_rows += rows_needed;
    }

    return 0;
}

fn estimateEntryRows(entry: DisplayEntry, width: u16) u32 {
    if (width == 0) return 0;

    return switch (entry.role) {
        .user => blk: {
            const text_width: u16 = if (width > 3) width - 3 else 1;
            break :blk estimateRows(text_width, "", entry.text) + 2;
        },
        else => estimateRows(width, rolePrefix(entry.role), entry.text),
    };
}

fn estimateRows(width: u16, prefix: []const u8, text: []const u8) u32 {
    if (width == 0) return 0;

    var rows: u32 = 1;
    var col: u16 = 0;

    const countBytes = struct {
        fn run(width_: u16, rows_: *u32, col_: *u16, bytes: []const u8) void {
            for (bytes) |byte| {
                if (byte == '\n') {
                    rows_.* += 1;
                    col_.* = 0;
                    continue;
                }

                col_.* +|= 1;
                if (col_.* >= width_) {
                    rows_.* += 1;
                    col_.* = 0;
                }
            }
        }
    };

    countBytes.run(width, &rows, &col, prefix);
    countBytes.run(width, &rows, &col, text);

    return rows;
}

fn isExitCommand(input: []const u8) bool {
    return std.mem.eql(u8, input, "/exit") or std.mem.eql(u8, input, "/quit");
}

test "isExitCommand recognizes exit commands" {
    try std.testing.expect(isExitCommand("/exit"));
    try std.testing.expect(isExitCommand("/quit"));
    try std.testing.expect(!isExitCommand("exit"));
}

test "visibleTranscriptStart picks latest entries that fit" {
    const entries = [_]DisplayEntry{
        .{ .role = .user, .text = @constCast("short") },
        .{ .role = .assistant, .text = @constCast("this is longer and wraps") },
        .{ .role = .assistant, .text = @constCast("tail") },
    };

    const idx = visibleTranscriptStart(&entries, 10, 4);
    try std.testing.expect(idx >= 1);
    try std.testing.expect(idx <= 2);
}

test "wrapSoftWords counts utf8 codepoints for width" {
    var lines = std.ArrayList(LineRange).empty;
    defer lines.deinit(std.testing.allocator);

    const text = "åäöx";
    try wrapSoftWords(std.testing.allocator, &lines, text, 3);

    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    try std.testing.expectEqualStrings("åäö", text[lines.items[0].start..lines.items[0].end]);
    try std.testing.expectEqualStrings("x", text[lines.items[1].start..lines.items[1].end]);
}

test "locateCursorSoftWrapped returns utf8-aware cursor column" {
    var lines = std.ArrayList(LineRange).empty;
    defer lines.deinit(std.testing.allocator);

    const text = "åäöx";
    try wrapSoftWords(std.testing.allocator, &lines, text, 3);

    const cursor = locateCursorSoftWrapped(lines.items, text, "åäö".len);
    try std.testing.expectEqual(@as(usize, 1), cursor.line);
    try std.testing.expectEqual(@as(usize, 0), cursor.col);
}
