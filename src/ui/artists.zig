const std = @import("std");
const c = @import("../c.zig");
const api = @import("../jellyfin/api.zig");
const models = @import("../jellyfin/models.zig");
const helpers = @import("helpers.zig");
const bg = @import("bg.zig");
const detail = @import("detail.zig");
const art_mod = @import("art.zig");

const log = std.log.scoped(.artists);
const gtk = c.gtk;
const App = @import("window.zig").App;
const g_signal_connect = helpers.g_signal_connect;

pub fn buildArtistsPage(self: *App) *gtk.GtkWidget {
    const page = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);

    const title = gtk.gtk_label_new("Artists");
    gtk.gtk_widget_add_css_class(title, "section-title");
    gtk.gtk_label_set_xalign(@ptrCast(title), 0);
    gtk.gtk_box_append(@ptrCast(page), title);

    const scroll = gtk.gtk_scrolled_window_new();
    gtk.gtk_widget_set_vexpand(scroll, 1);
    self.artist_list = gtk.gtk_flow_box_new();
    gtk.gtk_flow_box_set_homogeneous(@ptrCast(self.artist_list), 0);
    gtk.gtk_flow_box_set_column_spacing(@ptrCast(self.artist_list), 4);
    gtk.gtk_flow_box_set_row_spacing(@ptrCast(self.artist_list), 4);
    gtk.gtk_flow_box_set_max_children_per_line(@ptrCast(self.artist_list), 8);
    gtk.gtk_flow_box_set_min_children_per_line(@ptrCast(self.artist_list), 2);
    gtk.gtk_flow_box_set_selection_mode(@ptrCast(self.artist_list), gtk.GTK_SELECTION_NONE);
    gtk.gtk_scrolled_window_set_child(@ptrCast(scroll), self.artist_list);
    gtk.gtk_box_append(@ptrCast(page), scroll);

    return page;
}

pub fn loadArtists(self: *App) void {
    if (self.artists_loaded) return;

    // Show cached artists immediately
    if (api.Client.readCacheFile(self.allocator, "artists.json", 168)) |cached| {
        defer self.allocator.free(cached);
        if (models.parseItemList(self.allocator, cached)) |list| {
            self.artists = list;
            self.artists_loaded = true;
            populateArtists(self);
            log.info("loaded {d} artists from cache", .{list.items.len});
        } else |_| {}
    }

    // Always refresh in background
    bg.run(self.allocator, self.client, struct {
        app: *App,
        alloc: std.mem.Allocator,
        result: ?models.ItemList = null,

        pub fn work(s: *@This(), client: *api.Client) void {
            s.result = client.getArtists(200) catch null;
        }

        pub fn done(s: *@This()) void {
            const app = s.app;
            if (s.result) |list| {
                app.artists = list;
                app.artists_loaded = true;
                populateArtists(app);
                log.info("loaded {d} artists", .{list.items.len});
            }
        }
    }{ .app = self, .alloc = self.allocator });
}

fn populateArtists(self: *App) void {
    helpers.clearChildren(self.artist_list, .flowbox);
    const list = self.artists orelse return;

    const max_display: usize = 60;
    for (list.items[0..@min(list.items.len, max_display)], 0..) |artist, i| {
        const card = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);
        gtk.gtk_widget_add_css_class(card, "album-card");

        // Artist art placeholder
        const pic = gtk.gtk_picture_new();
        gtk.gtk_widget_add_css_class(pic, "grid-art");
        gtk.gtk_widget_set_size_request(pic, 160, 160);
        gtk.gtk_picture_set_content_fit(@ptrCast(pic), gtk.GTK_CONTENT_FIT_COVER);
        gtk.gtk_widget_set_name(pic, "needs-art");
        gtk.gtk_box_append(@ptrCast(card), pic);

        const name = helpers.makeLabel(self.allocator, artist.name);
        gtk.gtk_widget_add_css_class(name, "album-title");
        gtk.gtk_label_set_xalign(@ptrCast(name), 0);
        gtk.gtk_label_set_ellipsize(@ptrCast(name), 3);
        gtk.gtk_label_set_max_width_chars(@ptrCast(name), 22);
        gtk.gtk_box_append(@ptrCast(card), name);

        const button = gtk.gtk_button_new();
        gtk.gtk_widget_add_css_class(button, "flat");
        gtk.gtk_widget_add_css_class(button, "album-card-btn");
        gtk.gtk_widget_set_valign(button, gtk.GTK_ALIGN_START);
        gtk.gtk_button_set_child(@ptrCast(button), card);
        gtk.g_object_set_data(@ptrCast(button), "idx", @ptrFromInt(i + 1));
        _ = g_signal_connect(button, "clicked", &onArtistClicked, self);

        gtk.gtk_flow_box_append(@ptrCast(self.artist_list), button);
    }

    // Load artist art
    spawnArtistArtLoader(self);
}

