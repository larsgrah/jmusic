const std = @import("std");
const c = @import("../c.zig");
const api = @import("../jellyfin/api.zig");
const models = @import("../jellyfin/models.zig");
const bg = @import("bg.zig");
const helpers = @import("helpers.zig");
const art_mod = @import("art.zig");
const artists_mod = @import("artists.zig");

const log = std.log.scoped(.detail);
const gtk = c.gtk;
const App = @import("window.zig").App;

const g_signal_connect = helpers.g_signal_connect;
const makeLabel = helpers.makeLabel;
const setObjString = helpers.setObjString;
const setLabelText = helpers.setLabelText;
const clearChildren = helpers.clearChildren;
const loadCachedArt = art_mod.loadCachedArt;
const saveCachedArt = art_mod.saveCachedArt;
const applyTexture = art_mod.applyTexture;

pub fn buildDetailPage(self: *App) *gtk.GtkWidget {
    const page = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_set_hexpand(page, 1);

    const header = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 24);
    gtk.gtk_widget_add_css_class(header, "detail-header");

    self.detail_art = gtk.gtk_picture_new();
    gtk.gtk_widget_set_size_request(self.detail_art, 220, 220);
    gtk.gtk_widget_add_css_class(self.detail_art, "detail-art");
    gtk.gtk_box_append(@ptrCast(header), self.detail_art);

    const info = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 4);
    gtk.gtk_widget_set_valign(info, gtk.GTK_ALIGN_END);
    gtk.gtk_widget_set_hexpand(info, 1);

    self.detail_type_label = gtk.gtk_label_new("ALBUM");
    gtk.gtk_widget_add_css_class(self.detail_type_label, "type-label");
    gtk.gtk_label_set_xalign(@ptrCast(self.detail_type_label), 0);
    gtk.gtk_box_append(@ptrCast(info), self.detail_type_label);

    self.detail_title = gtk.gtk_label_new("");
    gtk.gtk_widget_add_css_class(self.detail_title, "detail-title");
    gtk.gtk_label_set_xalign(@ptrCast(self.detail_title), 0);
    gtk.gtk_label_set_ellipsize(@ptrCast(self.detail_title), 3);
    gtk.gtk_label_set_max_width_chars(@ptrCast(self.detail_title), 40);
    gtk.gtk_box_append(@ptrCast(info), self.detail_title);

    const artist_btn = gtk.gtk_button_new();
    gtk.gtk_button_set_has_frame(@ptrCast(artist_btn), 0);
    gtk.gtk_widget_add_css_class(artist_btn, "detail-artist-btn");
    gtk.gtk_widget_set_halign(artist_btn, gtk.GTK_ALIGN_START);
    self.detail_artist = gtk.gtk_label_new("");
    gtk.gtk_widget_add_css_class(self.detail_artist, "detail-artist");
    gtk.gtk_label_set_xalign(@ptrCast(self.detail_artist), 0);
    gtk.gtk_button_set_child(@ptrCast(artist_btn), self.detail_artist);
    _ = g_signal_connect(artist_btn, "clicked", &onArtistNameClicked, self);
    gtk.gtk_box_append(@ptrCast(info), artist_btn);

    const spacer = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_set_size_request(spacer, -1, 12);
    gtk.gtk_box_append(@ptrCast(info), spacer);

    const play_all = gtk.gtk_button_new_with_label("Play");
    gtk.gtk_widget_add_css_class(play_all, "play-all-btn");
    gtk.gtk_widget_set_halign(play_all, gtk.GTK_ALIGN_START);
    _ = g_signal_connect(play_all, "clicked", &onPlayAll, self);
    gtk.gtk_box_append(@ptrCast(info), play_all);

    gtk.gtk_box_append(@ptrCast(header), info);
    gtk.gtk_box_append(@ptrCast(page), header);

    const track_scroll = gtk.gtk_scrolled_window_new();
    gtk.gtk_widget_set_vexpand(track_scroll, 1);
    gtk.gtk_widget_set_hexpand(track_scroll, 1);

    const track_container = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_set_hexpand(track_container, 1);

    self.track_list_box = gtk.gtk_list_box_new();
    gtk.gtk_widget_add_css_class(self.track_list_box, "track-list");
    gtk.gtk_list_box_set_selection_mode(@ptrCast(self.track_list_box), gtk.GTK_SELECTION_SINGLE);
    _ = g_signal_connect(self.track_list_box, "row-activated", &onTrackActivated, self);
    gtk.gtk_box_append(@ptrCast(track_container), self.track_list_box);

    self.suggestions_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_set_visible(self.suggestions_box, 0);
    gtk.gtk_box_append(@ptrCast(track_container), self.suggestions_box);

    gtk.gtk_scrolled_window_set_child(@ptrCast(track_scroll), track_container);
    gtk.gtk_box_append(@ptrCast(page), track_scroll);

    return page;
}

