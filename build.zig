const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {

    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // const optimize = b.standardOptimizeOption(.{.preferred_optimize_mode = .ReleaseSafe});

    const zigwin32 = b.dependency("zigwin32", .{}).module("win32");
    const known_folders = b.dependency("known_folders", .{}).module("known-folders");
    const shared_memory = b.dependency("shared_memory", .{}).module("shared_memory");
    shared_memory.addImport("zigwin32", zigwin32);
    shared_memory.addImport("known-folders", known_folders);

    const use_shm_funcs = b.option(
        bool,
        "use_shm_funcs",
        "Use shm_open and shm_unlink instead of memfd_create",
    ) orelse false;

    const lib_unit_tests = b.addTest(
        .{
            .root_source_file = b.path("src/magicrings.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = use_shm_funcs,
        },
    );

    const options = b.addOptions();
    options.addOption(bool, "use_shm_funcs", use_shm_funcs);
    lib_unit_tests.root_module.addImport("zigwin32", zigwin32);
    lib_unit_tests.root_module.addImport("known-folders", known_folders);
    lib_unit_tests.root_module.addImport("shared_memory", shared_memory);

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    const unit_test_check = b.addTest(
        .{
            .root_source_file = b.path("src/magicrings.zig"),
            .target = target,
            .optimize = optimize,
        },
    );

    unit_test_check.root_module.addImport("zigwin32", zigwin32);
    unit_test_check.root_module.addImport("known-folders", known_folders);
    unit_test_check.root_module.addImport("shared_memory", shared_memory);

    const check = b.step("check", "Check if tests compiles");
    check.dependOn(&unit_test_check.step);

    const install_docs = b.addInstallDirectory(.{
        .source_dir = lib_unit_tests.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Install docs into zig-out/docs");
    docs_step.dependOn(&install_docs.step);
}
