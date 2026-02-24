const std = @import("std");

const WorkspaceTemplateFile = struct {
    path: []const u8,
    contents: []const u8,
};

fn readWorkspaceTemplateFile(b: *std.Build, path: []const u8) []const u8 {
    return std.fs.cwd().readFileAlloc(b.allocator, path, std.math.maxInt(usize)) catch |err| {
        std.debug.panic("failed to read workspace template {s}: {s}", .{ path, @errorName(err) });
    };
}

fn appendZigStringLiteral(output: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: []const u8) !void {
    try output.append(allocator, '"');
    for (bytes) |byte| {
        switch (byte) {
            '\\' => try output.appendSlice(allocator, "\\\\"),
            '"' => try output.appendSlice(allocator, "\\\""),
            '\n' => try output.appendSlice(allocator, "\\n"),
            '\r' => try output.appendSlice(allocator, "\\r"),
            '\t' => try output.appendSlice(allocator, "\\t"),
            else => {
                if (byte >= 0x20 and byte <= 0x7e) {
                    try output.append(allocator, byte);
                } else {
                    try output.writer(allocator).print("\\x{x:0>2}", .{byte});
                }
            },
        }
    }
    try output.append(allocator, '"');
}

fn collectWorkspaceTemplateFilesInDir(
    b: *std.Build,
    root_path: []const u8,
    relative_dir_path: []const u8,
    files: *std.ArrayList(WorkspaceTemplateFile),
) void {
    const open_path = if (relative_dir_path.len == 0)
        root_path
    else
        b.fmt("{s}/{s}", .{ root_path, relative_dir_path });

    var dir = std.fs.cwd().openDir(open_path, .{ .iterate = true }) catch |err| {
        std.debug.panic("failed to open workspace directory {s}: {s}", .{ open_path, @errorName(err) });
    };
    defer dir.close();

    var iterator = dir.iterate();
    while ((iterator.next() catch |err| {
        std.debug.panic("failed to iterate workspace directory {s}: {s}", .{ open_path, @errorName(err) });
    })) |entry| {
        const relative_path = if (relative_dir_path.len == 0)
            b.fmt("{s}", .{entry.name})
        else
            b.fmt("{s}/{s}", .{ relative_dir_path, entry.name });

        switch (entry.kind) {
            .directory => collectWorkspaceTemplateFilesInDir(b, root_path, relative_path, files),
            .file => {
                const content_path = b.fmt("{s}/{s}", .{ root_path, relative_path });
                const contents = readWorkspaceTemplateFile(b, content_path);
                files.append(b.allocator, .{
                    .path = relative_path,
                    .contents = contents,
                }) catch @panic("out of memory while collecting workspace templates");
            },
            else => {},
        }
    }
}

fn sortWorkspaceTemplateFiles(_: void, a: WorkspaceTemplateFile, b: WorkspaceTemplateFile) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

fn generateWorkspaceTemplatesModuleSource(b: *std.Build, root_path: []const u8) []const u8 {
    var files = std.ArrayList(WorkspaceTemplateFile).empty;
    defer files.deinit(b.allocator);

    collectWorkspaceTemplateFilesInDir(b, root_path, "", &files);
    std.mem.sort(WorkspaceTemplateFile, files.items, {}, sortWorkspaceTemplateFiles);

    var output = std.ArrayList(u8).empty;
    defer output.deinit(b.allocator);

    output.appendSlice(b.allocator, "pub const EmbeddedFile = struct {\n") catch @panic("out of memory");
    output.appendSlice(b.allocator, "    path: []const u8,\n") catch @panic("out of memory");
    output.appendSlice(b.allocator, "    contents: []const u8,\n") catch @panic("out of memory");
    output.appendSlice(b.allocator, "};\n\n") catch @panic("out of memory");
    output.appendSlice(b.allocator, "pub const files = [_]EmbeddedFile{\n") catch @panic("out of memory");

    for (files.items) |file| {
        output.appendSlice(b.allocator, "    .{ .path = ") catch @panic("out of memory");
        appendZigStringLiteral(&output, b.allocator, file.path) catch @panic("out of memory");
        output.appendSlice(b.allocator, ", .contents = ") catch @panic("out of memory");
        appendZigStringLiteral(&output, b.allocator, file.contents) catch @panic("out of memory");
        output.appendSlice(b.allocator, " },\n") catch @panic("out of memory");
    }

    output.appendSlice(b.allocator, "};\n") catch @panic("out of memory");
    return output.toOwnedSlice(b.allocator) catch @panic("out of memory");
}

