//! Inspired by Zig tokenizer.
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const version = @import("version.zig");

// -- parse ------------------------------------------------------------------

// Generate an AST.
//
// This is a tree

/// Parser
///
/// NodeList format:
///
/// RootNode
/// StanzaNode
///   FieldNode
///      StringNode or NameAndVersionNode
///      ...
///   FieldEndNode
///   ... (more FieldNode/FieldEndNode pairs)
/// StanzaEndNode
/// ... (more StanzaNode/StanzaEndNode pairs)
const Parser = struct {
    alloc: Allocator,
    source: []const u8,
    nodes: NodeList,
    parse_error: ?ParseError = null,

    //
    tokenizer: Tokenizer,

    const ParseError = struct {
        message: []const u8,
        token: Token,
    };

    const Ast = struct {
        nodes: NodeList,
    };
    const NodeList = std.ArrayList(Node);

    const RootNode = struct {};

    const StanzaNode = struct {};
    const FieldNode = struct {
        name: []const u8,
    };
    const NameAndVersionNode = struct {
        name: []const u8,
        version_constraint: version.VersionConstraint = .{},
    };
    const StringNode = struct {
        value: []const u8,
    };
    const FieldEndNode = void;
    const StanzaEndNode = void;

    const Node = union(enum) {
        root: RootNode,
        stanza: StanzaNode,
        field: FieldNode,
        name_and_version: NameAndVersionNode,
        string_node: StringNode,
        field_end: FieldEndNode,
        stanza_end: StanzaEndNode,
        eof: void,

        pub fn format(self: Node, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            _ = fmt;
            _ = options;
            try switch (self) {
                .root => writer.print("(root)", .{}),
                .stanza => writer.print("(stanza)", .{}),
                .field => |x| writer.print("(field {s})", .{x.name}),
                .name_and_version => |x| writer.print("(name-ver {s} {s})", .{ x.name, x.version_constraint }),
                .string_node => |x| writer.print("(string {s})", .{x.value}),
                .field_end => writer.print("(field-end)", .{}),
                .stanza_end => writer.print("(stanza-end)", .{}),
                .eof => writer.print("(eof)", .{}),
            };
        }
    };

    const State = enum {
        expect_field,
        expect_colon,
        expect_value,
    };

    pub fn init(alloc: Allocator, source: []const u8) !Parser {
        return .{
            .alloc = alloc,
            .source = source,
            .nodes = try std.ArrayList(Node).initCapacity(alloc, source.len / 5),
            .tokenizer = Tokenizer.init(source),
        };
    }

    pub fn deinit(self: *Parser) void {
        self.tokenizer.deinit();
        self.nodes.deinit();
        self.* = undefined;
    }

    pub fn parse(self: *Parser) !void {
        try self.nodes.append(Node{ .root = .{} });

        var value_tokens = try std.ArrayList(Token).initCapacity(self.alloc, 32);
        defer value_tokens.deinit();

        while (true) {
            const token = try self.parseStanza();
            if (token.tag == .eof) break;
        }
    }

    fn parseStanza(self: *Parser) !Token {
        try self.nodes.append(Node{ .stanza = .{} });

        var token: Token = undefined;
        while (true) {
            token = try self.parseField();
            if (token.tag == .eof) break;
        }

        try self.nodes.append(Node{ .stanza_end = {} });
        return token;
    }

    fn parseField(self: *Parser) !Token {
        var field: FieldNode = undefined;
        var token: Token = undefined;
        while (true) {
            token = self.tokenizer.next();
            switch (token.tag) {
                .identifier => {
                    field.name = self.source[token.loc.start..token.loc.end];
                    const expect_colon = self.tokenizer.next();
                    if (expect_colon.tag != .colon)
                        return self.parseError(expect_colon, "expected a colon at the end of field name");

                    try self.nodes.append(.{ .field = field });
                    switch ((try self.parseValue()).tag) {
                        .eof, .end_field => break,
                        else => continue,
                    }
                },
                else => {
                    return self.parseError(token, "expected identifier");
                },
            }
        }

        try self.nodes.append(Node{ .field_end = {} });
        return token;
    }

    fn parseValue(self: *Parser) !Token {
        // Parse strategy is to try to parse a list of package names.
        // If that fails, backtrack and capture a single string
        // literal until the end of field token.

        var tokens = try std.ArrayList(Token).initCapacity(self.alloc, 16);
        defer tokens.deinit();

        var nodes = try std.ArrayList(Node).initCapacity(self.alloc, 16);
        defer nodes.deinit();

        var node: Node = undefined;

        const ParseValueState = enum {
            start,
            identifier,
            identifier_open_round,
            string,
        };

        var state: ParseValueState = .start;

        var token: Token = undefined;
        while (true) {
            token = self.tokenizer.next();
            try tokens.append(token);

            switch (state) {
                .start => switch (token.tag) {
                    .identifier => {
                        state = .identifier;
                        node = Node{ .name_and_version = .{ .name = token.lexeme(self.source) orelse "unknown" } };
                    },
                    .comma => {
                        continue;
                    },
                    .eof, .end_field => break,
                    else => {
                        state = .string;
                        node = Node{ .string_node = .{ .value = self.source[token.loc.start..token.loc.end] } };
                    },
                },

                .identifier => switch (token.tag) {
                    .comma => {
                        state = .start;
                        try nodes.append(node);
                    },
                    .open_round => {
                        state = .identifier_open_round;
                    },
                    .eof, .end_field => {
                        state = .start;
                        try nodes.append(node);
                        break;
                    },
                    else => {
                        // switch to string
                        node = Node{ .string_node = .{ .value = self.source[tokens.items[0].loc.start..token.loc.end] } };
                        state = .string;
                    },
                },
                .identifier_open_round => switch (token.tag) {
                    .less_than, .less_than_equal, .equal, .greater_than_equal, .greater_than => {
                        const ver = version.Version.init(token.lexeme(self.source) orelse "unknown") catch {
                            return self.parseError(token, "expected version number");
                        };
                        const constraint: version.Constraint = switch (token.tag) {
                            .less_than => .lt,
                            .less_than_equal => .lte,
                            .equal => .eq,
                            .greater_than_equal => .gte,
                            .greater_than => .gt,
                            else => return self.parseError(token, "expected operator (<, >, = etc)"),
                        };

                        state = .start;
                        node.name_and_version.version_constraint = version.VersionConstraint.init(constraint, ver);
                        try nodes.append(node);

                        const expect_close_round = self.tokenizer.next();
                        if (expect_close_round.tag != .close_round)
                            return self.parseError(expect_close_round, "expected close parenthesis");
                    },
                    .eof => {
                        return self.parseError(token, "unexpected end of input");
                    },
                    else => {
                        // switch to string
                        node = Node{ .string_node = .{ .value = self.source[tokens.items[0].loc.start..token.loc.end] } };
                        state = .string;
                    },
                },
                .string => switch (token.tag) {
                    .eof, .end_field => {
                        try nodes.append(node);
                        break;
                    },
                    else => {
                        node.string_node.value = self.source[tokens.items[0].loc.start..token.loc.end];
                    },
                },
            }
        }

        for (nodes.items) |x| {
            try self.nodes.append(x);
        }

        return token;
    }

    fn parseError(self: *Parser, token: Token, message: []const u8) Token {
        self.parse_error = .{ .token = token, .message = message };
        return .{ .tag = .eof, .loc = token.loc };
    }
};