pub fn showAlbumDetail(self: *App, album_index: usize) void {
    const albums = self.albums orelse return;
    if (album_index >= albums.items.len) return;
    const album = albums.items[album_index];
    self.current_album_idx = album_index;
    self.current_playlist_idx = null;
    self.current_playlist_id = null;
    gtk.gtk_widget_set_visible(self.suggestions_box, 0);

    self.detail_load_gen += 1;
    setLabelText(self.detail_type_label, "ALBUM");
    setLabelText(self.detail_title, album.name);
    setLabelText(self.detail_artist, album.album_artist orelse "Unknown Artist");
    self.artist_albums = null;
    self.current_artist = null;
    gtk.gtk_picture_set_paintable(@ptrCast(self.detail_art), null);
    clearChildren(self.track_list_box, .listbox);
    self.navigateTo("detail");

    loadArtAsync(self, album.id, self.detail_art, 300);

    self.album_track_cache_mutex.lock();
    const cached = self.album_track_cache.get(album.id);
    self.album_track_cache_mutex.unlock();

    if (cached) |tracks| {
        self.tracks = tracks;
        for (tracks.items) |track| {
            addTrackRow(self, track);
        }
        self.highlightCurrentTrack();
    } else {
        loadDetailAsync(self, album.id, false);
    }
}

pub fn showAlbumById(self: *App, album_id: []const u8) void {
    self.detail_load_gen += 1;
    setLabelText(self.detail_type_label, "ALBUM");
    setLabelText(self.detail_title, "");
    setLabelText(self.detail_artist, "");
    self.artist_albums = null;
    // Keep current_artist so back button can restore artist detail
    gtk.gtk_picture_set_paintable(@ptrCast(self.detail_art), null);
    self.current_album_idx = null;
    self.current_playlist_idx = null;
    self.current_playlist_id = null;
    gtk.gtk_widget_set_visible(self.suggestions_box, 0);
    clearChildren(self.track_list_box, .listbox);
    self.navigateTo("detail");

    loadArtAsync(self, album_id, self.detail_art, 300);

    self.album_track_cache_mutex.lock();
    const cached = self.album_track_cache.get(album_id);
    self.album_track_cache_mutex.unlock();

    if (cached) |tracks| {
        self.tracks = tracks;
        if (tracks.items.len > 0) {
            setLabelText(self.detail_title, tracks.items[0].album orelse "Unknown");
            setLabelText(self.detail_artist, tracks.items[0].album_artist orelse "");
        }
        for (tracks.items) |track| {
            addTrackRow(self, track);
        }
        self.highlightCurrentTrack();
    } else {
        loadDetailAsync(self, album_id, false);
    }
}

