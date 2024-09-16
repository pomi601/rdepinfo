const std = @import("std");

/// Allocator must be thread-safe.
pub fn downloadFile(alloc: std.mem.Allocator, url: []const u8, out_path: []const u8) !void {
    var client = std.http.Client{ .allocator = alloc };

    var header_buffer: [16 * 1024]u8 = undefined;
    var buf: [16 * 1024]u8 = undefined;

    var out_file = try std.fs.cwd().createFile(out_path, .{ .exclusive = true });
    defer out_file.close();

    const uri = try std.Uri.parse(url);
    var req = try client.open(.GET, uri, .{
        .keep_alive = false,
        .server_header_buffer = &header_buffer,
    });
    defer req.deinit();
    try req.send();
    try req.finish();
    try req.wait();

    if (req.response.status.class() != .success) return error.HttpError;

    while (true) {
        const n = try req.read(&buf);
        if (n == 0) break;
        try out_file.writeAll(buf[0..n]);
    }
}
