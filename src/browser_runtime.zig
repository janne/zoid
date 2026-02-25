const std = @import("std");

pub const playwright_version = "1.55.0";
pub const browser_name = "chromium";

const app_data_app_name = "zoid";
const browser_store_dir_name = "browser";
const browser_binaries_dir_name = "ms-playwright";
const browser_state_file_name = "state.json";
const playwright_package = "playwright@" ++ playwright_version;

pub const Context = struct {
    app_data_dir_override: ?[]const u8 = null,
};

pub const Runner = enum {
    npx,
    bunx,
    pnpm_dlx,
    yarn_dlx,

    pub fn name(self: Runner) []const u8 {
        return switch (self) {
            .npx => "npx",
            .bunx => "bunx",
            .pnpm_dlx => "pnpm dlx",
            .yarn_dlx => "yarn dlx",
        };
    }

    fn checkArgv(self: Runner) []const []const u8 {
        return switch (self) {
            .npx => &.{ "npx", "--version" },
            .bunx => &.{ "bunx", "--version" },
            .pnpm_dlx => &.{ "pnpm", "--version" },
            .yarn_dlx => &.{ "yarn", "--version" },
        };
    }

    fn installArgv(self: Runner) []const []const u8 {
        return switch (self) {
            .npx => &.{ "npx", "--yes", playwright_package, "install", browser_name },
            .bunx => &.{ "bunx", playwright_package, "install", browser_name },
            .pnpm_dlx => &.{ "pnpm", "dlx", playwright_package, "install", browser_name },
            .yarn_dlx => &.{ "yarn", "dlx", playwright_package, "install", browser_name },
        };
    }
};

pub const InstallState = struct {
    playwright_version: []u8,
    runner: []u8,
    browser: []u8,
    installed_at_epoch: i64,

    pub fn deinit(self: *InstallState, allocator: std.mem.Allocator) void {
        allocator.free(self.playwright_version);
        allocator.free(self.runner);
        allocator.free(self.browser);
    }
};

pub const Status = struct {
    install_root: []u8,
    browsers_path: []u8,
    state_path: []u8,
    runner: ?Runner,
    browser_files_present: bool,
    state_exists: bool,
    state_valid: bool,
    state: ?InstallState,

    pub fn ready(self: *const Status) bool {
        return self.browser_files_present and self.state_valid and self.state != null;
    }

    pub fn deinit(self: *Status, allocator: std.mem.Allocator) void {
        allocator.free(self.install_root);
        allocator.free(self.browsers_path);
        allocator.free(self.state_path);
        if (self.state) |*value| value.deinit(allocator);
    }
};

pub const InstallResult = struct {
    status: Status,
    runner: Runner,

    pub fn deinit(self: *InstallResult, allocator: std.mem.Allocator) void {
        self.status.deinit(allocator);
    }
};

pub const UninstallResult = struct {
    install_root: []u8,
    removed: bool,

    pub fn deinit(self: *UninstallResult, allocator: std.mem.Allocator) void {
        allocator.free(self.install_root);
    }
};

pub fn install(allocator: std.mem.Allocator) !InstallResult {
    return installWithContext(allocator, .{});
}

pub fn status(allocator: std.mem.Allocator) !Status {
    return statusWithContext(allocator, .{});
}

pub fn uninstall(allocator: std.mem.Allocator) !UninstallResult {
    return uninstallWithContext(allocator, .{});
}

pub fn installWithContext(allocator: std.mem.Allocator, context: Context) !InstallResult {
    const runner = detectRunner(allocator) orelse return error.BrowserRuntimeNotFound;

    const paths = try Paths.init(allocator, context);
    defer paths.deinit(allocator);

    try std.fs.cwd().makePath(paths.install_root);
    try std.fs.cwd().makePath(paths.browsers_path);

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    try env_map.put("PLAYWRIGHT_BROWSERS_PATH", paths.browsers_path);

    const install_term = try runCommand(allocator, runner.installArgv(), &env_map, true);
    switch (install_term) {
        .Exited => |code| {
            if (code != 0) return error.BrowserInstallFailed;
        },
        else => return error.BrowserInstallFailed,
    }

    try writeStateFile(allocator, paths.state_path, runner);

    return .{
        .status = try statusWithContext(allocator, context),
        .runner = runner,
    };
}

