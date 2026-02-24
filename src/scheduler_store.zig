const std = @import("std");

pub const max_store_bytes: usize = 8 * 1024 * 1024;
const app_data_app_name = "zoid";
const store_dir_name = "scheduler";
const store_file_name = "scheduler_jobs.json";
const store_tmp_name = "scheduler_jobs.json.tmp";
const lock_file_name = "scheduler_jobs.lock";
const lock_retry_delay_ns: u64 = 50 * std.time.ns_per_ms;
const lock_retry_attempts: usize = 200;

pub const Job = struct {
    id: []u8,
    path: []u8,
    chat_id: i64,
    paused: bool,
    run_at: ?i64,
    cron: ?[]u8,
    next_run_at: i64,
    created_at: i64,
    updated_at: i64,
    last_run_at: ?i64,

    pub fn deinit(self: *Job, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.path);
        if (self.cron) |value| allocator.free(value);
    }

    pub fn clone(self: *const Job, allocator: std.mem.Allocator) !Job {
        return .{
            .id = try allocator.dupe(u8, self.id),
            .path = try allocator.dupe(u8, self.path),
            .chat_id = self.chat_id,
            .paused = self.paused,
            .run_at = self.run_at,
            .cron = if (self.cron) |value| try allocator.dupe(u8, value) else null,
            .next_run_at = self.next_run_at,
            .created_at = self.created_at,
            .updated_at = self.updated_at,
            .last_run_at = self.last_run_at,
        };
    }
};

pub const Lock = struct {
    lock_path: []u8,
    lock_file: std.fs.File,

    pub fn release(self: *Lock, allocator: std.mem.Allocator) void {
        self.lock_file.close();
        std.fs.cwd().deleteFile(self.lock_path) catch {};
        allocator.free(self.lock_path);
        self.* = undefined;
    }
};

pub fn deinitJobs(allocator: std.mem.Allocator, jobs: []Job) void {
    for (jobs) |*job| job.deinit(allocator);
    allocator.free(jobs);
}

pub fn cloneJobs(allocator: std.mem.Allocator, jobs: []const Job) ![]Job {
    var out = std.ArrayList(Job).empty;
    errdefer {
        for (out.items) |*job| job.deinit(allocator);
        out.deinit(allocator);
    }

    for (jobs) |job| {
        try out.append(allocator, try job.clone(allocator));
    }

    return out.toOwnedSlice(allocator);
}

pub fn acquireLock(allocator: std.mem.Allocator, workspace_root: []const u8) !Lock {
    const store_dir = try storeDirPath(allocator, workspace_root);
    defer allocator.free(store_dir);
    try std.fs.cwd().makePath(store_dir);

    const lock_path = try lockFilePath(allocator, workspace_root);
    errdefer allocator.free(lock_path);

    var attempts: usize = 0;
    while (true) : (attempts += 1) {
        const file = std.fs.cwd().createFile(lock_path, .{ .exclusive = true, .truncate = false }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                if (attempts >= lock_retry_attempts) return error.StoreLockTimeout;
                std.Thread.sleep(lock_retry_delay_ns);
                continue;
            },
            else => return err,
        };

        return .{
            .lock_path = lock_path,
            .lock_file = file,
        };
    }
}

pub fn loadJobs(allocator: std.mem.Allocator, workspace_root: []const u8) ![]Job {
    const file_path = try storeFilePath(allocator, workspace_root);
    defer allocator.free(file_path);

    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return try allocator.alloc(Job, 0),
        else => return err,
    };
    defer file.close();

    const bytes = try file.readToEndAlloc(allocator, max_store_bytes);
    defer allocator.free(bytes);

    if (bytes.len == 0) return try allocator.alloc(Job, 0);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidSchedulerStoreFormat,
    };

    const jobs_value = switch (root.get("jobs") orelse return error.InvalidSchedulerStoreFormat) {
        .array => |value| value,
        else => return error.InvalidSchedulerStoreFormat,
    };

    var jobs = std.ArrayList(Job).empty;
    errdefer {
        for (jobs.items) |*job| job.deinit(allocator);
        jobs.deinit(allocator);
    }

    for (jobs_value.items) |job_value| {
        const job_object = switch (job_value) {
            .object => |value| value,
            else => return error.InvalidSchedulerStoreFormat,
        };
        try jobs.append(allocator, try parseJob(allocator, job_object));
    }

    return jobs.toOwnedSlice(allocator);
}

