const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const parse = @import("parse.zig");
const Parser = parse.Parser;

const util = @import("util.zig");

const version = @import("version.zig");
const NameAndVersionConstraint = version.NameAndVersionConstraint;
const Version = version.Version;

const RDescription = @import("RDescription.zig");

const Repository = struct {
    const Package = struct {
        name: []const u8 = "",
        version: Version = .{ .string = "" },
        depends: []NameAndVersionConstraint = &.{},
        suggests: []NameAndVersionConstraint = &.{},
        imports: []NameAndVersionConstraint = &.{},
        linkingTo: []NameAndVersionConstraint = &.{},
    };

    alloc: Allocator,
    strings: std.ArrayList(u8),
    packages: std.MultiArrayList(Package),

    /// Call deinit when finished.
    pub fn init(alloc: Allocator) Repository {
        return .{
            .alloc = alloc,
            .strings = std.ArrayList(u8).init(alloc),
            .packages = .{},
        };
    }

    /// Release internal buffers and invalidate.
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
        self.strings.deinit();
        self.packages.deinit(self.alloc);
        self.* = undefined;
    }

    /// Read packages information from provided source. Expects Debian
    /// Control File format, same as R PACKAGES file.
    pub fn read(self: *Repository, source: []const u8) !void {
        var parser = try parse.Parser.init(self.alloc, source);
        defer parser.deinit();
        try parser.parse();

        // reserve estimated space and free before exit (empirical from CRAN PACKAGES)
        try self.packages.ensureTotalCapacity(self.alloc, parser.nodes.items.len / 30);
        defer self.packages.shrinkAndFree(self.alloc, self.packages.len);

        // reserve estimated space for strings
        try self.strings.ensureTotalCapacity(parser.nodes.items.len / 30 * 16);

        // reserve working list of []NameAndVersionConstraint
        var nav_list = try std.ArrayList(NameAndVersionConstraint).initCapacity(self.alloc, 16);
        defer nav_list.deinit();

        var result: Package = .{};

        const nodes = parser.nodes.items;
        var index: usize = 0;
        var node: Parser.Node = undefined;
        while (true) : (index += 1) {
            node = nodes[index];

            switch (node) {
                .eof => break,

                .stanza_end => {
                    try self.packages.append(self.alloc, result);
                    result = .{};
                    nav_list.clearRetainingCapacity();
                },

                .field => |field| {
                    if (std.mem.eql(u8, "Package", field.name)) {
                        result.name = try parsePackageName(nodes, &index, &self.strings);
                    } else if (std.mem.eql(u8, "Version", field.name)) {
                        result.version = try parsePackageVersion(nodes, &index);
                    } else if (std.mem.eql(u8, "Depends", field.name)) {
                        try parsePackages(nodes, &index, &nav_list);
                        result.depends = try nav_list.toOwnedSlice();
                    } else if (std.mem.eql(u8, "Suggests", field.name)) {
                        try parsePackages(nodes, &index, &nav_list);
                        result.suggests = try nav_list.toOwnedSlice();
                    } else if (std.mem.eql(u8, "Imports", field.name)) {
                        try parsePackages(nodes, &index, &nav_list);
                        result.imports = try nav_list.toOwnedSlice();
                    } else if (std.mem.eql(u8, "LinkingTo", field.name)) {
                        try parsePackages(nodes, &index, &nav_list);
                        result.linkingTo = try nav_list.toOwnedSlice();
                    }
                },

                else => continue,
            }
        }
    }

    fn parsePackageName(nodes: []Parser.Node, index: *usize, strings: *std.ArrayList(u8)) ![]const u8 {
        index.* += 1;
        switch (nodes[index.*]) {
            .name_and_version => |nv| {
                const start = strings.items.len;
                try strings.appendSlice(nv.name);
                return strings.items[start..strings.items.len];
            },
            // expect .name_and_version immediately after .field for a Package field
            else => unreachable,
        }
    }

    fn parsePackageVersion(nodes: []Parser.Node, index: *usize) !Version {
        index.* += 1;
        switch (nodes[index.*]) {
            .string_node => |s| {
                return try Version.init(s.value);
            },
            // expect .string_node immediately after .field for a Version field
            else => unreachable,
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

const Index = struct {
    const MapType = std.StringHashMap(IndexVersion);
    items: MapType,

    const IndexVersion = union(enum) {
        single: VersionIndex,
        multiple: std.ArrayList(VersionIndex),
    };
    const VersionIndex = struct { version: []const u8, index: usize };

    /// Create an index of the repo. Caller must deinit the returned index
    /// with the same allocator.
    pub fn init(alloc: Allocator, repo: Repository) !Index {
        // Index only supports up to max Index.Size items.
        if (repo.packages.len > std.math.maxInt(MapType.Size)) return error.OutOfMemory;
        var out = MapType.init(alloc);
        try out.ensureTotalCapacity(@intCast(repo.packages.len));

        const slice = repo.packages.slice();
        const names = slice.items(.name);
        const versions = slice.items(.version);

        var index: usize = 0;
        while (index < repo.packages.len) : (index += 1) {
            const name = names[index];
            const ver = versions[index].string;

            if (out.getPtr(name)) |p| {
                switch (p.*) {
                    .single => |vi| {
                        p.* = .{
                            .multiple = std.ArrayList(VersionIndex).init(alloc),
                        };
                        try p.multiple.append(vi);
                        try p.multiple.append(.{
                            .version = ver,
                            .index = index,
                        });
                    },
                    .multiple => |*l| {
                        try l.append(.{
                            .version = ver,
                            .index = index,
                        });
                    },
                }
            } else {
                out.putAssumeCapacityNoClobber(name, .{
                    .single = .{
                        .version = ver,
                        .index = index,
                    },
                });
            }
        }
        return .{ .items = out };
    }

    pub fn deinit(self: *Index) void {
        var it = self.items.valueIterator();
        while (it.next()) |v| switch (v.*) {
            .single => continue,
            .multiple => |l| {
                l.deinit();
            },
        };

        self.items.deinit();
        self.* = undefined;
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

    // Current PACKAGES has this as the first stanza:
    // Package: A3
    // Version: 1.0.0
    try testing.expectEqualStrings("A3", repo.packages.items(.name)[0]);
    try testing.expectEqualStrings("1.0.0", repo.packages.items(.version)[0].string);
    try testing.expectEqualStrings("AalenJohansen", repo.packages.items(.name)[1]);
    try testing.expectEqualStrings("1.0", repo.packages.items(.version)[1].string);
    try testing.expectEqualStrings("AATtools", repo.packages.items(.name)[2]);
    try testing.expectEqualStrings("0.0.2", repo.packages.items(.version)[2].string);

    // index
    var index = try Index.init(alloc, repo);
    defer index.deinit();
    try testing.expect(index.items.count() <= repo.packages.len);

    std.debug.print("Index count = {}\n", .{index.items.count()});

    try testing.expectEqual(0, index.items.get("A3").?.single.index);
    try testing.expectEqualStrings("1.0.0", index.items.get("A3").?.single.version);
    try testing.expectEqual(1, index.items.get("AalenJohansen").?.single.index);
    try testing.expectEqualStrings("1.0", index.items.get("AalenJohansen").?.single.version);
    try testing.expectEqual(2, index.items.get("AATtools").?.single.index);
    try testing.expectEqualStrings("0.0.2", index.items.get("AATtools").?.single.version);
}
