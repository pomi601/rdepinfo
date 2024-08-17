const std = @import("std");
const testing = std.testing;

test "library" {
    _ = @import("version.zig");
    _ = @import("RDescription.zig");
    _ = @import("packages.zig");
    _ = @import("parse.zig");
    _ = @import("util.zig");
}