test "parse" {
    const source =
        \\Package: renv
        \\Type: Package
        \\Title: Project Environments
        \\Version: 1.0.7.9000
        \\Authors@R: c(
        \\    person("Kevin", "Ushey", role = c("aut", "cre"), email = "kevin@rstudio.com",
        \\           comment = c(ORCID = "0000-0003-2880-7407")),
        \\    person("Hadley", "Wickham", role = c("aut"), email = "hadley@rstudio.com",
        \\           comment = c(ORCID = "0000-0003-4757-117X")),
        \\    person("Posit Software, PBC", role = c("cph", "fnd"))
        \\    )
        \\Description: A dependency management toolkit for R. Using 'renv', you can create
        \\    and manage project-local R libraries, save the state of these libraries to
        \\    a 'lockfile', and later restore your library as required. Together, these
        \\    tools can help make your projects more isolated, portable, and reproducible.
        \\License: MIT + file LICENSE
        \\URL: https://rstudio.github.io/renv/, https://github.com/rstudio/renv
        \\BugReports: https://github.com/rstudio/renv/issues
        \\Imports: utils
        \\Suggests: BiocManager (> 0.1), cli, covr, cpp11, devtools, gitcreds, jsonlite, jsonvalidate, knitr
        \\    (> 2.0),
        \\    miniUI, packrat, pak, R6, remotes, reticulate, rmarkdown, rstudioapi, shiny, testthat,
        \\    uuid, waldo, yaml, webfakes
        \\Encoding: UTF-8
        \\RoxygenNote: 7.3.2
        \\Roxygen: list(markdown = TRUE)
        \\VignetteBuilder: knitr
        \\Config/Needs/website: tidyverse/tidytemplate
        \\Config/testthat/edition: 3
        \\Config/testthat/parallel: true
        \\Config/testthat/start-first: bioconductor,python,install,restore,snapshot,retrieve,remotes
    ;
    const alloc = std.testing.allocator;

    var parser = try Parser.init(alloc, source);
    defer parser.deinit();
    try parser.parse();

    // std.debug.print("\nParser nodes:", .{});
    // for (parser.nodes.items) |node| {
    //     std.debug.print("  {s}", .{node});
    // }
}

