const std = @import("std");
const models = @import("models.zig");

const log = std.log.scoped(.jellyfin);

pub const Client = struct {
    allocator: std.mem.Allocator,
    base_url: []const u8,
    token: ?[]const u8 = null,
    user_id: ?[]const u8 = null,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    http: std.http.Client,

    pub fn init(allocator: std.mem.Allocator, base_url: []const u8) Client {
        return .{
            .allocator = allocator,
            .base_url = base_url,
            .http = .{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *Client) void {
        self.http.deinit();
    }

    pub fn authenticate(self: *Client, username: []const u8, password: []const u8) !void {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/Users/AuthenticateByName", .{self.base_url});
        defer self.allocator.free(url);

        const body = try std.fmt.allocPrint(
            self.allocator,
            "{{\"Username\":\"{s}\",\"Pw\":\"{s}\"}}",
            .{ username, password },
        );
        defer self.allocator.free(body);

        const result = try self.request(.POST, url, body);
        defer self.allocator.free(result);

        const AuthResponse = struct {
            AccessToken: []const u8 = "",
            User: struct {
                Id: []const u8 = "",
            } = .{},
        };

        const parsed = try std.json.parseFromSlice(AuthResponse, self.allocator, result, models.json_options);
        defer parsed.deinit();

        self.token = try self.allocator.dupe(u8, parsed.value.AccessToken);
        self.user_id = try self.allocator.dupe(u8, parsed.value.User.Id);
        self.username = username;
        self.password = password;
        log.info("authenticated as user {s}", .{self.user_id.?});
    }

    pub fn getAlbums(self: *Client) !models.ItemList {
        // Try cache first
        if (readCache(self.allocator)) |cached| {
            defer self.allocator.free(cached);
            const result = models.parseItemList(self.allocator, cached);
            if (result) |list| {
                log.info("loaded {d} albums from cache", .{list.items.len});
                return list;
            } else |_| {}
        }

        return self.fetchAndCacheAlbums();
    }

    pub fn fetchAndCacheAlbums(self: *Client) !models.ItemList {
        const uid = self.user_id orelse return error.NotAuthenticated;
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/Users/{s}/Items?IncludeItemTypes=MusicAlbum&Recursive=true&SortBy=SortName&Fields=BasicSyncInfo",
            .{ self.base_url, uid },
        );
        defer self.allocator.free(url);

        const body = try self.request(.GET, url, null);
        defer self.allocator.free(body);

        writeCache(body);

        return models.parseItemList(self.allocator, body);
    }

    fn getCacheBase(buf: *[256]u8) ?[]const u8 {
        const xdg = std.posix.getenv("XDG_CACHE_HOME");
        const home = std.posix.getenv("HOME");
        const base = xdg orelse (home orelse return null);
        const suffix = if (xdg != null) "/jmusic" else "/.cache/jmusic";
        return std.fmt.bufPrint(buf, "{s}{s}", .{ base, suffix }) catch null;
    }

    pub fn readCacheFile(allocator: std.mem.Allocator, name: []const u8, max_age_hours: u32) ?[]const u8 {
        var base_buf: [256]u8 = undefined;
        const base = getCacheBase(&base_buf) orelse return null;
        var path_buf: [300]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ base, name }) catch return null;

        const file = std.fs.openFileAbsolute(path, .{}) catch return null;
        defer file.close();

        const stat = file.stat() catch return null;
        const now = std.time.nanoTimestamp();
        const age_ns = now - @as(i128, stat.mtime);
        if (age_ns > @as(i128, max_age_hours) * std.time.ns_per_hour) return null;

        return file.readToEndAlloc(allocator, 32 * 1024 * 1024) catch null;
    }

    fn writeCacheFile(name: []const u8, data: []const u8) void {
        var base_buf: [256]u8 = undefined;
        const base = getCacheBase(&base_buf) orelse return;

        std.fs.makeDirAbsolute(base) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return,
        };

        var path_buf: [300]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ base, name }) catch return;

        const file = std.fs.createFileAbsolute(path, .{}) catch return;
        defer file.close();
        file.writeAll(data) catch {};
    }

    // Convenience: albums cache (24h)
    fn readCache(allocator: std.mem.Allocator) ?[]const u8 {
        return readCacheFile(allocator, "albums.json", 24);
    }
    fn writeCache(data: []const u8) void {
        writeCacheFile("albums.json", data);
    }

    pub fn getRecentlyAdded(self: *Client, limit: u32) !models.ItemList {
        // 1h cache - new albums don't change fast
        if (readCacheFile(self.allocator, "recent_added.json", 1)) |cached| {
            defer self.allocator.free(cached);
            if (models.parseItemList(self.allocator, cached)) |list| return list else |_| {}
        }
        const uid = self.user_id orelse return error.NotAuthenticated;
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/Users/{s}/Items?IncludeItemTypes=MusicAlbum&Recursive=true&SortBy=DateCreated&SortOrder=Descending&Limit={d}&Fields=BasicSyncInfo",
            .{ self.base_url, uid, limit },
        );
        defer self.allocator.free(url);
        const body = try self.request(.GET, url, null);
        defer self.allocator.free(body);
        writeCacheFile("recent_added.json", body);
        return models.parseItemList(self.allocator, body);
    }

    pub fn getRecentlyPlayed(self: *Client, limit: u32) !models.ItemList {
        // Short cache - play history changes often
        if (readCacheFile(self.allocator, "recent_played.json", 1)) |cached| {
            defer self.allocator.free(cached);
            if (models.parseItemList(self.allocator, cached)) |list| return list else |_| {}
        }
        const uid = self.user_id orelse return error.NotAuthenticated;
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/Users/{s}/Items?IncludeItemTypes=Audio&Recursive=true&SortBy=DatePlayed&SortOrder=Descending&Limit={d}&Filters=IsPlayed&Fields=BasicSyncInfo",
            .{ self.base_url, uid, limit },
        );
        defer self.allocator.free(url);
        const body = try self.request(.GET, url, null);
        defer self.allocator.free(body);
        writeCacheFile("recent_played.json", body);
        return models.parseItemList(self.allocator, body);
    }

    pub fn getRandomAlbums(self: *Client, limit: u32) !models.ItemList {
        const uid = self.user_id orelse return error.NotAuthenticated;
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/Users/{s}/Items?IncludeItemTypes=MusicAlbum&Recursive=true&SortBy=Random&Limit={d}&Fields=BasicSyncInfo",
            .{ self.base_url, uid, limit },
        );
        defer self.allocator.free(url);
        const body = try self.request(.GET, url, null);
        defer self.allocator.free(body);
        return models.parseItemList(self.allocator, body);
    }

    pub fn getFavoriteAlbums(self: *Client, limit: u32) !models.ItemList {
        const uid = self.user_id orelse return error.NotAuthenticated;
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/Users/{s}/Items?IncludeItemTypes=MusicAlbum&Recursive=true&Filters=IsFavorite&Limit={d}&Fields=BasicSyncInfo",
            .{ self.base_url, uid, limit },
        );
        defer self.allocator.free(url);
        const body = try self.request(.GET, url, null);
        defer self.allocator.free(body);
        return models.parseItemList(self.allocator, body);
    }

    pub fn getPlaylists(self: *Client) !models.ItemList {
        // Get user's own playlists (favorites + ones with their name)
        // Jellyfin doesn't have a "created by me" filter, so we get favorites
        // and personal mixes
        const uid = self.user_id orelse return error.NotAuthenticated;

        // Favorites first
        const fav_url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/Users/{s}/Items?IncludeItemTypes=Playlist&Recursive=true&Filters=IsFavorite&SortBy=SortName&Fields=BasicSyncInfo",
            .{ self.base_url, uid },
        );
        defer self.allocator.free(fav_url);
        const fav_body = try self.request(.GET, fav_url, null);
        defer self.allocator.free(fav_body);
        const favs = try models.parseItemList(self.allocator, fav_body);

        // Also get personal mixes (playlists with username)
        const user_url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/Users/{s}/Items?IncludeItemTypes=Playlist&Recursive=true&SortBy=SortName&Fields=BasicSyncInfo&Limit=50",
            .{ self.base_url, uid },
        );
        defer self.allocator.free(user_url);
        const user_body = try self.request(.GET, user_url, null);
        defer self.allocator.free(user_body);
        const all = try models.parseItemList(self.allocator, user_body);

        // Free the container slices after merging (items are shallow-copied into result)
        defer self.allocator.free(favs.items);
        defer self.allocator.free(all.items);

        var result = std.ArrayListUnmanaged(models.BaseItem).empty;

        // Add all favorites
        for (favs.items) |item| {
            result.append(self.allocator, item) catch continue;
        }

        // Add non-auto playlists that aren't already in favorites
        for (all.items) |item| {
            // Skip auto-generated playlists
            if (std.mem.startsWith(u8, item.name, "This is ")) continue;
            if (std.mem.startsWith(u8, item.name, "Back to the ")) continue;
            if (std.mem.endsWith(u8, item.name, " Radio")) continue;

            // Skip duplicates from favorites
            var found = false;
            for (result.items) |existing| {
                if (std.mem.eql(u8, existing.id, item.id)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                result.append(self.allocator, item) catch continue;
            }
        }

        const count: u32 = @intCast(result.items.len);
        return .{
            .items = result.toOwnedSlice(self.allocator) catch &.{},
            .total_count = count,
        };
    }


    pub fn createPlaylist(self: *Client, name: []const u8) ![]const u8 {
        const uid = self.user_id orelse return error.NotAuthenticated;
        const url = try std.fmt.allocPrint(self.allocator, "{s}/Playlists", .{self.base_url});
        defer self.allocator.free(url);

        const body = try std.fmt.allocPrint(
            self.allocator,
            "{{\"Name\":\"{s}\",\"UserId\":\"{s}\",\"Ids\":[],\"MediaType\":\"Audio\"}}",
            .{ name, uid },
        );
        defer self.allocator.free(body);

        const result = try self.request(.POST, url, body);
        defer self.allocator.free(result);

        // Response: {"Id":"..."}
        const Resp = struct { Id: []const u8 = "" };
        const parsed = try std.json.parseFromSlice(Resp, self.allocator, result, models.json_options);
        defer parsed.deinit();
        return try self.allocator.dupe(u8, parsed.value.Id);
    }

    pub fn addToPlaylist(self: *Client, playlist_id: []const u8, item_ids: []const []const u8) !void {
        // Build comma-separated IDs
        var ids_buf = std.ArrayListUnmanaged(u8).empty;
        defer ids_buf.deinit(self.allocator);
        for (item_ids, 0..) |id, i| {
            if (i > 0) ids_buf.append(self.allocator, ',') catch continue;
            ids_buf.appendSlice(self.allocator, id) catch continue;
        }
        const ids_str = ids_buf.items;

        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/Playlists/{s}/Items?Ids={s}",
            .{ self.base_url, playlist_id, ids_str },
        );
        defer self.allocator.free(url);

        const result = try self.request(.POST, url, null);
        self.allocator.free(result);
    }

    pub fn removeFromPlaylist(self: *Client, playlist_id: []const u8, entry_ids: []const []const u8) !void {
        var ids_buf = std.ArrayListUnmanaged(u8).empty;
        defer ids_buf.deinit(self.allocator);
        for (entry_ids, 0..) |id, i| {
            if (i > 0) ids_buf.append(self.allocator, ',') catch continue;
            ids_buf.appendSlice(self.allocator, id) catch continue;
        }

        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/Playlists/{s}/Items?EntryIds={s}",
            .{ self.base_url, playlist_id, ids_buf.items },
        );
        defer self.allocator.free(url);

        // DELETE request
        const uri = try std.Uri.parse(url);
        const auth = try self.authHeader();
        defer self.allocator.free(auth);
        var req = try self.http.request(.DELETE, uri, .{
            .extra_headers = &.{
                .{ .name = "Authorization", .value = auth },
            },
            .headers = .{ .accept_encoding = .{ .override = "identity" } },
        });
        defer req.deinit();
        try req.sendBodiless();
        var redirect_buf: [4096]u8 = undefined;
        _ = try req.receiveHead(&redirect_buf);
    }

    pub fn movePlaylistItem(self: *Client, playlist_id: []const u8, item_id: []const u8, new_index: u32) !void {
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/Playlists/{s}/Items/{s}/Move/{d}",
            .{ self.base_url, playlist_id, item_id, new_index },
        );
        defer self.allocator.free(url);

        const result = try self.request(.POST, url, null);
        self.allocator.free(result);
    }

    pub fn getInstantMix(self: *Client, item_id: []const u8, limit: u32) !models.ItemList {
        const uid = self.user_id orelse return error.NotAuthenticated;
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/Items/{s}/InstantMix?UserId={s}&Limit={d}&Fields=BasicSyncInfo",
            .{ self.base_url, item_id, uid, limit },
        );
        defer self.allocator.free(url);

        const body = try self.request(.GET, url, null);
        defer self.allocator.free(body);
        return models.parseItemList(self.allocator, body);
    }

    pub fn getPlaylistTracks(self: *Client, playlist_id: []const u8) !models.ItemList {
        const uid = self.user_id orelse return error.NotAuthenticated;
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/Users/{s}/Items?ParentId={s}&SortBy=SortName&Fields=BasicSyncInfo",
            .{ self.base_url, uid, playlist_id },
        );
        defer self.allocator.free(url);

        const body = try self.request(.GET, url, null);
        defer self.allocator.free(body);

        return models.parseItemList(self.allocator, body);
    }

    pub fn searchAlbums(self: *Client, query: []const u8, limit: u32) !models.ItemList {
        const uid = self.user_id orelse return error.NotAuthenticated;
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/Users/{s}/Items?IncludeItemTypes=MusicAlbum&Recursive=true&SortBy=SortName&Fields=BasicSyncInfo&SearchTerm={s}&Limit={d}",
            .{ self.base_url, uid, query, limit },
        );
        defer self.allocator.free(url);

        const body = try self.request(.GET, url, null);
        defer self.allocator.free(body);

        return models.parseItemList(self.allocator, body);
    }

    pub fn getAlbumTracks(self: *Client, album_id: []const u8) !models.ItemList {
        const uid = self.user_id orelse return error.NotAuthenticated;
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/Users/{s}/Items?ParentId={s}&SortBy=IndexNumber&Fields=BasicSyncInfo",
            .{ self.base_url, uid, album_id },
        );
        defer self.allocator.free(url);

        const body = try self.request(.GET, url, null);
        defer self.allocator.free(body);

        return models.parseItemList(self.allocator, body);
    }

    pub fn getArtists(self: *Client, limit: u32) !models.ItemList {
        // 24h cache like albums
        if (readCacheFile(self.allocator, "artists.json", 24)) |cached| {
            defer self.allocator.free(cached);
            if (models.parseItemList(self.allocator, cached)) |list| {
                log.info("loaded {d} artists from cache", .{list.items.len});
                return list;
            } else |_| {}
        }
        const uid = self.user_id orelse return error.NotAuthenticated;
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/Artists?UserId={s}&SortBy=SortName&Fields=BasicSyncInfo&Limit={d}",
            .{ self.base_url, uid, limit },
        );
        defer self.allocator.free(url);
        const body = try self.request(.GET, url, null);
        defer self.allocator.free(body);
        writeCacheFile("artists.json", body);
        return models.parseItemList(self.allocator, body);
    }

    pub fn searchArtists(self: *Client, query: []const u8, limit: u32) !models.ItemList {
        const uid = self.user_id orelse return error.NotAuthenticated;
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/Artists?UserId={s}&SearchTerm={s}&Limit={d}&Fields=BasicSyncInfo",
            .{ self.base_url, uid, query, limit },
        );
        defer self.allocator.free(url);
        const body = try self.request(.GET, url, null);
        defer self.allocator.free(body);
        return models.parseItemList(self.allocator, body);
    }

    pub fn getArtistAlbums(self: *Client, artist_id: []const u8) !models.ItemList {
        const uid = self.user_id orelse return error.NotAuthenticated;
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/Users/{s}/Items?IncludeItemTypes=MusicAlbum&Recursive=true&ArtistIds={s}&SortBy=ProductionYear,SortName&SortOrder=Descending&Fields=BasicSyncInfo",
            .{ self.base_url, uid, artist_id },
        );
        defer self.allocator.free(url);
        const body = try self.request(.GET, url, null);
        defer self.allocator.free(body);
        return models.parseItemList(self.allocator, body);
    }

    pub fn searchTracks(self: *Client, query: []const u8, limit: u32) !models.ItemList {
        const uid = self.user_id orelse return error.NotAuthenticated;
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/Users/{s}/Items?IncludeItemTypes=Audio&Recursive=true&SearchTerm={s}&Limit={d}&Fields=BasicSyncInfo",
            .{ self.base_url, uid, query, limit },
        );
        defer self.allocator.free(url);
        const body = try self.request(.GET, url, null);
        defer self.allocator.free(body);
        return models.parseItemList(self.allocator, body);
    }

    pub fn getStreamUrl(self: *Client, item_id: []const u8) ![]const u8 {
        return std.fmt.allocPrint(
            self.allocator,
            "{s}/Audio/{s}/universal?Container=opus,mp3,flac&AudioCodec=aac&api_key={s}",
            .{ self.base_url, item_id, self.token orelse return error.NotAuthenticated },
        );
    }

    pub fn getImageUrl(self: *Client, item_id: []const u8, max_width: u32) ![]const u8 {
        return std.fmt.allocPrint(
            self.allocator,
            "{s}/Items/{s}/Images/Primary?maxWidth={d}",
            .{ self.base_url, item_id, max_width },
        );
    }

    fn authHeader(self: *Client) ![]const u8 {
        if (self.token) |tok| {
            return std.fmt.allocPrint(
                self.allocator,
                "MediaBrowser Token=\"{s}\", Client=\"jmusic\", Device=\"desktop\", DeviceId=\"jmusic-zig\", Version=\"0.1.0\"",
                .{tok},
            );
        }
        return std.fmt.allocPrint(
            self.allocator,
            "MediaBrowser Client=\"jmusic\", Device=\"desktop\", DeviceId=\"jmusic-zig\", Version=\"0.1.0\"",
            .{},
        );
    }

    fn request(self: *Client, method: std.http.Method, url: []const u8, body_payload: ?[]const u8) ![]const u8 {
        return self.requestInner(method, url, body_payload, true);
    }

    fn requestInner(self: *Client, method: std.http.Method, url: []const u8, body_payload: ?[]const u8, allow_retry: bool) ![]const u8 {
        const uri = try std.Uri.parse(url);
        const auth = try self.authHeader();
        defer self.allocator.free(auth);

        const extra_headers: []const std.http.Header = &.{
            .{ .name = "Authorization", .value = auth },
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Accept-Encoding", .value = "identity" },
        };

        var req = try self.http.request(method, uri, .{
            .extra_headers = extra_headers,
            .headers = .{ .accept_encoding = .{ .override = "identity" } },
        });
        defer req.deinit();

        if (body_payload) |payload| {
            const mut_body = try self.allocator.dupe(u8, payload);
            defer self.allocator.free(mut_body);
            try req.sendBodyComplete(mut_body);
        } else {
            try req.sendBodiless();
        }

        var redirect_buf: [4096]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);
        if (response.head.status == .unauthorized and allow_retry) {
            if (self.username != null and self.password != null) {
                log.info("token expired, re-authenticating", .{});
                // Re-auth with a separate HTTP client to avoid circular error sets
                var auth_client = Client.init(self.allocator, self.base_url);
                defer auth_client.deinit();
                const auth_url = std.fmt.allocPrint(self.allocator, "{s}/Users/AuthenticateByName", .{self.base_url}) catch return error.HttpError;
                defer self.allocator.free(auth_url);
                const auth_body = std.fmt.allocPrint(self.allocator, "{{\"Username\":\"{s}\",\"Pw\":\"{s}\"}}", .{ self.username.?, self.password.? }) catch return error.HttpError;
                defer self.allocator.free(auth_body);
                const auth_result = auth_client.requestInner(.POST, auth_url, auth_body, false) catch return error.HttpError;
                defer self.allocator.free(auth_result);

                const AuthResp = struct { AccessToken: []const u8 = "", User: struct { Id: []const u8 = "" } = .{} };
                const parsed = std.json.parseFromSlice(AuthResp, self.allocator, auth_result, models.json_options) catch return error.HttpError;
                defer parsed.deinit();
                if (self.token) |old| self.allocator.free(old);
                if (self.user_id) |old| self.allocator.free(old);
                self.token = self.allocator.dupe(u8, parsed.value.AccessToken) catch return error.HttpError;
                self.user_id = self.allocator.dupe(u8, parsed.value.User.Id) catch return error.HttpError;
                log.info("re-authenticated", .{});

                return self.requestInner(method, url, body_payload, false);
            }
            return error.HttpError;
        }
        if (response.head.status != .ok) {
            log.err("{s} {s} -> {d}", .{ @tagName(method), url, @intFromEnum(response.head.status) });
            return error.HttpError;
        }

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.allocator);

        var reader = response.reader(&.{});
        reader.appendRemaining(self.allocator, &buf, .unlimited) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ReadFailed => return error.HttpError,
            error.StreamTooLong => unreachable,
        };

        return try buf.toOwnedSlice(self.allocator);
    }

    pub fn downloadToFile(self: *Client, url: []const u8, dest_path: []const u8) !void {
        const data = try self.fetchBytes(url);
        defer self.allocator.free(data);

        const file = try std.fs.createFileAbsolute(dest_path, .{});
        defer file.close();
        try file.writeAll(data);
    }

    pub fn fetchBytes(self: *Client, url: []const u8) ![]const u8 {
        const uri = try std.Uri.parse(url);

        var req = try self.http.request(.GET, uri, .{
            .headers = .{ .accept_encoding = .{ .override = "identity" } },
        });
        defer req.deinit();

        try req.sendBodiless();

        var redirect_buf: [4096]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);
        if (response.head.status != .ok) return error.HttpError;

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.allocator);

        var reader = response.reader(&.{});
        reader.appendRemaining(self.allocator, &buf, .unlimited) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ReadFailed => return error.HttpError,
            error.StreamTooLong => unreachable,
        };

        return try buf.toOwnedSlice(self.allocator);
    }
};
