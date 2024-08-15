const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;

const Version = struct {
    string: []const u8,
    major: usize = 0,
    minor: usize = 0,
    patch: usize = 0,

    pub fn init(string: []const u8) error{InvalidFormat}!Version {
        var major: usize = 0;
        var minor: usize = 0;
        var patch: usize = 0;

        // Format: r12345 (svn version)
        if (std.mem.startsWith(u8, string, "r")) {
            major = std.fmt.parseInt(usize, string[1..], 10) catch {
                return error.InvalidFormat;
            };
            return .{ .string = string, .major = major };
        }

        // Format 1.2.3 or 1.2-3 or 1-2-3
        var it = std.mem.splitAny(u8, string, ".-");
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
            .string = string,
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

const Constraint = enum {
    any,
    lt,
    lte,
    eq,
    gte,
    gt,

    pub fn format(self: Constraint, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        switch (self) {
            .any => try writer.print(".any", .{}),
            .lt => try writer.print("<", .{}),
            .lte => try writer.print("<=", .{}),
            .eq => try writer.print("==", .{}),
            .gte => try writer.print(">=", .{}),
            .gt => try writer.print(">", .{}),
        }
    }
};

const VersionConstraint = struct {
    constraint: Constraint = .any,
    version: ?Version = null,

    pub fn init(constraint: Constraint, version: Version) VersionConstraint {
        return .{ .constraint = constraint, .version = version };
    }

    pub fn initString(constraint: Constraint, version: []const u8) !VersionConstraint {
        assert(version.len > 0 or constraint == .any);
        return .{ .constraint = constraint, .version = try Version.init(version) };
    }

    /// Return true if other satisfies my version constraint.
    pub fn satisfied(self: VersionConstraint, other: Version) bool {
        if (self.constraint == .any) return true;
        assert(self.version != null);

        const order = other.order(self.version.?);
        switch (self.constraint) {
            .lt => return order == .lt,
            .lte => return order == .lt or order == .eq,
            .eq => return order == .eq,
            .gte => return order == .gt or order == .eq,
            .gt => return order == .gt,
            else => unreachable,
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
    versionConstraint: VersionConstraint = .{},

    /// Attempt to parse string into a name and optional version
    /// constraint. The format is `name (>= 3.2)` where the
    /// parenthetical expression is optional. The operators `=` and
    /// `==` are considered equal.
    const InitOptions = struct {
        max_size: usize = 128,
    };

    pub fn init(string: []const u8) error{InvalidFormat}!NameAndVersionConstraint {
        return initOptions(string, .{});
    }

    pub fn initOptions(string: []const u8, comptime opts: InitOptions) error{InvalidFormat}!NameAndVersionConstraint {
        const startsWith = std.mem.startsWith;
        const trim = std.mem.trim;

        var buf: [opts.max_size]u8 = undefined;
        const in_ = trim(u8, string, &std.ascii.whitespace);

        // handle cases with no ' ' sep, e.g. 'name(>= 3.1)'. We need
        // to use a local buffer to rewrite the string to one that
        // conforms to our format.
        const in = b: {
            const openRound = std.mem.indexOfScalar(u8, in_, '(');
            const space = std.mem.indexOfScalar(u8, in_, ' ');

            if (openRound) |open| {
                if (space == null or open < space.?) {
                    // add a space to help the rest of the parsing
                    if (open > opts.max_size - 2) return error.InvalidFormat;
                    std.mem.copyForwards(u8, &buf, in_[0..open]);
                    buf[open] = ' ';
                    std.mem.copyForwards(u8, buf[open + 1 ..], in_[open..]);
                    break :b buf[0 .. in_.len + 1];
                }
            }
            break :b in_;
        };

        var name: []const u8 = "";
        var it = std.mem.splitAny(u8, in, &std.ascii.whitespace);
        if (it.next()) |s| {
            name = s;
        } else return error.InvalidFormat;

        if (name.len == 0 or !std.ascii.isAlphabetic(name[0])) return error.InvalidFormat;

        const rest = trim(u8, it.rest(), &std.ascii.whitespace);

        if (startsWith(u8, rest, "(")) {
            const inner = trim(
                u8,
                trim(u8, rest, "()"),
                &std.ascii.whitespace,
            );
            // version constraint: >= 2.0, etc
            if (!startsWithAny(u8, inner, "=<>")) return error.InvalidFormat;
            it = std.mem.splitAny(u8, inner, &std.ascii.whitespace);

            // handle >=\n  1.0, i.e. multiple whitespace between op and version

            var op: ?[]const u8 = "";
            var ver: ?[]const u8 = "";

            // skip contiguous whitespace
            while (op != null and op.?.len == 0) op = it.next();
            while (ver != null and ver.?.len == 0) ver = it.next();

            if (op == null or ver == null) return error.InvalidFormat;

            if (ver.?.len == 0) {
                std.debug.print("Found an empty version with an op: {s}\n", .{op.?});
                return error.InvalidFormat;
            }

            var constraint: Constraint = .any;
            const op_ = op.?;
            if (startsWith(u8, op_, "<=")) {
                constraint = .lte;
            } else if (startsWith(u8, op_, "<")) {
                constraint = .lt;
            } else if (startsWith(u8, op_, ">=")) {
                constraint = .gte;
            } else if (startsWith(u8, op_, ">")) {
                constraint = .gt;
            } else if (startsWith(u8, op_, "=")) {
                constraint = .eq;
            } else return error.InvalidFormat;

            return .{ .name = name, .versionConstraint = try VersionConstraint.initString(constraint, ver.?) };
        } else if (rest.len > 0) return error.InvalidFormat;
        return .{ .name = name };
    }

    pub fn format(self: NameAndVersionConstraint, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("({s} {s})", .{ self.name, self.versionConstraint });
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
    try expectEqual(.any, v1.versionConstraint.constraint);
    try expectEqual(null, v1.versionConstraint.version);

    const v2 = try NameAndVersionConstraint.init("  pak  ( >= 2.0 ) ");
    try expectEqualStrings("pak", v2.name);
    try expectEqual(.gte, v2.versionConstraint.constraint);
    try expectEqual(2, v2.versionConstraint.version.?.major);

    const v3 = try NameAndVersionConstraint.init("x(= 1)");
    try expectEqualStrings("x", v3.name);
    try expectEqual(.eq, v3.versionConstraint.constraint);
    try expectEqual(1, v3.versionConstraint.version.?.major);

    try expectError(error.InvalidFormat, NameAndVersionConstraint.init("(= 1)"));
    try expectError(error.InvalidFormat, NameAndVersionConstraint.init("x (=1)"));
}

test "VersionConstraint" {
    const expect = testing.expect;

    const v1 = try VersionConstraint.initString(.any, "0");
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
