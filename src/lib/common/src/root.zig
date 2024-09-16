pub const config_json = @import("config-json.zig");
pub const download = @import("download.zig");

test {
    _ = config_json;
    _ = download;
}