pub fn saveJobs(allocator: std.mem.Allocator, workspace_root: []const u8, jobs: []const Job) !void {
    const dir_path = try storeDirPath(allocator, workspace_root);
    defer allocator.free(dir_path);
    try std.fs.cwd().makePath(dir_path);

    const file_path = try storeFilePath(allocator, workspace_root);
    defer allocator.free(file_path);

    const tmp_path = try storeTmpPath(allocator, workspace_root);
    defer allocator.free(tmp_path);

    const payload = try jobsToJson(allocator, jobs);
    defer allocator.free(payload);

    const tmp_file = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true });
    defer tmp_file.close();
    try tmp_file.writeAll(payload);

    try std.fs.cwd().rename(tmp_path, file_path);
}

pub fn storeFilePath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    const dir_path = try storeDirPath(allocator, workspace_root);
    defer allocator.free(dir_path);

    return std.fs.path.join(allocator, &.{ dir_path, store_file_name });
}

fn storeTmpPath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    const dir_path = try storeDirPath(allocator, workspace_root);
    defer allocator.free(dir_path);

    return std.fs.path.join(allocator, &.{ dir_path, store_tmp_name });
}

fn storeDirPath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    const app_data_dir = try appDataDirPath(allocator);
    defer allocator.free(app_data_dir);

    const namespace = try workspaceStoreNamespace(allocator, workspace_root);
    defer allocator.free(namespace);

    return std.fs.path.join(allocator, &.{ app_data_dir, store_dir_name, namespace });
}

fn lockFilePath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    const dir_path = try storeDirPath(allocator, workspace_root);
    defer allocator.free(dir_path);

    return std.fs.path.join(allocator, &.{ dir_path, lock_file_name });
}

fn appDataDirPath(allocator: std.mem.Allocator) ![]u8 {
    return std.fs.getAppDataDir(allocator, app_data_app_name);
}

fn workspaceStoreNamespace(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    const hash = std.hash.Wyhash.hash(0, workspace_root);
    return std.fmt.allocPrint(allocator, "{x}", .{hash});
}

fn parseJob(allocator: std.mem.Allocator, object: std.json.ObjectMap) !Job {
    const id = try allocator.dupe(u8, try requireString(object, "id"));
    errdefer allocator.free(id);

    const path = try allocator.dupe(u8, try requireString(object, "path"));
    errdefer allocator.free(path);

    const chat_id = try requireInteger(object, "chat_id");
    const paused = try requireBool(object, "paused");
    const run_at = try optionalInteger(object, "run_at");

    var cron_value: ?[]u8 = null;
    errdefer if (cron_value) |value| allocator.free(value);
    if (optionalString(object, "cron")) |cron_text| {
        cron_value = try allocator.dupe(u8, cron_text);
    }

    const next_run_at = try requireInteger(object, "next_run_at");
    const created_at = try requireInteger(object, "created_at");
    const updated_at = try requireInteger(object, "updated_at");
    const last_run_at = try optionalInteger(object, "last_run_at");

    return .{
        .id = id,
        .path = path,
        .chat_id = chat_id,
        .paused = paused,
        .run_at = run_at,
        .cron = cron_value,
        .next_run_at = next_run_at,
        .created_at = created_at,
        .updated_at = updated_at,
        .last_run_at = last_run_at,
    };
}

fn jobsToJson(allocator: std.mem.Allocator, jobs: []const Job) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();

    const writer = &out.writer;
    try writer.writeAll("{\"jobs\":[");
    for (jobs, 0..) |job, index| {
        if (index > 0) try writer.writeAll(",");
        try jobToJson(allocator, writer, &job);
    }
    try writer.writeAll("]}");

    return out.toOwnedSlice();
}

