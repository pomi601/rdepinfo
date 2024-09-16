const std = @import("std");
const Allocator = std.mem.Allocator;
const Hash = std.crypto.hash.sha2.Sha256;
const Mutex = std.Thread.Mutex;

const rdepinfo = @import("rdepinfo");
const NAVC = rdepinfo.version.NameAndVersionConstraint;
const NAVCHashMap = rdepinfo.version.NameAndVersionConstraintHashMap;
const NAVCHashMapSortContext = rdepinfo.version.NameAndVersionConstraintSortContext;
const isBasePackage = rdepinfo.isBasePackage;
const isRecommendedPackage = rdepinfo.isRecommendedPackage;

const common = @import("common");
const config_json = common.config_json;
const download = common.download;

const Config = config_json.Config;
const Repository = rdepinfo.Repository;

fn usage() noreturn {
    std.debug.print(
        \\Usage: discover-dependencies <config.json> <out_dir> [src_pkg_dir...]
    , .{});
    std.process.exit(1);
}

const NUM_ARGS_MIN = 2;

/// Requires thread-safe allocator.
fn readRepositories(alloc: Allocator, repos: []Config.Repo, out_dir: []const u8) !Repository {
    var repository = try Repository.init(alloc);

    var urls = try std.ArrayList([]const u8).initCapacity(alloc, repos.len);
    defer {
        for (urls.items) |x| alloc.free(x);
        urls.deinit();
    }
    var paths = try std.ArrayList([]const u8).initCapacity(alloc, repos.len);
    defer {
        for (paths.items) |x| alloc.free(x);
        paths.deinit();
    }

    for (repos) |repo| {
        const url = try std.fmt.allocPrint(alloc, "{s}/src/contrib/PACKAGES.gz", .{repo.url});
        const path = try std.fs.path.join(alloc, &.{ out_dir, repo.name, "PACKAGES.gz" });
        if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);
        urls.appendAssumeCapacity(url);
        paths.appendAssumeCapacity(path);
    }

    const options = download.DownloadOptions{
        .url = try urls.toOwnedSlice(),
        .path = try paths.toOwnedSlice(),
    };
    defer {
        alloc.free(options.url);
        alloc.free(options.path);
    }

    const statuses = try download.downloadFiles(alloc, options);
    defer alloc.free(statuses);

    var index: usize = 0;
    var errorp = false;
    while (index < statuses.len) : (index += 1) {
        switch (statuses[index]) {
            .ok => continue,
            .err => |e| {
                std.debug.print("ERROR: downloading '{s}': {s}\n", .{ options.url[index], e });
                errorp = true;
            },
        }
    }
    if (errorp) std.process.exit(1);

    var buf = try std.ArrayList(u8).initCapacity(alloc, 16 * 1024);
    defer buf.deinit();

    index = 0;
    while (index < options.path.len) : (index += 1) {
        const file = try std.fs.cwd().openFile(options.path[index], .{});
        defer file.close();
        try std.compress.gzip.decompress(file.reader(), buf.writer());

        _ = try repository.read(repos[index].url, buf.items);

        buf.clearRetainingCapacity();
    }
    return repository;
}

fn readPackageDirs(alloc: Allocator, dirs: []const []const u8) Repository {
    var repo = try Repository.init(alloc);

    var i: usize = 0;
    while (i < dirs.len) : (i += 1) {
        var package_dir = std.fs.cwd().openDir(dirs[i], .{ .iterate = true }) catch |err| {
            fatal("ERROR: could not open package directory '{s}': {s}\n", .{ dirs[i], @errorName(err) });
        };
        defer package_dir.close();

        readPackagesIntoRepository(alloc, &repo, package_dir) catch |err| {
            fatal("ERROR: could not read package '{s}': {s}\n", .{ dirs[i], @errorName(err) });
        };
        std.debug.print("read package directory '{s}'\n", .{dirs[i]});
    }
    return repo;
}

/// Walk directory recursively and add all DESCRIPTION files to the given repository.
fn readPackagesIntoRepository(alloc: Allocator, repository: *Repository, dir: std.fs.Dir) !void {
    var walker = try dir.walk(alloc);
    defer walker.deinit();

    while (try walker.next()) |d| {
        switch (d.kind) {
            .file => {
                if (std.mem.eql(u8, "DESCRIPTION", d.basename)) {
                    const file = try d.dir.openFile(d.basename, .{});
                    defer file.close();
                    const buf = try file.readToEndAlloc(alloc, 128 * 1024);
                    defer alloc.free(buf);

                    _ = try repository.read(d.path, buf);
                }
            },
            .directory => {
                var sub = try d.dir.openDir(d.basename, .{ .iterate = true });
                defer sub.close();
                try readPackagesIntoRepository(alloc, repository, sub);
            },
            else => continue,
        }
    }
}

