const std = @import("std");
const testing = std.testing;

test "library" {
    _ = @import("version.zig");
    _ = @import("repository.zig");
    _ = @import("parse.zig");
}
