const std = @import("std");

test "library" {
    _ = @import("version.zig");
    _ = @import("repository.zig");
    _ = @import("parse.zig");
}
