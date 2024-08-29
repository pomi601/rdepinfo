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
const repository_index = @import("lib/repository_index.zig");
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
        \\    broken <file> [file...]     Using files in PACKAGES format,
        \\                                report broken packages, if any.
        \\    bioc-url <version>          Report the URLs for all Bioc repositories.
        \\
        \\  Options:
        \\
    ,
        .{},
    );
}

const FLAGS = .{};

const Program = struct {
    alloc: Allocator,
    stdout: std.fs.File,
    stderr: std.fs.File,
    cwd: []const u8,
    options: Cmdline,
    repo: Repository,
    index: ?Repository.Index = null,

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
                try std.fmt.format(stderr.writer(), "{s}\n", .{msg});
                self.exitWithUsage();
            },
            else => {},
        }

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
        const stderr = self.stderr.writer();
        const words = self.options.positional().items;
        if (words.len < 1) self.exitWithUsage();

        const command = words[0];

        if (mem.eql(u8, "broken", command)) {
            try self.readRepos();
            try self.broken();
        } else if (mem.eql(u8, "bioc-urls", command)) {
            try self.biocUrls();
        } else {
            try stderr.print("Unrecognised command: '{s}'\n", .{command});
            self.exitWithUsage();
        }
    }

    pub fn exitWithUsage(self: Self) noreturn {
        usage(std.fs.path.basename(self.options.argv0));
        std.process.exit(1);
    }

    fn biocUrls(self: *Self) !void {
        const stderr = self.stderr.writer();
        const stdout = self.stdout.writer();
        const words = self.options.positional().items;
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

    fn readRepos(self: *Self) !void {
        const stderr = self.stderr.writer();
        const stdout = self.stdout.writer();

        const words = self.options.positional().items;
        if (words.len < 2) {
            try std.fmt.format(self.stderr.writer(), "Missing files: '{s}'\n", .{words[0]});
            self.exitWithUsage();
        }

        for (words[1..]) |path| {
            const source_: ?[]const u8 = try mos.file.readFileMaybeGzip(self.alloc, path);
            defer if (source_) |s| self.alloc.free(s); // free before next iteration

            if (source_) |source| {
                try std.fmt.format(stderr, "Reading file {s}...", .{path});
                const count = try self.repo.read(source);
                try std.fmt.format(stderr, " {} packages read.\n", .{count});
            }
        }

        try std.fmt.format(stdout, "Creating index... ", .{});
        self.index = try self.repo.createIndex();
        try std.fmt.format(stdout, "Done.\n", .{});
        try std.fmt.format(stdout, "Number of packages: {}\n", .{self.repo.packages.len});
    }

    fn broken(self: *Self) !void {
        const unsatisfiedDependencies = repository_index.Operations.unsatisfiedDependencies;

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

        var it = self.repo.iter();
        while (it.next()) |p| {
            const deps = try unsatisfiedDependencies(self.alloc, index, p.depends);
            const impo = try unsatisfiedDependencies(self.alloc, index, p.imports);
            const link = try unsatisfiedDependencies(self.alloc, index, p.linkingTo);
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