pub fn openPlaylistById(self: *App, pl_id: []const u8) void {
    var name: []const u8 = "Playlist";
    if (self.playlists) |pls| {
        for (pls.items) |item| {
            if (std.mem.eql(u8, item.id, pl_id)) {
                name = item.name;
                break;
            }
        }
    }

    setLabelText(self.detail_title, name);
    setLabelText(self.detail_artist, "Playlist");
    gtk.gtk_picture_set_paintable(@ptrCast(self.detail_art), null);
    self.current_playlist_id = pl_id;
    clearChildren(self.track_list_box, .listbox);
    gtk.gtk_widget_set_visible(self.suggestions_box, 0);
    self.navigateTo("detail");

    self.playlist_cache_mutex.lock();
    const cached_opt = self.playlist_cache.get(pl_id);
    self.playlist_cache_mutex.unlock();
    if (cached_opt) |cached| {
        self.tracks = cached;
        for (cached.items) |track| {
            addTrackRow(self, track);
        }
        self.highlightCurrentTrack();
        loadSuggestionsAsync(self, pl_id);
        return;
    }

    loadDetailAsync(self, pl_id, true);
}

pub fn addTrackRow(self: *App, track: models.BaseItem) void {
    addTrackRowInner(self, track, self.current_playlist_id != null);
}

fn addTrackRowInner(self: *App, track: models.BaseItem, is_playlist: bool) void {
    const row_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(row_box, "track-row");

    if (track.index_number) |num| {
        var buf: [8]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{num}) catch "?";
        buf[s.len] = 0;
        const lbl = gtk.gtk_label_new(@ptrCast(s.ptr));
        gtk.gtk_widget_add_css_class(lbl, "track-number");
        gtk.gtk_label_set_xalign(@ptrCast(lbl), 1);
        gtk.gtk_widget_set_size_request(lbl, 28, -1);
        gtk.gtk_box_append(@ptrCast(row_box), lbl);
    }

    const title = makeLabel(self.allocator, track.name);
    gtk.gtk_widget_add_css_class(title, "track-name");
    gtk.gtk_label_set_xalign(@ptrCast(title), 0);
    gtk.gtk_label_set_ellipsize(@ptrCast(title), 3);
    gtk.gtk_widget_set_hexpand(title, 1);
    gtk.gtk_box_append(@ptrCast(row_box), title);

    if (track.durationSeconds()) |dur| {
        const mins = @as(u32, @intFromFloat(dur)) / 60;
        const secs = @as(u32, @intFromFloat(dur)) % 60;
        var buf: [12]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}:{d:0>2}", .{ mins, secs }) catch "?:??";
        buf[s.len] = 0;
        const lbl = gtk.gtk_label_new(@ptrCast(s.ptr));
        gtk.gtk_widget_add_css_class(lbl, "track-duration");
        gtk.gtk_box_append(@ptrCast(row_box), lbl);
    }

    const pn_btn = gtk.gtk_button_new_from_icon_name("media-playlist-consecutive-symbolic");
    gtk.gtk_widget_add_css_class(pn_btn, "play-next-btn");
    gtk.gtk_button_set_has_frame(@ptrCast(pn_btn), 0);
    gtk.gtk_widget_set_tooltip_text(pn_btn, "Play next");
    _ = g_signal_connect(pn_btn, "clicked", &onPlayNextClicked, self);
    gtk.gtk_box_append(@ptrCast(row_box), pn_btn);

    if (is_playlist) {
        const up_btn = gtk.gtk_button_new_from_icon_name("go-up-symbolic");
        gtk.gtk_widget_add_css_class(up_btn, "reorder-btn");
        gtk.gtk_button_set_has_frame(@ptrCast(up_btn), 0);
        _ = g_signal_connect(up_btn, "clicked", &onMoveTrackUp, self);
        gtk.gtk_box_append(@ptrCast(row_box), up_btn);

        const down_btn = gtk.gtk_button_new_from_icon_name("go-down-symbolic");
        gtk.gtk_widget_add_css_class(down_btn, "reorder-btn");
        gtk.gtk_button_set_has_frame(@ptrCast(down_btn), 0);
        _ = g_signal_connect(down_btn, "clicked", &onMoveTrackDown, self);
        gtk.gtk_box_append(@ptrCast(row_box), down_btn);

        const rm_btn = gtk.gtk_button_new_from_icon_name("edit-delete-symbolic");
        gtk.gtk_widget_add_css_class(rm_btn, "remove-btn");
        gtk.gtk_button_set_has_frame(@ptrCast(rm_btn), 0);
        const tid_z = std.fmt.allocPrintSentinel(self.allocator, "{s}", .{track.id}, 0) catch null;
        if (tid_z) |z| setObjString(@ptrCast(rm_btn), "track-id", z);
        _ = g_signal_connect(rm_btn, "clicked", &onRemoveTrack, self);
        gtk.gtk_box_append(@ptrCast(row_box), rm_btn);
    }

    gtk.gtk_list_box_append(@ptrCast(self.track_list_box), row_box);
}

