const std = @import("std");
const mem = std.mem;
const mos = @import("mos");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const stable_list = @import("stable_list");
const StringStorage = stable_list.IndexedStringStorage;

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

// it's dubious to also exclude these from dependency checking,
// because some installations may not have recommended packages
// installed. But we still exclude them.
const recommended_packages = .{
    "boot",    "class",      "MASS",    "cluster", "codetools",
    "foreign", "KernSmooth", "lattice", "Matrix",  "mgcv",
    "nlme",    "nnet",       "rpart",   "spatial", "survival",
};

/// Return true if name is a base package.
pub fn isBasePackage(name: []const u8) bool {
    inline for (base_packages) |base| {
        if (std.mem.eql(u8, base, name)) return true;
    }
    return false;
}

/// Return true if name is a recommended package.
pub fn isRecommendedPackage(name: []const u8) bool {
    inline for (recommended_packages) |reco| {
        if (std.mem.eql(u8, reco, name)) return true;
    }
    return false;
}

//

/// Represents a package repository and provides a parser to update
/// itself from a Debian Control File (DCF), as used in standard R
/// package repository PACKAGES files.
pub const Repository = struct {
    alloc: Allocator,
    strings: ?StringStorage = null,
    packages: std.MultiArrayList(Package),
    parse_error: ?Parser.ParseError = null,

    /// Caller must call deinit to release internal buffers.
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

    /// Return package(s) information for given NameAndVersionConstraint.
    pub fn findPackage(
        self: Repository,
        alloc: Allocator,
        navc: NameAndVersionConstraint,
        comptime options: struct { max_results: u32 = 16 },
    ) error{OutOfMemory}![]Package {
        var out = try std.ArrayList(Package).initCapacity(alloc, options.max_results);
        const slice = self.packages.slice();
        var index: usize = 0;
        for (slice.items(.name)) |n| {
            if (mem.eql(u8, n, navc.name)) {
                if (navc.version_constraint.satisfied(slice.items(.version)[index])) {
                    out.appendAssumeCapacity(slice.get(index));
                    if (out.items.len == options.max_results) return error.OutOfMemory;
                }
            }
            index += 1;
        }
        return out.toOwnedSlice();
    }

    /// Return the latest package, if any, that satisfies the given
    /// NameAndVersionConstraint. If there are multiple packages that
    /// satisfy the constraint, return the one with the highest
    /// version.
    pub fn findLatestPackage(
        self: Repository,
        alloc: Allocator,
        navc: NameAndVersionConstraint,
    ) error{OutOfMemory}!?Package {
        const packages = try self.findPackage(alloc, navc, .{});
        defer alloc.free(packages);
        switch (packages.len) {
            0 => return null,
            1 => return packages[0],
            else => {
                var latest = packages[0];
                for (packages) |p| {
                    if (p.version.order(latest.version) == .gt) latest = p;
                }
                return latest;
            },
        }
    }

    /// Create an index of this repository. Caller must call deinit.
    pub fn createIndex(self: Repository) !Index {
        return Index.init(self);
    }

    /// Read packages information from provided source. Expects Debian
    /// Control File format, same as R PACKAGES file. Returns number
    /// of packages found.
    pub fn read(self: *Repository, name: []const u8, source: []const u8) !usize {
        var count: usize = 0;
        var parser = try parse.Parser.init(self.alloc);
        defer parser.deinit();
        parser.parse(source) catch |err| switch (err) {
            error.ParseError => |e| {
                self.parse_error = parser.parse_error;
                return e;
            },
            else => |e| {
                return e;
            },
        };

        // take over parser string storage
        var parser_strings = try parser.detachStrings();
        if (self.strings) |*ss| {
            try ss.claimOther(&parser_strings);
        } else {
            self.strings = parser_strings;
        }
        if (self.strings == null) return error.InvalidState;

        // reserve estimated space and free before exit (empirical from CRAN PACKAGES)
        try self.packages.ensureTotalCapacity(self.alloc, parser.nodes.items.len / 30);
        defer self.packages.shrinkAndFree(self.alloc, self.packages.len);

        // reserve estimated additional space for strings
        try self.strings.?.ensureCapacity(parser.nodes.items.len / 30 * 16);

        // reserve working list of []NameAndVersionConstraint
        var nav_list = try std.ArrayList(NameAndVersionConstraint).initCapacity(self.alloc, 16);
        defer nav_list.deinit();

        var result: Package = .{ .repository = try self.strings.?.append(name) };

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
                    count += 1;
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
        return count;
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
                return try Version.parse(s.value);
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

    //
    // -- iterator -----------------------------------------------------------
    //

    /// Represents a single package and its dependencies.
    pub const Package = struct {
        name: []const u8 = "",
        version: Version = .{},
        repository: []const u8 = "",
        depends: []NameAndVersionConstraint = &.{},
        suggests: []NameAndVersionConstraint = &.{},
        imports: []NameAndVersionConstraint = &.{},
        linkingTo: []NameAndVersionConstraint = &.{},
    };

    /// An iterator over a Repository.
    pub const Iterator = struct {
        index: usize = 0,
        slice: std.MultiArrayList(Package).Slice,

        /// Return an iterator which provides one package at a time
        /// from the Repository.
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

    //
    // -- transitive dependencies---------------------------------------------
    //

    /// Given a package name, return a slice of its transitive
    /// dependencies. If there is more than one package with the same
    /// name, select the latest version as the root.
    pub fn transitiveDependencies(
        self: Repository,
        alloc: Allocator,
        navc: NameAndVersionConstraint,
    ) error{ OutOfMemory, NotFound }![]NameAndVersionConstraint {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();

        var out = NameAndVersionConstraintHashMap.init(alloc);
        defer out.deinit();

        if (try self.findLatestPackage(alloc, navc)) |root_package| {
            try self.doTransitiveDependencies(&arena, root_package, &out);
            return try alloc.dupe(NameAndVersionConstraint, out.keys());
        } else return error.NotFound;
    }

    /// Given a package name, return a slice of its transitive
    /// dependencies. If there is more than one package with the same
    /// name, select the latest version as the root. Does not report
    /// dependencies on base or recommended packages.
    pub fn transitiveDependenciesNoBase(
        self: Repository,
        alloc: Allocator,
        navc: NameAndVersionConstraint,
    ) error{ OutOfMemory, NotFound }![]NameAndVersionConstraint {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();

        const out = NameAndVersionConstraintHashMap.init(alloc);
        defer out.deinit();

        if (self.findLatestPackage(alloc, navc)) |root_package| {
            try self.doTransitiveDependencies(&arena, &out, root_package);

            var result = std.ArrayList(NameAndVersionConstraint).initCapacity(alloc, out.items.len);
            for (out.keys()) |x| {
                if (isBasePackage(x.name)) continue;
                if (isRecommendedPackage(x.name)) continue;
                result.appendAssumeCapacity(x);
            }
            return result.toOwnedSlice();
        } else return error.NotFound;
    }

    const NameAndVersionConstraintHashMap = std.ArrayHashMap(
        NameAndVersionConstraint,
        bool,
        version.NameAndVersionConstraintContext,
        true,
    );

    fn doTransitiveDependencies(
        self: Repository,
        arena: *std.heap.ArenaAllocator,
        package: Package,
        out: *NameAndVersionConstraintHashMap,
    ) !void {
        for (package.depends) |navc| {
            if (try self.findLatestPackage(arena.allocator(), navc)) |p| {
                try out.put(navc, true);
                try self.doTransitiveDependencies(arena, p, out);
            } else return error.NotFound;
        }
        for (package.imports) |navc| {
            if (try self.findLatestPackage(arena.allocator(), navc)) |p| {
                try out.put(navc, true);
                try self.doTransitiveDependencies(arena, p, out);
            } else return error.NotFound;
        }
        for (package.linkingTo) |navc| {
            if (try self.findLatestPackage(arena.allocator(), navc)) |p| {
                try out.put(navc, true);
                try self.doTransitiveDependencies(arena, p, out);
            } else return error.NotFound;
        }

        // for (package.depends) |x| try out.put(x, true);
        // for (package.imports) |x| try out.put(x, true);
        // for (package.linkingTo) |x| try out.put(x, true);

        // const depends = try arena.allocator().dupe(NameAndVersionConstraint, out.keys());
        // for (depends) |navc| {
        //     if (try self.findLatestPackage(arena.allocator(), navc)) |p| {
        //         try self.doTransitiveDependencies(arena, p, out);
        //     } else return error.NotFound;
        // }
    }

    //
    // -- index --------------------------------------------------------------
    //

    /// Represents an Index of a Repository.
    pub const Index = struct {
        const MapType = std.StringHashMap(AvailableVersions);
        items: MapType,

        const AvailableVersions = union(enum) {
            single: VersionIndex,
            multiple: std.ArrayList(VersionIndex),

            pub fn format(
                self: AvailableVersions,
                comptime fmt: []const u8,
                options: std.fmt.FormatOptions,
                writer: anytype,
            ) !void {
                _ = options;
                _ = fmt;
                switch (self) {
                    .single => |vi| {
                        try writer.print("(IndexVersion.single {s} {})", .{
                            vi.version.string,
                            vi.index,
                        });
                    },
                    .multiple => |l| {
                        try writer.print("(IndexVersion.multiple", .{});
                        for (l.items) |x| {
                            try writer.print(" {s}", .{x.version});
                        }
                        try writer.print(")", .{});
                    },
                }
            }
        };

        const VersionIndex = struct { version: Version, index: usize };

        /// Create an index of the repo. Uses the repository's
        /// allocator for its internal buffers. Caller must deinit to
        /// release buffers.
        pub fn init(repo: Repository) !Index {
            // Index only supports up to max Index.Size items.
            if (repo.packages.len > std.math.maxInt(MapType.Size)) return error.OutOfMemory;
            var out = MapType.init(repo.alloc);
            try out.ensureTotalCapacity(@intCast(repo.packages.len));

            const slice = repo.packages.slice();
            const names = slice.items(.name);
            const versions = slice.items(.version);

            var idx: usize = 0;
            while (idx < repo.packages.len) : (idx += 1) {
                const name = names[idx];
                const ver = versions[idx];

                if (out.getPtr(name)) |p| {
                    switch (p.*) {
                        .single => |vi| {
                            p.* = .{
                                .multiple = std.ArrayList(VersionIndex).init(repo.alloc),
                            };
                            try p.multiple.append(vi);
                            try p.multiple.append(.{
                                .version = ver,
                                .index = idx,
                            });
                        },
                        .multiple => |*l| {
                            try l.append(.{
                                .version = ver,
                                .index = idx,
                            });
                        },
                    }
                } else {
                    out.putAssumeCapacityNoClobber(name, .{
                        .single = .{
                            .version = ver,
                            .index = idx,
                        },
                    });
                }
            }
            return .{ .items = out };
        }

        /// Release buffers and invalidate.
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

        /// Given a slice of required packages, return a slice of missing dependencies, if any.
        pub fn unsatisfied(
            self: Index,
            alloc: Allocator,
            require: []NameAndVersionConstraint,
        ) error{OutOfMemory}![]NameAndVersionConstraint {
            var out = std.ArrayList(NameAndVersionConstraint).init(alloc);
            defer out.deinit();

            for (require) |d| top: {
                if (isBasePackage(d.name)) continue;
                if (isRecommendedPackage(d.name)) continue;
                if (self.items.get(d.name)) |entry| switch (entry) {
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

        //

        /// Return an owned slice of package names and versions thate
        /// cannot be satisfied in the given repository, starting with the
        /// given root package. Caller must free the slice with the same
        /// allocator.
        pub fn unmetDependencies(
            self: Index,
            alloc: Allocator,
            repo: Repository,
            root: []const u8,
        ) error{ OutOfMemory, NotFound }![]NameAndVersionConstraint {
            if (try repo.findLatestPackage(alloc, .{ .name = root })) |p| {
                var broken = std.ArrayList(NameAndVersionConstraint).init(alloc);
                defer broken.deinit();

                const deps = try self.unsatisfied(alloc, p.depends);
                const impo = try self.unsatisfied(alloc, p.imports);
                const link = try self.unsatisfied(alloc, p.linkingTo);
                defer alloc.free(deps);
                defer alloc.free(impo);
                defer alloc.free(link);

                try broken.appendSlice(deps);
                try broken.appendSlice(impo);
                try broken.appendSlice(link);

                return broken.toOwnedSlice();
            }
            return error.NotFound;
        }
    };
};

//
// -- test -------------------------------------------------------------------
//

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
    _ = try repo.read("test repo", source.?);
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
    try testing.expectEqual(1, repo.packages.items(.version)[0].major);
    try testing.expectEqualStrings("AalenJohansen", repo.packages.items(.name)[1]);
    try testing.expectEqual(1, repo.packages.items(.version)[1].major);
    try testing.expectEqualStrings("AATtools", repo.packages.items(.name)[2]);
    try testing.expectEqual(0, repo.packages.items(.version)[2].major);

    const pack = try repo.findLatestPackage(alloc, .{ .name = "A3" });
    try testing.expect(pack != null);
    try testing.expectEqualStrings("A3", pack.?.name);

    // index
    var index = try repo.createIndex();
    defer index.deinit();
    try testing.expect(index.items.count() <= repo.packages.len);

    std.debug.print("Index count = {}\n", .{index.items.count()});

    try testing.expectEqual(0, index.items.get("A3").?.single.index);
    try testing.expectEqual(1, index.items.get("A3").?.single.version.major);
    try testing.expectEqual(1, index.items.get("AalenJohansen").?.single.index);
    try testing.expectEqual(1, index.items.get("AalenJohansen").?.single.version.major);
    try testing.expectEqual(2, index.items.get("AATtools").?.single.index);
    try testing.expectEqual(0, index.items.get("AATtools").?.single.version.major);
}

test "PACKAGES sanity check" {
    const path = "PACKAGES.gz";
    std.fs.cwd().access(path, .{}) catch return;
    const alloc = testing.allocator;
    const source: ?[]const u8 = try mos.file.readFileMaybeGzip(alloc, path);
    errdefer if (source) |s| alloc.free(s);

    var repo = try Repository.init(alloc);
    defer repo.deinit();
    if (source) |s| _ = try repo.read("test", s);
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
        const deps = try index.unsatisfied(alloc, p.depends);
        const impo = try index.unsatisfied(alloc, p.imports);
        const link = try index.unsatisfied(alloc, p.linkingTo);
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

test "find latest package" {
    const alloc = testing.allocator;
    const data1 =
        \\Package: foo
        \\Version: 1.0
        \\
        \\Package: foo
        \\Version: 1.0.1
    ;
    const data2 =
        \\Package: foo
        \\Version: 1.0.2
        \\
        \\Package: foo
        \\Version: 1.0.1
    ;

    {
        var repo = try Repository.init(alloc);
        defer repo.deinit();
        _ = try repo.read("test", data1);

        const package = try repo.findLatestPackage(alloc, .{ .name = "foo" });
        try testing.expectEqualStrings("foo", package.?.name);
        try testing.expectEqual(Version{ .major = 1, .minor = 0, .patch = 1, .rev = 0 }, package.?.version);
    }
    {
        var repo = try Repository.init(alloc);
        defer repo.deinit();
        _ = try repo.read("test", data2);

        const package = try repo.findLatestPackage(alloc, .{ .name = "foo" });
        try testing.expectEqualStrings("foo", package.?.name);
        try testing.expectEqualStrings("test", package.?.repository);
        try testing.expectEqual(Version{ .major = 1, .minor = 0, .patch = 2, .rev = 0 }, package.?.version);
    }
}

test "transitive dependencies" {
    const alloc = testing.allocator;
    const data1 =
        \\Package: parent
        \\Version: 1.0
        \\
        \\Package: child
        \\Version: 1.0
        \\Depends: parent (>= 1.0)
        \\
        \\Package: grandchild
        \\Version: 1.0
        \\Depends: child (>= 1.0)
    ;

    {
        var repo = try Repository.init(alloc);
        defer repo.deinit();
        _ = try repo.read("test", data1);

        const res = try repo.transitiveDependencies(alloc, .{ .name = "grandchild" });
        defer alloc.free(res);

        try testing.expectEqualDeep(
            res[0],
            NameAndVersionConstraint{ .name = "child", .version_constraint = try version.VersionConstraint.parse(.gte, "1.0") },
        );
    }
}
