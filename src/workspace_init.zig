const std = @import("std");
const workspace_templates = @import("workspace_templates");

pub const EmbeddedFile = workspace_templates.EmbeddedFile;

pub const InitOutcome = struct {
    copied_files: usize,
    conflict_path: ?[]u8,

    pub fn deinit(self: *InitOutcome, allocator: std.mem.Allocator) void {
        if (self.conflict_path) |path| allocator.free(path);
    }
};

pub const embedded_files = workspace_templates.files;

fn findEmbeddedContents(path: []const u8) ?[]const u8 {
    for (embedded_files) |entry| {
        if (std.mem.eql(u8, entry.path, path)) return entry.contents;
    }
    return null;
}

pub fn initWorkspace(
    allocator: std.mem.Allocator,
    destination_path: []const u8,
    force: bool,
) !InitOutcome {
    try ensureDestinationDirectory(destination_path);

    if (!force) {
        for (embedded_files) |entry| {
            const target_path = try std.fs.path.join(allocator, &.{ destination_path, entry.path });
            defer allocator.free(target_path);

            std.fs.cwd().access(target_path, .{}) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };

            return .{
                .copied_files = 0,
                .conflict_path = try allocator.dupe(u8, entry.path),
            };
        }
    }

    var copied_files: usize = 0;
    for (embedded_files) |entry| {
        const target_path = try std.fs.path.join(allocator, &.{ destination_path, entry.path });
        defer allocator.free(target_path);

        if (std.fs.path.dirname(target_path)) |parent| {
            try std.fs.cwd().makePath(parent);
        }

        const file = try std.fs.cwd().createFile(target_path, .{
            .exclusive = !force,
            .truncate = force,
        });
        defer file.close();

        try file.writeAll(entry.contents);
        copied_files += 1;
    }

    return .{
        .copied_files = copied_files,
        .conflict_path = null,
    };
}

fn ensureDestinationDirectory(destination_path: []const u8) !void {
    std.fs.cwd().makePath(destination_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var dir = std.fs.cwd().openDir(destination_path, .{}) catch |err| switch (err) {
        error.NotDir => return error.NotDir,
        else => return err,
    };
    defer dir.close();
}

test "initWorkspace copies embedded files when destination is empty" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    var outcome = try initWorkspace(std.testing.allocator, workspace_root, false);
    defer outcome.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, embedded_files.len), outcome.copied_files);
    try std.testing.expect(outcome.conflict_path == null);

    for (embedded_files) |entry| {
        const path = try std.fs.path.join(std.testing.allocator, &.{ workspace_root, entry.path });
        defer std.testing.allocator.free(path);

        const content = try std.fs.cwd().readFileAlloc(std.testing.allocator, path, entry.contents.len + 1);
        defer std.testing.allocator.free(content);

        try std.testing.expectEqualStrings(entry.contents, content);
    }
}

test "initWorkspace reports conflict and does not write files without force" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    const conflict_file = try tmp.dir.createFile("API.md", .{});
    defer conflict_file.close();
    try conflict_file.writeAll("existing\n");

    var outcome = try initWorkspace(std.testing.allocator, workspace_root, false);
    defer outcome.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), outcome.copied_files);
    try std.testing.expect(outcome.conflict_path != null);
    try std.testing.expectEqualStrings("API.md", outcome.conflict_path.?);

    try std.testing.expectError(error.FileNotFound, tmp.dir.access("ZOID.md", .{}));
}

test "initWorkspace overwrites existing files with force" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    try tmp.dir.makePath("scripts");
    const existing = try tmp.dir.createFile("scripts/cleanup.lua", .{});
    defer existing.close();
    try existing.writeAll("old\n");

    var outcome = try initWorkspace(std.testing.allocator, workspace_root, true);
    defer outcome.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, embedded_files.len), outcome.copied_files);
    try std.testing.expect(outcome.conflict_path == null);

    const content = try tmp.dir.readFileAlloc(std.testing.allocator, "scripts/cleanup.lua", 1024 * 1024);
    defer std.testing.allocator.free(content);
    const expected = findEmbeddedContents("scripts/cleanup.lua") orelse return error.UnexpectedMissingTemplate;
    try std.testing.expectEqualStrings(expected, content);
}