const PlAction = enum { move, remove, add };

pub fn doPlaylistAction(self: *App, pl_id: []const u8, item_id: []const u8, new_index: u32, action: PlAction) void {
    const pl_z = std.fmt.allocPrintSentinel(self.allocator, "{s}", .{pl_id}, 0) catch return;
    const item_z = std.fmt.allocPrintSentinel(self.allocator, "{s}", .{item_id}, 0) catch return;
    bg.run(self.allocator, self.client, struct {
        app: *App,
        pl_id: [:0]u8,
        item_id: [:0]u8,
        new_index: u32,
        action: PlAction,
        alloc: std.mem.Allocator,
        ok: bool = true,

        pub fn work(s: *@This(), client: *api.Client) void {
            switch (s.action) {
                .move => client.movePlaylistItem(s.pl_id, s.item_id, s.new_index) catch { s.ok = false; },
                .remove => client.removeFromPlaylist(s.pl_id, &.{s.item_id}) catch { s.ok = false; },
                .add => client.addToPlaylist(s.pl_id, &.{s.item_id}) catch { s.ok = false; },
            }
        }

        pub fn done(s: *@This()) void {
            defer s.alloc.free(s.pl_id);
            defer s.alloc.free(s.item_id);
            if (!s.ok) {
                setLabelText(s.app.np_title, "Playlist update failed");
                return;
            }
            refreshPlaylist(s.app);
        }
    }{ .app = self, .pl_id = pl_z, .item_id = item_z, .new_index = new_index, .action = action, .alloc = self.allocator });
}

pub fn refreshPlaylist(self: *App) void {
    const pl_id = self.current_playlist_id orelse return;
    loadDetailAsync(self, pl_id, true);
}

pub fn loadArtAsync(self: *App, item_id: []const u8, target: *gtk.GtkWidget, size: u32) void {
    const id_z = std.fmt.allocPrintSentinel(self.allocator, "{s}", .{item_id}, 0) catch return;
    _ = gtk.g_object_ref(target);
    bg.run(self.allocator, self.client, struct {
        widget: *gtk.GtkWidget,
        id: [:0]u8,
        size: u32,
        alloc: std.mem.Allocator,
        data: ?[]const u8 = null,

        pub fn work(s: *@This(), client: *api.Client) void {
            s.data = loadCachedArt(s.alloc, s.id) orelse blk: {
                const url = client.getImageUrl(s.id, s.size) catch return;
                defer s.alloc.free(url);
                const d = client.fetchBytes(url) catch return;
                saveCachedArt(s.id, d);
                break :blk d;
            };
        }

        pub fn done(s: *@This()) void {
            defer s.alloc.free(s.id);
            defer gtk.g_object_unref(s.widget);
            if (s.data) |d| {
                defer s.alloc.free(d);
                applyTexture(s.widget, d);
            }
        }
    }{ .widget = target, .id = id_z, .size = size, .alloc = self.allocator });
}

pub fn loadDetailAsync(self: *App, id: []const u8, is_playlist: bool) void {
    const Ctx = struct {
        app: *App,
        id: []const u8,
        is_playlist: bool,
        gen: u32,
        base_url: []const u8,
        token: ?[]const u8,
        user_id: ?[]const u8,
        username: ?[]const u8,
        password: ?[]const u8,
        alloc: std.mem.Allocator,
    };
    const ctx = self.allocator.create(Ctx) catch return;
    ctx.* = .{
        .app = self, .id = id, .is_playlist = is_playlist,
        .gen = self.detail_load_gen,
        .base_url = self.client.base_url, .token = self.client.token,
        .user_id = self.client.user_id, .username = self.client.username,
        .password = self.client.password, .alloc = self.allocator,
    };
    const thread = std.Thread.spawn(.{}, detailLoadThread, .{ctx}) catch {
        self.allocator.destroy(ctx);
        return;
    };
    thread.detach();
}

