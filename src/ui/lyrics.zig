const std = @import("std");
const c = @import("../c.zig");
const helpers = @import("helpers.zig");
const bg = @import("bg.zig");
const api = @import("../jellyfin/api.zig");

const log = std.log.scoped(.lyrics);
const gtk = c.gtk;
const App = @import("window.zig").App;
const g_signal_connect = helpers.g_signal_connect;

pub const LyricLine = struct {
    t: f64,
    text: []const u8,
};

pub fn buildLyricsPanel(self: *App) void {
    self.lyrics_revealer = gtk.gtk_revealer_new();
    gtk.gtk_revealer_set_transition_type(@ptrCast(self.lyrics_revealer), gtk.GTK_REVEALER_TRANSITION_TYPE_SLIDE_RIGHT);
    gtk.gtk_revealer_set_transition_duration(@ptrCast(self.lyrics_revealer), 200);
    gtk.gtk_revealer_set_reveal_child(@ptrCast(self.lyrics_revealer), 0);
    gtk.gtk_widget_set_halign(self.lyrics_revealer, gtk.GTK_ALIGN_START);
    gtk.gtk_widget_set_valign(self.lyrics_revealer, gtk.GTK_ALIGN_FILL);

    const panel = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(panel, "lyrics-panel");
    gtk.gtk_widget_set_size_request(panel, 340, -1);

    const header = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_set_margin_start(header, 16);
    gtk.gtk_widget_set_margin_end(header, 16);
    gtk.gtk_widget_set_margin_top(header, 12);
    gtk.gtk_widget_set_margin_bottom(header, 8);

    const title = gtk.gtk_label_new("Lyrics");
    gtk.gtk_widget_add_css_class(title, "queue-title");
    gtk.gtk_label_set_xalign(@ptrCast(title), 0);
    gtk.gtk_widget_set_hexpand(title, 1);
    gtk.gtk_box_append(@ptrCast(header), title);
    gtk.gtk_box_append(@ptrCast(panel), header);

    self.lyrics_scroll = gtk.gtk_scrolled_window_new();
    gtk.gtk_widget_set_vexpand(self.lyrics_scroll, 1);
    self.lyrics_list = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(self.lyrics_list, "lyrics-list");
    gtk.gtk_scrolled_window_set_child(@ptrCast(self.lyrics_scroll), self.lyrics_list);
    gtk.gtk_box_append(@ptrCast(panel), self.lyrics_scroll);

    gtk.gtk_revealer_set_child(@ptrCast(self.lyrics_revealer), panel);
}

pub fn onToggleLyrics(_: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data));
    const revealed = gtk.gtk_revealer_get_reveal_child(@ptrCast(self.lyrics_revealer));
    gtk.gtk_revealer_set_reveal_child(@ptrCast(self.lyrics_revealer), if (revealed != 0) 0 else 1);
}

pub fn fetchLyrics(self: *App, track_name: []const u8, artist_name: []const u8, duration: f64) void {
    // Clear current lyrics
    self.freeLyrics();
    helpers.clearChildren(self.lyrics_list, .box);

    const status = gtk.gtk_label_new("Loading lyrics...");
    gtk.gtk_widget_add_css_class(status, "lyrics-line");
    gtk.gtk_box_append(@ptrCast(self.lyrics_list), status);

    const Ctx = struct {
        app: *App,
        alloc: std.mem.Allocator,
        track: []const u8,
        artist: []const u8,
        duration: f64,
        result: ?[]u8 = null,

        pub fn work(s: *@This(), _: *api.Client) void {
            log.info("fetching lyrics for '{s}' - '{s}'", .{ s.artist, s.track });
            s.result = lrclibFetch(s.alloc, s.artist, s.track, s.duration);
            if (s.result) |r| {
                log.info("got {d} bytes of lyrics", .{r.len});
            } else {
                log.warn("no lyrics found", .{});
            }
        }

        pub fn done(s: *@This()) void {
            defer s.alloc.free(s.track);
            defer s.alloc.free(s.artist);

            if (s.result) |lrc_data| {
                const lines = parseLrc(s.alloc, lrc_data) catch {
                    s.alloc.free(lrc_data);
                    showNoLyrics(s.app);
                    return;
                };
                s.alloc.free(lrc_data);
                s.app.lyrics_lines = lines;
                s.app.lyrics_current_idx = null;
                rebuildLyricsList(s.app);
                log.info("loaded {d} lyric lines", .{lines.len});
            } else {
                showNoLyrics(s.app);
            }
        }
    };

    const track_copy = self.allocator.dupe(u8, track_name) catch return;
    const artist_copy = self.allocator.dupe(u8, artist_name) catch {
        self.allocator.free(track_copy);
        return;
    };
    bg.run(self.allocator, self.client, Ctx{
        .app = self,
        .alloc = self.allocator,
        .track = track_copy,
        .artist = artist_copy,
        .duration = duration,
    });
}

