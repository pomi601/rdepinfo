const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const version = @import("version.zig");
const Repository = @import("repository.zig").Repository;

pub const CNameAndVersion = extern struct {
    name_ptr: [*]const u8 = "",
    name_len: usize = 0,
    version: version.VersionConstraint = .{},

    pub fn format(
        self: CNameAndVersion,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print(
            "{s} {}",
            .{ self.name_ptr[0..self.name_len], self.version },
        );
    }

    export fn debug_print_name_and_version(self: *const CNameAndVersion) void {
        const stderr = std.io.getStdErr();
        stderr.writer().print("{}", .{self}) catch {
            return;
        };
    }
};

pub const NameAndVersionBuffer = extern struct {
    ptr: [*]CNameAndVersion,
    len: usize,

    export fn repo_name_version_buffer_create(n: usize) ?*NameAndVersionBuffer {
        const alloc = std.heap.c_allocator;
        const out = alloc.create(NameAndVersionBuffer) catch {
            return null;
        };
        errdefer alloc.destroy(out);

        const buf = alloc.alloc(CNameAndVersion, n) catch {
            return null;
        };
        @memset(buf, .{});

        out.*.ptr = buf.ptr;
        out.*.len = buf.len;

        return out;
    }

    export fn repo_name_version_buffer_destroy(buf: ?*NameAndVersionBuffer) void {
        if (buf) |b| {
            const alloc = std.heap.c_allocator;
            alloc.free(b.*.ptr[0..b.*.len]);
            b.* = undefined;
            alloc.destroy(b);
        } else return;
    }

    // TODO it would be nice to not have to make these
    // memory-allocating copies

    pub fn toZig(self: NameAndVersionBuffer, alloc: Allocator) ![]version.NameAndVersionConstraint {
        const out = try alloc.alloc(version.NameAndVersionConstraint, self.len);
        for (out, self.ptr[0..self.len]) |*o, in| {
            o.name = in.name_ptr[0..in.name_len];
            o.version_constraint = in.version;
        }
        return out;
    }

    pub fn toC(alloc: Allocator, in: []version.NameAndVersionConstraint) !*NameAndVersionBuffer {
        const buf = try alloc.alloc(CNameAndVersion, in.len);
        errdefer alloc.free(buf);

        const res = try alloc.create(NameAndVersionBuffer);
        for (buf, in) |*out, i| {
            out.name_ptr = i.name.ptr;
            out.name_len = i.name.len;
            out.version = i.version_constraint;
        }

        res.* = .{ .ptr = buf.ptr, .len = buf.len };
        return res;
    }
};

/// Returns an opaque pointer, or null in case of failure. Caller must
/// call deinit on the returned pointer.
export fn repo_init() ?*anyopaque {
    const alloc = std.heap.c_allocator;
    const repo = Repository.init(alloc) catch {
        return null;
    };
    const out: *Repository = alloc.create(Repository) catch {
        return null;
    };

    out.* = repo;
    return out;
}

/// Frees all associated memory.
export fn repo_deinit(repo_: ?*anyopaque) void {
    if (repo_) |repo__| {
        const repo: *Repository = @ptrCast(@alignCast(repo__));
        repo.deinit();
        std.heap.c_allocator.destroy(repo);
    }
}

/// Read a buffer into the existing repository. Returns the number of packages read.
export fn repo_read(repo_: *anyopaque, buf: [*]u8, sz: usize) usize {
    const repo: *Repository = @ptrCast(@alignCast(repo_));
    const slice = buf[0..sz];
    const res = repo.read(slice) catch {
        if (repo.parse_error) |err| {
            std.debug.print("Parser error: {s}: {}\n", .{ err.message, err.token });
        }
        return 0;
    };

    std.debug.print("repo_read: added repo of {} bytes\n", .{sz});
    return res;
}

/// Returns an opaque pointer, or null in case of failure. Caller must
/// call deinit on the returned pointer.
export fn repo_index_init(repo_: *anyopaque) ?*anyopaque {
    const alloc = std.heap.c_allocator;
    const repo: *Repository = @ptrCast(@alignCast(repo_));
    const index = Repository.Index.init(repo.*) catch {
        return null;
    };

    const out: *Repository.Index = alloc.create(Repository.Index) catch {
        return null;
    };

    out.* = index;
    return out;
}

/// Frees all associated memory.
export fn repo_index_deinit(index_: ?*anyopaque) void {
    if (index_) |index__| {
        const index: *Repository.Index = @ptrCast(@alignCast(index__));
        index.deinit();
        std.heap.c_allocator.destroy(index);
    }
}

/// Given a package name in a repo, return a newly allocated buffer
/// with any packages whose constraints cannot be satisfied. The
/// caller must call repo_name_version_buffer_destroy on the returned
/// buffer.
export fn repo_index_unsatisfied(
    index_: *anyopaque,
    repo_: *anyopaque,
    root_ptr: [*]const u8,
    root_len: usize,
) ?*NameAndVersionBuffer {
    const alloc = std.heap.c_allocator;
    const index: *Repository.Index = @ptrCast(@alignCast(index_));
    const repo: *Repository = @ptrCast(@alignCast(repo_));

    const res = index.unmetDependencies(alloc, repo.*, root_ptr[0..root_len]) catch {
        return null;
    };

    return NameAndVersionBuffer.toC(alloc, res) catch {
        return null;
    };
}