fn detailLoadThread(ctx: anytype) void {
    defer ctx.alloc.destroy(ctx);

    var client = api.Client.init(ctx.alloc, ctx.base_url);
    defer client.deinit();
    client.token = ctx.token;
    client.user_id = ctx.user_id;
    client.username = ctx.username;
    client.password = ctx.password;

    const tracks = if (ctx.is_playlist)
        client.getPlaylistTracks(ctx.id)
    else
        client.getAlbumTracks(ctx.id);

    const result = tracks catch return;

    const Cb = struct {
        app: *App,
        tracks: models.ItemList,
        id: []const u8,
        is_playlist: bool,
        gen: u32,
        alloc: std.mem.Allocator,

        fn apply(data: ?*anyopaque) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(data));
            defer self.alloc.destroy(self);

            // Stale response - user already navigated elsewhere
            if (!self.is_playlist and self.gen != self.app.detail_load_gen) return 0;

            if (self.is_playlist) {
                if (self.app.current_playlist_id == null) return 0;
                if (!std.mem.eql(u8, self.app.current_playlist_id.?, self.id)) return 0;
            }

            if (self.is_playlist) {
                self.app.playlist_cache_mutex.lock();
                self.app.playlist_cache.put(self.id, self.tracks) catch {};
                self.app.playlist_cache_mutex.unlock();
            } else {
                self.app.album_track_cache_mutex.lock();
                self.app.album_track_cache.put(self.id, self.tracks) catch {};
                self.app.album_track_cache_mutex.unlock();
            }

            self.app.tracks = self.tracks;
            clearChildren(self.app.track_list_box, .listbox);
            for (self.tracks.items) |track| {
                addTrackRow(self.app, track);
            }
            self.app.highlightCurrentTrack();

            if (self.is_playlist) {
                loadSuggestionsAsync(self.app, self.id);
            }
            return 0;
        }
    };

    const cb = ctx.alloc.create(Cb) catch return;
    cb.* = .{ .app = ctx.app, .tracks = result, .id = ctx.id, .is_playlist = ctx.is_playlist, .gen = ctx.gen, .alloc = ctx.alloc };
    _ = gtk.g_idle_add(&Cb.apply, cb);
}

pub fn loadSuggestionsAsync(self: *App, playlist_id: []const u8) void {
    const Ctx = struct {
        app: *App, pl_id: []const u8, base_url: []const u8,
        token: ?[]const u8, user_id: ?[]const u8,
        username: ?[]const u8, password: ?[]const u8,
        alloc: std.mem.Allocator,
    };
    const ctx = self.allocator.create(Ctx) catch return;
    ctx.* = .{
        .app = self, .pl_id = playlist_id,
        .base_url = self.client.base_url, .token = self.client.token,
        .user_id = self.client.user_id, .username = self.client.username,
        .password = self.client.password, .alloc = self.allocator,
    };
    const thread = std.Thread.spawn(.{}, suggestionsThread, .{ctx}) catch {
        self.allocator.destroy(ctx);
        return;
    };
    thread.detach();
}

