const std = @import("std");

const Build = std.Build;
const Compile = std.Build.Step.Compile;
const ResolvedTarget = Build.ResolvedTarget;
const OptimizeMode = std.builtin.OptimizeMode;

const targets: []const std.Target.Query = &.{
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .linux },
    .{ .cpu_arch = .x86_64, .os_tag = .macos },
    .{ .cpu_arch = .x86_64, .os_tag = .linux },
    .{ .cpu_arch = .x86_64, .os_tag = .windows },
};

pub fn build_fetch_assets(b: *Build, target: ResolvedTarget, optimize: OptimizeMode) *Compile {
    const exe = b.addExecutable(.{
        .name = "fetch-assets",
        .root_source_file = b.path("src/exe/fetch-assets/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // const common = b.dependency("common", .{
    //     .target = target,
    //     .optimize = optimize,
    // }).module("common");

    // exe.root_module.addImport("common", common);
    return exe;
}

pub fn build(b: *Build) !void {
    // -- begin options ------------------------------------------------------
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dep_optimize = b.option(
        std.builtin.OptimizeMode,
        "dep-optimize",
        "optimization mode of most dependencies",
    ) orelse .ReleaseFast;
    // -- end options --------------------------------------------------------

    // -- begin executable ---------------------------------------------------
    const exe = b.addExecutable(.{
        .name = "rdepinfocmd",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mos = b.dependency("mos", .{
        .target = target,
        .optimize = dep_optimize,
    }).module("mos");
    exe.root_module.addImport("mos", mos);

    const cmdline = b.dependency("cmdline", .{
        .target = target,
        .optimize = dep_optimize,
    }).module("cmdline");
    exe.root_module.addImport("cmdline", cmdline);

    const stable_list = b.dependency("stable_list", .{
        .target = target,
        .optimize = dep_optimize,
    }).module("stable_list");
    exe.root_module.addImport("stable_list", stable_list);

    b.installArtifact(exe);
    b.getInstallStep().dependOn(&exe.step);
    // -- end executable -----------------------------------------------------

    // -- begin C static library -----------------------------------------------

    var lib_for_docs: ?*std.Build.Step.Compile = null;

    for (targets) |t| {
        const target_ = b.resolveTargetQuery(t);
        const lib = b.addStaticLibrary(.{
            .name = "rdepinfo",
            .root_source_file = b.path("src/lib/root.zig"),
            .target = target_,
            .optimize = optimize,

            // position independent code
            .pic = true,

            // this prevents the inclusion of stack trace printing
            // code, which is roughly 500k.
            // https://ziggit.dev/t/strip-option-in-build-zig/1371/8
            .strip = true,
        });
        lib.root_module.addImport("mos", mos);
        lib.root_module.addImport("stable_list", stable_list);
        lib.linkLibC();

        // just take the first one, it doesn't matter
        if (lib_for_docs == null) lib_for_docs = lib;

        const target_out = b.addInstallArtifact(lib, .{
            .dest_dir = .{
                .override = .{
                    .custom = try t.zigTriple(b.allocator),
                },
            },
        });

        b.getInstallStep().dependOn(&target_out.step);
    }

    // -- end C static library -----------------------------------------------

    // -- begin module -------------------------------------------------------

    const mod = b.addModule("rdepinfo", .{
        .root_source_file = b.path("src/lib/repository.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("mos", mos);
    mod.addImport("stable_list", stable_list);

    // -- end module ---------------------------------------------------------

    // -- begin tools --------------------------------------------------------

    const fetch_assets = build_fetch_assets(b, target, optimize);
    b.installArtifact(fetch_assets);
    b.getInstallStep().dependOn(&fetch_assets.step);

    // -- end tools ----------------------------------------------------------

    // -- begin check --------------------------------------------------------
    const exe_check = b.addExecutable(.{
        .name = "rdepinfo",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_check.root_module.addImport("mos", mos);
    exe_check.root_module.addImport("cmdline", cmdline);
    exe_check.root_module.addImport("stable_list", stable_list);

    const check = b.step("check", "Check if rdepinfo compiles");
    check.dependOn(&exe_check.step);
    check.dependOn(&fetch_assets.step);
    // -- end check ----------------------------------------------------------

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
    lib_unit_tests.root_module.addImport("stable_list", stable_list);
    lib_unit_tests.root_module.addImport("mos", mos);
    lib_unit_tests.linkLibC();

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_unit_tests.root_module.addImport("stable_list", stable_list);
    exe_unit_tests.root_module.addImport("mos", mos);

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
    // -- end test -----------------------------------------------------------

    // -- begin dependency tests ---------------------------------------------

    const dep_test_step = b.step(
        "dep-test",
        "Run all dependency unit tests",
    );

    // NOTE: these only find tests which have the same
    // root_source_file as the module itself.
    dep_test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .root_source_file = cmdline.root_source_file.?,
        .target = target,
        .optimize = dep_optimize,
    })).step);

    dep_test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .root_source_file = stable_list.root_source_file.?,
        .target = target,
        .optimize = dep_optimize,
    })).step);

    dep_test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .root_source_file = mos.root_source_file.?,
        .target = target,
        .optimize = dep_optimize,
    })).step);

    // -- end dependency tests ---------------------------------------------

    // -- begin generated documentation ------------------------------------

    if (lib_for_docs) |lib| {
        const doc_step = b.step("doc", "Generate documentation");
        const doc_install = b.addInstallDirectory(.{
            .install_dir = .prefix,
            .install_subdir = "doc",
            .source_dir = lib.getEmittedDocs(),
        });
        doc_install.step.dependOn(&lib.step);
        doc_step.dependOn(&doc_install.step);
        b.getInstallStep().dependOn(&doc_install.step);
    }

    // -- end generated documentation --------------------------------------

}
