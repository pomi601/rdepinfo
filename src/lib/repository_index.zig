const std = @import("std");
const Allocator = std.mem.Allocator;

const Repository = @import("repository.zig").Repository;

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

    /// Create an index of the repo. Caller must deinit with the
    /// same allocator.
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

    /// Given a slice of requirements, return a slice of missing dependencies, if any.
    pub fn unsatisfied(
        self: Index,
        alloc: Allocator,
        require: []NameAndVersionConstraint,
    ) error{OutOfMemory}![]NameAndVersionConstraint {
        var out = std.ArrayList(NameAndVersionConstraint).init(alloc);

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

    pub fn isBasePackage(name: []const u8) bool {
        inline for (base_packages) |base| {
            if (std.mem.eql(u8, base, name)) return true;
        }
        return false;
    }

    pub fn isRecommendedPackage(name: []const u8) bool {
        inline for (recommended_packages) |reco| {
            if (std.mem.eql(u8, reco, name)) return true;
        }
        return false;
    }
};
