const std = @import("std");
const testing = std.testing;
const parse = @import("parse.zig");
const util = @import("util.zig");

const RDescription = @import("RDescription.zig");

test "PACKAGES.gz" {
    const path = "PACKAGES.gz";
    std.fs.cwd().access(path, .{}) catch return;
    const alloc = testing.allocator;

    const source = b: {
        if (try util.isGzipFile(path))
            break :b try util.decompressGzipFile(alloc, path);

        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        break :b try file.readToEndAlloc(alloc, std.math.maxInt(usize));
    };
    defer alloc.free(source);

    var parser = try parse.Parser.init(alloc, source);
    defer parser.deinit();
    parser.parse() catch |err| switch (err) {
        error.ParseError => {
            if (parser.parse_error) |perr| {
                std.debug.print("ERROR: ParseError: {s}: {}:{s}\n", .{ perr.message, perr.token, source[perr.token.loc.start..perr.token.loc.end] });
            }
        },
        error.OutOfMemory => {
            std.debug.print("ERROR: OutOfMemory\n", .{});
        },
    };

    std.debug.print("Parser nodes: {d}\n", .{parser.nodes.items.len});
    std.debug.print("Number of stanzas parsed: {d}\n", .{parser.numStanzas()});

    var rdv2 = try RDescription.fromAst(alloc, parser.nodes.items, 0);
    defer rdv2.deinit(alloc);

    var entries = std.ArrayList(RDescription).init(alloc);
    defer {
        for (entries.items) |*e| {
            e.deinit(alloc);
        }
        entries.deinit();
    }

    var count: usize = 1000;
    while (count > 0) : (count -= 1) {
        try entries.append(try RDescription.fromAst(alloc, parser.nodes.items, count));
    }
}
