const std = @import("std");
const c = @import("../c.zig");
const api = @import("../jellyfin/api.zig");
const models = @import("../jellyfin/models.zig");
const helpers = @import("helpers.zig");
const bg = @import("bg.zig");
const artists_mod = @import("artists.zig");
const playback = @import("playback.zig");

const log = std.log.scoped(.search);
const gtk = c.gtk;
const App = @import("window.zig").App;
const g_signal_connect = helpers.g_signal_connect;

pub fn buildSearchPage(self: *App) *gtk.GtkWidget {
    const scroll = gtk.gtk_scrolled_window_new();
    gtk.gtk_widget_set_vexpand(scroll, 1);
    self.search_results_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);
    gtk.gtk_scrolled_window_set_child(@ptrCast(scroll), self.search_results_box);
    return scroll;
}

pub fn runSearch(self: *App, query: []const u8) void {
    if (query.len == 0) return;

    helpers.clearChildren(self.search_results_box, .box);
    self.search_gen += 1;
    const gen = self.search_gen;

    // Local album filter (instant)
    const albums = self.albums orelse null;
    if (albums) |album_list| {
        var count: usize = 0;
        var first_album_idx: ?usize = null;
        for (album_list.items, 0..) |album, i| {
            if (count >= 6) break;
            if (helpers.matchesSearch(album, query)) {
                if (first_album_idx == null) first_album_idx = i;
                count += 1;
            }
        }
        if (count > 0) {
            addSectionTitle(self, "Albums");
            const grid = gtk.gtk_flow_box_new();
            gtk.gtk_flow_box_set_homogeneous(@ptrCast(grid), 0);
            gtk.gtk_flow_box_set_column_spacing(@ptrCast(grid), 4);
            gtk.gtk_flow_box_set_row_spacing(@ptrCast(grid), 4);
            gtk.gtk_flow_box_set_max_children_per_line(@ptrCast(grid), 6);
            gtk.gtk_flow_box_set_min_children_per_line(@ptrCast(grid), 2);
            gtk.gtk_flow_box_set_selection_mode(@ptrCast(grid), gtk.GTK_SELECTION_NONE);

            var added: usize = 0;
            for (album_list.items, 0..) |album, i| {
                if (added >= 6) break;
                if (helpers.matchesSearch(album, query)) {
                    addAlbumCard(self, grid, album, i);
                    added += 1;
                }
            }
            gtk.gtk_box_append(@ptrCast(self.search_results_box), grid);
        }
    }

    // Search artists and tracks in background
    const q = self.allocator.dupe(u8, query) catch return;
    bg.run(self.allocator, self.client, struct {
        app: *App,
        alloc: std.mem.Allocator,
        query: []const u8,
        gen: u32,
        artists: ?models.ItemList = null,
        tracks: ?models.ItemList = null,

        pub fn work(s: *@This(), client: *api.Client) void {
            s.artists = client.searchArtists(s.query, 6) catch null;
            s.tracks = client.searchTracks(s.query, 10) catch null;
        }

        pub fn done(s: *@This()) void {
            defer s.alloc.free(s.query);
            if (s.gen != s.app.search_gen) return;

            if (s.artists) |list| {
                if (list.items.len > 0) {
                    addSectionTitle(s.app, "Artists");
                    for (list.items, 0..) |artist, i| {
                        addArtistRow(s.app, artist, i);
                    }
                }
                s.app.search_artists = list;
            }

            if (s.tracks) |list| {
                if (list.items.len > 0) {
                    addSectionTitle(s.app, "Tracks");
                    for (list.items) |track| {
                        addTrackRow(s.app, track);
                    }
                }
                s.app.search_tracks = list;
            }
        }
    }{ .app = self, .alloc = self.allocator, .query = q, .gen = gen });
}

fn addSectionTitle(self: *App, title: [*:0]const u8) void {
    const label = gtk.gtk_label_new(title);
    gtk.gtk_widget_add_css_class(label, "section-title");
    gtk.gtk_label_set_xalign(@ptrCast(label), 0);
    gtk.gtk_box_append(@ptrCast(self.search_results_box), label);
}