fn showNoLyrics(self: *App) void {
    helpers.clearChildren(self.lyrics_list, .box);
    const label = gtk.gtk_label_new("No lyrics found");
    gtk.gtk_widget_add_css_class(label, "lyrics-line");
    gtk.gtk_widget_set_margin_top(label, 20);
    gtk.gtk_box_append(@ptrCast(self.lyrics_list), label);
}

fn rebuildLyricsList(self: *App) void {
    helpers.clearChildren(self.lyrics_list, .box);
    const lines = self.lyrics_lines orelse return;

    for (lines) |line| {
        if (line.text.len == 0) {
            const spacer = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 0);
            gtk.gtk_widget_set_size_request(spacer, -1, 12);
            gtk.gtk_box_append(@ptrCast(self.lyrics_list), spacer);
            continue;
        }
        const btn = gtk.gtk_button_new();
        gtk.gtk_button_set_has_frame(@ptrCast(btn), 0);
        gtk.gtk_widget_add_css_class(btn, "lyrics-line");

        const label = helpers.makeLabel(self.allocator, line.text);
        gtk.gtk_label_set_xalign(@ptrCast(label), 0);
        gtk.gtk_label_set_wrap(@ptrCast(label), 1);
        gtk.gtk_label_set_wrap_mode(@ptrCast(label), 1);
        gtk.gtk_button_set_child(@ptrCast(btn), label);

        // Store timestamp as integer millis in object data
        const ms: usize = @intFromFloat(line.t * 1000);
        gtk.g_object_set_data(@ptrCast(btn), "ts", @ptrFromInt(ms + 1));
        _ = g_signal_connect(btn, "clicked", &onLyricClicked, self);

        gtk.gtk_box_append(@ptrCast(self.lyrics_list), btn);
    }
}

fn onLyricClicked(btn: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data));
    const raw = @intFromPtr(gtk.g_object_get_data(@ptrCast(btn), "ts"));
    if (raw == 0) return;
    const ms = raw - 1;
    const secs_f: f64 = @as(f64, @floatFromInt(ms)) / 1000.0;

    if (self.sonos_active) |idx| {
        const secs: u32 = @intFromFloat(secs_f);
        if (self.sonos_client) |sc| sc.seek(self.sonos_speakers[idx].ip(), secs) catch {};
        self.sonos_position_secs = secs;
        self.sonos_sub_secs = 0;
    } else if (self.player) |p| {
        const len = p.getLengthSeconds();
        if (len > 0) p.seek(secs_f / @as(f64, len));
    }
}

// Called from progress timer to highlight current line
pub fn updateLyricsHighlight(self: *App, position_secs: f32) void {
    const lines = self.lyrics_lines orelse return;
    if (lines.len == 0) return;

    // Binary search for current line
    const pos: f64 = @floatCast(position_secs);
    var lo: usize = 0;
    var hi: usize = lines.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (lines[mid].t <= pos) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    const idx = if (lo > 0) lo - 1 else 0;

    if (self.lyrics_current_idx != null and self.lyrics_current_idx.? == idx) return;

    // Remove old highlight
    if (self.lyrics_current_idx) |old| {
        const old_child = getNthChild(self.lyrics_list, old);
        if (old_child != null) gtk.gtk_widget_remove_css_class(old_child, "lyrics-active");
    }

    // Add new highlight
    const new_child = getNthChild(self.lyrics_list, idx);
    if (new_child != null) {
        gtk.gtk_widget_add_css_class(new_child, "lyrics-active");

        // Scroll to keep current line centered in the panel
        const adj = gtk.gtk_scrolled_window_get_vadjustment(@ptrCast(self.lyrics_scroll));
        if (adj != null) {
            // Compute y offset by summing heights of preceding children
            var y: f64 = 0;
            var child = gtk.gtk_widget_get_first_child(self.lyrics_list);
            while (child != null and child != new_child) : (child = gtk.gtk_widget_get_next_sibling(child)) {
                y += @floatFromInt(gtk.gtk_widget_get_height(child));
            }
            const panel_h: f64 = @floatFromInt(gtk.gtk_widget_get_height(self.lyrics_scroll));
            const target = y - panel_h / 3;
            gtk.gtk_adjustment_set_value(adj, @max(0, target));
        }
    }

    self.lyrics_current_idx = idx;
}

