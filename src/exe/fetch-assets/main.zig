const std = @import("std");
const Allocator = std.mem.Allocator;
const Hash = std.crypto.hash.sha2.Sha256;
const Mutex = std.Thread.Mutex;

const common = @import("common");
const config_json = common.config_json;
const download = common.download;

const Config = config_json.Config;

fn usage() noreturn {
    std.debug.print(
        \\Usage: fetch-assets <config.json> <out_dir>
    , .{});
    std.process.exit(1);
}

const NUM_ARGS = 2;

fn hashOne(
    alloc: Allocator,
    asset_name: []const u8,
    asset: Config.OneAsset,
    file_path: []const u8,
    config_path: []const u8,
    config_mutex: *Mutex,
) void {
    const hash = blk: {
        const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
            fatal("ERROR: could not open file '{s}': {s}\n", .{ file_path, @errorName(err) });
        };
        defer file.close();

        // hash the file
        var buf: [std.mem.page_size]u8 = undefined;
        var hasher = Hash.init(.{});
        while (true) {
            const n = file.read(&buf) catch |err| {
                file.close();
                fatal("ERROR: read error on file '{s}': {s}\n", .{ file_path, @errorName(err) });
            };
            if (n == 0) break;
            hasher.update(buf[0..n]);
        }
        break :blk hasher.finalResult();
    };

    // compare to expected, or write to config file if expected is blank
    if (asset.hash.len != 0) {
        var expected: [Hash.digest_length]u8 = undefined;
        _ = std.fmt.hexToBytes(&expected, asset.hash) catch |err| {
            fatal("ERROR: could not decode hash '{s}': {s}\n", .{ asset.hash, @errorName(err) });
        };
        if (!std.mem.eql(u8, &expected, &hash)) {
            fatal(
                "ERROR: hash mismatch for '{s}':\n    expected: {s}\n         got: {s}\n",
                .{
                    asset_name,
                    std.fmt.bytesToHex(expected, .lower),
                    std.fmt.bytesToHex(hash, .lower),
                },
            );
        }
    } else {
        // write hash to file
        config_mutex.lock();
        defer config_mutex.unlock();
        const config_root = config_json.readConfigRoot(alloc, config_path, .{}) catch |err| {
            fatal("ERROR: unable to read config file '{s}': {s}\n", .{ config_path, @errorName(err) });
        };
        var config = config_root.@"generate-build";
        config.assets.map.put(alloc, asset_name, .{
            .url = asset.url,
            .hash = &std.fmt.bytesToHex(hash, .lower),
        }) catch |err| {
            fatal("ERROR: failed to add key: '{s}' to hash table: {s}\n", .{
                asset_name,
                @errorName(err),
            });
        };

        const config_file = std.fs.cwd().createFile(config_path, .{}) catch |err| {
            fatal("ERROR: cannot open config file '{s}': {s}\n", .{ config_path, @errorName(err) });
        };
        defer config_file.close();

        std.json.stringify(
            config_root,
            .{ .whitespace = .indent_2 },
            config_file.writer(),
        ) catch |err| {
            config_file.close();
            fatal("ERROR: could not stringify to JSON: {s}\n", .{@errorName(err)});
        };

        // print warning
        std.debug.print("WARNING: wrote new hash for asset '{s}'\n", .{asset_name});
    }
}

fn downloadOne(
    asset_name: []const u8,
    asset: Config.OneAsset,
    out_dir: []const u8,
    config_path: []const u8,
    mutex: *Mutex,
) void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const basename = std.fs.path.basenamePosix(asset.url);
    const out_path = std.fs.path.join(arena.allocator(), &.{ out_dir, basename }) catch |err| {
        fatal("ERROR: unable to join paths '{s}' and '{s}': {s}\n", .{
            out_dir,
            basename,
            @errorName(err),
        });
    };

    download.downloadFile(arena.allocator(), asset.url, out_path) catch |err| {
        fatal("ERROR: download of '{s}' failed: {s}\n", .{ asset.url, @errorName(err) });
    };

    hashOne(
        arena.allocator(),
        asset_name,
        asset,
        out_path,
        config_path,
        mutex,
    );
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const args = try std.process.argsAlloc(arena.allocator());
    defer std.process.argsFree(arena.allocator(), args);

    if (args.len != NUM_ARGS + 1) usage();
    const config_path = args[1];
    const out_dir_path = args[2];

    const config_root = try config_json.readConfigRoot(arena.allocator(), config_path, .{});
    const config = config_root.@"generate-build";
    const assets = config.assets;

    var pool: std.Thread.Pool = undefined;
    try std.Thread.Pool.init(&pool, .{ .allocator = alloc });
    defer pool.deinit();
    var config_file_lock = std.Thread.Mutex{};
    var wg = std.Thread.WaitGroup{};

    for (assets.map.keys()) |name| {
        if (assets.map.get(name)) |asset| {
            pool.spawnWg(
                &wg,
                &downloadOne,
                .{ name, asset, out_dir_path, config_path, &config_file_lock },
            );
        }
    }

    pool.waitAndWork(&wg);
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format, args);
    std.process.exit(1);
}