// -- tokenize ---------------------------------------------------------------

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
        colon,
        comma,
        end_field,
        end_stanza,
        open_round,
        close_round,
        less_than,
        less_than_equal,
        equal,
        plus,
        greater_than_equal,
        greater_than,
        eof,
    };
    pub fn lexeme(token: Token, source: []const u8) ?[]const u8 {
        return switch (token.tag) {
            .end_field,
            .end_stanza,
            .eof,
            .invalid,
            => null,

            .identifier,
            .string_literal,
            .less_than,
            .less_than_equal,
            .equal,
            .greater_than_equal,
            .greater_than,
            => source[token.loc.start..token.loc.end],

            .colon => ":",
            .close_round => ")",
            .comma => ",",
            .open_round => "(",
            .plus => "+",
        };
    }
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

    pub fn deinit(self: *Tokenizer) void {
        self.* = undefined;
    }

    const State = enum {
        start,
        identifier,
        identifier_open_round,
        string_literal,
        string_literal_backslash,
        version_literal,
        version_literal_dot,
        version_literal_r,
        version_literal_r_digit,
        expect_version,
        newline,
        open_angle,
        open_angle_equal,
        close_angle,
        close_angle_equal,
        equal,
        unparsed,
        invalid,
    };

    /// Return next token. Will always return an .eof at the end. If
    /// an unrecognized token appears in the input, the remainder of
    /// the field is returned as a string_literal.
    pub fn next(self: *Tokenizer) Token {
        var state: State = .start;
        var result: Token = .{
            .tag = .eof,
            .loc = .{
                .start = self.index,
                .end = self.index,
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
                        result.tag = .string_literal;
                    },
                    '"' => {
                        state = .string_literal;
                        result.tag = .string_literal;
                    },
                    '(' => {
                        result.tag = .open_round;
                        self.index += 1;
                        break;
                    },
                    ')' => {
                        result.tag = .close_round;
                        self.index += 1;
                        break;
                    },
                    '<' => {
                        state = .open_angle;
                    },
                    '>' => {
                        state = .close_angle;
                    },
                    '=' => {
                        state = .equal;
                    },
                    ':' => {
                        result.tag = .colon;
                        self.index += 1;
                        break;
                    },
                    ',' => {
                        result.tag = .comma;
                        self.index += 1;
                        break;
                    },
                    0x01...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => {
                        state = .invalid;
                    },
                    else => {
                        result.tag = .string_literal;
                        state = .unparsed;
                    },
                },
                .unparsed => {
                    switch (c) {
                        '\n' => {
                            break;
                        },
                        else => continue,
                    }
                },
                .open_angle => {
                    switch (c) {
                        ' ', '\r', '\n', '\t' => {
                            state = .expect_version;
                            result.tag = .less_than;
                        },
                        '=' => {
                            state = .expect_version;
                            result.tag = .less_than_equal;
                        },
                        'r', '0'...'9' => {
                            state = .expect_version;
                            result.tag = .less_than;
                            self.index -= 1; // backtrack
                        },
                        else => {
                            state = .invalid;
                        },
                    }
                },
                .open_angle_equal => {
                    switch (c) {
                        ' ', '\r', '\n', '\t' => {
                            state = .expect_version;
                            result.tag = .less_than_equal;
                        },
                        'r', '0'...'9' => {
                            state = .expect_version;
                            result.tag = .less_than_equal;
                            self.index -= 1; // backtrack
                        },
                        else => {
                            state = .invalid;
                        },
                    }
                },
                .close_angle => {
                    switch (c) {
                        ' ', '\r', '\n', '\t' => {
                            state = .expect_version;
                            result.tag = .greater_than;
                        },
                        '=' => {
                            state = .expect_version;
                            result.tag = .greater_than_equal;
                        },
                        'r', '0'...'9' => {
                            state = .expect_version;
                            result.tag = .greater_than;
                            self.index -= 1; // backtrack
                        },
                        else => {
                            state = .invalid;
                        },
                    }
                },
                .close_angle_equal => {
                    switch (c) {
                        ' ', '\r', '\n', '\t' => {
                            state = .expect_version;
                            result.tag = .greater_than_equal;
                        },
                        'r', '0'...'9' => {
                            state = .expect_version;
                            result.tag = .greater_than_equal;
                            self.index -= 1; // backtrack
                        },
                        else => {
                            state = .invalid;
                        },
                    }
                },
                .equal => {
                    switch (c) {
                        ' ', '\r', '\n', '\t' => {
                            state = .expect_version;
                            result.tag = .equal;
                        },
                        '=' => {
                            state = .expect_version;
                            result.tag = .equal;
                        },
                        'r', '0'...'9' => {
                            state = .expect_version;
                            result.tag = .equal;
                            self.index -= 1; // backtrack
                        },
                        else => {
                            state = .invalid;
                        },
                    }
                },

                // comes after an operator
                .expect_version => {
                    switch (c) {
                        ' ', '\r', '\n', '\t' => {
                            continue;
                        },
                        'r', '0'...'9' => {
                            state = .version_literal;
                            result.loc.start = self.index;
                        },
                        else => {
                            result.tag = .equal;
                            break;
                        },
                    }
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
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .end_field;
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
                        0x01...0x08, 0x0b...0x1f, 0x7f => {
                            state = .invalid;
                        },
                        else => continue,
                    }
                },
                .string_literal_backslash => {
                    switch (c) {
                        0, '\n' => {
                            result.tag = .invalid;
                            break;
                        },
                        else => {
                            state = .string_literal;
                        },
                    }
                },
                .version_literal => {
                    switch (c) {
                        'r' => {
                            state = .version_literal_r;
                        },
                        '.' => {
                            state = .version_literal_dot;
                        },
                        ')' => {
                            break;
                        },
                        '\n' => {
                            break;
                        },
                        ' ', '\r', '\t' => {
                            self.index += 1;
                            break;
                        },
                        '0'...'9' => continue,
                        else => {
                            result.tag = .invalid;
                            break;
                        },
                    }
                },
                .version_literal_dot => {
                    switch (c) {
                        '0'...'9' => {
                            state = .version_literal;
                        },
                        else => {
                            result.tag = .invalid;
                            break;
                        },
                    }
                },
                .version_literal_r => {
                    switch (c) {
                        '0'...'9' => {
                            state = .version_literal_r_digit;
                        },
                        else => {
                            result.tag = .invalid;
                            break;
                        },
                    }
                },
                .version_literal_r_digit => {
                    switch (c) {
                        ' ', '\n', '\r', '\t' => {
                            self.index += 1;
                            break;
                        },
                        '0'...'9' => continue,
                        else => {
                            result.tag = .invalid;
                            break;
                        },
                    }
                },

                .identifier => {
                    switch (c) {
                        'a'...'z', 'A'...'Z', '_', '0'...'9' => continue,
                        '\n' => {
                            break;
                        },
                        ' ', '\r', '\t' => {
                            self.index += 1;
                            break;
                        },
                        ':' => {
                            break;
                        },
                        ',' => {
                            break;
                        },
                        '(' => {
                            break;
                            // state = .identifier_open_round;
                        },
                        ')' => {
                            break;
                        },
                        0x01...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => {
                            state = .invalid;
                        },
                        else => continue,
                    }
                },
                .identifier_open_round => {
                    switch (c) {
                        ' ', '\r', '\n', '\t', '<', '>', '=' => {
                            self.index -= 1; // backtrack
                            break;
                        },
                        else => {
                            state = .identifier;
                        },
                    }
                },

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

