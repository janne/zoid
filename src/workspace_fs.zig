const std = @import("std");
const builtin = @import("builtin");

pub const ReadResult = struct {
    path: []u8,
    content: []u8,

    pub fn deinit(self: ReadResult, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.content);
    }
};

pub const WriteResult = struct {
    path: []u8,
    bytes_written: usize,

    pub fn deinit(self: WriteResult, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub const DeleteResult = struct {
    path: []u8,

    pub fn deinit(self: DeleteResult, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub const CreateDirectoryResult = struct {
    path: []u8,

    pub fn deinit(self: CreateDirectoryResult, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub const RemoveDirectoryResult = struct {
    path: []u8,

    pub fn deinit(self: RemoveDirectoryResult, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub const EntryType = enum {
    file,
    directory,
    symlink,
    other,
};

pub const PathMetadata = struct {
    name: []u8,
    path: []u8,
    entry_type: EntryType,
    size: u64,
    mode: []u8,
    owner: []u8,
    group: []u8,
    modified_at: []u8,
    exists: bool,

    pub fn deinit(self: PathMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
        allocator.free(self.mode);
        allocator.free(self.owner);
        allocator.free(self.group);
        allocator.free(self.modified_at);
    }
};

pub const ListDirectoryResult = struct {
    path: []u8,
    entries: []PathMetadata,

    pub fn deinit(self: ListDirectoryResult, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        for (self.entries) |entry| entry.deinit(allocator);
        allocator.free(self.entries);
    }
};

pub const GrepMatch = struct {
    path: []u8,
    line: usize,
    column: usize,
    text: []u8,

    pub fn deinit(self: GrepMatch, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.text);
    }
};

pub const GrepResult = struct {
    path: []u8,
    matches: []GrepMatch,
    files_scanned: usize,
    truncated: bool,

    pub fn deinit(self: GrepResult, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        for (self.matches) |match| match.deinit(allocator);
        allocator.free(self.matches);
    }
};

const default_missing_modified_at = "1970-01-01T00:00:00Z";
pub const default_max_grep_matches: usize = 200;
pub const max_allowed_grep_matches: usize = 5_000;
const max_grep_line_bytes: usize = 256 * 1024;

const NativeStat = struct {
    size: u64,
    mode: u32,
    kind: std.fs.File.Kind,
    mtime_ns: i128,
    uid: ?u64,
    gid: ?u64,
};

pub fn readFileAlloc(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    requested_path: []const u8,
    max_bytes: usize,
) !ReadResult {
    const resolved_path = try resolveAllowedReadPath(allocator, workspace_root, requested_path);
    errdefer allocator.free(resolved_path);

    const file = try std.fs.cwd().openFile(resolved_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, max_bytes);
    errdefer allocator.free(content);

    return .{
        .path = resolved_path,
        .content = content,
    };
}

pub fn writeFile(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    requested_path: []const u8,
    content: []const u8,
) !WriteResult {
    const resolved_path = try resolveAllowedWritePath(allocator, workspace_root, requested_path);
    errdefer allocator.free(resolved_path);

    const file = try std.fs.cwd().createFile(resolved_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);

    return .{
        .path = resolved_path,
        .bytes_written = content.len,
    };
}

pub fn deleteFile(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    requested_path: []const u8,
) !DeleteResult {
    const resolved_path = try resolveAllowedReadPath(allocator, workspace_root, requested_path);
    errdefer allocator.free(resolved_path);

    try std.fs.cwd().deleteFile(resolved_path);
    return .{
        .path = resolved_path,
    };
}

pub fn createDirectory(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    requested_path: []const u8,
) !CreateDirectoryResult {
    const resolved_path = try resolveAllowedWritePath(allocator, workspace_root, requested_path);
    errdefer allocator.free(resolved_path);

    try std.fs.cwd().makeDir(resolved_path);

    return .{
        .path = resolved_path,
    };
}

pub fn removeDirectory(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    requested_path: []const u8,
) !RemoveDirectoryResult {
    const resolved_path = try resolveAllowedReadPath(allocator, workspace_root, requested_path);
    errdefer allocator.free(resolved_path);

    try std.fs.cwd().deleteDir(resolved_path);

    return .{
        .path = resolved_path,
    };
}

pub fn getPathMetadata(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    requested_path: []const u8,
    missing_type: EntryType,
) !PathMetadata {
    var resolved_path: []u8 = undefined;
    var resolved_exists = true;
    resolved_path = resolveAllowedReadPath(allocator, workspace_root, requested_path) catch |err| switch (err) {
        error.FileNotFound => blk: {
            resolved_exists = false;
            break :blk try resolveAllowedWritePath(allocator, workspace_root, requested_path);
        },
        else => return err,
    };

    return buildMetadataFromResolvedPath(
        allocator,
        resolved_path,
        resolved_exists,
        missing_type,
    );
}

pub fn listDirectory(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    requested_path: []const u8,
) !ListDirectoryResult {
    const resolved_path = try resolveAllowedReadPath(allocator, workspace_root, requested_path);
    errdefer allocator.free(resolved_path);

    const metadata = try statPath(resolved_path);
    if (metadata.kind != .directory) return error.NotDir;

    var dir = try std.fs.openDirAbsolute(resolved_path, .{ .iterate = true });
    defer dir.close();

    var entries = std.ArrayList(PathMetadata).empty;
    errdefer {
        for (entries.items) |entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        const child_path = try std.fs.path.join(allocator, &.{ resolved_path, entry.name });

        const child_metadata = buildMetadataFromResolvedPath(allocator, child_path, true, .file) catch |err| switch (err) {
            error.FileNotFound => {
                allocator.free(child_path);
                continue;
            },
            else => {
                allocator.free(child_path);
                return err;
            },
        };
        try entries.append(allocator, child_metadata);
    }

    std.mem.sort(PathMetadata, entries.items, {}, sortMetadataByNameAsc);

    return .{
        .path = resolved_path,
        .entries = try entries.toOwnedSlice(allocator),
    };
}

pub fn grep(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    requested_path: []const u8,
    needle: []const u8,
    recursive: bool,
    max_matches: usize,
) !GrepResult {
    if (needle.len == 0 or max_matches == 0) return error.InvalidToolArguments;

    const resolved_path = try resolveAllowedReadPath(allocator, workspace_root, requested_path);
    errdefer allocator.free(resolved_path);

    const stat_data = try statPath(resolved_path);

    var matches = std.ArrayList(GrepMatch).empty;
    errdefer {
        for (matches.items) |match| match.deinit(allocator);
        matches.deinit(allocator);
    }

    var files_scanned: usize = 0;
    var truncated = false;

    switch (stat_data.kind) {
        .file => try grepFileResolvedPath(
            allocator,
            resolved_path,
            needle,
            max_matches,
            &matches,
            &files_scanned,
            &truncated,
        ),
        .directory => try grepDirectoryResolvedPath(
            allocator,
            workspace_root,
            resolved_path,
            needle,
            recursive,
            max_matches,
            &matches,
            &files_scanned,
            &truncated,
        ),
        else => return error.InvalidToolArguments,
    }

    return .{
        .path = resolved_path,
        .matches = try matches.toOwnedSlice(allocator),
        .files_scanned = files_scanned,
        .truncated = truncated,
    };
}

fn grepDirectoryResolvedPath(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    directory_path: []const u8,
    needle: []const u8,
    recursive: bool,
    max_matches: usize,
    matches: *std.ArrayList(GrepMatch),
    files_scanned: *usize,
    truncated: *bool,
) !void {
    if (truncated.*) return;

    var list_result = try listDirectory(allocator, workspace_root, directory_path);
    defer list_result.deinit(allocator);

    for (list_result.entries) |entry| {
        if (truncated.*) return;

        switch (entry.entry_type) {
            .file => try grepFileResolvedPath(
                allocator,
                entry.path,
                needle,
                max_matches,
                matches,
                files_scanned,
                truncated,
            ),
            .directory => if (recursive) {
                try grepDirectoryResolvedPath(
                    allocator,
                    workspace_root,
                    entry.path,
                    needle,
                    recursive,
                    max_matches,
                    matches,
                    files_scanned,
                    truncated,
                );
            },
            else => {},
        }
    }
}

fn grepFileResolvedPath(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    needle: []const u8,
    max_matches: usize,
    matches: *std.ArrayList(GrepMatch),
    files_scanned: *usize,
    truncated: *bool,
) !void {
    if (truncated.*) return;

    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();
    files_scanned.* += 1;

    var reader = file.deprecatedReader();

    var line_number: usize = 0;
    while (try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', max_grep_line_bytes)) |line| {
        defer allocator.free(line);
        line_number += 1;

        const line_without_cr = std.mem.trimRight(u8, line, "\r");
        var search_index: usize = 0;
        while (std.mem.indexOfPos(u8, line_without_cr, search_index, needle)) |match_index| {
            if (matches.items.len >= max_matches) {
                truncated.* = true;
                return;
            }

            const owned_path = try allocator.dupe(u8, file_path);
            errdefer allocator.free(owned_path);

            const owned_text = try allocator.dupe(u8, line_without_cr);
            errdefer allocator.free(owned_text);

            try matches.append(allocator, .{
                .path = owned_path,
                .line = line_number,
                .column = match_index + 1,
                .text = owned_text,
            });

            search_index = match_index + needle.len;
        }
    }
}

pub fn resolveAllowedReadPath(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    requested_path: []const u8,
) ![]u8 {
    const candidate = try toCandidatePath(allocator, workspace_root, requested_path);
    defer allocator.free(candidate);

    const canonical = try std.fs.cwd().realpathAlloc(allocator, candidate);
    errdefer allocator.free(canonical);
    if (!isPathInsideWorkspace(workspace_root, canonical)) {
        return error.PathNotAllowed;
    }
    return canonical;
}

pub fn resolveAllowedWritePath(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    requested_path: []const u8,
) ![]u8 {
    const candidate = try toCandidatePath(allocator, workspace_root, requested_path);
    defer allocator.free(candidate);

    const parent_path = std.fs.path.dirname(candidate) orelse return error.InvalidToolArguments;
    const parent_realpath = try std.fs.cwd().realpathAlloc(allocator, parent_path);
    defer allocator.free(parent_realpath);
    if (!isPathInsideWorkspace(workspace_root, parent_realpath)) {
        return error.PathNotAllowed;
    }

    const file_name = std.fs.path.basename(candidate);
    if (file_name.len == 0 or std.mem.eql(u8, file_name, ".") or std.mem.eql(u8, file_name, "..")) {
        return error.InvalidToolArguments;
    }

    const resolved = try std.fs.path.join(allocator, &.{ parent_realpath, file_name });
    errdefer allocator.free(resolved);
    if (!isPathInsideWorkspace(workspace_root, resolved)) {
        return error.PathNotAllowed;
    }

    const existing_realpath = std.fs.cwd().realpathAlloc(allocator, resolved) catch null;
    if (existing_realpath) |path_value| {
        defer allocator.free(path_value);
        if (!isPathInsideWorkspace(workspace_root, path_value)) {
            return error.PathNotAllowed;
        }
    }
    return resolved;
}

fn toCandidatePath(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    requested_path: []const u8,
) ![]u8 {
    if (requested_path.len == 0) return error.InvalidToolArguments;
    if (std.fs.path.isAbsolute(requested_path)) {
        return allocator.dupe(u8, requested_path);
    }
    return std.fs.path.join(allocator, &.{ workspace_root, requested_path });
}

fn isPathInsideWorkspace(workspace_root: []const u8, candidate_path: []const u8) bool {
    if (std.mem.eql(u8, workspace_root, "/")) {
        return std.mem.startsWith(u8, candidate_path, "/");
    }
    if (!std.mem.startsWith(u8, candidate_path, workspace_root)) return false;
    if (candidate_path.len == workspace_root.len) return true;
    return candidate_path[workspace_root.len] == std.fs.path.sep;
}

pub fn entryTypeToString(entry_type: EntryType) []const u8 {
    return switch (entry_type) {
        .file => "file",
        .directory => "directory",
        .symlink => "symlink",
        .other => "other",
    };
}

fn buildMetadataFromResolvedPath(
    allocator: std.mem.Allocator,
    resolved_path: []u8,
    exists: bool,
    missing_type: EntryType,
) !PathMetadata {
    if (!exists) {
        return buildMissingMetadata(allocator, resolved_path, missing_type);
    }

    const stat_data = statPath(resolved_path) catch |err| switch (err) {
        error.FileNotFound => return buildMissingMetadata(allocator, resolved_path, missing_type),
        else => return err,
    };

    errdefer allocator.free(resolved_path);

    const name = try allocator.dupe(u8, std.fs.path.basename(resolved_path));
    errdefer allocator.free(name);
    const mode = try formatMode(allocator, stat_data.mode);
    errdefer allocator.free(mode);
    const owner = try resolveOwnerName(allocator, stat_data.uid);
    errdefer allocator.free(owner);
    const group = try resolveGroupName(allocator, stat_data.gid);
    errdefer allocator.free(group);
    const modified_at = try formatModifiedAt(allocator, stat_data.mtime_ns);
    errdefer allocator.free(modified_at);

    return .{
        .name = name,
        .path = resolved_path,
        .entry_type = entryTypeFromFileKind(stat_data.kind),
        .size = stat_data.size,
        .mode = mode,
        .owner = owner,
        .group = group,
        .modified_at = modified_at,
        .exists = true,
    };
}

fn buildMissingMetadata(
    allocator: std.mem.Allocator,
    resolved_path: []u8,
    missing_type: EntryType,
) !PathMetadata {
    errdefer allocator.free(resolved_path);

    const name = try allocator.dupe(u8, std.fs.path.basename(resolved_path));
    errdefer allocator.free(name);
    const mode = try allocator.dupe(u8, "0000");
    errdefer allocator.free(mode);
    const owner = try allocator.dupe(u8, "");
    errdefer allocator.free(owner);
    const group = try allocator.dupe(u8, "");
    errdefer allocator.free(group);
    const modified_at = try allocator.dupe(u8, default_missing_modified_at);
    errdefer allocator.free(modified_at);

    return .{
        .name = name,
        .path = resolved_path,
        .entry_type = missing_type,
        .size = 0,
        .mode = mode,
        .owner = owner,
        .group = group,
        .modified_at = modified_at,
        .exists = false,
    };
}

fn statPath(path: []const u8) !NativeStat {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        const file_stat = try std.fs.cwd().statFile(path);
        return .{
            .size = file_stat.size,
            .mode = @as(u32, @intCast(file_stat.mode)),
            .kind = file_stat.kind,
            .mtime_ns = file_stat.mtime,
            .uid = null,
            .gid = null,
        };
    }

    const posix_stat = try std.posix.fstatat(std.posix.AT.FDCWD, path, std.posix.AT.SYMLINK_NOFOLLOW);
    const file_stat = std.fs.File.Stat.fromPosix(posix_stat);

    return .{
        .size = file_stat.size,
        .mode = @as(u32, @intCast(file_stat.mode)),
        .kind = file_stat.kind,
        .mtime_ns = file_stat.mtime,
        .uid = @as(u64, @intCast(posix_stat.uid)),
        .gid = @as(u64, @intCast(posix_stat.gid)),
    };
}

fn entryTypeFromFileKind(kind: std.fs.File.Kind) EntryType {
    return switch (kind) {
        .file => .file,
        .directory => .directory,
        .sym_link => .symlink,
        else => .other,
    };
}

fn formatMode(allocator: std.mem.Allocator, mode: u32) ![]u8 {
    const permission_bits = mode & 0o7777;
    return std.fmt.allocPrint(allocator, "{o:0>4}", .{permission_bits});
}

fn resolveOwnerName(allocator: std.mem.Allocator, uid: ?u64) ![]u8 {
    const uid_value = uid orelse return allocator.dupe(u8, "unknown");

    if (builtin.os.tag != .windows and builtin.os.tag != .wasi) {
        if (std.c.getpwuid(@as(std.c.uid_t, @intCast(uid_value)))) |entry| {
            if (entry.name) |name_ptr| {
                return allocator.dupe(u8, std.mem.span(name_ptr));
            }
        }
    }
    return std.fmt.allocPrint(allocator, "{d}", .{uid_value});
}

fn resolveGroupName(allocator: std.mem.Allocator, gid: ?u64) ![]u8 {
    const gid_value = gid orelse return allocator.dupe(u8, "unknown");

    if (builtin.os.tag != .windows and builtin.os.tag != .wasi) {
        if (std.c.getgrgid(@as(std.c.gid_t, @intCast(gid_value)))) |entry| {
            if (entry.name) |name_ptr| {
                return allocator.dupe(u8, std.mem.span(name_ptr));
            }
        }
    }
    return std.fmt.allocPrint(allocator, "{d}", .{gid_value});
}

fn formatModifiedAt(allocator: std.mem.Allocator, mtime_ns: i128) ![]u8 {
    const mtime_sec: u64 = blk: {
        if (mtime_ns <= 0) break :blk 0;
        const whole_seconds = @divFloor(mtime_ns, std.time.ns_per_s);
        break :blk std.math.cast(u64, whole_seconds) orelse std.math.maxInt(u64);
    };

    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = mtime_sec };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    );
}

fn sortMetadataByNameAsc(_: void, a: PathMetadata, b: PathMetadata) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

test "getPathMetadata returns file metadata and keeps missing file handles writable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    {
        const file = try tmp.dir.createFile("example.txt", .{});
        defer file.close();
        try file.writeAll("hello");
    }

    var existing = try getPathMetadata(std.testing.allocator, workspace_root, "example.txt", .file);
    defer existing.deinit(std.testing.allocator);

    try std.testing.expect(existing.exists);
    try std.testing.expectEqualStrings("example.txt", existing.name);
    try std.testing.expectEqualStrings("file", entryTypeToString(existing.entry_type));
    try std.testing.expect(existing.size == 5);
    try std.testing.expect(existing.mode.len == 4);
    try std.testing.expect(existing.owner.len > 0);
    try std.testing.expect(existing.group.len > 0);
    try std.testing.expect(existing.modified_at.len == 20);
    try std.testing.expect(std.mem.endsWith(u8, existing.modified_at, "Z"));

    var missing = try getPathMetadata(std.testing.allocator, workspace_root, "missing.txt", .file);
    defer missing.deinit(std.testing.allocator);

    try std.testing.expect(!missing.exists);
    try std.testing.expectEqualStrings("missing.txt", missing.name);
    try std.testing.expectEqualStrings("file", entryTypeToString(missing.entry_type));
    try std.testing.expectEqual(@as(u64, 0), missing.size);
    try std.testing.expectEqualStrings("0000", missing.mode);
    try std.testing.expectEqualStrings(default_missing_modified_at, missing.modified_at);
}

test "listDirectory returns sorted metadata entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    {
        const file = try tmp.dir.createFile("b.txt", .{});
        defer file.close();
        try file.writeAll("b");
    }
    {
        const file = try tmp.dir.createFile("a.txt", .{});
        defer file.close();
        try file.writeAll("aa");
    }
    try tmp.dir.makeDir("z-dir");

    var listing = try listDirectory(std.testing.allocator, workspace_root, ".");
    defer listing.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(workspace_root, listing.path);
    try std.testing.expectEqual(@as(usize, 3), listing.entries.len);
    try std.testing.expectEqualStrings("a.txt", listing.entries[0].name);
    try std.testing.expectEqualStrings("b.txt", listing.entries[1].name);
    try std.testing.expectEqualStrings("z-dir", listing.entries[2].name);
    try std.testing.expectEqualStrings("directory", entryTypeToString(listing.entries[2].entry_type));
}

