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
const DCF = @import("DebianControlFile.zig");
const version = @import("version.zig");
const NameAndVersionConstraint = version.NameAndVersionConstraint;

stanza: DCF.Stanza,
depends: []NameAndVersionConstraint = &.{},
suggests: []NameAndVersionConstraint = &.{},
imports: []NameAndVersionConstraint = &.{},
linkingTo: []NameAndVersionConstraint = &.{},

pub fn deinit(self: *Self, alloc: Allocator) void {
    self.stanza.deinit(alloc);
    alloc.free(self.depends);
    alloc.free(self.suggests);
    alloc.free(self.imports);
    alloc.free(self.linkingTo);
    self.* = undefined;
}

pub fn fromStanza(alloc: Allocator, stanza: DCF.Stanza) !Self {
    const my_stanza = try stanza.clone(alloc);
    var list = std.ArrayList(NameAndVersionConstraint).init(alloc);
    defer list.deinit();
    var depends: []NameAndVersionConstraint = &.{};
    var suggests: []NameAndVersionConstraint = &.{};
    var imports: []NameAndVersionConstraint = &.{};
    var linkingTo: []NameAndVersionConstraint = &.{};

    if (get_field(my_stanza.fields, "Depends")) |f| {
        depends = try process_value(&list, f.val);
    }
    if (get_field(my_stanza.fields, "Suggests")) |f| {
        suggests = try process_value(&list, f.val);
    }
    if (get_field(my_stanza.fields, "Imports")) |f| {
        imports = try process_value(&list, f.val);
    }
    if (get_field(my_stanza.fields, "LinkingTo")) |f| {
        linkingTo = try process_value(&list, f.val);
    }

    return .{
        .stanza = my_stanza,
        .depends = depends,
        .suggests = suggests,
        .imports = imports,
        .linkingTo = linkingTo,
    };
}

fn get_field(fields: []DCF.Field, name: []const u8) ?DCF.Field {
    for (fields) |f| {
        if (std.mem.eql(u8, f.key, name)) return f;
    }
    return null;
}

fn process_value(
    list: *std.ArrayList(NameAndVersionConstraint),
    val: []const u8,
) ![]NameAndVersionConstraint {
    list.clearRetainingCapacity();
    var it = std.mem.splitScalar(u8, val, ',');
    while (it.next()) |x_| {
        const x = std.mem.trim(u8, x_, &std.ascii.whitespace);
        try list.append(try NameAndVersionConstraint.init(x));
    }
    return try list.toOwnedSlice();
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
    var dcf = try DCF.parse(alloc, data);
    defer dcf.deinit(alloc);

    var rd = try Self.fromStanza(alloc, dcf.stanzas[0]);
    defer rd.deinit(alloc);

    try expectEqualStrings("R", rd.depends[0].name);
    try expectEqual(.gte, rd.depends[0].versionConstraint.constraint);
    try expectEqual(3, rd.depends[0].versionConstraint.version.?.major);
    try expectEqual(6, rd.depends[0].versionConstraint.version.?.minor);
    try expectEqual(0, rd.depends[0].versionConstraint.version.?.patch);
    try expectEqualStrings("usethis", rd.depends[1].name);
    try expectEqual(.gte, rd.depends[1].versionConstraint.constraint);
    try expectEqual(2, rd.depends[1].versionConstraint.version.?.major);
    try expectEqual(1, rd.depends[1].versionConstraint.version.?.minor);
    try expectEqual(6, rd.depends[1].versionConstraint.version.?.patch);
}

const Self = @This();