fn jobToJson(allocator: std.mem.Allocator, writer: *std.Io.Writer, job: *const Job) !void {
    try writer.writeAll("{\"id\":");
    try writeJsonString(allocator, writer, job.id);
    try writer.writeAll(",\"path\":");
    try writeJsonString(allocator, writer, job.path);
    try writer.writeAll(",\"chat_id\":");
    try writer.print("{d}", .{job.chat_id});
    try writer.writeAll(",\"paused\":");
    try writer.writeAll(if (job.paused) "true" else "false");
    try writer.writeAll(",\"run_at\":");
    if (job.run_at) |run_at| {
        try writer.print("{d}", .{run_at});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"cron\":");
    if (job.cron) |cron| {
        try writeJsonString(allocator, writer, cron);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"next_run_at\":");
    try writer.print("{d}", .{job.next_run_at});
    try writer.writeAll(",\"created_at\":");
    try writer.print("{d}", .{job.created_at});
    try writer.writeAll(",\"updated_at\":");
    try writer.print("{d}", .{job.updated_at});
    try writer.writeAll(",\"last_run_at\":");
    if (job.last_run_at) |last| {
        try writer.print("{d}", .{last});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll("}");
}

fn requireString(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    return switch (object.get(name) orelse return error.InvalidSchedulerStoreFormat) {
        .string => |value| value,
        else => error.InvalidSchedulerStoreFormat,
    };
}

fn optionalString(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |text| text,
        .null => null,
        else => null,
    };
}

fn requireInteger(object: std.json.ObjectMap, name: []const u8) !i64 {
    return switch (object.get(name) orelse return error.InvalidSchedulerStoreFormat) {
        .integer => |value| value,
        else => error.InvalidSchedulerStoreFormat,
    };
}

fn optionalInteger(object: std.json.ObjectMap, name: []const u8) !?i64 {
    return switch (object.get(name) orelse return null) {
        .integer => |value| value,
        .null => null,
        else => error.InvalidSchedulerStoreFormat,
    };
}

fn requireBool(object: std.json.ObjectMap, name: []const u8) !bool {
    return switch (object.get(name) orelse return error.InvalidSchedulerStoreFormat) {
        .bool => |value| value,
        else => error.InvalidSchedulerStoreFormat,
    };
}

fn writeJsonString(allocator: std.mem.Allocator, writer: *std.Io.Writer, value: []const u8) !void {
    const escaped = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(escaped);
    try writer.writeAll(escaped);
}

test "saveJobs and loadJobs roundtrip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    var initial_jobs = [_]Job{
        .{
            .id = try std.testing.allocator.dupe(u8, "job-1"),
            .path = try std.testing.allocator.dupe(u8, "script.lua"),
            .chat_id = 123,
            .paused = false,
            .run_at = 100,
            .cron = null,
            .next_run_at = 100,
            .created_at = 90,
            .updated_at = 90,
            .last_run_at = null,
        },
        .{
            .id = try std.testing.allocator.dupe(u8, "job-2"),
            .path = try std.testing.allocator.dupe(u8, "job.lua"),
            .chat_id = 456,
            .paused = true,
            .run_at = null,
            .cron = try std.testing.allocator.dupe(u8, "0 21 * * *"),
            .next_run_at = 200,
            .created_at = 100,
            .updated_at = 150,
            .last_run_at = 120,
        },
    };
    defer {
        for (&initial_jobs) |*job| job.deinit(std.testing.allocator);
    }

    try saveJobs(std.testing.allocator, workspace_root, &initial_jobs);

    const loaded = try loadJobs(std.testing.allocator, workspace_root);
    defer deinitJobs(std.testing.allocator, loaded);

    try std.testing.expectEqual(@as(usize, 2), loaded.len);
    try std.testing.expectEqualStrings("job-1", loaded[0].id);
    try std.testing.expectEqualStrings("script.lua", loaded[0].path);
    try std.testing.expectEqual(@as(i64, 456), loaded[1].chat_id);
    try std.testing.expectEqualStrings("job.lua", loaded[1].path);
    try std.testing.expectEqualStrings("0 21 * * *", loaded[1].cron.?);
}

test "scheduler store path is under app-data and outside workspace root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    const file_path = try storeFilePath(std.testing.allocator, workspace_root);
    defer std.testing.allocator.free(file_path);

    const app_data_dir = try std.fs.getAppDataDir(std.testing.allocator, app_data_app_name);
    defer std.testing.allocator.free(app_data_dir);

    try std.testing.expect(std.mem.startsWith(u8, file_path, app_data_dir));
    try std.testing.expect(!std.mem.startsWith(u8, file_path, workspace_root));
}
