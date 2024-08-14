//! Debian Control File
//!
//! https://www.debian.org/doc/debian-policy/ch-controlfields.html
//!
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Self = @This();

const Field = struct {
    key: []const u8,
    val: []const u8,
};

const StanzaRaw = struct {
    lines: [][]const u8,

    pub fn deinit(self: *StanzaRaw, alloc: Allocator) void {
        alloc.free(self.lines);
        self.* = undefined;
    }
};

const Stanza = struct {
    fields: std.ArrayList(Field),

    pub fn fromRaw(alloc: Allocator, raw: StanzaRaw) error{ InvalidFormat, OutOfMemory }!Stanza {
        var fields = std.ArrayList(Field).init(alloc);
        for (raw.lines) |line| {
            if (std.mem.indexOfScalar(u8, line, ':')) |pos| {
                if (pos + 1 >= line.len) return error.InvalidFormat;

                try fields.append(Field{
                    .key = line[0 .. pos - 1],
                    .val = line[pos + 1 ..],
                });
                continue;
            }
            return error.InvalidFormat;
        }

        return .{ .fields = fields };
    }

    pub fn deinit(self: *Stanza) void {
        self.fields.deinit();
        self.* = undefined;
    }
};

stanzas: []Stanza,

pub fn deinit(self: *Self, alloc: Allocator) void {
    for (self.stanzas) |*stanza| {
        stanza.deinit();
    }
    alloc.free(self.stanzas);
    self.* = undefined;
}

pub fn parse(alloc: Allocator, bs: []const u8) !Self {
    var pos: usize = 0;
    var column_pos: usize = 0;
    var line_start: usize = 0;
    var in_comment = false;

    var stanzas_raw = std.ArrayList(StanzaRaw).init(alloc);
    defer {
        for (stanzas_raw.items) |*raw| {
            raw.deinit(alloc);
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
                if (pos < bs.len - 1 and bs[pos + 1] == 0x20 or bs[pos + 1] == 0x09) continue;

                // line ends.
                // look back and chop \r if any

                const line = bs[line_start..(if (bs[pos - 1] == '\r') pos - 1 else pos)];

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
                    std.debug.print("Appending line: {s}\n", .{line});
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

        for (stanza.fields.items) |field| {
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
    std.debug.print("Length of input string: {}\n", .{data.len});

    const alloc = std.testing.allocator;
    var res = try Self.parse(alloc, data);
    defer res.deinit(alloc);

    std.debug.print("\nInput:\n{s}\n", .{data});

    res.debugPrint();

    try testing.expectEqual(2, res.stanzas.len);
    try testing.expectEqual(2, res.stanzas[0].fields.items.len);
    try testing.expectEqual(1, res.stanzas[1].fields.items.len);
}

test "misformed" {
    const data =
        \\Field1 is missing a colon
    ;
    const alloc = std.testing.allocator;
    try testing.expectError(error.InvalidFormat, Self.parse(alloc, data));
}
