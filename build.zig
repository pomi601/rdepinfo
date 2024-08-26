const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // -- begin options ------------------------------------------------------
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dep_optimize = b.option(
        std.builtin.OptimizeMode,
        "dep-optimize",
        "optimization mode of most dependencies",
    ) orelse .ReleaseFast;
    // -- end options --------------------------------------------------------

    // -- begin static library -----------------------------------------------
    const lib = b.addStaticLibrary(.{
        .name = "rdepinfo",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/lib/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(lib);
    // -- end static library -------------------------------------------------

    // -- begin executable ---------------------------------------------------
    const exe = b.addExecutable(.{
        .name = "rdepinfo",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.linkLibrary(lib);

    const cmdline = b.dependency("cmdline", .{
        .target = target,
        .optimize = dep_optimize,
    }).module("cmdline");
    exe.root_module.addImport("cmdline", cmdline);

    const string_storage = b.dependency("string_storage", .{
        .target = target,
        .optimize = dep_optimize,
    }).module("string_storage");
    exe.root_module.addImport("string_storage", string_storage);

    b.installArtifact(exe);
    // -- end executable -----------------------------------------------------

    // -- begin run ----------------------------------------------------------
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
    // -- end run ------------------------------------------------------------

    // -- begin test ---------------------------------------------------------
    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/lib/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_unit_tests.root_module.addImport("string_storage", string_storage);

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_unit_tests.root_module.addImport("string_storage", string_storage);

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
    // -- end test -----------------------------------------------------------
}
