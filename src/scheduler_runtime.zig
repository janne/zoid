const std = @import("std");
const cron_adapter = @import("cron_adapter.zig");
const scheduler_store = @import("scheduler_store.zig");
const workspace_fs = @import("workspace_fs.zig");
const c = @cImport({
    @cInclude("timelib.h");
});
const short_job_id_alphabet = "abcdefghijklmnopqrstuvwxyz0123456789";
const short_job_id_len: usize = 5;
const max_job_id_generate_attempts: usize = 128;

pub const telegram_dm_chat_id_state_file_name = "telegram_dm_chat_id.txt";

pub const Context = struct {
    workspace_root: []const u8,
};

pub const CreateRequest = struct {
    path: []const u8,
    at: ?[]const u8 = null,
    cron: ?[]const u8 = null,
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
    const has_at = request.at != null;
    const has_cron = request.cron != null;
    if (has_at == has_cron) return error.InvalidSchedule;

    const resolved_path = try workspace_fs.resolveAllowedReadPath(
        allocator,
        context.workspace_root,
        request.path,
    );
    errdefer allocator.free(resolved_path);

    try validateJobPath(resolved_path);

    const now = std.time.timestamp();

    var run_at_epoch: ?i64 = null;
    var cron_text: ?[]u8 = null;
    var next_run_at: i64 = undefined;

    if (request.at) |at_text| {
        const parsed = try parseAtToEpoch(at_text);
        run_at_epoch = parsed;
        next_run_at = parsed;
    } else if (request.cron) |cron_value| {
        _ = try cron_adapter.parseCronExpression(cron_value);
        next_run_at = (try cron_adapter.nextRunAt(cron_value, now - 60)) orelse return error.InvalidSchedule;
        cron_text = try allocator.dupe(u8, cron_value);
    } else {
        unreachable;
    }

    var lock = try scheduler_store.acquireLock(allocator, context.workspace_root);
    defer lock.release(allocator);

    const loaded_jobs = try scheduler_store.loadJobs(allocator, context.workspace_root);
    var jobs = std.ArrayList(scheduler_store.Job).fromOwnedSlice(loaded_jobs);
    defer {
        for (jobs.items) |*job| job.deinit(allocator);
        jobs.deinit(allocator);
    }

    const id = try generateJobId(allocator, jobs.items);

    const new_job: scheduler_store.Job = .{
        .id = id,
        .path = resolved_path,
        .chat_id = 0,
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

    const index = findJobIndexById(jobs.items, job_id) orelse return false;
    var removed = jobs.orderedRemove(index);
    removed.deinit(allocator);
    try scheduler_store.saveJobs(allocator, context.workspace_root, jobs.items);
    return true;
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

pub fn parseAtToEpoch(value: []const u8) !i64 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidTimestamp;

    if (tryParseAtToEpochTimelib(trimmed)) |epoch| return epoch;

    if (stripCaseInsensitivePrefix(trimmed, "in")) |without_in| {
        if (tryParseAtToEpochTimelib(without_in)) |epoch| return epoch;
    }

    if (stripCaseInsensitiveSuffix(trimmed, "from now")) |without_from_now| {
        if (tryParseAtToEpochTimelib(without_from_now)) |epoch| return epoch;
    }

    var normalization_buffer: [512]u8 = undefined;
    if (replaceCaseInsensitive(trimmed, "stockholm time", "Europe/Stockholm", &normalization_buffer)) |with_timezone| {
        if (tryParseAtToEpochTimelib(with_timezone)) |epoch| return epoch;

        var at_cleanup_buffer: [512]u8 = undefined;
        const without_at = removeFirstStandaloneWord(with_timezone, "at", &at_cleanup_buffer) orelse with_timezone;
        if (tryParseAtToEpochTimelib(without_at)) |epoch| return epoch;

        var hour_buffer: [512]u8 = undefined;
        if (addMinutesToStandaloneHour(without_at, &hour_buffer)) |with_hour_minutes| {
            if (tryParseAtToEpochTimelib(with_hour_minutes)) |epoch| return epoch;
        }
    }

    return error.InvalidTimestamp;
}

fn tryParseAtToEpochTimelib(value: []const u8) ?i64 {
    return parseAtToEpochTimelib(value) catch null;
}

fn parseAtToEpochTimelib(value: []const u8) !i64 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidTimestamp;

    var parsed_errors: ?*c.timelib_error_container = null;
    const parsed = c.timelib_strtotime(
        trimmed.ptr,
        trimmed.len,
        &parsed_errors,
        c.timelib_builtin_db(),
        c.timelib_parse_tzfile,
    ) orelse return error.InvalidTimestamp;
    defer c.timelib_time_dtor(parsed);
    defer if (parsed_errors) |errors| c.timelib_error_container_dtor(errors);
    if (hasTimelibParseErrors(parsed_errors)) return error.InvalidTimestamp;

    const now_epoch = std.time.timestamp();
    const now = c.timelib_time_ctor() orelse return error.InvalidTimestamp;
    defer c.timelib_time_dtor(now);
    c.timelib_unixtime2gmt(now, @as(c.timelib_sll, @intCast(now_epoch)));

    c.timelib_fill_holes(parsed, now, c.TIMELIB_NO_CLONE);
    c.timelib_update_ts(parsed, null);
    return std.math.cast(i64, parsed.*.sse) orelse return error.InvalidTimestamp;
}

