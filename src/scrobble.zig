const std = @import("std");

const log = std.log.scoped(.scrobble);

const LASTFM_API_URL = "https://ws.audioscrobbler.com/2.0/";
const LASTFM_AUTH_URL = "https://www.last.fm/api/auth/?api_key={s}&token={s}";

pub const Scrobbler = struct {
    allocator: std.mem.Allocator,
    http: std.http.Client,

    // Last.fm
    lastfm_api_key: ?[]const u8 = null,
    lastfm_secret: ?[]const u8 = null,
    lastfm_session: ?[]const u8 = null,

    // ListenBrainz
    listenbrainz_token: ?[]const u8 = null,

    // Track state
    current_track: ?[]const u8 = null,
    current_artist: ?[]const u8 = null,
    current_album: ?[]const u8 = null,
    current_duration: u32 = 0,
    play_start: i64 = 0,
    scrobbled: bool = false,

    pub fn init(allocator: std.mem.Allocator) Scrobbler {
        return .{
            .allocator = allocator,
            .http = .{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *Scrobbler) void {
        self.http.deinit();
    }

    pub fn enabled(self: *Scrobbler) bool {
        return self.lastfm_session != null or self.listenbrainz_token != null;
    }

    // Call when a new track starts playing
    pub fn nowPlaying(self: *Scrobbler, track: []const u8, artist: []const u8, album: []const u8, duration_secs: u32) void {
        self.current_track = track;
        self.current_artist = artist;
        self.current_album = album;
        self.current_duration = duration_secs;
        self.play_start = @divTrunc(std.time.milliTimestamp(), 1000);
        self.scrobbled = false;

        if (self.lastfm_session != null) self.lastfmNowPlaying(track, artist, album) catch |err| {
            log.warn("last.fm now playing failed: {}", .{err});
        };
        if (self.listenbrainz_token != null) self.listenbrainzNowPlaying(track, artist) catch |err| {
            log.warn("listenbrainz now playing failed: {}", .{err});
        };
    }

    // Call periodically (e.g. from progress timer). Scrobbles once at 50%.
    pub fn checkScrobble(self: *Scrobbler, position_secs: u32) void {
        if (self.scrobbled) return;
        if (self.current_duration < 30) return; // Last.fm requires >= 30s tracks
        if (position_secs < self.current_duration / 2) return;

        self.scrobbled = true;
        const track = self.current_track orelse return;
        const artist = self.current_artist orelse return;
        const album = self.current_album orelse "";

        log.info("scrobbling: {s} - {s}", .{ artist, track });

        if (self.lastfm_session != null) self.lastfmScrobble(track, artist, album) catch |err| {
            log.warn("last.fm scrobble failed: {}", .{err});
        };
        if (self.listenbrainz_token != null) self.listenbrainzScrobble(track, artist) catch |err| {
            log.warn("listenbrainz scrobble failed: {}", .{err});
        };
    }

    // -- Last.fm --

    fn lastfmNowPlaying(self: *Scrobbler, track: []const u8, artist: []const u8, album: []const u8) !void {
        var params: [5]Param = .{
            .{ .key = "method", .val = "track.updateNowPlaying" },
            .{ .key = "artist", .val = artist },
            .{ .key = "track", .val = track },
            .{ .key = "album", .val = album },
            .{ .key = "sk", .val = self.lastfm_session orelse return },
        };
        try self.lastfmCall(&params);
    }

    fn lastfmScrobble(self: *Scrobbler, track: []const u8, artist: []const u8, album: []const u8) !void {
        var ts_buf: [16]u8 = undefined;
        const timestamp = std.fmt.bufPrint(&ts_buf, "{d}", .{self.play_start}) catch return;

        var params: [6]Param = .{
            .{ .key = "method", .val = "track.scrobble" },
            .{ .key = "artist", .val = artist },
            .{ .key = "track", .val = track },
            .{ .key = "album", .val = album },
            .{ .key = "timestamp", .val = timestamp },
            .{ .key = "sk", .val = self.lastfm_session orelse return },
        };
        try self.lastfmCall(&params);
    }

    pub fn lastfmGetToken(self: *Scrobbler) ![]const u8 {
        const api_key = self.lastfm_api_key orelse return error.NoApiKey;
        var params: [2]Param = .{
            .{ .key = "method", .val = "auth.getToken" },
            .{ .key = "api_key", .val = api_key },
        };
        const body = try self.lastfmCallRaw(&params, false);
        defer self.allocator.free(body);

        // Parse <token>...</token> from XML
        const start = std.mem.indexOf(u8, body, "<token>") orelse return error.ParseError;
        const end = std.mem.indexOf(u8, body[start + 7 ..], "</token>") orelse return error.ParseError;
        return try self.allocator.dupe(u8, body[start + 7 ..][0..end]);
    }

    pub fn lastfmGetSession(self: *Scrobbler, token: []const u8) ![]const u8 {
        const api_key = self.lastfm_api_key orelse return error.NoApiKey;
        var params: [3]Param = .{
            .{ .key = "method", .val = "auth.getSession" },
            .{ .key = "api_key", .val = api_key },
            .{ .key = "token", .val = token },
        };
        const body = try self.lastfmCallRaw(&params, true);
        defer self.allocator.free(body);

        const start = std.mem.indexOf(u8, body, "<key>") orelse return error.ParseError;
        const end = std.mem.indexOf(u8, body[start + 5 ..], "</key>") orelse return error.ParseError;
        return try self.allocator.dupe(u8, body[start + 5 ..][0..end]);
    }

    const Param = struct { key: []const u8, val: []const u8 };

    fn lastfmCall(self: *Scrobbler, params: []Param) !void {
        const body = try self.lastfmCallRaw(params, true);
        self.allocator.free(body);
    }

    fn lastfmCallRaw(self: *Scrobbler, params: []Param, sign: bool) ![]const u8 {
        const api_key = self.lastfm_api_key orelse return error.NoApiKey;

        // Build full param list including api_key, then sort
        var all_params: [10]Param = undefined;
        var count: usize = 0;

        // Add api_key if not already in params
        var has_api_key = false;
        for (params) |p| {
            if (std.mem.eql(u8, p.key, "api_key")) has_api_key = true;
        }
        if (!has_api_key) {
            all_params[count] = .{ .key = "api_key", .val = api_key };
            count += 1;
        }
        for (params) |p| {
            all_params[count] = p;
            count += 1;
        }

        const sorted = all_params[0..count];
        std.mem.sort(Param, sorted, {}, struct {
            fn cmp(_: void, a: Param, b: Param) bool {
                return std.mem.order(u8, a.key, b.key) == .lt;
            }
        }.cmp);

        // Build POST body and signature string in sorted order
        var body_buf: [2048]u8 = undefined;
        var body_stream = std.io.fixedBufferStream(&body_buf);
        const bw = body_stream.writer();

        var sig_buf: [2048]u8 = undefined;
        var sig_stream = std.io.fixedBufferStream(&sig_buf);
        const sw = sig_stream.writer();

        for (sorted, 0..) |p, i| {
            if (i > 0) bw.writeByte('&') catch return error.BufferOverflow;
            bw.writeAll(p.key) catch return error.BufferOverflow;
            bw.writeByte('=') catch return error.BufferOverflow;
            urlEncode(bw, p.val) catch return error.BufferOverflow;
            sw.writeAll(p.key) catch {};
            sw.writeAll(p.val) catch {};
        }

        if (sign) {
            sw.writeAll(self.lastfm_secret orelse return error.NoSecret) catch {};
            const sig_hash = md5(sig_stream.getWritten());
            var sig_hex: [32]u8 = undefined;
            for (sig_hash, 0..) |byte, j| {
                sig_hex[j * 2] = "0123456789abcdef"[byte >> 4];
                sig_hex[j * 2 + 1] = "0123456789abcdef"[byte & 0xf];
            }
            bw.writeAll("&api_sig=") catch return error.BufferOverflow;
            bw.writeAll(&sig_hex) catch return error.BufferOverflow;
        }

        const post_body = body_stream.getWritten();
        return self.httpPost(LASTFM_API_URL, post_body, "application/x-www-form-urlencoded");
    }

    // -- ListenBrainz --

    fn listenbrainzNowPlaying(self: *Scrobbler, track: []const u8, artist: []const u8) !void {
        var buf: [1024]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        const w = stream.writer();
        try w.writeAll("{\"listen_type\":\"playing_now\",\"payload\":[{\"track_metadata\":{\"track_name\":\"");
        try jsonEscape(w, track);
        try w.writeAll("\",\"artist_name\":\"");
        try jsonEscape(w, artist);
        try w.writeAll("\"}}]}");
        const body = stream.getWritten();

        const result = try self.listenbrainzPost(body);
        self.allocator.free(result);
    }

    fn listenbrainzScrobble(self: *Scrobbler, track: []const u8, artist: []const u8) !void {
        var buf: [1024]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        const w = stream.writer();
        try w.print("{{\"listen_type\":\"single\",\"payload\":[{{\"listened_at\":{d},\"track_metadata\":{{\"track_name\":\"", .{self.play_start});
        try jsonEscape(w, track);
        try w.writeAll("\",\"artist_name\":\"");
        try jsonEscape(w, artist);
        try w.writeAll("\"}}]}");
        // Close the outer object properly
        const body = stream.getWritten();

        const result = try self.listenbrainzPost(body);
        self.allocator.free(result);
    }

    fn listenbrainzPost(self: *Scrobbler, body: []const u8) ![]const u8 {
        const token = self.listenbrainz_token orelse return error.NoToken;
        const url = "https://api.listenbrainz.org/1/submit-listens";
        const uri = try std.Uri.parse(url);

        var auth_buf: [128]u8 = undefined;
        const auth = try std.fmt.bufPrint(&auth_buf, "Token {s}", .{token});

        var req = try self.http.request(.POST, uri, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
                .{ .name = "Authorization", .value = auth },
            },
            .headers = .{ .accept_encoding = .{ .override = "identity" } },
        });
        defer req.deinit();

        const mut_body = try self.allocator.dupe(u8, body);
        defer self.allocator.free(mut_body);
        try req.sendBodyComplete(mut_body);

        var redir_buf: [4096]u8 = undefined;
        var response = try req.receiveHead(&redir_buf);

        var resp_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer resp_buf.deinit(self.allocator);
        var reader = response.reader(&.{});
        reader.appendRemaining(self.allocator, &resp_buf, .unlimited) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ReadFailed => return error.HttpError,
            error.StreamTooLong => unreachable,
        };
        return try resp_buf.toOwnedSlice(self.allocator);
    }

    // -- HTTP helper --

    fn httpPost(self: *Scrobbler, url: []const u8, body: []const u8, content_type: []const u8) ![]const u8 {
        const uri = try std.Uri.parse(url);
        var req = try self.http.request(.POST, uri, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = content_type },
            },
            .headers = .{ .accept_encoding = .{ .override = "identity" } },
        });
        defer req.deinit();

        const mut_body = try self.allocator.dupe(u8, body);
        defer self.allocator.free(mut_body);
        try req.sendBodyComplete(mut_body);

        var redir_buf: [4096]u8 = undefined;
        var response = try req.receiveHead(&redir_buf);

        var resp_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer resp_buf.deinit(self.allocator);
        var reader = response.reader(&.{});
        reader.appendRemaining(self.allocator, &resp_buf, .unlimited) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ReadFailed => return error.HttpError,
            error.StreamTooLong => unreachable,
        };
        return try resp_buf.toOwnedSlice(self.allocator);
    }
};