test "tokenize" {
    try testTokenize("Field: val (<2)", &.{ .identifier, .colon, .identifier, .open_round, .less_than, .close_round, .eof });
    try testTokenize("Field: val (<=2)", &.{ .identifier, .colon, .identifier, .open_round, .less_than_equal, .close_round, .eof });
    try testTokenize("Field: val (> 2)", &.{ .identifier, .colon, .identifier, .open_round, .greater_than, .close_round, .eof });
    try testTokenize("Field: val(>= 2)", &.{ .identifier, .colon, .identifier, .open_round, .greater_than_equal, .close_round, .eof });
    try testTokenize("Field/foo@*: val(a), val^2", &.{ .identifier, .colon, .identifier, .open_round, .identifier, .close_round, .comma, .identifier, .eof });
}

test "tokenize continuation" {
    const data =
        \\Field1: val1 val2
        \\ continues
        \\  again
        \\Field2: val3
    ;
    try testTokenize(data, &.{ .identifier, .colon, .identifier, .identifier, .identifier, .identifier, .end_field, .identifier, .colon, .identifier, .eof });
}

test "tokenize string" {
    const data = "\"string with \\\" inside";

    try testTokenize(data, &.{ .string_literal, .eof });

    var tokenizer = Tokenizer.init(data);
    const token = tokenizer.next();
    try testing.expectEqualStrings(data, token.lexeme(data).?);
}