fn addAlbumCard(self: *App, grid: *gtk.GtkWidget, album: models.BaseItem, index: usize) void {
    const card = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(card, "album-card");

    const pic = gtk.gtk_picture_new();
    gtk.gtk_widget_add_css_class(pic, "grid-art");
    gtk.gtk_widget_set_size_request(pic, 120, 120);
    gtk.gtk_picture_set_content_fit(@ptrCast(pic), gtk.GTK_CONTENT_FIT_COVER);
    gtk.gtk_box_append(@ptrCast(card), pic);

    const title = helpers.makeLabel(self.allocator, album.name);
    gtk.gtk_widget_add_css_class(title, "album-title");
    gtk.gtk_label_set_xalign(@ptrCast(title), 0);
    gtk.gtk_label_set_ellipsize(@ptrCast(title), 3);
    gtk.gtk_label_set_max_width_chars(@ptrCast(title), 18);
    gtk.gtk_box_append(@ptrCast(card), title);

    if (album.album_artist) |artist_name| {
        const artist = helpers.makeLabel(self.allocator, artist_name);
        gtk.gtk_widget_add_css_class(artist, "album-artist");
        gtk.gtk_label_set_xalign(@ptrCast(artist), 0);
        gtk.gtk_label_set_ellipsize(@ptrCast(artist), 3);
        gtk.gtk_box_append(@ptrCast(card), artist);
    }

    const button = gtk.gtk_button_new();
    gtk.gtk_widget_add_css_class(button, "flat");
    gtk.gtk_widget_add_css_class(button, "album-card-btn");
    gtk.gtk_widget_set_valign(button, gtk.GTK_ALIGN_START);
    gtk.gtk_button_set_child(@ptrCast(button), card);
    gtk.g_object_set_data(@ptrCast(button), "idx", @ptrFromInt(index + 1));
    _ = g_signal_connect(button, "clicked", &onAlbumClicked, self);

    gtk.gtk_flow_box_append(@ptrCast(grid), button);

    // Load art
    const id_z = std.fmt.allocPrintSentinel(self.allocator, "{s}", .{album.id}, 0) catch return;
    _ = gtk.g_object_ref(pic);
    bg.run(self.allocator, self.client, struct {
        widget: *gtk.GtkWidget,
        id: [:0]u8,
        alloc: std.mem.Allocator,
        data: ?[]const u8 = null,
        pub fn work(s: *@This(), client: *api.Client) void {
            const art = @import("art.zig");
            s.data = art.loadCachedArt(s.alloc, s.id) orelse blk: {
                const url = client.getImageUrl(s.id, 120) catch return;
                defer s.alloc.free(url);
                const d = client.fetchBytes(url) catch return;
                art.saveCachedArt(s.id, d);
                break :blk d;
            };
        }
        pub fn done(s: *@This()) void {
            defer { gtk.g_object_unref(s.widget); s.alloc.free(s.id); }
            const img = s.data orelse return;
            defer s.alloc.free(img);
            const gbytes = gtk.g_bytes_new(img.ptr, img.len);
            defer gtk.g_bytes_unref(gbytes);
            var err: ?*gtk.GError = null;
            const texture = gtk.gdk_texture_new_from_bytes(gbytes, &err);
            if (texture != null) {
                gtk.gtk_picture_set_paintable(@ptrCast(s.widget), @ptrCast(texture));
                gtk.g_object_unref(texture);
            }
        }
    }{ .widget = pic, .id = id_z, .alloc = self.allocator });
}

fn addArtistRow(self: *App, artist: models.BaseItem, index: usize) void {
    const btn = gtk.gtk_button_new();
    gtk.gtk_button_set_has_frame(@ptrCast(btn), 0);
    gtk.gtk_widget_add_css_class(btn, "search-row");

    const row = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_set_margin_start(row, 20);
    gtk.gtk_widget_set_margin_end(row, 20);
    gtk.gtk_widget_set_margin_top(row, 4);
    gtk.gtk_widget_set_margin_bottom(row, 4);

    const icon = gtk.gtk_image_new_from_icon_name("avatar-default-symbolic");
    gtk.gtk_image_set_pixel_size(@ptrCast(icon), 24);
    gtk.gtk_box_append(@ptrCast(row), icon);

    const name = helpers.makeLabel(self.allocator, artist.name);
    gtk.gtk_widget_add_css_class(name, "track-name");
    gtk.gtk_label_set_xalign(@ptrCast(name), 0);
    gtk.gtk_label_set_ellipsize(@ptrCast(name), 3);
    gtk.gtk_widget_set_hexpand(name, 1);
    gtk.gtk_box_append(@ptrCast(row), name);

    const type_label = gtk.gtk_label_new("Artist");
    gtk.gtk_widget_add_css_class(type_label, "track-duration");
    gtk.gtk_box_append(@ptrCast(row), type_label);

    gtk.gtk_button_set_child(@ptrCast(btn), row);
    gtk.g_object_set_data(@ptrCast(btn), "idx", @ptrFromInt(index + 1));
    _ = g_signal_connect(btn, "clicked", &onArtistRowClicked, self);
    gtk.gtk_box_append(@ptrCast(self.search_results_box), btn);
}