pub fn statusWithContext(allocator: std.mem.Allocator, context: Context) !Status {
    const paths = try Paths.init(allocator, context);
    defer paths.deinit(allocator);

    var loaded_state = try loadStateFile(allocator, paths.state_path);
    errdefer if (loaded_state.state) |*value| value.deinit(allocator);

    return .{
        .install_root = try allocator.dupe(u8, paths.install_root),
        .browsers_path = try allocator.dupe(u8, paths.browsers_path),
        .state_path = try allocator.dupe(u8, paths.state_path),
        .runner = detectRunner(allocator),
        .browser_files_present = hasChromiumArtifacts(paths.browsers_path) catch false,
        .state_exists = loaded_state.exists,
        .state_valid = loaded_state.valid,
        .state = loaded_state.state,
    };
}

pub fn uninstallWithContext(allocator: std.mem.Allocator, context: Context) !UninstallResult {
    const paths = try Paths.init(allocator, context);
    defer paths.deinit(allocator);

    const existed_before = blk: {
        std.fs.cwd().access(paths.install_root, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => return err,
        };
        break :blk true;
    };
    if (!existed_before) {
        return .{
            .install_root = try allocator.dupe(u8, paths.install_root),
            .removed = false,
        };
    }

    try std.fs.cwd().deleteTree(paths.install_root);

    const removed = if (std.fs.cwd().access(paths.install_root, .{})) |_|
        false
    else |err| switch (err) {
        error.FileNotFound => true,
        else => return err,
    };

    return .{
        .install_root = try allocator.dupe(u8, paths.install_root),
        .removed = removed,
    };
}

fn detectRunner(allocator: std.mem.Allocator) ?Runner {
    const order = [_]Runner{
        .npx,
        .bunx,
        .pnpm_dlx,
        .yarn_dlx,
    };

    for (order) |runner| {
        if (runnerAvailable(allocator, runner)) {
            return runner;
        }
    }
    return null;
}

fn runnerAvailable(allocator: std.mem.Allocator, runner: Runner) bool {
    const term = runCommand(allocator, runner.checkArgv(), null, false) catch return false;
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn runCommand(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    env_map: ?*const std.process.EnvMap,
    inherit_output: bool,
) !std.process.Child.Term {
    var child = std.process.Child.init(argv, allocator);
    child.expand_arg0 = .expand;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = if (inherit_output) .Inherit else .Ignore;
    child.stderr_behavior = if (inherit_output) .Inherit else .Ignore;
    child.env_map = env_map;

    return child.spawnAndWait();
}

const LoadedState = struct {
    exists: bool,
    valid: bool,
    state: ?InstallState,
};

fn loadStateFile(allocator: std.mem.Allocator, state_path: []const u8) !LoadedState {
    const contents = std.fs.cwd().readFileAlloc(allocator, state_path, 64 * 1024) catch |err| switch (err) {
        error.FileNotFound => {
            return .{
                .exists = false,
                .valid = false,
                .state = null,
            };
        },
        else => return err,
    };
    defer allocator.free(contents);

    if (contents.len == 0) {
        return .{
            .exists = true,
            .valid = false,
            .state = null,
        };
    }

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, contents, .{}) catch {
        return .{
            .exists = true,
            .valid = false,
            .state = null,
        };
    };
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |value| value,
        else => {
            return .{
                .exists = true,
                .valid = false,
                .state = null,
            };
        },
    };

    const version_value = switch (object.get("playwright_version") orelse {
        return .{
            .exists = true,
            .valid = false,
            .state = null,
        };
    }) {
        .string => |value| value,
        else => {
            return .{
                .exists = true,
                .valid = false,
                .state = null,
            };
        },
    };

    const runner_value = switch (object.get("runner") orelse {
        return .{
            .exists = true,
            .valid = false,
            .state = null,
        };
    }) {
        .string => |value| value,
        else => {
            return .{
                .exists = true,
                .valid = false,
                .state = null,
            };
        },
    };

    const browser_value = switch (object.get("browser") orelse {
        return .{
            .exists = true,
            .valid = false,
            .state = null,
        };
    }) {
        .string => |value| value,
        else => {
            return .{
                .exists = true,
                .valid = false,
                .state = null,
            };
        },
    };

    const installed_at_epoch = switch (object.get("installed_at_epoch") orelse {
        return .{
            .exists = true,
            .valid = false,
            .state = null,
        };
    }) {
        .integer => |value| value,
        else => {
            return .{
                .exists = true,
                .valid = false,
                .state = null,
            };
        },
    };

    return .{
        .exists = true,
        .valid = true,
        .state = .{
            .playwright_version = try allocator.dupe(u8, version_value),
            .runner = try allocator.dupe(u8, runner_value),
            .browser = try allocator.dupe(u8, browser_value),
            .installed_at_epoch = installed_at_epoch,
        },
    };
}