test "tokenize version" {
    const data = "(> 3.2.1)";
    try testTokenize(data, &.{ .open_round, .greater_than, .close_round, .eof });

    var tokenizer = Tokenizer.init(data);
    _ = tokenizer.next();
    const token = tokenizer.next();
    try testing.expectEqualStrings("3.2.1", token.lexeme(data).?);
}

test "tokenize license" {
    return error.SkipZigTest;

    // const data =
    //     \\ License: MIT + file LICENSE
    // ;
    // try testTokenize(data, &.{ .identifier, .colon, .identifier, .plus, .identifier, .identifier, .eof });
}

test "tokenize R" {
    const data =
        \\Authors@R: c(
        \\    person("Kevin", "Ushey", role = c("aut", "cre"))
        \\    )
    ;
    try testTokenize(data, &.{
        .identifier,
        .colon,
        .identifier,
        .open_round,
        .identifier,
        .open_round,
        .string_literal,
        .comma,
        .string_literal,
        .comma,
        .identifier,
        .equal,
        .identifier,
        .open_round,
        .string_literal,
        .comma,
        .string_literal,
        .close_round,
        .close_round,
        .close_round,
        .eof,
    });
}

test "tokenize description" {
    const data =
        \\Version: 1.0.7.9000
        \\Description: A dependency management toolkit for R. Using 'renv', you can create
        \\    and manage project-local R libraries, save the state of these libraries to
        \\    a 'lockfile', and later restore your library as required. Together, these
        \\    tools can help make your projects more isolated, portable, and reproducible.
        \\Authors@R: c(
        \\    person("Kevin", "Ushey", role = c("aut", "cre"))
        \\    )
        \\URL: https://rstudio.github.io/renv/, https://github.com/rstudio/renv
        \\Suggests: BiocManager (> 0.1), cli, covr, cpp11, devtools, gitcreds, jsonlite, jsonvalidate, knitr
        \\    (> 2.0),
        \\    miniUI, packrat, pak, R6, remotes, reticulate, rmarkdown, rstudioapi, shiny, testthat,
        \\    uuid, waldo, yaml, webfakes
    ;
    // std.debug.print("\n", .{});
    var tokenizer = Tokenizer.init(data);
    while (true) {
        const token = tokenizer.next();
        // std.debug.print("{}: {?s}\n", .{ token, token.lexeme(data) });
        if (token.tag == .eof) break;
    }

    // try testTokenize(data, &.{ .identifier, .colon });
}

fn testTokenize(source: []const u8, expected_token_tags: []const Token.Tag) !void {
    // std.debug.print("\n", .{});
    var tokenizer = Tokenizer.init(source);
    for (expected_token_tags) |expected_token_tag| {
        const token = tokenizer.next();
        // std.debug.print("{}: {?s}\n", .{ token, token.lexeme(source) });
        try std.testing.expectEqual(expected_token_tag, token.tag);
    }
    // Last token should always be eof, even when the last token was invalid,
    // in which case the tokenizer is in an invalid state, which can only be
    // recovered by opinionated means outside the scope of this implementation.
    const last_token = tokenizer.next();
    try std.testing.expectEqual(Token.Tag.eof, last_token.tag);
    try std.testing.expectEqual(source.len, last_token.loc.start);
    try std.testing.expectEqual(source.len, last_token.loc.end);
}