// -- Helpers --

fn jsonEscape(writer: anytype, input: []const u8) !void {
    for (input) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            else => try writer.writeByte(ch),
        }
    }
}

fn urlEncode(writer: anytype, input: []const u8) !void {
    for (input) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            try writer.writeByte(ch);
        } else {
            try writer.print("%{X:0>2}", .{ch});
        }
    }
}

// MD5 - needed for Last.fm API signatures
fn md5(input: []const u8) [16]u8 {
    const s: [64]u5 = .{
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5,  9, 14, 20, 5,  9, 14, 20, 5,  9, 14, 20, 5,  9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    };
    const k: [64]u32 = .{
        0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
        0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
        0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
        0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
        0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
        0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
        0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
        0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
    };

    var a0: u32 = 0x67452301;
    var b0: u32 = 0xefcdab89;
    var c0: u32 = 0x98badcfe;
    var d0: u32 = 0x10325476;

    const msg_len: u64 = input.len;
    // Pad: original + 1 byte (0x80) + zeros + 8 bytes length
    const padded_len = (input.len + 1 + 8 + 63) & ~@as(usize, 63);
    var padded: [1024]u8 = undefined; // enough for typical API sigs
    if (padded_len > padded.len) return .{0} ** 16;
    @memcpy(padded[0..input.len], input);
    padded[input.len] = 0x80;
    @memset(padded[input.len + 1 .. padded_len - 8], 0);
    std.mem.writeInt(u64, padded[padded_len - 8 ..][0..8], msg_len * 8, .little);

    var offset: usize = 0;
    while (offset < padded_len) : (offset += 64) {
        const chunk = padded[offset..][0..64];
        var m: [16]u32 = undefined;
        for (0..16) |j| {
            m[j] = std.mem.readInt(u32, chunk[j * 4 ..][0..4], .little);
        }

        var a = a0;
        var b = b0;
        var c = c0;
        var d = d0;

        for (0..64) |i| {
            var f: u32 = undefined;
            var g: usize = undefined;
            if (i < 16) {
                f = (b & c) | (~b & d);
                g = i;
            } else if (i < 32) {
                f = (d & b) | (~d & c);
                g = (5 * i + 1) % 16;
            } else if (i < 48) {
                f = b ^ c ^ d;
                g = (3 * i + 5) % 16;
            } else {
                f = c ^ (b | ~d);
                g = (7 * i) % 16;
            }

            const temp = d;
            d = c;
            c = b;
            b = b +% std.math.rotl(u32, a +% f +% k[i] +% m[g], @as(u32, s[i]));
            a = temp;
        }

        a0 +%= a;
        b0 +%= b;
        c0 +%= c;
        d0 +%= d;
    }

    var result: [16]u8 = undefined;
    std.mem.writeInt(u32, result[0..4], a0, .little);
    std.mem.writeInt(u32, result[4..8], b0, .little);
    std.mem.writeInt(u32, result[8..12], c0, .little);
    std.mem.writeInt(u32, result[12..16], d0, .little);
    return result;
}