fn suggestionsThread(ctx: anytype) void {
    defer ctx.alloc.destroy(ctx);

    var client = api.Client.init(ctx.alloc, ctx.base_url);
    defer client.deinit();
    client.token = ctx.token;
    client.user_id = ctx.user_id;
    client.username = ctx.username;
    client.password = ctx.password;

    const mix = client.getInstantMix(ctx.pl_id, 10) catch return;

    const Cb = struct {
        app: *App, mix: models.ItemList, pl_id: []const u8, alloc: std.mem.Allocator,

        fn apply(data: ?*anyopaque) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(data));
            defer self.alloc.destroy(self);
            if (self.app.current_playlist_id) |current| {
                if (std.mem.eql(u8, current, self.pl_id)) {
                    buildSuggestionsUI(self.app, self.mix);
                }
            }
            return 0;
        }
    };

    const cb = ctx.alloc.create(Cb) catch return;
    cb.* = .{ .app = ctx.app, .mix = mix, .pl_id = ctx.pl_id, .alloc = ctx.alloc };
    _ = gtk.g_idle_add(&Cb.apply, cb);
}

fn buildSuggestionsUI(self: *App, mix: models.ItemList) void {
    clearChildren(self.suggestions_box, .box);

    if (mix.items.len == 0) {
        gtk.gtk_widget_set_visible(self.suggestions_box, 0);
        return;
    }

    gtk.gtk_widget_set_visible(self.suggestions_box, 1);

    const header = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_set_margin_start(header, 16);
    gtk.gtk_widget_set_margin_top(header, 16);
    gtk.gtk_widget_set_margin_bottom(header, 4);
    const title = gtk.gtk_label_new("Suggested tracks");
    gtk.gtk_widget_add_css_class(title, "suggestion-title");
    gtk.gtk_label_set_xalign(@ptrCast(title), 0);
    gtk.gtk_box_append(@ptrCast(header), title);
    gtk.gtk_box_append(@ptrCast(self.suggestions_box), header);

    const list = gtk.gtk_list_box_new();
    gtk.gtk_widget_add_css_class(list, "track-list");
    gtk.gtk_list_box_set_selection_mode(@ptrCast(list), gtk.GTK_SELECTION_NONE);

    for (mix.items) |track| {
        const row_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 12);
        gtk.gtk_widget_add_css_class(row_box, "track-row");
        gtk.gtk_widget_add_css_class(row_box, "suggestion-row");

        const name_label = makeLabel(self.allocator, track.name);
        gtk.gtk_widget_add_css_class(name_label, "track-name");
        gtk.gtk_label_set_xalign(@ptrCast(name_label), 0);
        gtk.gtk_label_set_ellipsize(@ptrCast(name_label), 3);
        gtk.gtk_widget_set_hexpand(name_label, 1);
        gtk.gtk_box_append(@ptrCast(row_box), name_label);

        if (track.album_artist) |artist| {
            const artist_label = makeLabel(self.allocator, artist);
            gtk.gtk_widget_add_css_class(artist_label, "track-duration");
            gtk.gtk_box_append(@ptrCast(row_box), artist_label);
        }

        const add_btn = gtk.gtk_button_new_from_icon_name("list-add-symbolic");
        gtk.gtk_widget_add_css_class(add_btn, "suggestion-add-btn");
        gtk.gtk_button_set_has_frame(@ptrCast(add_btn), 0);

        const track_id_z = std.fmt.allocPrintSentinel(self.allocator, "{s}", .{track.id}, 0) catch null;
        if (track_id_z) |z| setObjString(@ptrCast(add_btn), "track-id", z);
        _ = g_signal_connect(add_btn, "clicked", &onAddSuggestion, self);
        gtk.gtk_box_append(@ptrCast(row_box), add_btn);

        gtk.gtk_list_box_append(@ptrCast(list), row_box);
    }

    gtk.gtk_box_append(@ptrCast(self.suggestions_box), list);
}

fn onPlayAll(_: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data));
    const tracks = self.tracks orelse return;
    if (tracks.items.len == 0) return;
    self.setQueue(tracks.items, 0);
    self.playTrack(0);
}

