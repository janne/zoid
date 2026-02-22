const std = @import("std");
const config_keys = @import("config_keys.zig");
const config_runtime = @import("config_runtime.zig");
const cron_adapter = @import("cron_adapter.zig");
const scheduler_store = @import("scheduler_store.zig");
const workspace_fs = @import("workspace_fs.zig");

pub const Context = struct {
    workspace_root: []const u8,
    request_chat_id: ?i64 = null,
    config_path_override: ?[]const u8 = null,
};

pub const CreateRequest = struct {
    job_type: scheduler_store.JobType,
    path: []const u8,
    run_at: ?[]const u8 = null,
    cron: ?[]const u8 = null,
    chat_id: ?i64 = null,
};

pub const DueJob = struct {
    job: scheduler_store.Job,
    scheduled_for: i64,

    pub fn deinit(self: *DueJob, allocator: std.mem.Allocator) void {
        self.job.deinit(allocator);
    }
};

pub fn deinitDueJobs(allocator: std.mem.Allocator, due_jobs: []DueJob) void {
    for (due_jobs) |*due_job| due_job.deinit(allocator);
    allocator.free(due_jobs);
}

pub fn createJob(allocator: std.mem.Allocator, context: Context, request: CreateRequest) !scheduler_store.Job {
    const has_run_at = request.run_at != null;
    const has_cron = request.cron != null;
    if (has_run_at == has_cron) return error.InvalidSchedule;

    const resolved_path = try workspace_fs.resolveAllowedReadPath(
        allocator,
        context.workspace_root,
        request.path,
    );
    errdefer allocator.free(resolved_path);

    try validateJobPath(request.job_type, resolved_path);

    const now = std.time.timestamp();

    var run_at_epoch: ?i64 = null;
    var cron_text: ?[]u8 = null;
    var next_run_at: i64 = undefined;

    if (request.run_at) |run_at_text| {
        const parsed = try parseRfc3339ToEpoch(run_at_text);
        run_at_epoch = parsed;
        next_run_at = parsed;
    } else if (request.cron) |cron_value| {
        _ = try cron_adapter.parseCronExpression(cron_value);
        next_run_at = (try cron_adapter.nextRunAt(cron_value, now - 60)) orelse return error.InvalidSchedule;
        cron_text = try allocator.dupe(u8, cron_value);
    } else {
        unreachable;
    }

    const chat_id = try resolveChatId(allocator, context, request.chat_id);

    var lock = try scheduler_store.acquireLock(allocator, context.workspace_root);
    defer lock.release(allocator);

    const loaded_jobs = try scheduler_store.loadJobs(allocator, context.workspace_root);
    var jobs = std.ArrayList(scheduler_store.Job).fromOwnedSlice(loaded_jobs);
    defer {
        for (jobs.items) |*job| job.deinit(allocator);
        jobs.deinit(allocator);
    }

    const id = try generateJobId(allocator);

    const new_job: scheduler_store.Job = .{
        .id = id,
        .job_type = request.job_type,
        .path = resolved_path,
        .chat_id = chat_id,
        .paused = false,
        .run_at = run_at_epoch,
        .cron = cron_text,
        .next_run_at = next_run_at,
        .created_at = now,
        .updated_at = now,
        .last_run_at = null,
    };

    try jobs.append(allocator, new_job);
    try scheduler_store.saveJobs(allocator, context.workspace_root, jobs.items);

    return jobs.items[jobs.items.len - 1].clone(allocator);
}

pub fn listJobs(allocator: std.mem.Allocator, context: Context) ![]scheduler_store.Job {
    var lock = try scheduler_store.acquireLock(allocator, context.workspace_root);
    defer lock.release(allocator);

    return scheduler_store.loadJobs(allocator, context.workspace_root);
}

pub fn deleteJob(allocator: std.mem.Allocator, context: Context, job_id: []const u8) !bool {
    var lock = try scheduler_store.acquireLock(allocator, context.workspace_root);
    defer lock.release(allocator);

    const loaded_jobs = try scheduler_store.loadJobs(allocator, context.workspace_root);
    var jobs = std.ArrayList(scheduler_store.Job).fromOwnedSlice(loaded_jobs);
    defer {
        for (jobs.items) |*job| job.deinit(allocator);
        jobs.deinit(allocator);
    }

    var index: usize = 0;
    while (index < jobs.items.len) : (index += 1) {
        if (std.mem.eql(u8, jobs.items[index].id, job_id)) {
            var removed = jobs.orderedRemove(index);
            removed.deinit(allocator);
            try scheduler_store.saveJobs(allocator, context.workspace_root, jobs.items);
            return true;
        }
    }

    return false;
}

pub fn pauseJob(allocator: std.mem.Allocator, context: Context, job_id: []const u8) !bool {
    return updatePausedState(allocator, context, job_id, true);
}

pub fn resumeJob(allocator: std.mem.Allocator, context: Context, job_id: []const u8) !bool {
    return updatePausedState(allocator, context, job_id, false);
}

