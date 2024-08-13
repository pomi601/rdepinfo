const std = @import("std");
const cmdline = @import("cmdline");

fn usage(opts: cmdline.Options) void {
    std.debug.print("Usage: {s} [--verbose]\n", .{std.fs.path.basename(opts.argv0)});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .enable_memory_limit = true }){};
    defer {
        std.debug.print("GPA: total requested bytes: {}\n", .{gpa.total_requested_bytes});
        if (gpa.deinit() == .leak)
            std.debug.print("Memory leak detected.\n", .{});
    }
    const alloc = gpa.allocator();
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
}

test main {}