fn writeStateFile(allocator: std.mem.Allocator, state_path: []const u8, runner: Runner) !void {
    if (std.fs.path.dirname(state_path)) |parent| {
        try std.fs.cwd().makePath(parent);
    }

    const payload = try std.fmt.allocPrint(
        allocator,
        \\{{
        \\  "playwright_version": "{s}",
        \\  "runner": "{s}",
        \\  "browser": "{s}",
        \\  "installed_at_epoch": {d}
        \\}}
        \\
    ,
        .{ playwright_version, runner.name(), browser_name, std.time.timestamp() },
    );
    defer allocator.free(payload);

    const file = try std.fs.cwd().createFile(state_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(payload);
}

fn hasChromiumArtifacts(path: []const u8) !bool {
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer dir.close();

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind == .directory and std.mem.startsWith(u8, entry.name, "chromium")) {
            return true;
        }
    }

    return false;
}

const Paths = struct {
    app_data_dir: []u8,
    install_root: []u8,
    browsers_path: []u8,
    state_path: []u8,

    fn init(allocator: std.mem.Allocator, context: Context) !Paths {
        const app_data_dir = if (context.app_data_dir_override) |override|
            try allocator.dupe(u8, override)
        else
            try std.fs.getAppDataDir(allocator, app_data_app_name);
        errdefer allocator.free(app_data_dir);

        const install_root = try std.fs.path.join(allocator, &.{ app_data_dir, browser_store_dir_name });
        errdefer allocator.free(install_root);

        const browsers_path = try std.fs.path.join(allocator, &.{ install_root, browser_binaries_dir_name });
        errdefer allocator.free(browsers_path);

        const state_path = try std.fs.path.join(allocator, &.{ install_root, browser_state_file_name });
        errdefer allocator.free(state_path);

        return .{
            .app_data_dir = app_data_dir,
            .install_root = install_root,
            .browsers_path = browsers_path,
            .state_path = state_path,
        };
    }

    fn deinit(self: *const Paths, allocator: std.mem.Allocator) void {
        allocator.free(self.app_data_dir);
        allocator.free(self.install_root);
        allocator.free(self.browsers_path);
        allocator.free(self.state_path);
    }
};

test "status reports missing install when no files exist" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const app_data_dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(app_data_dir);

    var result = try statusWithContext(std.testing.allocator, .{
        .app_data_dir_override = app_data_dir,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.state_exists);
    try std.testing.expect(!result.state_valid);
    try std.testing.expect(!result.browser_files_present);
    try std.testing.expect(!result.ready());
}

test "status detects valid state and chromium artifacts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const app_data_dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(app_data_dir);

    const install_root = try std.fs.path.join(std.testing.allocator, &.{ app_data_dir, browser_store_dir_name });
    defer std.testing.allocator.free(install_root);
    try tmp.dir.makePath("browser/ms-playwright/chromium-1234");

    const state_path = try std.fs.path.join(std.testing.allocator, &.{ install_root, browser_state_file_name });
    defer std.testing.allocator.free(state_path);
    const state_file = try std.fs.cwd().createFile(state_path, .{ .truncate = true });
    defer state_file.close();
    try state_file.writeAll(
        \\{
        \\  "playwright_version": "1.55.0",
        \\  "runner": "npx",
        \\  "browser": "chromium",
        \\  "installed_at_epoch": 1
        \\}
        \\
    );

    var result = try statusWithContext(std.testing.allocator, .{
        .app_data_dir_override = app_data_dir,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.state_exists);
    try std.testing.expect(result.state_valid);
    try std.testing.expect(result.browser_files_present);
    try std.testing.expect(result.ready());
    try std.testing.expectEqualStrings("1.55.0", result.state.?.playwright_version);
}

test "status reports invalid state file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const app_data_dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(app_data_dir);

    try tmp.dir.makePath("browser");
    const state_path = try std.fs.path.join(std.testing.allocator, &.{ app_data_dir, browser_store_dir_name, browser_state_file_name });
    defer std.testing.allocator.free(state_path);

    const state_file = try std.fs.cwd().createFile(state_path, .{ .truncate = true });
    defer state_file.close();
    try state_file.writeAll("not-json\n");

    var result = try statusWithContext(std.testing.allocator, .{
        .app_data_dir_override = app_data_dir,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.state_exists);
    try std.testing.expect(!result.state_valid);
    try std.testing.expect(result.state == null);
    try std.testing.expect(!result.ready());
}

test "uninstall removes browser install tree" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const app_data_dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(app_data_dir);

    try tmp.dir.makePath("browser/ms-playwright/chromium-1234");
    const state_file = try tmp.dir.createFile("browser/state.json", .{});
    defer state_file.close();
    try state_file.writeAll("{}");

    var result = try uninstallWithContext(std.testing.allocator, .{
        .app_data_dir_override = app_data_dir,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.removed);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("browser", .{}));
}
