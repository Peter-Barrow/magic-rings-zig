const std = @import("std");
const builtin = @import("builtin");

// // Although this function looks imperative, note that its job is to
// // declaratively construct a build graph that will be executed by an external
// // runner.
// pub fn build(b: *std.Build) void {
//     // Standard target options allows the person running `zig build` to choose
//     // what target to build for. Here we do not override the defaults, which
//     // means any target is allowed, and the default is native. Other options
//     // for restricting supported target set are available.
//     const target = b.standardTargetOptions(.{});
//
//     // Standard optimization options allow the person running `zig build` to select
//     // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
//     // set a preferred release mode, allowing the user to decide how to optimize.
//     const optimize = b.standardOptimizeOption(.{});
//
//     const exe = b.addExecutable(.{
//         .name = "magic-ring-zig",
//         .root_source_file = b.path("src/main.zig"),
//         .target = target,
//         .optimize = optimize,
//         // .link_libc = true,
//     });
//
//     // If building on windows then add zigwin32
//     const zigwin32 = b.dependency("zigwin32", .{}).module("zigwin32");
//     exe.root_module.addImport("zigwin32", zigwin32);
//
//     const known_folders = b.dependency("known-folders", .{}).module("known-folders");
//     exe.root_module.addImport("known-folders", known_folders);
//
//     // This declares intent for the executable to be installed into the
//     // standard location when the user invokes the "install" step (the default
//     // step when running `zig build`).
//     b.installArtifact(exe);
//
//     // This *creates* a Run step in the build graph, to be executed when another
//     // step is evaluated that depends on it. The next line below will establish
//     // such a dependency.
//     const run_cmd = b.addRunArtifact(exe);
//
//     // By making the run step depend on the install step, it will be run from the
//     // installation directory rather than directly from within the cache directory.
//     // This is not necessary, however, if the application depends on other installed
//     // files, this ensures they will be present and in the expected location.
//     run_cmd.step.dependOn(b.getInstallStep());
//
//     // This allows the user to pass arguments to the application in the build
//     // command itself, like this: `zig build run -- arg1 arg2 etc`
//     if (b.args) |args| {
//         run_cmd.addArgs(args);
//     }
//
//     // This creates a build step. It will be visible in the `zig build --help` menu,
//     // and can be selected like this: `zig build run`
//     // This will evaluate the `run` step rather than the default, which is "install".
//     const run_step = b.step("run", "Run the app");
//     run_step.dependOn(&run_cmd.step);
//
//     // Creates a step for unit testing. This only builds the test executable
//     // but does not run it.
//     const lib_unit_tests = b.addTest(.{
//         .root_source_file = b.path("src/root.zig"),
//         .target = target,
//         .optimize = optimize,
//         // .link_libc = true,
//     });
//
//     const use_shm_funcs = b.option(
//         bool,
//         "use_shm_funcs",
//         "Use shm_open and shm_unlink instead of memfd_create",
//     ) orelse false;
//
//     const options = b.addOptions();
//     options.addOption(bool, "use_shm_funcs", use_shm_funcs);
//     lib_unit_tests.root_module.addOptions("config", options);
//     lib_unit_tests.root_module.addImport("zigwin32", zigwin32);
//     lib_unit_tests.root_module.addImport("known-folders", known_folders);
//
//     const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
//
//     // const exe_unit_tests = b.addTest(.{
//     //     .root_source_file = b.path("src/main.zig"),
//     //     .target = target,
//     //     .optimize = optimize,
//     // });
//
//     // const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
//
//     // Similar to creating the run step earlier, this exposes a `test` step to
//     // the `zig build --help` menu, providing a way for the user to request
//     // running the unit tests.
//     const test_step = b.step("test", "Run unit tests");
//     test_step.dependOn(&run_lib_unit_tests.step);
//     // test_step.dependOn(&run_exe_unit_tests.step);
// }

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

    const zigwin32 = b.dependency("zigwin32", .{}).module("win32");
    const known_folders = b.dependency("known_folders", .{}).module("known-folders");
    const shared_memory = b.dependency("shared_memory", .{}).module("shared_memory");
    shared_memory.addImport("known-folders", known_folders);

    const use_shm_funcs = b.option(
        bool,
        "use_shm_funcs",
        "Use shm_open and shm_unlink instead of memfd_create",
    ) orelse false;

    const lib_unit_tests = b.addTest(
        .{
            .root_source_file = b.path("src/magic_ring.zig"),
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
            .root_source_file = b.path("src/magic_ring.zig"),
            .target = target,
            .optimize = optimize,
        },
    );

    unit_test_check.root_module.addImport("zigwin32", zigwin32);
    unit_test_check.root_module.addImport("known-folders", known_folders);
    unit_test_check.root_module.addImport("shared_memory", shared_memory);

    const check = b.step("check", "Check if tests compiles");
    check.dependOn(&unit_test_check.step);
}