fn onArtistNameClicked(_: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data));
    const raw: [*c]const u8 = gtk.gtk_label_get_text(@ptrCast(self.detail_artist));
    if (raw == null) return;
    const artist_name = std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
    if (artist_name.len == 0) return;

    // If we already have the artist list, find by name
    if (self.artists) |list| {
        for (list.items) |artist| {
            if (std.mem.eql(u8, artist.name, artist_name)) {
                artists_mod.showArtistDetail(self, artist);
                return;
            }
        }
    }

    // Search for the artist by name
    const name_copy = self.allocator.dupe(u8, artist_name) catch return;
    bg.run(self.allocator, self.client, struct {
        app: *App,
        alloc: std.mem.Allocator,
        name: []const u8,
        result: ?models.ItemList = null,

        pub fn work(s: *@This(), client: *api.Client) void {
            s.result = client.searchArtists(s.name, 5) catch null;
        }

        pub fn done(s: *@This()) void {
            defer s.alloc.free(s.name);
            if (s.result) |list| {
                // Find exact match
                for (list.items) |artist| {
                    if (std.ascii.eqlIgnoreCase(artist.name, s.name)) {
                        artists_mod.showArtistDetail(s.app, artist);
                        return;
                    }
                }
                // Fallback to first result
                if (list.items.len > 0) {
                    artists_mod.showArtistDetail(s.app, list.items[0]);
                }
            }
        }
    }{ .app = self, .alloc = self.allocator, .name = name_copy });
}

fn onTrackActivated(_: *gtk.GtkListBox, row: *gtk.GtkListBoxRow, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data));
    const index: usize = @intCast(gtk.gtk_list_box_row_get_index(row));

    // If we're viewing an artist's albums, navigate to that album
    if (self.artist_albums) |albums| {
        if (index < albums.items.len) {
            self.showAlbumById(albums.items[index].id);
            self.artist_albums = null;
            return;
        }
    }

    const tracks = self.tracks orelse return;
    if (index >= tracks.items.len) return;

    if (self.track_queue != null and self.queue_index == index) {
        const p = self.player orelse return;
        if (p.state == .playing or p.state == .paused) return;
    }

    self.setQueue(tracks.items, index);
    self.playTrack(index);
}

fn onPlayNextClicked(button: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data));
    const tracks = self.tracks orelse return;

    const row_box = gtk.gtk_widget_get_parent(@ptrCast(button)) orelse return;
    const list_row = gtk.gtk_widget_get_parent(row_box) orelse return;
    const idx: usize = @intCast(gtk.gtk_list_box_row_get_index(@ptrCast(list_row)));
    if (idx >= tracks.items.len) return;

    self.insertNextInQueue(tracks.items[idx]);
    log.info("queued: {s}", .{tracks.items[idx].name});
}

fn onMoveTrackUp(button: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data));
    const pl_id = self.current_playlist_id orelse return;
    const tracks = self.tracks orelse return;

    const row_box = gtk.gtk_widget_get_parent(@ptrCast(button)) orelse return;
    const list_row = gtk.gtk_widget_get_parent(row_box) orelse return;
    const idx: usize = @intCast(gtk.gtk_list_box_row_get_index(@ptrCast(list_row)));
    if (idx == 0 or idx >= tracks.items.len) return;

    doPlaylistAction(self, pl_id, tracks.items[idx].id, @intCast(idx - 1), .move);
}

fn onMoveTrackDown(button: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data));
    const pl_id = self.current_playlist_id orelse return;
    const tracks = self.tracks orelse return;

    const row_box = gtk.gtk_widget_get_parent(@ptrCast(button)) orelse return;
    const list_row = gtk.gtk_widget_get_parent(row_box) orelse return;
    const idx: usize = @intCast(gtk.gtk_list_box_row_get_index(@ptrCast(list_row)));
    if (idx + 1 >= tracks.items.len) return;

    doPlaylistAction(self, pl_id, tracks.items[idx].id, @intCast(idx + 1), .move);
}

fn onRemoveTrack(button: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data));
    const pl_id = self.current_playlist_id orelse return;

    const id_ptr = gtk.g_object_get_data(@ptrCast(button), "track-id");
    if (id_ptr == null) return;
    const track_id = std.mem.span(@as([*:0]const u8, @ptrCast(id_ptr)));

    doPlaylistAction(self, pl_id, track_id, 0, .remove);
}

