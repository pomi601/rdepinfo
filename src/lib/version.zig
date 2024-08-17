const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;

pub const Version = struct {
    string: []const u8,
    major: usize = 0,
    minor: usize = 0,
    patch: usize = 0,

    pub fn init(string: []const u8) error{InvalidFormat}!Version {
        var major: usize = 0;
        var minor: usize = 0;
        var patch: usize = 0;

        const in = std.mem.trim(u8, string, &std.ascii.whitespace);

        // Format: r12345 (svn version)
        if (std.mem.startsWith(u8, in, "r")) {
            major = std.fmt.parseInt(usize, in[1..], 10) catch {
                return error.InvalidFormat;
            };
            return .{ .string = in, .major = major };
        }

        // Format 1.2.3 or 1.2-3 or 1-2-3
        var it = std.mem.splitAny(u8, in, ".-");
        if (it.next()) |maj| {
            major = std.fmt.parseInt(usize, maj, 10) catch {
                return error.InvalidFormat;
            };
        }

        if (it.next()) |min| {
            minor = std.fmt.parseInt(usize, min, 10) catch {
                return error.InvalidFormat;
            };
        }

        if (it.next()) |p| {
            patch = std.fmt.parseInt(usize, p, 10) catch {
                return error.InvalidFormat;
            };
        }

        if (major < 0 or minor < 0 or patch < 0) return error.InvalidFormat;

        return .{
            .string = in,
            .major = major,
            .minor = minor,
            .patch = patch,
        };
    }

    pub fn order(self: Version, other: Version) std.math.Order {
        if (self.major > other.major) return .gt;
        if (self.major < other.major) return .lt;
        if (self.minor > other.minor) return .gt;
        if (self.minor < other.minor) return .lt;
        if (self.patch > other.patch) return .gt;
        if (self.patch < other.patch) return .lt;
        return .eq;
    }

    pub fn format(self: Version, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("({}.{}.{})", .{ self.major, self.minor, self.patch });
    }
};

pub const Constraint = enum {
    lt,
    lte,
    eq,
    gte,
    gt,

    pub fn format(self: Constraint, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        switch (self) {
            .lt => try writer.print("<", .{}),
            .lte => try writer.print("<=", .{}),
            .eq => try writer.print("==", .{}),
            .gte => try writer.print(">=", .{}),
            .gt => try writer.print(">", .{}),
        }
    }
};

pub const VersionConstraint = struct {
    constraint: Constraint = .gte,
    version: Version = .{ .string = "0.0.0", .major = 0, .minor = 0, .patch = 0 },

    pub fn init(constraint: Constraint, version: Version) VersionConstraint {
        return .{ .constraint = constraint, .version = version };
    }

    pub fn initString(constraint: Constraint, version: []const u8) !VersionConstraint {
        return .{ .constraint = constraint, .version = try Version.init(version) };
    }

    /// Return true if other satisfies my version constraint.
    pub fn satisfied(self: VersionConstraint, other: Version) bool {
        const order = other.order(self.version);
        switch (self.constraint) {
            .lt => return order == .lt,
            .lte => return order == .lt or order == .eq,
            .eq => return order == .eq,
            .gte => return order == .gt or order == .eq,
            .gt => return order == .gt,
        }
    }

    pub fn format(self: VersionConstraint, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("({} {?})", .{ self.constraint, self.version });
    }
};

pub const NameAndVersionConstraint = struct {
    name: []const u8,
    version_constraint: VersionConstraint = .{},

    /// Attempt to parse string into a name and optional version
    /// constraint. The format is `name (>= 3.2)` where the
    /// parenthetical expression is optional. The operators `=` and
    /// `==` are considered equal.
    pub fn init(string: []const u8) error{InvalidFormat}!NameAndVersionConstraint {
        const startsWith = std.mem.startsWith;
        const trim = std.mem.trim;

        const in = trim(u8, string, &std.ascii.whitespace);

        var name: []const u8 = "";
        var it = std.mem.splitAny(u8, in, "(" ++ &std.ascii.whitespace);
        if (it.next()) |s| {
            name = s;
        } else return error.InvalidFormat;

        if (name.len == 0 or !std.ascii.isAlphabetic(name[0])) return error.InvalidFormat;

        const rest = trim(u8, it.rest(), &std.ascii.whitespace);

        const inner = trim(
            u8,
            trim(u8, rest, "()"),
            &std.ascii.whitespace,
        );

        var constraint: Constraint = .gte;

        if (startsWith(u8, inner, "<=")) {
            constraint = .lte;
        } else if (startsWith(u8, inner, "<")) {
            constraint = .lt;
        } else if (startsWith(u8, inner, ">=")) {
            constraint = .gte;
        } else if (startsWith(u8, inner, ">")) {
            constraint = .gt;
        } else if (startsWith(u8, inner, "=")) {
            constraint = .eq;
        } else {
            // no constraint found
            return .{ .name = name };
        }

        // now trim off operators and whitespace, what's left is
        // the version string
        const ver = trim(u8, inner, "<>=" ++ std.ascii.whitespace);

        return .{
            .name = name,
            .version_constraint = try VersionConstraint.initString(constraint, ver),
        };
    }

    pub fn format(self: NameAndVersionConstraint, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("({s} {s})", .{ self.name, self.version_constraint });
    }
};

