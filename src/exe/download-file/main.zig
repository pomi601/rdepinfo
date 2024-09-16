const std = @import("std");
const Allocator = std.mem.Allocator;

const common = @import("common");
const download = common.download;

fn usage() noreturn {
    std.debug.print(
        \\Usage: download-file <url> <out_file_path>
    , .{});
    std.process.exit(1);
}

const NUM_ARGS = 2;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const args = try std.process.argsAlloc(arena.allocator());
    defer std.process.argsFree(arena.allocator(), args);

    if (args.len != NUM_ARGS + 1) usage();
    const url = args[1];
    const out_file_path = args[2];

    download.downloadFile(arena.allocator(), url, out_file_path) catch |err| {
        fatal("ERROR: download of '{s}' to '{s}' failed: {s}\n", .{
            url,
            out_file_path,
            @errorName(err),
        });
    };
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format, args);
    std.process.exit(1);
}
