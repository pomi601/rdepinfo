//! Debian Control File
//!
//! https://www.debian.org/doc/debian-policy/ch-controlfields.html
//!
const std = @import("std");
const testing = std.testing;
const util = @import("util.zig");

const Allocator = std.mem.Allocator;
const Self = @This();

pub const Field = struct {
    key: []const u8,
    val: []const u8,
};

const StanzaRaw = struct {
    lines: [][]const u8,
};

pub const Stanza = struct {
    fields: []Field, // owned

    pub fn fromRaw(alloc: Allocator, raw: StanzaRaw) (Allocator.Error || error{InvalidFormat})!Stanza {
        var fields = std.ArrayList(Field).init(alloc);
        for (raw.lines) |line| {
            if (std.mem.indexOfScalar(u8, line, ':')) |pos| {
                if (pos + 1 >= line.len) return error.InvalidFormat;

                try fields.append(Field{
                    .key = line[0..pos],
                    .val = std.mem.trim(u8, line[pos + 1 ..], &std.ascii.whitespace),
                });
                continue;
            }
            return error.InvalidFormat;
        }

        return .{ .fields = try fields.toOwnedSlice() };
    }

    pub fn deinit(self: *Stanza, alloc: Allocator) void {
        alloc.free(self.fields);
        self.* = undefined;
    }

    pub fn clone(self: Stanza, alloc: Allocator) Allocator.Error!Stanza {
        return .{ .fields = try alloc.dupe(Field, self.fields) };
    }
};

stanzas: []Stanza,

pub fn deinit(self: *Self, alloc: Allocator) void {
    for (self.stanzas) |*stanza| {
        stanza.deinit(alloc);
    }
    alloc.free(self.stanzas);
    self.* = undefined;
}

const ParseFileOptions = struct {
    max_bytes: usize = std.math.maxInt(usize),
};

const ParseFileResult = struct {
    buffer: []u8,
    dcf: Self,
};

/// Read the entire file into memory, decompressing it if it a gzip
/// file, and parse it. Caller must free the returned buffer with the
/// same allocator.
pub fn parseFileAlloc(
    alloc: Allocator,
    abs_or_rel_path: []const u8,
    comptime opts: ParseFileOptions,
) !ParseFileResult {
    const bytes = b: {
        if (try util.isGzipFile(abs_or_rel_path))
            break :b try util.decompressGzipFile(alloc, abs_or_rel_path);

        const file = try std.fs.cwd().openFile(abs_or_rel_path, .{});
        defer file.close();
        break :b try file.readToEndAlloc(alloc, opts.max_bytes);
    };

    return .{ .buffer = bytes, .dcf = try parse(alloc, bytes) };
}

pub fn parse(alloc: Allocator, bs: []const u8) !Self {
    var pos: usize = 0;
    var column_pos: usize = 0;
    var line_start: usize = 0;
    var in_comment = false;

    var stanzas_raw = std.ArrayList(StanzaRaw).init(alloc);
    defer {
        for (stanzas_raw.items) |*raw| {
            alloc.free(raw.lines);
        }
        stanzas_raw.deinit();
    }
    var lines = std.ArrayList([]const u8).init(alloc);
    defer lines.deinit();

    const empty_stanza = StanzaRaw{ .lines = undefined };
    var current_stanza = empty_stanza;

    // record line starting position
    line_start = pos;

    while (pos < bs.len) : (pos += 1) {
        switch (bs[pos]) {
            '\n' => {
                // if in_comment, reset line_start to ignore previous line
                if (in_comment) {
                    line_start = pos + 1;
                    in_comment = false;
                    continue;
                }

                // reset column position and in_comment
                column_pos = 0;
                in_comment = false;

                // look forward, a space or tab means a continuation
                if (pos + 1 < bs.len) {
                    if (bs[pos + 1] == 0x20 or bs[pos + 1] == 0x09) continue;
                }

                // line ends
                const line = bs[line_start..pos];

                if (line.len == 0) {
                    // field ends.
                    // if no lines in stanza, don't end it. Ignores
                    // multiple contiguous newlines at start of file
                    // or between stanzas.
                    if (lines.items.len > 0) {
                        current_stanza.lines = try lines.toOwnedSlice();
                        try stanzas_raw.append(current_stanza);
                        current_stanza = empty_stanza;
                        lines.clearRetainingCapacity();
                    }
                } else {
                    try lines.append(line);
                }
                line_start = pos + 1;
            },
            '#' => {
                if (column_pos == 0) in_comment = true;
                column_pos += 1;
            },
            else => {
                column_pos += 1;
            },
        }
    }
    // end of data, line and field end
    if (pos - line_start > 0) {
        const line = bs[line_start..pos];
        try lines.append(line);
    }
    current_stanza.lines = try lines.toOwnedSlice();
    try stanzas_raw.append(current_stanza);

    // parse raw into structured
    var stanzas = try std.ArrayList(Stanza).initCapacity(alloc, stanzas_raw.items.len);
    errdefer stanzas.deinit();
    for (stanzas_raw.items) |raw| {
        stanzas.appendAssumeCapacity(try Stanza.fromRaw(alloc, raw));
    }

    return .{ .stanzas = try stanzas.toOwnedSlice() };
}

pub fn debugPrint(self: *const Self) void {
    std.debug.print("{*}\n", .{self});
    std.debug.print(" {} Stanzas:\n", .{self.stanzas.len});

    for (self.stanzas, 1..) |stanza, i| {
        std.debug.print("  {}:\n", .{i});

        for (stanza.fields) |field| {
            std.debug.print("  {s}: {s}\n", .{ field.key, field.val });
        }
    }
}

test "parse" {
    const data =
        \\#comment
        \\
        \\
        \\Field1: val1 val2
        \\ continues
        \\ keeps continuing
        \\# comment line
        \\Field2: val3 val4
        \\# another comment
        \\
        \\NextStanza: val1 val2
    ;

    const alloc = std.testing.allocator;
    var res = try Self.parse(alloc, data);
    defer res.deinit(alloc);

    try testing.expectEqual(2, res.stanzas.len);
    try testing.expectEqual(2, res.stanzas[0].fields.len);
    try testing.expectEqual(1, res.stanzas[1].fields.len);

    try testing.expectEqualStrings("Field1", res.stanzas[0].fields[0].key);
    try testing.expectEqualStrings("val1 val2\n continues\n keeps continuing", res.stanzas[0].fields[0].val);
}

test "misformed" {
    const data =
        \\Field1 is missing a colon
    ;
    const alloc = std.testing.allocator;
    try testing.expectError(error.InvalidFormat, Self.parse(alloc, data));
}
