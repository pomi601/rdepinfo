const std = @import("std");
const testing = std.testing;

const DCF = @import("DebianControlFile.zig");
const RDescription = @import("RDescription.zig");

test "PACKAGES.gz" {
    std.fs.cwd().access("PACKAGES.gz", .{}) catch return;
    const alloc = testing.allocator;
    var res = try DCF.parseFileAlloc(alloc, "PACKAGES.gz", .{});
    defer {
        alloc.free(res.buffer);
        res.dcf.deinit(alloc);
    }

    const dcf = res.dcf;
    var entries = try std.ArrayList(RDescription).initCapacity(alloc, dcf.stanzas.len);
    defer {
        for (entries.items) |*e| {
            e.deinit(alloc);
        }
        entries.deinit();
    }

    for (dcf.stanzas) |stanza| {
        try entries.append(try RDescription.fromStanza(alloc, stanza));
    }

    std.debug.print("Number of stanzas: {}\n", .{dcf.stanzas.len});
}