test "createDirectory and removeDirectory enforce existence and emptiness rules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    var created = try createDirectory(std.testing.allocator, workspace_root, "memory");
    defer created.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.endsWith(u8, created.path, "memory"));

    try std.testing.expectError(
        error.PathAlreadyExists,
        createDirectory(std.testing.allocator, workspace_root, "memory"),
    );

    const file = try tmp.dir.createFile("memory/note.txt", .{});
    file.close();

    removeDirectory(std.testing.allocator, workspace_root, "memory") catch |err| {
        const err_name = @errorName(err);
        const is_non_empty =
            std.mem.eql(u8, err_name, "DirNotEmpty") or
            std.mem.eql(u8, err_name, "DirectoryNotEmpty");
        try std.testing.expect(is_non_empty);
        return;
    };
    return error.TestExpectedError;
}

test "grep supports recursive and non-recursive search" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    try tmp.dir.makePath("logs/nested");
    {
        const top_file = try tmp.dir.createFile("logs/top.txt", .{});
        defer top_file.close();
        try top_file.writeAll("hello needle\nskip\n");
    }
    {
        const nested_file = try tmp.dir.createFile("logs/nested/deep.txt", .{});
        defer nested_file.close();
        try nested_file.writeAll("needle here too\n");
    }
    {
        const unrelated = try tmp.dir.createFile("logs/nested/other.txt", .{});
        defer unrelated.close();
        try unrelated.writeAll("no match\n");
    }

    var non_recursive = try grep(
        std.testing.allocator,
        workspace_root,
        "logs",
        "needle",
        false,
        100,
    );
    defer non_recursive.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), non_recursive.matches.len);
    try std.testing.expectEqual(@as(usize, 1), non_recursive.files_scanned);
    try std.testing.expect(!non_recursive.truncated);
    try std.testing.expectEqualStrings("top.txt", std.fs.path.basename(non_recursive.matches[0].path));
    try std.testing.expectEqual(@as(usize, 1), non_recursive.matches[0].line);
    try std.testing.expectEqual(@as(usize, 7), non_recursive.matches[0].column);

    var recursive = try grep(
        std.testing.allocator,
        workspace_root,
        "logs",
        "needle",
        true,
        100,
    );
    defer recursive.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), recursive.matches.len);
    try std.testing.expectEqual(@as(usize, 3), recursive.files_scanned);
    try std.testing.expect(!recursive.truncated);
    try std.testing.expectEqualStrings("deep.txt", std.fs.path.basename(recursive.matches[0].path));
    try std.testing.expectEqualStrings("top.txt", std.fs.path.basename(recursive.matches[1].path));
}