fn onArtistClicked(button: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data));
    const raw = @intFromPtr(gtk.g_object_get_data(@ptrCast(button), "idx"));
    if (raw == 0) return;
    const idx = raw - 1;
    const list = self.artists orelse return;
    if (idx >= list.items.len) return;

    const artist = list.items[idx];
    showArtistDetail(self, artist);
}

pub fn showArtistDetail(self: *App, artist: models.BaseItem) void {
    self.current_artist = artist;
    helpers.setLabelText(self.detail_type_label, "ARTIST");
    helpers.setLabelText(self.detail_title, artist.name);
    helpers.setLabelText(self.detail_artist, "");
    gtk.gtk_picture_set_paintable(@ptrCast(self.detail_art), null);

    helpers.clearChildren(self.track_list_box, .listbox);
    self.tracks = null;
    self.current_playlist_id = null;
    self.current_album_idx = null;

    self.navigateTo("detail");

    // Fetch artist's albums in background, then show as a track list
    bg.run(self.allocator, self.client, struct {
        app: *App,
        alloc: std.mem.Allocator,
        artist_id: []const u8,
        result: ?models.ItemList = null,

        pub fn work(s: *@This(), client: *api.Client) void {
            s.result = client.getArtistAlbums(s.artist_id) catch null;
        }

        pub fn done(s: *@This()) void {
            defer s.alloc.free(s.artist_id);
            const app = s.app;
            if (s.result) |albums| {
                log.info("artist has {d} albums", .{albums.items.len});
                showArtistAlbums(app, albums);
            } else {
                log.warn("failed to fetch artist albums", .{});
            }
        }
    }{
        .app = self,
        .alloc = self.allocator,
        .artist_id = self.allocator.dupe(u8, artist.id) catch return,
    });

    // Load artist art
    const art_id_z = std.fmt.allocPrintSentinel(self.allocator, "{s}", .{artist.id}, 0) catch return;
    bg.run(self.allocator, self.client, struct {
        app: *App,
        id: [:0]u8,
        alloc: std.mem.Allocator,
        data: ?[]const u8 = null,

        pub fn work(s: *@This(), client: *api.Client) void {
            s.data = art_mod.loadCachedArt(s.alloc, s.id) orelse blk: {
                const url = client.getImageUrl(s.id, 200) catch return;
                defer s.alloc.free(url);
                const d = client.fetchBytes(url) catch return;
                art_mod.saveCachedArt(s.id, d);
                break :blk d;
            };
        }

        pub fn done(s: *@This()) void {
            defer s.alloc.free(s.id);
            const img_data = s.data orelse return;
            defer s.alloc.free(img_data);

            const gbytes = gtk.g_bytes_new(img_data.ptr, img_data.len);
            defer gtk.g_bytes_unref(gbytes);
            var err: ?*gtk.GError = null;
            const texture = gtk.gdk_texture_new_from_bytes(gbytes, &err);
            if (texture != null) {
                gtk.gtk_picture_set_paintable(@ptrCast(s.app.detail_art), @ptrCast(texture));
                gtk.g_object_unref(texture);
            }
        }
    }{ .app = self, .id = art_id_z, .alloc = self.allocator });
}

