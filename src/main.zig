const std = @import("std");
const Allocator = std.mem.Allocator;

const mos = @import("mos");
const cmdline = @import("cmdline");
const Cmdline = cmdline.Options(.{});

const version = @import("lib/version.zig");
const repository = @import("lib/repository.zig");
const repository_index = @import("lib/repository_index.zig");
const Repository = repository.Repository;

fn usage(progname: []const u8) void {
    std.debug.print(
        \\Usage: {s} <command> [options]
        \\  Commands:
        \\    broken              Report broken dependencies
        \\
        \\  Options:
        \\    --repo <file>       A repository PACKAGES.gz file. (May be repeated.)
        \\
    ,
        .{progname},
    );
}

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
        const words = self.options.positional().items;
        if (words.len < 1) self.exitWithUsage();

        const command = words[0];

        if (mos.streql("broken", command)) {
            try self.readRepos();
            try self.broken();
        } else {
            try std.fmt.format(self.stderr.writer(), "Unrecognised command: '{s}'\n", .{command});
            self.exitWithUsage();
        }
    }

    pub fn exitWithUsage(self: Self) noreturn {
        usage(std.fs.path.basename(self.options.argv0));
        std.process.exit(1);
    }

    fn readRepos(self: *Self) !void {
        const stderr = self.stderr.writer();
        const stdout = self.stdout.writer();

        if (self.options.getMany("repo")) |repos| {
            for (repos) |path| {
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
        try Cmdline.init(alloc, .{
            .{"verbose"},
            .{ "repo", "repo" },
        }),
    );
    defer program.deinit();

    try program.run();

    // const stdout = std.io.getStdOut();
    // try stdout.writeAll(bytes);

}
