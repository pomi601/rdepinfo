const std = @import("std");

pub const Config = struct {
    repos: []Repo,

    pub const Repo = struct {
        name: []const u8,
        url: []const u8,
    };
};

pub const ConfigRoot = struct {
    @"update-deps": Config,
    assets: Assets,
};

pub const Assets = std.json.ArrayHashMap(OneAsset);
pub const OneAsset = struct {
    url: []const u8 = "",
    hash: []const u8 = "",
};

/// Caller should supply an arena allocator as this parse will leak memory.
pub fn readConfigRoot(alloc: std.mem.Allocator, path: []const u8) !ConfigRoot {
    const config_file = try std.fs.cwd().openFile(path, .{});
    defer config_file.close();

    const buf = try config_file.readToEndAlloc(alloc, 128 * 1024);
    const root = try std.json.parseFromSliceLeaky(ConfigRoot, alloc, buf, .{
        .ignore_unknown_fields = true,
    });
    return root;
}