pub fn takeDueJobs(allocator: std.mem.Allocator, context: Context, now: i64) ![]DueJob {
    var lock = try scheduler_store.acquireLock(allocator, context.workspace_root);
    defer lock.release(allocator);

    const loaded_jobs = try scheduler_store.loadJobs(allocator, context.workspace_root);
    var jobs = std.ArrayList(scheduler_store.Job).fromOwnedSlice(loaded_jobs);
    defer {
        for (jobs.items) |*job| job.deinit(allocator);
        jobs.deinit(allocator);
    }

    var due_jobs = std.ArrayList(DueJob).empty;
    errdefer {
        for (due_jobs.items) |*due_job| due_job.deinit(allocator);
        due_jobs.deinit(allocator);
    }

    var index: usize = 0;
    while (index < jobs.items.len) {
        var job = &jobs.items[index];
        if (job.paused or job.next_run_at > now) {
            index += 1;
            continue;
        }

        try due_jobs.append(allocator, .{
            .job = try job.clone(allocator),
            .scheduled_for = job.next_run_at,
        });

        if (job.run_at != null) {
            var removed = jobs.orderedRemove(index);
            removed.deinit(allocator);
            continue;
        }

        const cron_value = job.cron orelse {
            job.paused = true;
            job.updated_at = now;
            index += 1;
            continue;
        };

        const next_run_at = (try cron_adapter.nextRunAt(cron_value, now)) orelse {
            job.paused = true;
            job.updated_at = now;
            index += 1;
            continue;
        };

        job.last_run_at = now;
        job.next_run_at = next_run_at;
        job.updated_at = now;
        index += 1;
    }

    if (due_jobs.items.len > 0) {
        try scheduler_store.saveJobs(allocator, context.workspace_root, jobs.items);
    }

    return due_jobs.toOwnedSlice(allocator);
}

pub fn secondsUntilNextDue(allocator: std.mem.Allocator, context: Context, now: i64) !?u64 {
    var lock = try scheduler_store.acquireLock(allocator, context.workspace_root);
    defer lock.release(allocator);

    const jobs = try scheduler_store.loadJobs(allocator, context.workspace_root);
    defer scheduler_store.deinitJobs(allocator, jobs);

    var min_diff: ?u64 = null;
    for (jobs) |job| {
        if (job.paused) continue;
        if (job.next_run_at <= now) return 0;

        const diff_i64 = job.next_run_at - now;
        const diff = std.math.cast(u64, diff_i64) orelse continue;
        if (min_diff == null or diff < min_diff.?) min_diff = diff;
    }

    return min_diff;
}

pub fn parseRfc3339ToEpoch(value: []const u8) !i64 {
    if (value.len < 20) return error.InvalidTimestamp;
    if (value[4] != '-' or value[7] != '-' or value[10] != 'T' or value[13] != ':' or value[16] != ':') {
        return error.InvalidTimestamp;
    }

    const year = try std.fmt.parseInt(i64, value[0..4], 10);
    const month = try std.fmt.parseInt(i64, value[5..7], 10);
    const day = try std.fmt.parseInt(i64, value[8..10], 10);
    const hour = try std.fmt.parseInt(i64, value[11..13], 10);
    const minute = try std.fmt.parseInt(i64, value[14..16], 10);
    const second = try std.fmt.parseInt(i64, value[17..19], 10);

    if (month < 1 or month > 12) return error.InvalidTimestamp;
    if (day < 1 or day > daysInMonth(year, month)) return error.InvalidTimestamp;
    if (hour < 0 or hour > 23) return error.InvalidTimestamp;
    if (minute < 0 or minute > 59) return error.InvalidTimestamp;
    if (second < 0 or second > 59) return error.InvalidTimestamp;

    var offset_seconds: i64 = 0;
    if (value.len == 20 and value[19] == 'Z') {
        offset_seconds = 0;
    } else if (value.len == 25 and (value[19] == '+' or value[19] == '-')) {
        if (value[22] != ':') return error.InvalidTimestamp;
        const offset_hour = try std.fmt.parseInt(i64, value[20..22], 10);
        const offset_minute = try std.fmt.parseInt(i64, value[23..25], 10);
        if (offset_hour < 0 or offset_hour > 23) return error.InvalidTimestamp;
        if (offset_minute < 0 or offset_minute > 59) return error.InvalidTimestamp;

        const sign: i64 = if (value[19] == '+') 1 else -1;
        offset_seconds = sign * (offset_hour * 3600 + offset_minute * 60);
    } else {
        return error.InvalidTimestamp;
    }

    const days = daysFromCivil(year, month, day);
    const day_seconds = hour * 3600 + minute * 60 + second;
    return days * 86400 + day_seconds - offset_seconds;
}

