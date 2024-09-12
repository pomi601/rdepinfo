const std = @import("std");

pub const version = @import("version.zig");
pub const repository = @import("repository.zig");
pub const parse = @import("parse.zig");

test "library" {
    _ = @import("version.zig");
    _ = @import("repository.zig");
    _ = @import("parse.zig");
}
