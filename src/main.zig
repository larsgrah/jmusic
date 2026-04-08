const std = @import("std");
const c = @import("c.zig");
const api = @import("jellyfin/api.zig");
const models = @import("jellyfin/models.zig");
const DiskCache = @import("audio/cache.zig").DiskCache;
const Player = @import("audio/player.zig").Player;
const App = @import("ui/window.zig").App;
pub const sonos = @import("sonos.zig");
pub const discord = @import("discord.zig");
pub const scrobble = @import("scrobble.zig");

const log = std.log.scoped(.main);

pub const Config = struct {
    server: []const u8,
    username: []const u8,
    password: []const u8,
    cache_size_mb: u32 = 512,
    lastfm_api_key: ?[]const u8 = null,
    lastfm_secret: ?[]const u8 = null,
    lastfm_session_key: ?[]const u8 = null,
    listenbrainz_token: ?[]const u8 = null,
};

fn loadConfig(allocator: std.mem.Allocator) !Config {
    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    const path = try std.fmt.allocPrint(allocator, "{s}/.config/jmusic/config.json", .{home});
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
        log.err("config not found at {s}: {}", .{ path, err });
        log.err("create it with: {{\"server\":\"http://...\",\"username\":\"...\",\"password\":\"...\"}}", .{});
        return error.NoConfig;
    };
    defer file.close();

    const data = try file.readToEndAlloc(allocator, 4096);
    defer allocator.free(data);

    const parsed = try std.json.parseFromSlice(Config, allocator, data, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    return .{
        .server = try allocator.dupe(u8, parsed.value.server),
        .username = try allocator.dupe(u8, parsed.value.username),
        .password = try allocator.dupe(u8, parsed.value.password),
        .cache_size_mb = parsed.value.cache_size_mb,
        .lastfm_api_key = if (parsed.value.lastfm_api_key) |v| try allocator.dupe(u8, v) else null,
        .lastfm_secret = if (parsed.value.lastfm_secret) |v| try allocator.dupe(u8, v) else null,
        .lastfm_session_key = if (parsed.value.lastfm_session_key) |v| try allocator.dupe(u8, v) else null,
        .listenbrainz_token = if (parsed.value.listenbrainz_token) |v| try allocator.dupe(u8, v) else null,
    };
}

fn onActivate(gtk_app: *c.gtk.GtkApplication, data: ?*anyopaque) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(data));
    app.build(gtk_app);
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    const config = loadConfig(allocator) catch return;

    var client = api.Client.init(allocator, config.server);
    defer client.deinit();

    // Defer auth + album loading to after the window is visible
    var app = App{
        .allocator = allocator,
        .client = &client,
        .player = null,
        .config = &config,
        .playlist_cache = std.StringHashMap(models.ItemList).init(allocator),
        .album_track_cache = std.StringHashMap(models.ItemList).init(allocator),
        .disk_audio_cache = DiskCache.init(allocator, config.cache_size_mb),
    };

    const gtk_app = c.gtk.gtk_application_new("com.jmusic.app", 0);
    defer c.gtk.g_object_unref(gtk_app);

    _ = c.gtk.g_signal_connect_data(
        @ptrCast(gtk_app),
        "activate",
        @ptrCast(&onActivate),
        &app,
        null,
        0,
    );

    _ = c.gtk.g_application_run(@ptrCast(gtk_app), 0, null);

    if (app.player) |p| p.destroy(allocator);
}
