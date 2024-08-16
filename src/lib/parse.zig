//! Inspired by Zig tokenizer.
const std = @import("std");

pub const Token = struct {
    tag: Tag,
    loc: Loc,

    pub const Loc = struct {
        start: usize,
        end: usize,
    };

    pub const Tag = enum {
        invalid,
        identifier,
        string_literal,
        version_literal,
        colon,
        end_field,
        end_stanza,
        open_round,
        close_round,
        less_than,
        less_than_equal,
        equal,
        greater_than_equal,
        greater_than,
        eof,
    };
};

pub const Tokenizer = struct {
    buffer: []const u8,
    index: usize,

    pub fn init(buffer: []const u8) Tokenizer {
        return .{
            .buffer = buffer,

            // UTF-8 BOM
            .index = if (std.mem.startsWith(u8, buffer, "\xEF\xBB\xBF")) 3 else 0,
        };
    }

    const State = enum {
        start,
        string_literal,
        string_literal_backslash,
        version_literal,
        version_literal_dot,
        newline,
        invalid,
    };

    pub fn next(self: *Tokenizer) Token {
        var state: State = .start;
        var result: Token = .{
            .tag = undefined,
            .loc = .{
                .start = self.index,
                .end = undefined,
            },
        };

        while (self.index < self.buffer.len) : (self.index += 1) {
            const c = self.buffer[self.index];
            switch (state) {
                .start => switch (c) {
                    0 => {
                        if (self.index == self.buffer.len) return .{
                            .tag = .eof,
                            .loc = .{ .start = self.index, .end = self.index },
                        };
                        state = .invalid;
                    },
                    '\r', '\t', ' ' => {
                        result.loc.start = self.index + 1;
                    },
                    '\n' => {
                        state = .newline;
                    },
                    'a'...'z', 'A'...'Z', '_' => {
                        state = .identifier;
                        result.tag = .identifier;
                    },
                    '0'...'9' => {
                        state = .version_literal;
                        result.tag = .version_literal;
                    },
                    '"' => {
                        state = .string_literal;
                        result.tag = .string_literal;
                    },
                    '(' => {
                        result.tag = .open_round;
                        result.index += 1;
                        break;
                    },
                    ')' => {
                        result.tag = .close_round;
                        result.index += 1;
                        break;
                    },
                },
                .newline => switch (c) {
                    ' ', '\t' => {
                        // newline followed by space or tab continues a field definition
                        state = .start;
                        result.loc.start = self.index + 1;
                    },
                    '\n' => {
                        // two newlines in a row end stanza
                        result.tag = .end_stanza;
                        self.index = self.index + 1;
                        break;
                    },
                    else => {
                        break;
                    },
                },
                .string_literal => {
                    switch (c) {
                        0 => {
                            if (self.index != self.buffer.len) {
                                state = .invalid;
                                continue;
                            }
                            result.tag = .invalid;
                            break;
                        },
                        '\\' => {
                            state = .string_literal_backslash;
                        },
                        '"' => {
                            self.index += 1;
                            break;
                        },
                        0x01...0x09, 0x0b...0x1f, 0x7f => {
                            state = .invalid;
                        },
                        else => continue,
                    }
                },
                .string_literal_backslash => {},
                .invalid => switch (c) {
                    0 => if (self.index == self.buffer.len) {
                        result.tag = .invalid;
                        break;
                    },
                    '\n' => {
                        result.tag = .invalid;
                        break;
                    },
                    else => continue,
                },
            }
        }

        result.loc.end = self.index;
        return result;
    }
};
