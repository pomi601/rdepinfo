const std = @import("std");
const cmdline = @import("cmdline");

fn usage(opts: cmdline.Options) void {
    std.debug.print("Usage: {s} [--verbose]\n", .{std.fs.path.basename(opts.argv0)});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .enable_memory_limit = true }){};
    defer {
        // sadly this is not the max requested bytes -- it is reduced
        // when alloc.free() is used
        std.debug.print(
            "GPA: total requested bytes: {}\n",
            .{gpa.total_requested_bytes},
        );
        if (gpa.deinit() == .leak)
            std.debug.print("Memory leak detected.\n", .{});
    }
    const alloc = gpa.allocator();

    // current working directory
    const cwd = try std.fs.cwd().realpathAlloc(alloc, ".");
    defer alloc.free(cwd);
    std.debug.print("cwd = {s}\n", .{cwd});

    // command line options
    var opts = try cmdline.Options.init(
        alloc,
        .{
            .{"verbose"},
        },
    );
    defer opts.deinit();
    if (try opts.parse() == .err) {
        usage(opts);
        std.process.exit(1);
    }
    opts.debugPrint();

    // get path on command line
    const path = opts.positional().items[0];
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const bytes = try file.readToEndAlloc(alloc, 1024 * 1024);
    defer alloc.free(bytes);
    std.debug.print(
        "GPA: total requested bytes: {}\n",
        .{gpa.total_requested_bytes},
    );

    const stdout = std.io.getStdOut();
    try stdout.writeAll(bytes);
}

test main {
    _ = @import("DebianControlFile.zig");
    _ = @import("version.zig");
    _ = @import("RDescription.zig");
}