fn getNthChild(container: *gtk.GtkWidget, n: usize) ?*gtk.GtkWidget {
    var child = gtk.gtk_widget_get_first_child(container);
    var i: usize = 0;
    while (child != null) : ({
        child = gtk.gtk_widget_get_next_sibling(child);
        i += 1;
    }) {
        if (i == n) return child;
    }
    return null;
}

// -- lrclib.net fetch --

fn lrclibFetch(allocator: std.mem.Allocator, artist: []const u8, track: []const u8, duration: f64) ?[]u8 {
    var http = std.http.Client{ .allocator = allocator };
    defer http.deinit();

    // URL-encode params
    const artist_enc = urlEncode(allocator, artist) catch return null;
    defer allocator.free(artist_enc);
    const track_enc = urlEncode(allocator, track) catch return null;
    defer allocator.free(track_enc);

    // Try direct get first
    const url_get = std.fmt.allocPrint(allocator, "https://lrclib.net/api/get?artist_name={s}&track_name={s}", .{ artist_enc, track_enc }) catch return null;
    defer allocator.free(url_get);

    if (httpGet(allocator, &http, url_get)) |body| {
        defer allocator.free(body);
        if (extractLrcFromJson(allocator, body)) |lrc| return lrc;
    }

    // Fallback to search
    const url_search = std.fmt.allocPrint(allocator, "https://lrclib.net/api/search?track_name={s}&artist_name={s}", .{ track_enc, artist_enc }) catch return null;
    defer allocator.free(url_search);

    if (httpGet(allocator, &http, url_search)) |body| {
        defer allocator.free(body);
        if (extractBestFromSearch(allocator, body, artist, track, duration)) |lrc| return lrc;
    }

    return null;
}

fn extractLrcFromJson(allocator: std.mem.Allocator, body: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();
    switch (parsed.value) {
        .object => |obj| {
            // Prefer synced lyrics
            if (obj.get("syncedLyrics")) |v| {
                switch (v) {
                    .string => |s| return allocator.dupe(u8, s) catch null,
                    else => {},
                }
            }
            if (obj.get("plainLyrics")) |v| {
                switch (v) {
                    .string => |s| return allocator.dupe(u8, s) catch null,
                    else => {},
                }
            }
        },
        else => {},
    }
    return null;
}

fn extractBestFromSearch(allocator: std.mem.Allocator, body: []const u8, artist: []const u8, track: []const u8, duration: f64) ?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();
    switch (parsed.value) {
        .array => |arr| {
            var best_score: f64 = -1e9;
            var best_lrc: ?[]const u8 = null;
            var best_synced = false;

            for (arr.items) |item| {
                const obj = switch (item) {
                    .object => |o| o,
                    else => continue,
                };

                var lrc: ?[]const u8 = null;
                var is_synced = false;
                if (obj.get("syncedLyrics")) |v| switch (v) {
                    .string => |s| {
                        lrc = s;
                        is_synced = true;
                    },
                    else => {},
                };
                if (lrc == null) if (obj.get("plainLyrics")) |v| switch (v) {
                    .string => |s| lrc = s,
                    else => {},
                };
                if (lrc == null) continue;

                var score: f64 = 0;
                if (obj.get("duration")) |dp| switch (dp) {
                    .float => |f| score -= @abs(f - duration),
                    .integer => |i| score -= @abs(@as(f64, @floatFromInt(i)) - duration),
                    else => {},
                };
                if (obj.get("artistName")) |ap| switch (ap) {
                    .string => |s| if (std.ascii.eqlIgnoreCase(s, artist)) {
                        score += 5;
                    },
                    else => {},
                };
                if (obj.get("trackName")) |tp| switch (tp) {
                    .string => |s| if (std.ascii.eqlIgnoreCase(s, track)) {
                        score += 5;
                    },
                    else => {},
                };

                if (best_lrc == null or (is_synced and !best_synced) or (is_synced == best_synced and score > best_score)) {
                    best_score = score;
                    best_lrc = lrc;
                    best_synced = is_synced;
                }
            }

            if (best_lrc) |l| return allocator.dupe(u8, l) catch null;
        },
        else => {},
    }
    return null;
}

