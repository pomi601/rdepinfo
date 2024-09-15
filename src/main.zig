//!
//!
//! rdepinfo broken PACKAGES.gz PACKAGES-bioc-3.19.gz PACKAGES-bioc-data.gz PACKAGES-bioc-data-experiment.gz

// Bioconductor repositories:

const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;

const mos = @import("mos");
const cmdline = @import("cmdline");
const Cmdline = cmdline.Options(.{});

const version = @import("lib/version.zig");
const repository = @import("lib/repository.zig");
const Repository = repository.Repository;

const bioc_repos = struct {
    const main = "https://bioconductor.org/packages/{s}/bioc/src/contrib/PACKAGES.gz";
    const annotation = "https://bioconductor.org/packages/release/data/annotation/src/contrib/PACKAGES.gz";
    const experiment = "https://bioconductor.org/packages/release/data/experiment/src/contrib/PACKAGES.gz";
    const workflows = "https://bioconductor.org/packages/{s}/workflows/src/contrib/PACKAGES.gz";
};

fn usage(progname: []const u8) void {
    _ = progname;
    std.debug.print(
        \\Usage: rdepinfo broken <file> [files...]
        \\Usage: rdepinfo bioc-url <version>
        \\  Commands:
        \\    bioc-url <version>            Report the URLs for all Bioc repositories.
        \\    broken <file> [file...]       Using files in PACKAGES format,
        \\                                  report broken packages, if any.
        \\    can-install <name> <file> ... Exit with status 0 if <name> is installable.
        \\    depends <name> <file> ...     Report packages <name> depends on.
        \\
        \\  Options:
        \\    -q, --quiet                   Suppress stderr messages
        \\
    ,
        .{},
    );
}

const FLAGS = .{
    .{ "quiet", false },
};