fn addTrackRow(self: *App, track: models.BaseItem) void {
    const btn = gtk.gtk_button_new();
    gtk.gtk_button_set_has_frame(@ptrCast(btn), 0);
    gtk.gtk_widget_add_css_class(btn, "search-row");

    const row = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_set_margin_start(row, 20);
    gtk.gtk_widget_set_margin_end(row, 20);
    gtk.gtk_widget_set_margin_top(row, 4);
    gtk.gtk_widget_set_margin_bottom(row, 4);

    const icon = gtk.gtk_image_new_from_icon_name("audio-x-generic-symbolic");
    gtk.gtk_image_set_pixel_size(@ptrCast(icon), 24);
    gtk.gtk_box_append(@ptrCast(row), icon);

    const info = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 1);
    gtk.gtk_widget_set_hexpand(info, 1);

    const name = helpers.makeLabel(self.allocator, track.name);
    gtk.gtk_widget_add_css_class(name, "track-name");
    gtk.gtk_label_set_xalign(@ptrCast(name), 0);
    gtk.gtk_label_set_ellipsize(@ptrCast(name), 3);
    gtk.gtk_box_append(@ptrCast(info), name);

    const artist_text = track.album_artist orelse track.album orelse "";
    if (artist_text.len > 0) {
        const artist = helpers.makeLabel(self.allocator, artist_text);
        gtk.gtk_widget_add_css_class(artist, "track-duration");
        gtk.gtk_label_set_xalign(@ptrCast(artist), 0);
        gtk.gtk_box_append(@ptrCast(info), artist);
    }

    gtk.gtk_box_append(@ptrCast(row), info);

    if (track.durationSeconds()) |dur| {
        var dur_buf: [12]u8 = undefined;
        const total: u32 = @intFromFloat(dur);
        const dur_str = std.fmt.bufPrint(&dur_buf, "{d}:{d:0>2}", .{ total / 60, total % 60 }) catch "?:??";
        dur_buf[dur_str.len] = 0;
        const dur_label = gtk.gtk_label_new(@ptrCast(dur_buf[0..dur_str.len :0].ptr));
        gtk.gtk_widget_add_css_class(dur_label, "track-duration");
        gtk.gtk_box_append(@ptrCast(row), dur_label);
    }

    gtk.gtk_button_set_child(@ptrCast(btn), row);
    // Store track ID for playback
    helpers.setObjString(@ptrCast(btn), "track-id",
        std.fmt.allocPrintSentinel(self.allocator, "{s}", .{track.id}, 0) catch return);
    _ = g_signal_connect(btn, "clicked", &onTrackRowClicked, self);
    gtk.gtk_box_append(@ptrCast(self.search_results_box), btn);
}

fn onAlbumClicked(button: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data));
    const raw = @intFromPtr(gtk.g_object_get_data(@ptrCast(button), "idx"));
    if (raw == 0) return;
    self.showAlbumDetail(raw - 1);
}

fn onArtistRowClicked(button: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data));
    const raw = @intFromPtr(gtk.g_object_get_data(@ptrCast(button), "idx"));
    if (raw == 0) return;
    const idx = raw - 1;
    const list = self.search_artists orelse return;
    if (idx >= list.items.len) return;
    artists_mod.showArtistDetail(self, list.items[idx]);
}

fn onTrackRowClicked(button: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data));
    const tracks = self.search_tracks orelse return;

    // Find the track by matching button position in the results
    const raw_id = gtk.g_object_get_data(@ptrCast(button), "track-id");
    if (raw_id == null) return;
    const track_id = std.mem.span(@as([*:0]const u8, @ptrCast(raw_id)));

    for (tracks.items, 0..) |track, i| {
        if (std.mem.eql(u8, track.id, track_id)) {
            // Play this track, queue the search results
            playback.setQueue(self, tracks.items, i);
            playback.playTrack(self, i);
            return;
        }
    }
}
