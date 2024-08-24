const std = @import("std");
const Allocator = std.mem.Allocator;

/// Return true if file has a magic number indicating it is a gzip
/// file.
pub fn isGzipFile(abs_or_rel_path: []const u8) !bool {
    // https://datatracker.ietf.org/doc/html/rfc1952

    const file = try std.fs.cwd().openFile(abs_or_rel_path, .{});
    defer file.close();

    var buf: [4]u8 = .{ 0, 0, 0, 0 };
    const n = try file.pread(&buf, 0);
    if (n < 4) return error.EndOfFile;

    return buf[0] == 0x1f and buf[1] == 0x8b;
}

/// Decompress a gzip file and return an owned slice. Caller must
/// dispose of it using the same allocator.
pub fn decompressGzipFile(alloc: Allocator, abs_or_rel_path: []const u8) ![]u8 {
    const cwd = std.fs.cwd();
    const stat = try cwd.statFile(abs_or_rel_path);
    var bytes = try std.ArrayList(u8).initCapacity(alloc, stat.size * 2);
    errdefer bytes.deinit();

    const file = try cwd.openFile(abs_or_rel_path, .{});
    defer file.close();

    try std.compress.gzip.decompress(file.reader(), bytes.writer());
    return bytes.toOwnedSlice();
}

/// Read entire file. Caller must free returned slice using the same
/// allocator.
pub fn readFile(alloc: Allocator, abs_or_rel_path: []const u8) ![]const u8 {
    const file = try std.fs.cwd().openFile(abs_or_rel_path, .{});
    defer file.close();
    return try file.readToEndAlloc(alloc, std.math.maxInt(usize));
}

/// Read entire file, possibly gzip. Caller must free returned slice
/// using the same allocator.
pub fn readFileMaybeGzip(alloc: Allocator, abs_or_rel_path: []const u8) ![]const u8 {
    if (try isGzipFile(abs_or_rel_path))
        return try decompressGzipFile(alloc, abs_or_rel_path);

    return try readFile(alloc, abs_or_rel_path);
}
