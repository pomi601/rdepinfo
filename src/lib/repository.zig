const std = @import("std");
const mos = @import("mos");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const string_storage = @import("string_storage");
const StringStorage = string_storage.IndexedStringStorage;

const parse = @import("parse.zig");
const Parser = parse.Parser;

const version = @import("version.zig");
const NameAndVersionConstraint = version.NameAndVersionConstraint;
const Version = version.Version;

// dependencies on these packages are not checked
const base_packages = .{
    "base",   "compiler", "datasets", "graphics", "grDevices",
    "grid",   "methods",  "parallel", "splines",  "stats",
    "stats4", "tcltk",    "tools",    "utils",    "R",
};
const recommended_packages = .{
    "boot",    "class",      "MASS",    "cluster", "codetools",
    "foreign", "KernSmooth", "lattice", "Matrix",  "mgcv",
    "nlme",    "nnet",       "rpart",   "spatial", "survival",
};

pub const Repository = struct {
    alloc: Allocator,
    strings: ?StringStorage = null,
    packages: std.MultiArrayList(Package),

    pub const Index = @import("repository_index.zig").Index;

    const Package = struct {
        name: []const u8 = "",
        version: Version = .{ .string = "" },
        depends: []NameAndVersionConstraint = &.{},
        suggests: []NameAndVersionConstraint = &.{},
        imports: []NameAndVersionConstraint = &.{},
        linkingTo: []NameAndVersionConstraint = &.{},
    };

    const Iterator = struct {
        index: usize = 0,
        slice: std.MultiArrayList(Package).Slice,

        pub fn init(repo: Repository) Iterator {
            return .{
                .slice = repo.packages.slice(),
            };
        }

        pub fn next(self: *Iterator) ?Package {
            if (self.index < self.slice.len) {
                const out = self.index;
                self.index += 1;
                return self.slice.get(out);
            }
            return null;
        }
    };

    /// Call deinit when finished.
    pub fn init(alloc: Allocator) !Repository {
        return .{
            .alloc = alloc,
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
        if (self.strings) |*s| s.deinit();
        self.packages.deinit(self.alloc);
        self.* = undefined;
    }

    /// Return an iterator over the package data.
    pub fn iter(self: Repository) Iterator {
        return Iterator.init(self);
    }

    /// Return the first package.
    pub fn first(self: Repository) ?Package {
        var it = self.iter();
        return it.next();
    }

    /// Create an index of this repository. Caller must call deinit.
    pub fn createIndex(self: Repository) !Index {
        return Index.init(self);
    }

    /// Read packages information from provided source. Expects Debian
    /// Control File format, same as R PACKAGES file.
    pub fn read(self: *Repository, source: []const u8) !void {
        var parser = try parse.Parser.init(self.alloc);
        defer parser.deinit();
        try parser.parse(source);

        // take over parser string storage
        if (self.strings) |_| return error.InvalidState;
        self.strings = try parser.claimStrings();
        if (self.strings == null) return error.InvalidState;

        // reserve estimated space and free before exit (empirical from CRAN PACKAGES)
        try self.packages.ensureTotalCapacity(self.alloc, parser.nodes.items.len / 30);
        defer self.packages.shrinkAndFree(self.alloc, self.packages.len);

        // reserve estimated additional space for strings
        try self.strings.?.ensureCapacity(parser.nodes.items.len / 30 * 16);

        // reserve working list of []NameAndVersionConstraint
        var nav_list = try std.ArrayList(NameAndVersionConstraint).initCapacity(self.alloc, 16);
        defer nav_list.deinit();

        var result: Package = .{};

        const nodes = parser.nodes.items;
        var idx: usize = 0;
        var node: Parser.Node = undefined;
        while (true) : (idx += 1) {
            node = nodes[idx];

            switch (node) {
                .eof => break,

                .stanza_end => {
                    try self.packages.append(self.alloc, result);
                    result = .{};
                    nav_list.clearRetainingCapacity();
                },

                .field => |field| {
                    if (mos.streql("Package", field.name)) {
                        result.name = try parsePackageName(nodes, &idx, &self.strings.?);
                    } else if (mos.streql("Version", field.name)) {
                        result.version = try parsePackageVersion(nodes, &idx);
                    } else if (mos.streql("Depends", field.name)) {
                        try parsePackages(nodes, &idx, &nav_list);
                        result.depends = try nav_list.toOwnedSlice();
                    } else if (mos.streql("Suggests", field.name)) {
                        try parsePackages(nodes, &idx, &nav_list);
                        result.suggests = try nav_list.toOwnedSlice();
                    } else if (mos.streql("Imports", field.name)) {
                        try parsePackages(nodes, &idx, &nav_list);
                        result.imports = try nav_list.toOwnedSlice();
                    } else if (mos.streql("LinkingTo", field.name)) {
                        try parsePackages(nodes, &idx, &nav_list);
                        result.linkingTo = try nav_list.toOwnedSlice();
                    }
                },

                else => continue,
            }
        }
    }

    fn parsePackageName(nodes: []Parser.Node, idx: *usize, strings: *StringStorage) ![]const u8 {
        idx.* += 1;
        switch (nodes[idx.*]) {
            .name_and_version => |nv| {
                return try strings.append(nv.name);
            },
            // expect .name_and_version immediately after .field for a Package field
            else => unreachable,
        }
    }

    fn parsePackageVersion(nodes: []Parser.Node, idx: *usize) !Version {
        idx.* += 1;
        switch (nodes[idx.*]) {
            .string_node => |s| {
                return try Version.init(s.value);
            },
            // expect .string_node immediately after .field for a Version field
            else => unreachable,
        }
    }

    fn parsePackages(
        nodes: []Parser.Node,
        idx: *usize,
        list: *std.ArrayList(NameAndVersionConstraint),
    ) !void {
        idx.* += 1;
        while (true) : (idx.* += 1) {
            const node = nodes[idx.*];
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

    var source: ?[]const u8 = try mos.file.readFileMaybeGzip(alloc, path);
    try testing.expect(source != null);
    errdefer if (source) |s| alloc.free(s);

    var timer = try std.time.Timer.start();

    var parser = try parse.Parser.init(alloc);
    defer parser.deinit();
    parser.parse(source.?) catch |err| switch (err) {
        error.ParseError => {
            if (parser.parse_error) |perr| {
                std.debug.print("ERROR: ParseError: {s}: {}:{s}\n", .{
                    perr.message,
                    perr.token,
                    source.?[perr.token.loc.start..perr.token.loc.end],
                });
            }
        },
        error.OutOfMemory => {
            std.debug.print("ERROR: OutOfMemory\n", .{});
        },
        else => unreachable,
    };

    std.debug.print("Parse to AST only = {}ms\n", .{@divFloor(timer.lap(), 1_000_000)});
    std.debug.print("Parser nodes: {d}\n", .{parser.nodes.items.len});
    std.debug.print("Number of stanzas parsed: {d}\n", .{parser.numStanzas()});

    // read entire repo
    var repo = try Repository.init(alloc);
    defer repo.deinit();
    try repo.read(source.?);
    std.debug.print(
        "Parse to Repository ({} packages) = {}ms\n",
        .{ repo.packages.len, @divFloor(timer.lap(), 1_000_000) },
    );

    // after parser.parse() returns, we should be able to immediate
    // release the source. Note that repo.read() also uses it in this
    // test.
    if (source) |s| alloc.free(s);
    source = null;

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
    var index = try repo.createIndex();
    defer index.deinit();
    try testing.expect(index.items.count() <= repo.packages.len);

    std.debug.print("Index count = {}\n", .{index.items.count()});

    try testing.expectEqual(0, index.items.get("A3").?.single.index);
    try testing.expectEqualStrings("1.0.0", index.items.get("A3").?.single.version.string);
    try testing.expectEqual(1, index.items.get("AalenJohansen").?.single.index);
    try testing.expectEqualStrings("1.0", index.items.get("AalenJohansen").?.single.version.string);
    try testing.expectEqual(2, index.items.get("AATtools").?.single.index);
    try testing.expectEqualStrings("0.0.2", index.items.get("AATtools").?.single.version.string);
}

test "PACKAGES sanity check" {
    const path = "PACKAGES.gz";
    std.fs.cwd().access(path, .{}) catch return;
    const alloc = testing.allocator;
    const source: ?[]const u8 = try mos.file.readFileMaybeGzip(alloc, path);
    errdefer if (source) |s| alloc.free(s);

    var repo = try Repository.init(alloc);
    defer repo.deinit();
    if (source) |s| try repo.read(s);
    if (source) |s| alloc.free(s);

    var index = try repo.createIndex();
    defer index.deinit();

    var unsatisfied = std.StringHashMap(std.ArrayList(NameAndVersionConstraint)).init(alloc);
    defer {
        var it = unsatisfied.iterator();
        while (it.next()) |x| x.value_ptr.deinit();
        unsatisfied.deinit();
    }

    var it = repo.iter();
    while (it.next()) |p| {
        const deps = try unsatisfiedDependencies(alloc, index, p.depends);
        const impo = try unsatisfiedDependencies(alloc, index, p.imports);
        const link = try unsatisfiedDependencies(alloc, index, p.linkingTo);
        defer alloc.free(deps);
        defer alloc.free(impo);
        defer alloc.free(link);

        const res = try unsatisfied.getOrPut(p.name);
        if (!res.found_existing) res.value_ptr.* = std.ArrayList(NameAndVersionConstraint).init(alloc);
        try res.value_ptr.appendSlice(deps);
        try res.value_ptr.appendSlice(impo);
        try res.value_ptr.appendSlice(link);
    }

    var un_it = unsatisfied.iterator();
    while (un_it.next()) |u| {
        for (u.value_ptr.items) |nav| {
            std.debug.print("Package '{s}' dependency '{s}' version '{s}' not satisfied.\n", .{
                u.key_ptr.*,
                nav.name,
                nav.version_constraint,
            });
        }
    }
}

pub fn unsatisfiedDependencies(
    alloc: Allocator,
    index: Repository.Index,
    depends: []NameAndVersionConstraint,
) ![]NameAndVersionConstraint {
    var out = std.ArrayList(NameAndVersionConstraint).init(alloc);

    for (depends) |d| top: {
        if (isBasePackage(d.name)) continue;
        if (isRecommendedPackage(d.name)) continue;
        if (index.items.get(d.name)) |entry| switch (entry) {
            .single => |e| {
                if (d.version_constraint.satisfied(e.version)) break;
            },
            .multiple => |es| {
                for (es.items) |e| {
                    if (d.version_constraint.satisfied(e.version)) break :top;
                }
            },
        };
        try out.append(d);
    }
    return out.toOwnedSlice();
}

pub fn isBasePackage(name: []const u8) bool {
    inline for (base_packages) |base| {
        if (mos.streql(base, name)) return true;
    }
    return false;
}

pub fn isRecommendedPackage(name: []const u8) bool {
    inline for (recommended_packages) |reco| {
        if (mos.streql(reco, name)) return true;
    }
    return false;
}
