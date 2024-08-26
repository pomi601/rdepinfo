//!
//! RDescription
//!
//! Parse DESCRIPTION file
//!
//! https://cran.r-project.org/doc/manuals/R-exts.html#The-DESCRIPTION-file
//!
//!
//! Provides structured access to dependency-related fields only:
//! Depends, Suggests, Imports, LinkingTo

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const StringStorage = @import("string_storage").StringStorage;
const version = @import("version.zig");
const NameAndVersionConstraint = version.NameAndVersionConstraint;
const parse = @import("parse.zig");
const Parser = parse.Parser;

strings: StringStorage,
depends: []NameAndVersionConstraint = &.{},
suggests: []NameAndVersionConstraint = &.{},
imports: []NameAndVersionConstraint = &.{},
linkingTo: []NameAndVersionConstraint = &.{},

pub fn deinit(self: *Self, alloc: Allocator) void {
    alloc.free(self.depends);
    alloc.free(self.suggests);
    alloc.free(self.imports);
    alloc.free(self.linkingTo);
    self.strings.deinit();
    self.* = undefined;
}

pub fn fromSource(alloc: Allocator, source: []const u8) !Self {
    // Parse the source into an AST
    var parser = try Parser.init(alloc);
    defer parser.deinit();
    try parser.parse(source);

    return fromAst(alloc, parser.nodes.items, 0, try parser.claimStrings());
}

/// Parse one stanza denoted by stanza_index.
pub fn fromAst(alloc: Allocator, nodes: []Parser.Node, stanza_index: usize, strings: StringStorage) !Self {
    // Parsing the AST for this use case is easy, since we only care
    // about the first stanza. So we can iterate through nodes until
    // we hit the end-stanza node.
    var list = std.ArrayList(NameAndVersionConstraint).init(alloc);
    defer list.deinit();
    var depends: []NameAndVersionConstraint = &.{};
    var suggests: []NameAndVersionConstraint = &.{};
    var imports: []NameAndVersionConstraint = &.{};
    var linkingTo: []NameAndVersionConstraint = &.{};

    var index: usize = 0;
    var node: Parser.Node = undefined;

    // advance to requested stanza
    var seeking = stanza_index;
    while (true) : (index += 1) {
        if (seeking == 0) break;

        node = nodes[index];
        if (node == .stanza) seeking -= 1;
        if (node == .eof) return error.NotFound;
    }

    while (true) : (index += 1) {
        node = nodes[index];
        if (node == .stanza_end) break;
        switch (node) {
            .field => |field| {
                if (std.mem.eql(u8, "Depends", field.name)) {
                    try parsePackages(nodes, &index, &list);
                    depends = try list.toOwnedSlice();
                } else if (std.mem.eql(u8, "Suggests", field.name)) {
                    try parsePackages(nodes, &index, &list);
                    suggests = try list.toOwnedSlice();
                } else if (std.mem.eql(u8, "Imports", field.name)) {
                    try parsePackages(nodes, &index, &list);
                    imports = try list.toOwnedSlice();
                } else if (std.mem.eql(u8, "LinkingTo", field.name)) {
                    try parsePackages(nodes, &index, &list);
                    linkingTo = try list.toOwnedSlice();
                }
            },
            else => continue,
        }
    }

    return .{
        .strings = strings,
        .depends = depends,
        .suggests = suggests,
        .imports = imports,
        .linkingTo = linkingTo,
    };
}

fn parsePackages(
    nodes: []Parser.Node,
    index: *usize,
    list: *std.ArrayList(NameAndVersionConstraint),
) !void {
    index.* += 1;
    while (true) : (index.* += 1) {
        const node = nodes[index.*];
        switch (node) {
            .name_and_version => |nv| {
                try list.append(NameAndVersionConstraint{
                    .name = nv.name,
                    .version_constraint = nv.version_constraint,
                });
            },
            else => break,
        }
    }
}

