const std = @import("std");
const testing = std.testing;

test "library" {
    _ = @import("DebianControlFile.zig");
    _ = @import("version.zig");
    _ = @import("RDescription.zig");
    _ = @import("packages.zig");
    _ = @import("util.zig");
}