fn updatePausedState(
    allocator: std.mem.Allocator,
    context: Context,
    job_id: []const u8,
    paused: bool,
) !bool {
    var lock = try scheduler_store.acquireLock(allocator, context.workspace_root);
    defer lock.release(allocator);

    const loaded_jobs = try scheduler_store.loadJobs(allocator, context.workspace_root);
    var jobs = std.ArrayList(scheduler_store.Job).fromOwnedSlice(loaded_jobs);
    defer {
        for (jobs.items) |*job| job.deinit(allocator);
        jobs.deinit(allocator);
    }

    const now = std.time.timestamp();

    for (jobs.items) |*job| {
        if (!std.mem.eql(u8, job.id, job_id)) continue;
        job.paused = paused;
        job.updated_at = now;

        if (!paused) {
            if (job.cron) |cron_value| {
                const next_run_at = (try cron_adapter.nextRunAt(cron_value, now - 60)) orelse return error.InvalidSchedule;
                job.next_run_at = next_run_at;
            }
        }

        try scheduler_store.saveJobs(allocator, context.workspace_root, jobs.items);
        return true;
    }

    return false;
}

fn validateJobPath(job_type: scheduler_store.JobType, resolved_path: []const u8) !void {
    const extension = std.fs.path.extension(resolved_path);
    switch (job_type) {
        .lua => {
            if (!std.mem.eql(u8, extension, ".lua")) return error.InvalidJobPath;
        },
        .markdown => {
            if (!std.mem.eql(u8, extension, ".md")) return error.InvalidJobPath;
        },
    }
}

fn resolveChatId(allocator: std.mem.Allocator, context: Context, explicit_chat_id: ?i64) !i64 {
    if (explicit_chat_id) |value| return value;
    if (context.request_chat_id) |value| return value;

    var config_response = try config_runtime.execute(
        allocator,
        .{ .config_path_override = context.config_path_override },
        .{ .get = config_keys.telegram_default_chat_id },
    );
    defer config_response.deinit(allocator);

    const raw = switch (config_response) {
        .get => |value| value,
        else => unreachable,
    };

    if (raw) |chat_id_text| {
        return std.fmt.parseInt(i64, chat_id_text, 10) catch return error.InvalidDefaultChatId;
    }

    return error.ChatIdRequired;
}

fn generateJobId(allocator: std.mem.Allocator) ![]u8 {
    var random_value: u64 = undefined;
    std.crypto.random.bytes(std.mem.asBytes(&random_value));
    return std.fmt.allocPrint(allocator, "job-{d}-{x}", .{ std.time.nanoTimestamp(), random_value });
}

fn isLeapYear(year: i64) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

fn daysInMonth(year: i64, month: i64) i64 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    var y = year;
    y -= if (month <= 2) 1 else 0;

    const era = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe = y - era * 400;
    const adjusted_month: i64 = month + (if (month > 2) @as(i64, -3) else @as(i64, 9));
    const doy = @divFloor(153 * adjusted_month + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

test "parseRfc3339ToEpoch parses Zulu and offset timestamps" {
    const zulu = try parseRfc3339ToEpoch("2026-01-10T10:00:00Z");
    const offset = try parseRfc3339ToEpoch("2026-01-10T11:00:00+01:00");
    try std.testing.expectEqual(zulu, offset);
}

test "create/list/delete/pause/resume lifecycle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    {
        const file = try tmp.dir.createFile("task.lua", .{});
        defer file.close();
        try file.writeAll("print('ok')\n");
    }

    const context = Context{ .workspace_root = workspace_root, .request_chat_id = 777 };

    const created = try createJob(std.testing.allocator, context, .{
        .job_type = .lua,
        .path = "task.lua",
        .run_at = "2026-01-10T10:00:00Z",
    });
    defer {
        var copy = created;
        copy.deinit(std.testing.allocator);
    }

    const listed = try listJobs(std.testing.allocator, context);
    defer scheduler_store.deinitJobs(std.testing.allocator, listed);
    try std.testing.expectEqual(@as(usize, 1), listed.len);

    try std.testing.expect(try pauseJob(std.testing.allocator, context, created.id));
    try std.testing.expect(try resumeJob(std.testing.allocator, context, created.id));
    try std.testing.expect(try deleteJob(std.testing.allocator, context, created.id));
}

test "resolveChatId prefers explicit over request and config" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    {
        const file = try tmp.dir.createFile("task.md", .{});
        defer file.close();
        try file.writeAll("hello\n");
    }

    const config_path = try std.fs.path.join(std.testing.allocator, &.{ workspace_root, "config.json" });
    defer std.testing.allocator.free(config_path);
    try std.fs.cwd().writeFile(.{ .sub_path = config_path, .data = "{\"TELEGRAM_DEFAULT_CHAT_ID\":\"555\"}" });

    const context = Context{
        .workspace_root = workspace_root,
        .request_chat_id = 444,
        .config_path_override = config_path,
    };

    const created = try createJob(std.testing.allocator, context, .{
        .job_type = .markdown,
        .path = "task.md",
        .run_at = "2026-01-10T10:00:00Z",
        .chat_id = 333,
    });
    defer {
        var copy = created;
        copy.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(i64, 333), created.chat_id);
}