fn stripCaseInsensitivePrefix(value: []const u8, prefix: []const u8) ?[]const u8 {
    if (value.len <= prefix.len) return null;
    if (!std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix)) return null;
    if (value[prefix.len] != ' ' and value[prefix.len] != '\t') return null;
    return std.mem.trim(u8, value[prefix.len + 1 ..], " \t");
}

fn stripCaseInsensitiveSuffix(value: []const u8, suffix: []const u8) ?[]const u8 {
    if (value.len <= suffix.len) return null;
    const suffix_start = value.len - suffix.len;
    if (!std.ascii.eqlIgnoreCase(value[suffix_start..], suffix)) return null;
    if (suffix_start > 0 and value[suffix_start - 1] != ' ' and value[suffix_start - 1] != '\t') return null;
    return std.mem.trim(u8, value[0..suffix_start], " \t");
}

fn replaceCaseInsensitive(
    value: []const u8,
    needle: []const u8,
    replacement: []const u8,
    buffer: []u8,
) ?[]const u8 {
    if (needle.len == 0 or value.len < needle.len) return null;

    var index: usize = 0;
    while (index + needle.len <= value.len) : (index += 1) {
        if (!std.ascii.eqlIgnoreCase(value[index .. index + needle.len], needle)) continue;

        const new_len = value.len - needle.len + replacement.len;
        if (new_len > buffer.len) return null;

        @memcpy(buffer[0..index], value[0..index]);
        @memcpy(buffer[index .. index + replacement.len], replacement);
        @memcpy(buffer[index + replacement.len .. new_len], value[index + needle.len ..]);

        return std.mem.trim(u8, buffer[0..new_len], " \t");
    }

    return null;
}

fn removeFirstStandaloneWord(value: []const u8, word: []const u8, buffer: []u8) ?[]const u8 {
    if (word.len == 0 or value.len < word.len) return null;

    var index: usize = 0;
    while (index + word.len <= value.len) : (index += 1) {
        if (!std.ascii.eqlIgnoreCase(value[index .. index + word.len], word)) continue;

        const left_ok = index == 0 or value[index - 1] == ' ' or value[index - 1] == '\t';
        const right_index = index + word.len;
        const right_ok = right_index == value.len or value[right_index] == ' ' or value[right_index] == '\t';
        if (!left_ok or !right_ok) continue;

        const prefix = std.mem.trimRight(u8, value[0..index], " \t");
        var after = right_index;
        while (after < value.len and (value[after] == ' ' or value[after] == '\t')) : (after += 1) {}
        const suffix = std.mem.trimLeft(u8, value[after..], " \t");

        const separator_len: usize = if (prefix.len > 0 and suffix.len > 0) 1 else 0;
        const new_len = prefix.len + separator_len + suffix.len;
        if (new_len > buffer.len) return null;

        @memcpy(buffer[0..prefix.len], prefix);
        if (separator_len == 1) buffer[prefix.len] = ' ';
        @memcpy(buffer[prefix.len + separator_len .. new_len], suffix);

        return buffer[0..new_len];
    }

    return null;
}