const Program = struct {
    alloc: Allocator,
    stdout: std.fs.File,
    stderr: std.fs.File,
    cwd: []const u8,
    options: Cmdline,
    repo: Repository,
    index: ?Repository.Index = null,
    quiet: bool = false,

    pub fn init(alloc: Allocator, options: Cmdline) !Self {
        const stdout = std.io.getStdOut();
        const stderr = std.io.getStdErr();

        const cwd = try std.fs.cwd().realpathAlloc(alloc, ".");
        errdefer alloc.free(cwd);
        var repo = try Repository.init(alloc);
        errdefer repo.deinit();

        var self: Self = .{
            .alloc = alloc,
            .stdout = stdout,
            .stderr = stderr,
            .cwd = cwd,
            .options = options,
            .repo = repo,
        };

        const res = try self.options.parse();
        switch (res) {
            .err => |e| {
                const msg = e.toMessage(self.alloc) catch "Unknown error.";
                try stderr.writer().print("{s}\n", .{msg});
                self.exitWithUsage();
            },
            else => {},
        }

        if (self.options.present("quiet"))
            self.quiet = true;

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.options.deinit();
        if (self.index) |*x| x.deinit();
        self.repo.deinit();

        self.stderr.close();
        self.stdout.close();
        self.* = undefined;
    }

    pub fn run(self: *Self) !void {
        const words = self.options.positional();
        if (words.len < 1) self.exitWithUsage();
        const command = words[0];

        if (mem.eql(u8, "broken", command)) {
            try self.readRepos(1);
            var it = self.repo.iter();
            if (try self.broken(&it))
                std.process.exit(1);
        } else if (mem.eql(u8, "bioc-urls", command)) {
            try self.biocUrls();
        } else if (mem.eql(u8, "can-install", command)) {
            try self.readRepos(2);
            try self.canInstall();
        } else if (mem.eql(u8, "depends", command)) {
            try self.readRepos(2);
            try self.depends();
        } else {
            try self.log("Unrecognised command: '{s}'\n", .{command});
            self.exitWithUsage();
        }
    }

    pub fn exitWithUsage(self: Self) noreturn {
        usage(std.fs.path.basename(self.options.argv0));
        std.process.exit(1);
    }

    fn canInstall(self: *Self) !void {
        const words = self.options.positional();
        if (words.len < 3) {
            self.exitWithUsage();
        }
        const name = words[1];

        const package = try self.repo.findLatestPackage(self.alloc, .{ .name = name });
        if (package) |p| {
            var iter = struct {
                package: Repository.Package,
                done: bool = false,
                pub fn next(this: *This) ?Repository.Package {
                    if (this.done) return null;
                    this.done = true;
                    return this.package;
                }
                const This = @This();
            }{ .package = p };

            const any_broken = try self.broken(&iter);
            if (any_broken) {
                try self.log("Package cannot be installed: {s}\n", .{name});
                std.process.exit(1);
            }
        } else {
            try self.log("Cannot find package: {s}\n", .{name});
            std.process.exit(1);
        }
        try self.log("OK", .{});
    }

    fn depends(self: *Self) !void {
        const stdout = self.stdout.writer();

        const words = self.options.positional();
        if (words.len < 2) {
            self.exitWithUsage();
        }
        const name = words[1];

        const package = try self.repo.findLatestPackage(self.alloc, .{ .name = name });
        if (package) |p| {
            for (p.depends) |x| {
                try stdout.print("{s}\n", .{x.name});
            }
            for (p.imports) |x| {
                try stdout.print("{s}\n", .{x.name});
            }
            for (p.linkingTo) |x| {
                try stdout.print("{s}\n", .{x.name});
            }
        } else {
            try self.log("Cannot find package: {s}\n", .{name});
            std.process.exit(1);
        }
    }

    fn biocUrls(self: *Self) !void {
        const stderr = self.stderr.writer();
        const stdout = self.stdout.writer();
        const words = self.options.positional();
        if (words.len < 2) {
            try stderr.print("Missing version number: '{s}'\n", .{words[0]});
            self.exitWithUsage();
        }
        const version_number = words[1];

        try stdout.print(bioc_repos.main ++ "\n", .{version_number});
        try stdout.print(bioc_repos.annotation ++ "\n", .{});
        try stdout.print(bioc_repos.experiment ++ "\n", .{});
        try stdout.print(bioc_repos.workflows ++ "\n", .{version_number});
    }

    fn readRepos(self: *Self, start: usize) !void {
        const stderr = self.stderr.writer();

        const words = self.options.positional();
        if (words.len < start + 1) {
            try std.fmt.format(self.stderr.writer(), "Missing files: '{s}'\n", .{words[0]});
            self.exitWithUsage();
        }

        for (words[start..]) |path| {
            const source_: ?[]const u8 = mos.file.readFileMaybeGzip(self.alloc, path) catch {
                try self.log("Could not read file: {s}\n", .{path});
                std.process.exit(1);
            };

            defer if (source_) |s| self.alloc.free(s); // free before next iteration

            if (source_) |source| {
                try self.log("Reading file {s}...", .{path});
                const count = self.repo.read(path, source) catch |err| switch (err) {
                    error.InvalidState => |e| {
                        try stderr.print("INTERNAL ERROR: Invalid state. (Sorry.)\n", .{});
                        return e;
                    },
                    error.ParseError => {
                        if (self.repo.parse_error) |pe| {
                            try stderr.print(
                                "PARSE ERROR: {s}, {}: {s}\n",
                                .{ pe.message, pe.token.tag, source[pe.token.loc.start..pe.token.loc.end] },
                            );
                            return err;
                        } else unreachable;
                    },
                    else => |e| {
                        try stderr.print("UNKOWN ERROR: {}\n", .{e});
                        return e;
                    },
                };
                try self.log(" {} packages read.\n", .{count});
            }
        }

        try self.log("Creating index... ", .{});
        self.index = try self.repo.createIndex();
        try self.log("Done.\n", .{});
        try self.log("Number of packages: {}\n", .{self.repo.packages.len});
    }

    fn broken(self: *Self, iterator: anytype) !bool {
        const index = b: {
            if (self.index) |x| {
                break :b x;
            } else {
                return error.InvalidState;
            }
        };

        var unsatisfied = std.StringHashMap(std.ArrayList(version.NameAndVersionConstraint)).init(self.alloc);
        defer {
            var it = unsatisfied.iterator();
            while (it.next()) |x| x.value_ptr.deinit();
            unsatisfied.deinit();
        }

        while (iterator.next()) |p| {
            const deps = try index.unsatisfied(self.alloc, p.depends);
            const impo = try index.unsatisfied(self.alloc, p.imports);
            const link = try index.unsatisfied(self.alloc, p.linkingTo);
            defer self.alloc.free(deps);
            defer self.alloc.free(impo);
            defer self.alloc.free(link);

            const res = try unsatisfied.getOrPut(p.name);
            if (!res.found_existing) res.value_ptr.* = std.ArrayList(version.NameAndVersionConstraint).init(self.alloc);
            try res.value_ptr.appendSlice(deps);
            try res.value_ptr.appendSlice(impo);
            try res.value_ptr.appendSlice(link);
        }

        var un_it = unsatisfied.iterator();
        var any_broken = false;
        while (un_it.next()) |u| {
            for (u.value_ptr.items) |nav| {
                any_broken = true;
                try self.log("Package '{s}' dependency '{s}' version '{s}' not satisfied.\n", .{
                    u.key_ptr.*,
                    nav.name,
                    nav.version_constraint,
                });
            }
        }
        return any_broken;
    }

    fn log(self: Self, comptime format: []const u8, args: anytype) !void {
        if (self.quiet) return;
        const stderr = self.stderr.writer();
        try stderr.print(format, args);
    }

    const Self = @This();
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        if (gpa.deinit() == .leak)
            std.debug.print("Memory leak detected.\n", .{});
    }
    const alloc = gpa.allocator();

    var program = try Program.init(
        alloc,
        try Cmdline.init(alloc, FLAGS),
    );
    defer program.deinit();

    try program.run();
}