fn calculateDependencies(alloc: Allocator, packages: Repository, cloud: Repository) ![]NAVC {
    // collect external dependencies
    var deps = NAVCHashMap.init(alloc);
    defer deps.deinit();

    var it = packages.iter();
    while (it.next()) |p| {
        for (p.depends) |navc| {
            if (isBasePackage(navc.name)) continue;
            if (isRecommendedPackage(navc.name)) continue;
            if (try packages.findLatestPackage(alloc, navc) == null) {
                try deps.put(navc, true);
            }
        }
        for (p.imports) |navc| {
            if (isBasePackage(navc.name)) continue;
            if (isRecommendedPackage(navc.name)) continue;
            if (try packages.findLatestPackage(alloc, navc) == null) {
                try deps.put(navc, true);
            }
        }
        for (p.linkingTo) |navc| {
            if (isBasePackage(navc.name)) continue;
            if (isRecommendedPackage(navc.name)) continue;
            if (try packages.findLatestPackage(alloc, navc) == null) {
                try deps.put(navc, true);
            }
        }
    }

    // sort the hash map
    deps.sort(NAVCHashMapSortContext{ .keys = deps.keys() });

    // print direct dependencies
    std.debug.print("\nDirect dependencies:\n", .{});
    for (deps.keys()) |navc| {
        std.debug.print("    {}\n", .{navc});
    }

    // collect their transitive dependencies
    const temp_keys = try alloc.dupe(NAVC, deps.keys());
    defer alloc.free(temp_keys);

    for (temp_keys) |navc| {
        const trans = cloud.transitiveDependenciesNoBase(alloc, navc) catch |err| switch (err) {
            error.NotFound => {
                std.debug.print("skipping {s}: could not finish transitive dependencies.\n", .{navc.name});
                continue;
            },
            error.OutOfMemory => {
                fatal("out of memory.\n", .{});
            },
        };
        defer alloc.free(trans);
        for (trans) |x|
            try deps.put(x, true);
    }

    // sort the hash map
    deps.sort(NAVCHashMapSortContext{ .keys = deps.keys() });

    // print everything out
    std.debug.print("\nTransitive dependencies:\n", .{});
    for (deps.keys()) |navc| {
        std.debug.print("    {}\n", .{navc});
    }

    // merge version constraints
    const merged = try rdepinfo.version.mergeNameAndVersionConstraints(alloc, deps.keys());
    std.debug.print("\nMerged transitive dependencies:\n", .{});
    for (merged) |navc| {
        std.debug.print("    {}\n", .{navc});
    }

    return merged;
}

/// Requires thread-safe allocator.
fn checkAndCreateAssets(alloc: Allocator, packages: []NAVC, cloud: Repository) !config_json.Assets {
    const cloud_index = try cloud.createIndex();

    // find the source
    var assets = config_json.Assets{};
    var lock = std.Thread.Mutex{};

    var pool: std.Thread.Pool = undefined;
    try std.Thread.Pool.init(&pool, .{ .allocator = alloc });
    defer pool.deinit();
    var wg = std.Thread.WaitGroup{};

    for (packages) |navc| {
        pool.spawnWg(
            &wg,
            &checkAndAddOnePackage,
            .{ alloc, navc, cloud, cloud_index, &assets, &lock },
        );
    }
    pool.waitAndWork(&wg);

    const C = struct {
        keys: []const []const u8,
        pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
            return std.mem.order(u8, ctx.keys[a_index], ctx.keys[b_index]) == .lt;
        }
    }; // TODO: move this to a util lib somewhere
    assets.map.sort(C{ .keys = assets.map.keys() });
    return assets;
}

fn checkAndAddOnePackage(
    alloc: Allocator,
    package: NAVC,
    cloud: Repository,
    index: Repository.Index,
    assets: *config_json.Assets,
    lock: *Mutex,
) void {
    if (index.findPackage(package)) |found| {
        const slice = cloud.packages.slice();
        const name = slice.items(.name)[found];
        const repo = slice.items(.repository)[found];
        const ver = slice.items(.version_string)[found];
        const url1 = std.fmt.allocPrint(
            alloc,
            "{s}/src/contrib/{s}_{s}.tar.gz",
            .{ repo, name, ver },
        ) catch @panic("OOM");
        const url2 = std.fmt.allocPrint(
            alloc,
            "{s}/src/contrib/Archive/{s}_{s}.tar.gz",
            .{ repo, name, ver },
        ) catch @panic("OOM");

        if (download.headOk(alloc, url1) catch false) {
            lock.lock();
            defer lock.unlock();
            assets.map.put(alloc, package.name, .{ .url = url1 }) catch @panic("OOM");
        } else if (download.headOk(alloc, url2) catch false) {
            lock.lock();
            defer lock.unlock();
            assets.map.put(alloc, package.name, .{ .url = url2 }) catch @panic("OOM");
        } else {
            fatal("ERROR: NOT FOUND: {s}\nNOT FOUND: {s}\n", .{ url1, url2 });
        }
    }
}

fn writeAssets(alloc: std.mem.Allocator, path: []const u8, assets: config_json.Assets) !void {
    var root = try config_json.readConfigRoot(alloc, path);
    root.assets = assets;
    const config_file = try std.fs.cwd().openFile(path, .{ .mode = .write_only });
    defer config_file.close();
    try std.json.stringify(root, .{ .whitespace = .indent_2 }, config_file.writer());
    std.debug.print("\nWrote {s}\n", .{path});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    var tsa = std.heap.ThreadSafeAllocator{ .child_allocator = arena.allocator() };
    const alloc = tsa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < NUM_ARGS_MIN + 1) usage();
    const config_path = args[1];
    const out_dir_path = args[2];

    const config = try config_json.readConfigRoot(alloc, config_path);
    const repos = config.@"update-deps".repos;

    // this requires a threadsafe allocator
    const repositories = try readRepositories(alloc, repos, out_dir_path);

    const packages = readPackageDirs(alloc, args[3..args.len]);
    const merged = try calculateDependencies(alloc, packages, repositories);

    const assets = try checkAndCreateAssets(alloc, merged, repositories);
    try writeAssets(alloc, config_path, assets);
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format, args);
    std.process.exit(1);
}