fn onAddSuggestion(button: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data));
    const pl_id = self.current_playlist_id orelse return;

    const id_ptr = gtk.g_object_get_data(@ptrCast(button), "track-id");
    if (id_ptr == null) return;
    const track_id = std.mem.span(@as([*:0]const u8, @ptrCast(id_ptr)));

    const row = gtk.gtk_widget_get_parent(@ptrCast(button));
    if (row != null) {
        const list_row = gtk.gtk_widget_get_parent(row.?);
        if (list_row != null) {
            const list_parent = gtk.gtk_widget_get_parent(list_row.?);
            if (list_parent != null) {
                gtk.gtk_list_box_remove(@ptrCast(list_parent), list_row);
            }
        }
    }

    doPlaylistAction(self, pl_id, track_id, 0, .add);
}

pub fn onPlaylistActivated(_: *gtk.GtkListBox, row: *gtk.GtkListBoxRow, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data));
    const index: usize = @intCast(gtk.gtk_list_box_row_get_index(row));
    const pls = self.playlists orelse return;
    if (index >= pls.items.len) return;
    const playlist = pls.items[index];

    setLabelText(self.detail_title, playlist.name);
    setLabelText(self.detail_artist, "Playlist");
    gtk.gtk_picture_set_paintable(@ptrCast(self.detail_art), null);

    self.navigateTo("detail");

    self.current_album_idx = null;
    self.current_playlist_idx = index;
    self.current_playlist_id = playlist.id;

    clearChildren(self.track_list_box, .listbox);
    gtk.gtk_widget_set_visible(self.suggestions_box, 0);

    self.playlist_cache_mutex.lock();
    const pl_cached = self.playlist_cache.get(playlist.id);
    self.playlist_cache_mutex.unlock();
    if (pl_cached) |cached| {
        self.tracks = cached;
        for (cached.items) |track| {
            addTrackRow(self, track);
        }
        self.highlightCurrentTrack();
    } else {
        loadDetailAsync(self, playlist.id, true);
    }
    loadSuggestionsAsync(self, playlist.id);
}

pub fn onNewPlaylist(_: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data));

    const pls = self.playlists;
    var num: u32 = 1;
    while (num < 100) : (num += 1) {
        var name_buf: [32]u8 = undefined;
        const candidate = std.fmt.bufPrint(&name_buf, "New Playlist #{d}", .{num}) catch break;
        var taken = false;
        if (pls) |p| {
            for (p.items) |item| {
                if (item.name.len == candidate.len and std.mem.eql(u8, item.name, candidate)) {
                    taken = true;
                    break;
                }
            }
        }
        if (!taken) break;
    }

    var name_buf: [32]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "New Playlist #{d}", .{num}) catch return;
    const name_z = std.fmt.allocPrintSentinel(self.allocator, "{s}", .{name}, 0) catch return;

    self.current_playlist_id = null;
    self.current_playlist_idx = null;
    self.current_album_idx = null;
    setLabelText(self.detail_title, name);
    setLabelText(self.detail_artist, "Playlist");
    gtk.gtk_picture_set_paintable(@ptrCast(self.detail_art), null);
    clearChildren(self.track_list_box, .listbox);
    self.tracks = null;
    self.navigateTo("detail");
    gtk.gtk_widget_set_visible(self.suggestions_box, 0);

    bg.run(self.allocator, self.client, struct {
        app: *App,
        name: [:0]u8,
        alloc: std.mem.Allocator,
        new_id: ?[]const u8 = null,

        pub fn work(s: *@This(), client: *api.Client) void {
            s.new_id = client.createPlaylist(s.name) catch null;
            s.app.playlists = client.getPlaylists() catch null;
        }

        pub fn done(s: *@This()) void {
            defer s.alloc.free(s.name);
            if (s.new_id) |id| {
                s.app.current_playlist_id = id;
                log.info("created playlist: {s}", .{id});
            }
            s.app.populatePlaylists();
        }
    }{ .app = self, .name = name_z, .alloc = self.allocator });
}
