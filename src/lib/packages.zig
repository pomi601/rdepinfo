const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const parse = @import("parse.zig");
const Parser = parse.Parser;

const util = @import("util.zig");

const NameAndVersionConstraint = @import("version.zig").NameAndVersionConstraint;

const RDescription = @import("RDescription.zig");

const Repository = struct {
    const Package = struct {
        depends: []NameAndVersionConstraint = &.{},
        suggests: []NameAndVersionConstraint = &.{},
        imports: []NameAndVersionConstraint = &.{},
        linkingTo: []NameAndVersionConstraint = &.{},
    };

    alloc: Allocator,
    packages: std.MultiArrayList(Package),

    pub fn init(alloc: Allocator) Repository {
        return .{ .alloc = alloc, .packages = .{} };
    }

    pub fn deinit(self: *Repository) void {
        const slice = self.packages.slice();
        for (slice.items(.depends)) |x| {
            self.alloc.free(x);
        }
        for (slice.items(.suggests)) |x| {
            self.alloc.free(x);
        }
        for (slice.items(.imports)) |x| {
            self.alloc.free(x);
        }
        for (slice.items(.linkingTo)) |x| {
            self.alloc.free(x);
        }
        self.packages.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn read(self: *Repository, source: []const u8) !void {
        var parser = try parse.Parser.init(self.alloc, source);
        defer parser.deinit();
        try parser.parse();

        // reserve estimated space and free before exit (empirical from CRAN PACKAGES)
        try self.packages.ensureTotalCapacity(self.alloc, parser.nodes.items.len / 30);
        defer self.packages.shrinkAndFree(self.alloc, self.packages.len);

        // reserve working list of []NameAndVersionConstraint
        var nav_list = try std.ArrayList(NameAndVersionConstraint).initCapacity(self.alloc, 16);
        defer nav_list.deinit();

        var depends: []NameAndVersionConstraint = &.{};
        var suggests: []NameAndVersionConstraint = &.{};
        var imports: []NameAndVersionConstraint = &.{};
        var linkingTo: []NameAndVersionConstraint = &.{};

        const nodes = parser.nodes.items;
        var index: usize = 0;
        var node: Parser.Node = undefined;
        while (true) : (index += 1) {
            node = nodes[index];

            switch (node) {
                .eof => break,

                .stanza_end => {
                    try self.packages.append(self.alloc, .{
                        .depends = depends,
                        .suggests = suggests,
                        .imports = imports,
                        .linkingTo = linkingTo,
                    });
                    depends = &.{};
                    suggests = &.{};
                    imports = &.{};
                    linkingTo = &.{};
                    nav_list.clearRetainingCapacity();
                },

                .field => |field| {
                    if (std.mem.eql(u8, "Depends", field.name)) {
                        try parsePackages(nodes, &index, &nav_list);
                        depends = try nav_list.toOwnedSlice();
                    } else if (std.mem.eql(u8, "Suggests", field.name)) {
                        try parsePackages(nodes, &index, &nav_list);
                        suggests = try nav_list.toOwnedSlice();
                    } else if (std.mem.eql(u8, "Imports", field.name)) {
                        try parsePackages(nodes, &index, &nav_list);
                        imports = try nav_list.toOwnedSlice();
                    } else if (std.mem.eql(u8, "LinkingTo", field.name)) {
                        try parsePackages(nodes, &index, &nav_list);
                        linkingTo = try nav_list.toOwnedSlice();
                    }
                },

                else => continue,
            }
        }
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
};

test "PACKAGES.gz" {
    const path = "PACKAGES.gz";
    std.fs.cwd().access(path, .{}) catch return;
    const alloc = testing.allocator;

    const source = try util.readFileMaybeGzip(alloc, path);
    defer alloc.free(source);

    var timer = try std.time.Timer.start();

    var parser = try parse.Parser.init(alloc, source);
    defer parser.deinit();
    parser.parse() catch |err| switch (err) {
        error.ParseError => {
            if (parser.parse_error) |perr| {
                std.debug.print("ERROR: ParseError: {s}: {}:{s}\n", .{ perr.message, perr.token, source[perr.token.loc.start..perr.token.loc.end] });
            }
        },
        error.OutOfMemory => {
            std.debug.print("ERROR: OutOfMemory\n", .{});
        },
    };
    std.debug.print("Parse to AST only = {}ms\n", .{@divFloor(timer.lap(), 1_000_000)});
    std.debug.print("Parser nodes: {d}\n", .{parser.nodes.items.len});
    std.debug.print("Number of stanzas parsed: {d}\n", .{parser.numStanzas()});

    // read entire repo
    var repo = Repository.init(alloc);
    defer repo.deinit();
    try repo.read(source);
    std.debug.print("Parse to Repository ({} packages) = {}ms\n", .{ repo.packages.len, @divFloor(timer.lap(), 1_000_000) });
}