fn addLuaSupport(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const lua_dep = b.dependency("lua", .{});
    const lua_root = lua_dep.path("");

    const lua_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "lua",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    lua_lib.root_module.addIncludePath(lua_root);
    lua_lib.root_module.addCSourceFiles(.{
        .root = lua_root,
        .files = &.{
            "lapi.c",
            "lauxlib.c",
            "lbaselib.c",
            "lcode.c",
            "lcorolib.c",
            "lctype.c",
            "ldblib.c",
            "ldebug.c",
            "ldo.c",
            "ldump.c",
            "lfunc.c",
            "lgc.c",
            "linit.c",
            "liolib.c",
            "llex.c",
            "lmathlib.c",
            "lmem.c",
            "loadlib.c",
            "lobject.c",
            "lopcodes.c",
            "loslib.c",
            "lparser.c",
            "lstate.c",
            "lstring.c",
            "lstrlib.c",
            "ltable.c",
            "ltablib.c",
            "ltm.c",
            "lundump.c",
            "lutf8lib.c",
            "lvm.c",
            "lzio.c",
        },
    });

    module.addIncludePath(lua_root);
    module.linkLibrary(lua_lib);
    module.link_libc = true;

    if (target.result.os.tag == .linux) {
        module.linkSystemLibrary("m", .{});
        module.linkSystemLibrary("dl", .{});
    }
}

fn addTimelibSupport(
    b: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const timelib_dep = b.dependency("timelib", .{
        .target = target,
        .optimize = optimize,
    });
    const timelib_root = timelib_dep.path("ext/date/lib");

    module.addIncludePath(timelib_root);
    module.addCSourceFiles(.{
        .root = timelib_root,
        .files = &.{
            "astro.c",
            "dow.c",
            "interval.c",
            "parse_date.c",
            "parse_iso_intervals.c",
            "parse_posix.c",
            "parse_tz.c",
            "timelib.c",
            "tm2unixtime.c",
            "unixtime2tm.c",
        },
        .flags = &.{
            "-DHAVE_GETTIMEOFDAY",
            "-DHAVE_UNISTD_H",
            "-DHAVE_DIRENT_H",
        },
    });
}

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("zoid", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
    });
    const workspace_templates_source = generateWorkspaceTemplatesModuleSource(b, "workspace");
    const generated = b.addWriteFiles();
    const workspace_templates_path = generated.add("workspace_templates.zig", workspace_templates_source);
    mod.addAnonymousImport("workspace_templates", .{
        .root_source_file = workspace_templates_path,
    });

    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    const cron_dep = b.dependency("cron", .{
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("vaxis", vaxis_dep.module("vaxis"));
    mod.addImport("cron", cron_dep.module("cron"));
    addLuaSupport(b, mod, target, optimize);
    addTimelibSupport(b, mod, target, optimize);

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe = b.addExecutable(.{
        .name = "zoid",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                // Here "zoid" is the name you will use in your source code to
                // import this module (e.g. `@import("zoid")`). The name is
                // repeated because you are allowed to rename your imports, which
                // can be extremely useful in case of collisions (which can happen
                // importing modules from different packages).
                .{ .name = "zoid", .module = mod },
            },
        }),
    });
    addLuaSupport(b, exe.root_module, target, optimize);

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}
