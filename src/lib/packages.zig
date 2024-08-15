const std = @import("std");
const testing = std.testing;

const DCF = @import("DebianControlFile.zig");

test "PACKAGES.gz" {
    std.fs.cwd().access("PACKAGES.gz", .{}) catch return;
    const alloc = testing.allocator;
    var res = try DCF.parseFileAlloc(alloc, "PACKAGES.gz", .{});
    defer {
        alloc.free(res.buffer);
        res.dcf.deinit(alloc);
    }

    const dcf = res.dcf;

    std.debug.print("Number of stanzas: {}\n", .{dcf.stanzas.len});
}