test "RDescription" {
    const expectEqual = testing.expectEqual;
    const expectEqualStrings = testing.expectEqualStrings;
    const data =
        \\Package: devtools
        \\Title: Tools to Make Developing R Packages Easier
        \\Version: 2.4.5.9000
        \\Authors@R: c(
        \\    person("Hadley", "Wickham", role = "aut"),
        \\    person("Jim", "Hester", role = "aut"),
        \\    person("Winston", "Chang", role = "aut"),
        \\    person("Jennifer", "Bryan", , "jenny@posit.co", role = c("aut", "cre"),
        \\           comment = c(ORCID = "0000-0002-6983-2759")),
        \\    person("Posit Software, PBC", role = c("cph", "fnd"))
        \\  )
        \\Description: Collection of package development tools.
        \\License: MIT + file LICENSE
        \\URL: https://devtools.r-lib.org/, https://github.com/r-lib/devtools
        \\BugReports: https://github.com/r-lib/devtools/issues
        \\Depends:
        \\    R (>= 3.6),
        \\    usethis (>= 2.1.6)
        \\Imports:
        \\    cli (>= 3.3.0),
        \\    desc (>= 1.4.1),
        \\    ellipsis (>= 0.3.2),
        \\    fs (>= 1.5.2),
        \\    lifecycle (>= 1.0.1),
        \\    memoise (>= 2.0.1),
        \\    miniUI (>= 0.1.1.1),
        \\    pkgbuild (>= 1.3.1),
        \\    pkgdown (>= 2.0.6),
        \\    pkgload (>= 1.3.0),
        \\    profvis (>= 0.3.7),
        \\    rcmdcheck (>= 1.4.0),
        \\    remotes (>= 2.4.2),
        \\    rlang (>= 1.0.4),
        \\    roxygen2 (>= 7.2.1),
        \\    rversions (>= 2.1.1),
        \\    sessioninfo (>= 1.2.2),
        \\    stats,
        \\    testthat (>= 3.2.0),
        \\    tools,
        \\    urlchecker (>= 1.0.1),
        \\    utils,
        \\    withr (>= 2.5.0)
        \\Suggests:
        \\    BiocManager (>= 1.30.18),
        \\    callr (>= 3.7.1),
        \\    covr (>= 3.5.1),
        \\    curl (>= 4.3.2),
        \\    digest (>= 0.6.29),
        \\    DT (>= 0.23),
        \\    foghorn (>= 1.4.2),
        \\    gh (>= 1.3.0),
        \\    gmailr (>= 1.0.1),
        \\    httr (>= 1.4.3),
        \\    knitr (>= 1.39),
        \\    lintr (>= 3.0.0),
        \\    MASS,
        \\    mockery (>= 0.4.3),
        \\    pingr (>= 2.0.1),
        \\    rhub (>= 1.1.1),
        \\    rmarkdown (>= 2.14),
        \\    rstudioapi (>= 0.13),
        \\    spelling (>= 2.2)
        \\VignetteBuilder:
        \\    knitr
        \\Remotes:
        \\    r-lib/testthat
        \\Config/Needs/website: tidyverse/tidytemplate
        \\Config/testthat/edition: 3
        \\Encoding: UTF-8
        \\Language: en-US
        \\Roxygen: list(markdown = TRUE)
        \\RoxygenNote: 7.2.3
    ;

    const alloc = std.testing.allocator;
    var rdv2 = try Self.fromSource(alloc, data);
    defer rdv2.deinit(alloc);

    try expectEqualStrings("R", rdv2.depends[0].name);
    try expectEqual(.gte, rdv2.depends[0].version_constraint.constraint);
    try expectEqual(3, rdv2.depends[0].version_constraint.version.major);
    try expectEqual(6, rdv2.depends[0].version_constraint.version.minor);
    try expectEqual(0, rdv2.depends[0].version_constraint.version.patch);
    try expectEqualStrings("usethis", rdv2.depends[1].name);
    try expectEqual(.gte, rdv2.depends[1].version_constraint.constraint);
    try expectEqual(2, rdv2.depends[1].version_constraint.version.major);
    try expectEqual(1, rdv2.depends[1].version_constraint.version.minor);
    try expectEqual(6, rdv2.depends[1].version_constraint.version.patch);
}

const Self = @This();