fn httpGet(allocator: std.mem.Allocator, http: *std.http.Client, url: []const u8) ?[]u8 {
    const uri = std.Uri.parse(url) catch return null;
    var req = http.request(.GET, uri, .{
        .extra_headers = &.{
            .{ .name = "User-Agent", .value = "jmusic/1.0" },
        },
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
    }) catch return null;
    defer req.deinit();
    req.sendBodiless() catch return null;

    var redir_buf: [4096]u8 = undefined;
    var response = req.receiveHead(&redir_buf) catch return null;
    if (response.head.status != .ok) return null;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    var reader = response.reader(&.{});
    reader.appendRemaining(allocator, &buf, .unlimited) catch return null;
    return buf.toOwnedSlice(allocator) catch null;
}

// -- LRC parser --

pub fn parseLrc(allocator: std.mem.Allocator, text: []const u8) ![]LyricLine {
    var lines = std.ArrayListUnmanaged(LyricLine).empty;

    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r");
        if (line.len == 0) continue;

        var start: usize = 0;
        var times = std.ArrayListUnmanaged(f64).empty;
        defer times.deinit(allocator);

        // Extract all [mm:ss.xx] timestamps
        while (start < line.len) {
            const lb = std.mem.indexOfScalarPos(u8, line, start, '[') orelse break;
            const rb = std.mem.indexOfScalarPos(u8, line, lb, ']') orelse break;
            const tag = line[lb + 1 .. rb];

            if (std.mem.indexOfScalar(u8, tag, ':')) |colon| {
                const mm = std.fmt.parseUnsigned(u64, tag[0..colon], 10) catch {
                    start = rb + 1;
                    continue;
                };
                const rest = tag[colon + 1 ..];
                var ss: u64 = 0;
                var cs: u64 = 0;
                if (std.mem.indexOfScalar(u8, rest, '.')) |di| {
                    ss = std.fmt.parseUnsigned(u64, rest[0..di], 10) catch 0;
                    cs = std.fmt.parseUnsigned(u64, rest[di + 1 ..], 10) catch 0;
                } else {
                    ss = std.fmt.parseUnsigned(u64, rest, 10) catch 0;
                }
                const t: f64 = @as(f64, @floatFromInt(mm * 60 + ss)) + @as(f64, @floatFromInt(cs)) / 100.0;
                try times.append(allocator, t);
            }
            start = rb + 1;
        }

        const last_rb = std.mem.lastIndexOfScalar(u8, line, ']') orelse 0;
        const text_start = if (last_rb > 0) last_rb + 1 else 0;
        const lyric = std.mem.trim(u8, line[text_start..], " ");

        if (times.items.len == 0 and lyric.len > 0) {
            try lines.append(allocator, .{ .t = 0, .text = try allocator.dupe(u8, lyric) });
        } else {
            for (times.items) |t| {
                try lines.append(allocator, .{ .t = t, .text = try allocator.dupe(u8, lyric) });
            }
        }
    }

    // Sort by timestamp
    std.sort.block(LyricLine, lines.items, {}, struct {
        fn lessThan(_: void, a: LyricLine, b: LyricLine) bool {
            return a.t < b.t;
        }
    }.lessThan);

    return try lines.toOwnedSlice(allocator);
}

fn urlEncode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    for (input) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            try out.append(allocator, ch);
        } else {
            try out.append(allocator, '%');
            const hex = "0123456789ABCDEF";
            try out.append(allocator, hex[ch >> 4]);
            try out.append(allocator, hex[ch & 0xf]);
        }
    }
    return try out.toOwnedSlice(allocator);
}