fn addMinutesToStandaloneHour(value: []const u8, buffer: []u8) ?[]const u8 {
    var index: usize = 0;
    while (index < value.len) : (index += 1) {
        if (!std.ascii.isDigit(value[index])) continue;
        if (index > 0 and value[index - 1] != ' ' and value[index - 1] != '\t') continue;

        var token_end = index;
        while (token_end < value.len and std.ascii.isDigit(value[token_end])) : (token_end += 1) {}
        const token_len = token_end - index;
        if (token_len == 0 or token_len > 2) continue;
        if (token_end < value.len and value[token_end] == ':') continue;
        if (token_end < value.len and value[token_end] != ' ' and value[token_end] != '\t') continue;

        const hour = std.fmt.parseInt(u8, value[index..token_end], 10) catch continue;
        if (hour > 23) continue;

        const new_len = value.len + 3;
        if (new_len > buffer.len) return null;

        @memcpy(buffer[0..token_end], value[0..token_end]);
        @memcpy(buffer[token_end .. token_end + 3], ":00");
        @memcpy(buffer[token_end + 3 .. new_len], value[token_end..]);
        return buffer[0..new_len];
    }

    return null;
}

fn hasTimelibParseErrors(errors: ?*c.timelib_error_container) bool {
    if (errors) |container| {
        return container.*.error_count > 0;
    }
    return false;
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

    const index = findJobIndexById(jobs.items, job_id) orelse return false;
    var job = &jobs.items[index];
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

fn findJobIndexById(jobs: []const scheduler_store.Job, id: []const u8) ?usize {
    for (jobs, 0..) |job, index| {
        if (std.mem.eql(u8, job.id, id)) return index;
    }
    return null;
}

fn validateJobPath(resolved_path: []const u8) !void {
    const extension = std.fs.path.extension(resolved_path);
    if (!std.mem.eql(u8, extension, ".lua")) return error.InvalidJobPath;
}

pub fn loadDefaultDmChatIdAtPath(
    allocator: std.mem.Allocator,
    path: []const u8,
) !?i64 {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();

    const raw = try file.readToEndAlloc(allocator, 128);
    defer allocator.free(raw);

    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;

    return std.fmt.parseInt(i64, trimmed, 10) catch return error.InvalidDefaultDmChatId;
}

fn defaultDmChatIdStatePath(allocator: std.mem.Allocator) ![]u8 {
    const app_data_dir = try std.fs.getAppDataDir(allocator, "zoid");
    defer allocator.free(app_data_dir);
    return std.fs.path.join(allocator, &.{ app_data_dir, telegram_dm_chat_id_state_file_name });
}

pub fn persistDefaultDmChatIdAtPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    chat_id: i64,
) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try std.fs.cwd().makePath(parent);
    }
    const content = try std.fmt.allocPrint(allocator, "{d}\n", .{chat_id});
    defer allocator.free(content);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = content });
}

pub fn loadDefaultDmChatId(allocator: std.mem.Allocator) !?i64 {
    const state_path = try defaultDmChatIdStatePath(allocator);
    defer allocator.free(state_path);
    return loadDefaultDmChatIdAtPath(allocator, state_path);
}

fn generateJobId(allocator: std.mem.Allocator, existing_jobs: []const scheduler_store.Job) ![]u8 {
    var candidate: [short_job_id_len]u8 = undefined;

    var attempts: usize = 0;
    while (attempts < max_job_id_generate_attempts) : (attempts += 1) {
        var random_bytes: [short_job_id_len]u8 = undefined;
        std.crypto.random.bytes(&random_bytes);

        for (random_bytes, 0..) |byte, index| {
            candidate[index] = short_job_id_alphabet[@as(usize, byte) % short_job_id_alphabet.len];
        }

        if (!jobIdExists(existing_jobs, candidate[0..])) {
            return allocator.dupe(u8, candidate[0..]);
        }
    }

    return error.JobIdGenerationFailed;
}

fn jobIdExists(jobs: []const scheduler_store.Job, id: []const u8) bool {
    for (jobs) |job| {
        if (std.mem.eql(u8, job.id, id)) return true;
    }
    return false;
}

test "parseAtToEpoch parses absolute timestamps and named timezone text" {
    const zulu = try parseAtToEpoch("2026-01-10T10:00:00Z");
    const offset = try parseAtToEpoch("2026-01-10T11:00:00+01:00");
    const natural = try parseAtToEpoch("January 10 2026 10:00 UTC");
    try std.testing.expectEqual(zulu, offset);
    try std.testing.expectEqual(zulu, natural);

    const now = std.time.timestamp();
    const stockholm = try parseAtToEpoch("tomorrow at 12 stockholm time");
    try std.testing.expect(stockholm > now);
}