fn showArtistAlbums(self: *App, albums: models.ItemList) void {
    helpers.clearChildren(self.track_list_box, .listbox);

    for (albums.items, 0..) |album, i| {
        const row = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 12);
        gtk.gtk_widget_add_css_class(row, "track-row");
        gtk.gtk_widget_set_margin_start(row, 8);
        gtk.gtk_widget_set_margin_end(row, 8);

        // Album art thumbnail
        const pic = gtk.gtk_picture_new();
        gtk.gtk_widget_add_css_class(pic, "grid-art");
        gtk.gtk_widget_set_size_request(pic, 48, 48);
        gtk.gtk_picture_set_content_fit(@ptrCast(pic), gtk.GTK_CONTENT_FIT_COVER);
        gtk.gtk_box_append(@ptrCast(row), pic);

        const info_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 2);
        gtk.gtk_widget_set_valign(info_box, gtk.GTK_ALIGN_CENTER);
        gtk.gtk_widget_set_hexpand(info_box, 1);

        const name = helpers.makeLabel(self.allocator, album.name);
        gtk.gtk_widget_add_css_class(name, "track-name");
        gtk.gtk_label_set_xalign(@ptrCast(name), 0);
        gtk.gtk_label_set_ellipsize(@ptrCast(name), 3);
        gtk.gtk_box_append(@ptrCast(info_box), name);

        if (album.album_artist) |artist_name| {
            const artist = helpers.makeLabel(self.allocator, artist_name);
            gtk.gtk_widget_add_css_class(artist, "track-duration");
            gtk.gtk_label_set_xalign(@ptrCast(artist), 0);
            gtk.gtk_box_append(@ptrCast(info_box), artist);
        }

        gtk.gtk_box_append(@ptrCast(row), info_box);
        gtk.gtk_list_box_append(@ptrCast(self.track_list_box), row);

        // Store album index for click handling
        const list_row = gtk.gtk_widget_get_parent(row);
        if (list_row != null) {
            gtk.g_object_set_data(@ptrCast(list_row), "album-id", @constCast(@ptrCast(album.id.ptr)));
            gtk.g_object_set_data(@ptrCast(list_row), "album-idx", @ptrFromInt(i + 1));
        }

        // Load album art thumbnail
        loadAlbumThumb(self, album.id, pic);
    }

    // Store albums for click navigation and override row-activated
    self.artist_albums = albums;
}

fn loadAlbumThumb(self: *App, album_id: []const u8, pic: *gtk.GtkWidget) void {
    const id_z = std.fmt.allocPrintSentinel(self.allocator, "{s}", .{album_id}, 0) catch return;
    _ = gtk.g_object_ref(pic);
    bg.run(self.allocator, self.client, struct {
        widget: *gtk.GtkWidget,
        id: [:0]u8,
        alloc: std.mem.Allocator,
        data: ?[]const u8 = null,

        pub fn work(s: *@This(), client: *api.Client) void {
            s.data = art_mod.loadCachedArt(s.alloc, s.id) orelse blk: {
                const url = client.getImageUrl(s.id, 80) catch return;
                defer s.alloc.free(url);
                const d = client.fetchBytes(url) catch return;
                art_mod.saveCachedArt(s.id, d);
                break :blk d;
            };
        }

        pub fn done(s: *@This()) void {
            defer {
                gtk.g_object_unref(s.widget);
                s.alloc.free(s.id);
            }
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

fn spawnArtistArtLoader(self: *App) void {
    const list = self.artists orelse return;
    _ = self.grid_art_gen.fetchAdd(1, .release);
    const gen = self.grid_art_gen.load(.acquire);

    var jobs = std.array_list.AlignedManaged(art_mod.ArtJob, null).init(self.allocator);

    var child = gtk.gtk_widget_get_first_child(self.artist_list);
    var i: usize = 0;
    while (child != null) : ({
        child = gtk.gtk_widget_get_next_sibling(child);
        i += 1;
    }) {
        if (i >= list.items.len) break;
        const btn = gtk.gtk_widget_get_first_child(child) orelse continue;
        const card_box = gtk.gtk_widget_get_first_child(btn) orelse continue;
        const picture = gtk.gtk_widget_get_first_child(card_box) orelse continue;

        const name_ptr = gtk.gtk_widget_get_name(picture);
        if (name_ptr == null) continue;
        const name_slice = std.mem.span(@as([*:0]const u8, @ptrCast(name_ptr)));
        if (!std.mem.eql(u8, name_slice, "needs-art")) continue;

        gtk.gtk_widget_set_name(picture, "art-loading");
        jobs.append(.{ .id = list.items[i].id, .widget = picture }) catch continue;
    }

    self.spawnArtThread(jobs, gen, &self.grid_art_gen);
}
