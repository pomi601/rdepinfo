const std = @import("std");
const mos = @import("mos");
const cmdline = @import("cmdline");
const Cmdline = cmdline.Options(.{});

const Repository = @import("lib/repository.zig").Repository;

fn usage(opts: Cmdline) void {
    std.debug.print(
        \\Usage: {s} [--verbose] PACKAGES...
        \\  Positional arguments:
        \\    PACKAGES: may be text or gzip file in R package repository format
        \\
    ,
        .{std.fs.path.basename(opts.argv0)},
    );
}

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        if (gpa.deinit() == .leak)
            std.debug.print("Memory leak detected.\n", .{});
    }
    const alloc = gpa.allocator();

    // current working directory
    const cwd = try std.fs.cwd().realpathAlloc(alloc, ".");
    defer alloc.free(cwd);
    // std.debug.print("cwd = {s}\n", .{cwd});

    // command line options
    var opts = try Cmdline.init(
        alloc,
        .{
            .{"verbose"},
        },
    );
    defer opts.deinit();
    if (try opts.parse() == .err or opts.positional().items.len < 1) {
        usage(opts);
        std.process.exit(1);
    }
    // opts.debugPrint();

    var repo = try Repository.init(alloc);
    defer repo.deinit();

    for (opts.positional().items) |path| {
        const source_: ?[]const u8 = try mos.file.readFileMaybeGzip(alloc, path);
        defer if (source_) |s| alloc.free(s); // free before next iteration

        if (source_) |source| {
            try std.fmt.format(stderr, "Reading file {s}...", .{path});
            const count = try repo.read(source);
            try std.fmt.format(stderr, " {} packages read.\n", .{count});
        }
    }

    // const stdout = std.io.getStdOut();
    // try stdout.writeAll(bytes);

    try std.fmt.format(stdout, "Done.\n", .{});
    try std.fmt.format(stdout, "Number of packages: {}\n", .{repo.packages.len});
}