test "parseAtToEpoch parses relative expressions around current time" {
    const now = std.time.timestamp();

    const from_now = try parseAtToEpoch("5 minutes from now");
    try std.testing.expect(from_now >= now + 4 * 60);
    try std.testing.expect(from_now <= now + 6 * 60);

    const in_minutes = try parseAtToEpoch("in 5 minutes");
    try std.testing.expect(in_minutes >= now + 4 * 60);
    try std.testing.expect(in_minutes <= now + 6 * 60);
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

    const context = Context{ .workspace_root = workspace_root };

    const created = try createJob(std.testing.allocator, context, .{
        .path = "task.lua",
        .at = "2026-01-10T10:00:00Z",
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

test "createJob with relative at schedules in the future" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    {
        const file = try tmp.dir.createFile("task.lua", .{});
        defer file.close();
        try file.writeAll("print('ok')\n");
    }

    const now = std.time.timestamp();
    const created = try createJob(std.testing.allocator, .{ .workspace_root = workspace_root }, .{
        .path = "task.lua",
        .at = "5 minutes from now",
    });
    defer {
        var copy = created;
        copy.deinit(std.testing.allocator);
    }

    try std.testing.expect(created.next_run_at >= now + 4 * 60);
    try std.testing.expect(created.next_run_at <= now + 6 * 60);
}

test "createJob no longer requires chat context" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    {
        const file = try tmp.dir.createFile("task.lua", .{});
        defer file.close();
        try file.writeAll("print('hello')\n");
    }

    const created = try createJob(std.testing.allocator, .{ .workspace_root = workspace_root }, .{
        .path = "task.lua",
        .at = "2026-01-10T10:00:00Z",
    });
    defer {
        var copy = created;
        copy.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(i64, 0), created.chat_id);
    try std.testing.expectEqual(short_job_id_len, created.id.len);
    for (created.id) |char| {
        try std.testing.expect(std.mem.indexOfScalar(u8, short_job_id_alphabet, char) != null);
    }
}

test "loadDefaultDmChatIdAtPath parses stored id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    const dm_state_path = try std.fs.path.join(std.testing.allocator, &.{ workspace_root, "dm_chat_id.txt" });
    defer std.testing.allocator.free(dm_state_path);
    try persistDefaultDmChatIdAtPath(std.testing.allocator, dm_state_path, 555);

    const loaded = try loadDefaultDmChatIdAtPath(std.testing.allocator, dm_state_path);
    try std.testing.expectEqual(@as(i64, 555), loaded.?);
}

test "job id matching requires exact id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    var jobs = [_]scheduler_store.Job{
        .{
            .id = try std.testing.allocator.dupe(u8, "job-abc"),
            .path = try std.testing.allocator.dupe(u8, "/tmp/one.lua"),
            .chat_id = 0,
            .paused = false,
            .run_at = 100,
            .cron = null,
            .next_run_at = 100,
            .created_at = 1,
            .updated_at = 1,
            .last_run_at = null,
        },
        .{
            .id = try std.testing.allocator.dupe(u8, "job-abcde"),
            .path = try std.testing.allocator.dupe(u8, "/tmp/two.lua"),
            .chat_id = 0,
            .paused = false,
            .run_at = null,
            .cron = try std.testing.allocator.dupe(u8, "*/5 * * * *"),
            .next_run_at = 200,
            .created_at = 1,
            .updated_at = 1,
            .last_run_at = null,
        },
    };
    defer for (&jobs) |*job| job.deinit(std.testing.allocator);

    try scheduler_store.saveJobs(std.testing.allocator, workspace_root, &jobs);

    const context = Context{ .workspace_root = workspace_root };
    try std.testing.expect(try deleteJob(std.testing.allocator, context, "job-abc"));
    try std.testing.expect(!(try pauseJob(std.testing.allocator, context, "job-abcd")));
    try std.testing.expect(try pauseJob(std.testing.allocator, context, "job-abcde"));

    const listed = try listJobs(std.testing.allocator, context);
    defer scheduler_store.deinitJobs(std.testing.allocator, listed);
    try std.testing.expectEqual(@as(usize, 1), listed.len);
    try std.testing.expectEqualStrings("job-abcde", listed[0].id);
    try std.testing.expect(listed[0].paused);
}
