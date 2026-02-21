const std = @import("std");

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