fn startsWithAny(comptime T: type, haystack: []const T, candidates: []const T) bool {
    if (haystack.len < 1) return false;
    for (candidates) |x| {
        if (haystack[0] == x) return true;
    }
    return false;
}

test "NameAndVersionConstraint" {
    const expectEqual = testing.expectEqual;
    const expectEqualStrings = testing.expectEqualStrings;
    const expectError = testing.expectError;

    const v1 = try NameAndVersionConstraint.init("package");
    try expectEqualStrings("package", v1.name);
    try expectEqual(.gte, v1.version_constraint.constraint);
    try expectEqual(0, v1.version_constraint.version.major);
    try expectEqual(0, v1.version_constraint.version.minor);
    try expectEqual(0, v1.version_constraint.version.patch);

    const v2 = try NameAndVersionConstraint.init("  pak  ( >= 2.0 ) ");
    try expectEqualStrings("pak", v2.name);
    try expectEqual(.gte, v2.version_constraint.constraint);
    try expectEqual(2, v2.version_constraint.version.major);

    const v3 = try NameAndVersionConstraint.init("x(= 1)");
    try expectEqualStrings("x", v3.name);
    try expectEqual(.eq, v3.version_constraint.constraint);
    try expectEqual(1, v3.version_constraint.version.major);

    const v4 = try NameAndVersionConstraint.init("x (=1)");
    try expectEqualStrings("x", v4.name);
    try expectEqual(.eq, v4.version_constraint.constraint);
    try expectEqual(1, v4.version_constraint.version.major);

    try expectError(error.InvalidFormat, NameAndVersionConstraint.init("(= 1)"));
}

test "VersionConstraint" {
    const expect = testing.expect;

    const v1 = try VersionConstraint.initString(.gte, "0");
    try expect(v1.satisfied(try Version.init("1.0")));
    try expect(v1.satisfied(try Version.init("0.0")));

    const v2 = try VersionConstraint.initString(.gte, "3.2.4");
    try expect(v2.satisfied(try Version.init("3.2.4")));
    try expect(v2.satisfied(try Version.init("3.2.5")));
    try expect(v2.satisfied(try Version.init("3.3.4")));
    try expect(v2.satisfied(try Version.init("4.0.0")));
    try expect(!v2.satisfied(try Version.init("3")));
    try expect(!v2.satisfied(try Version.init("3.2.3")));
    try expect(!v2.satisfied(try Version.init("3.1.4")));
    try expect(!v2.satisfied(try Version.init("2.2.4")));

    const v3 = try VersionConstraint.initString(.lte, "1.2.3");
    try expect(v3.satisfied(try Version.init("1.2.3")));
    try expect(v3.satisfied(try Version.init("1.2.2")));
    try expect(!v3.satisfied(try Version.init("1.2.4")));
}

test "Version.init" {
    const expectEqual = testing.expectEqual;
    const expectError = testing.expectError;

    const v1 = try Version.init("1.2.3");
    try expectEqual(1, v1.major);
    try expectEqual(2, v1.minor);
    try expectEqual(3, v1.patch);

    const v2 = try Version.init("r1234");
    try expectEqual(1234, v2.major);
    try expectEqual(0, v2.minor);
    try expectEqual(0, v2.patch);

    const v3 = try Version.init("1");
    try expectEqual(1, v3.major);
    try expectEqual(0, v3.minor);
    try expectEqual(0, v3.patch);

    const v4 = try Version.init("1.2");
    try expectEqual(1, v4.major);
    try expectEqual(2, v4.minor);
    try expectEqual(0, v4.patch);

    const v5 = try Version.init("0.2");
    try expectEqual(0, v5.major);
    try expectEqual(2, v5.minor);
    try expectEqual(0, v5.patch);

    try expectError(error.InvalidFormat, Version.init("v123"));
    try expectError(error.InvalidFormat, Version.init("r123.32"));
    try expectError(error.InvalidFormat, Version.init(".32"));

    try expectError(error.InvalidFormat, Version.init("-3.0.4"));
}

test "Version.order" {
    const expectEqual = testing.expectEqual;

    try expectEqual(.gt, (try Version.init("1")).order(try Version.init("0")));
    try expectEqual(.lt, (try Version.init("0")).order(try Version.init("1")));
    try expectEqual(.eq, (try Version.init("1")).order(try Version.init("1")));

    try expectEqual(.gt, (try Version.init("1.1")).order(try Version.init("1")));
    try expectEqual(.gt, (try Version.init("1.1")).order(try Version.init("1.0")));
    try expectEqual(.gt, (try Version.init("1.1")).order(try Version.init("1.0.1")));

    try expectEqual(.lt, (try Version.init("1.0.0")).order(try Version.init("1.0.1")));
    try expectEqual(.eq, (try Version.init("1.0.0")).order(try Version.init("1.0.0")));

    try expectEqual(.gt, (try Version.init("1.0.1")).order(try Version.init("1.0.0")));
    try expectEqual(.lt, (try Version.init("1.0.0")).order(try Version.init("1.0.1")));
    try expectEqual(.eq, (try Version.init("1.0.0")).order(try Version.init("1.0.0")));

    try expectEqual(.gt, (try Version.init("1.1")).order(try Version.init("1.0.5")));
    try expectEqual(.lt, (try Version.init("0")).order(try Version.init("1")));
}
