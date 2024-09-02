const std = @import("std");
const testing = std.testing;
const Repository = @import("repository.zig").Repository;

export fn repo_init() ?*anyopaque {
    const repo = Repository.init(std.heap.c_allocator) catch {
        return null;
    };

    const out: *Repository = std.heap.c_allocator.create(Repository) catch {
        return null;
    };

    out.* = repo;

    return out;
}

export fn repo_deinit(repo_: *anyopaque) void {
    const repo: *Repository = @ptrCast(@alignCast(repo_));
    repo.deinit();
}

export fn repo_read(repo_: *anyopaque, buf: [*]u8, sz: usize) usize {
    const repo: *Repository = @ptrCast(@alignCast(repo_));
    const slice = buf[0..sz];
    return repo.read(slice) catch {
        return 0;
    };
}
