const std = @import("std");
const c = @import("../c.zig");
const models = @import("../jellyfin/models.zig");
const art_mod = @import("art.zig");
const helpers = @import("helpers.zig");

const gtk = c.gtk;
const App = @import("window.zig").App;
const ArtJob = art_mod.ArtJob;
const collectArtJobsFromBox = art_mod.collectArtJobsFromBox;
const g_signal_connect = helpers.g_signal_connect;
const makeLabel = helpers.makeLabel;
const setObjString = helpers.setObjString;
const clearChildren = helpers.clearChildren;

pub fn buildHomePage(self: *App) void {
    clearChildren(self.home_box, .box);

    if (self.home_recent) |recent| {
        if (recent.items.len > 0) {
            addHomeSection(self, "Continue Listening", dedupeByAlbum(self, recent.items));
        }
    }

    if (self.home_added) |added| {
        if (added.items.len > 0) {
            addHomeSection(self, "Recently Added", added.items);
        }
    }

    if (self.home_favorites) |favs| {
        if (favs.items.len > 0) {
            addHomeSection(self, "Favorites", favs.items);
        }
    }

    if (self.home_random) |random| {
        if (random.items.len > 0) {
            addHomeSection(self, "Discover", random.items);
        }
    }

    spawnHomeArtLoader(self);
}

pub fn dedupeByAlbum(self: *App, songs: []models.BaseItem) []models.BaseItem {
    if (self.deduped_albums) |old| self.allocator.free(old);
    self.deduped_albums = null;

    var seen = std.StringHashMap(void).init(self.allocator);
    defer seen.deinit();

    var result = self.allocator.alloc(models.BaseItem, @min(songs.len, 20)) catch return &.{};
    var count: usize = 0;

    for (songs) |song| {
        if (count >= 20) break;
        const album_id = song.album_id orelse song.parent_id orelse continue;
        if (seen.contains(album_id)) continue;
        seen.put(album_id, {}) catch continue;

        result[count] = .{
            .id = album_id,
            .name = song.album orelse song.name,
            .album_artist = song.album_artist,
            .item_type = "MusicAlbum",
        };
        count += 1;
    }

    self.deduped_albums = result;
    return result[0..count];
}

fn addHomeSection(self: *App, title: [*:0]const u8, items: []models.BaseItem) void {
    const section = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(section, "home-section");

    const label = gtk.gtk_label_new(title);
    gtk.gtk_widget_add_css_class(label, "section-title");
    gtk.gtk_label_set_xalign(@ptrCast(label), 0);
    gtk.gtk_box_append(@ptrCast(section), label);

    const scroll = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(@ptrCast(scroll), gtk.GTK_POLICY_AUTOMATIC, gtk.GTK_POLICY_NEVER);
    gtk.gtk_widget_set_size_request(scroll, -1, 230);

    const row = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(row, "home-row");
    gtk.gtk_widget_set_margin_start(row, 20);
    gtk.gtk_widget_set_margin_end(row, 20);

    for (items) |item| {
        const card = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);
        gtk.gtk_widget_add_css_class(card, "album-card");

        const pic = gtk.gtk_picture_new();
        gtk.gtk_widget_add_css_class(pic, "grid-art");
        gtk.gtk_widget_set_size_request(pic, 150, 150);
        gtk.gtk_widget_set_vexpand(pic, 0);
        gtk.gtk_widget_set_hexpand(pic, 0);
        gtk.gtk_picture_set_content_fit(@ptrCast(pic), gtk.GTK_CONTENT_FIT_COVER);
        if (std.fmt.allocPrintSentinel(self.allocator, "{s}", .{item.id}, 0)) |z|
            setObjString(@ptrCast(pic), "art-id", z)
        else |_| {}
        gtk.gtk_widget_set_name(pic, "needs-art");
        gtk.gtk_box_append(@ptrCast(card), pic);

        const name = makeLabel(self.allocator, item.name);
        gtk.gtk_widget_add_css_class(name, "album-title");
        gtk.gtk_label_set_xalign(@ptrCast(name), 0);
        gtk.gtk_label_set_ellipsize(@ptrCast(name), 3);
        gtk.gtk_label_set_max_width_chars(@ptrCast(name), 18);
        gtk.gtk_box_append(@ptrCast(card), name);

        if (item.album_artist) |artist_name| {
            const artist = makeLabel(self.allocator, artist_name);
            gtk.gtk_widget_add_css_class(artist, "album-artist");
            gtk.gtk_label_set_xalign(@ptrCast(artist), 0);
            gtk.gtk_label_set_ellipsize(@ptrCast(artist), 3);
            gtk.gtk_label_set_max_width_chars(@ptrCast(artist), 18);
            gtk.gtk_box_append(@ptrCast(card), artist);
        }

        const button = gtk.gtk_button_new();
        gtk.gtk_widget_add_css_class(button, "flat");
        gtk.gtk_widget_add_css_class(button, "album-card-btn");
        gtk.gtk_widget_set_valign(button, gtk.GTK_ALIGN_START);
        gtk.gtk_button_set_child(@ptrCast(button), card);

        if (std.fmt.allocPrintSentinel(self.allocator, "{s}", .{item.id}, 0)) |z|
            setObjString(@ptrCast(button), "item-id", z)
        else |_| {}
        _ = g_signal_connect(button, "clicked", &onHomeCardClicked, self);

        gtk.gtk_box_append(@ptrCast(row), button);
    }

    gtk.gtk_scrolled_window_set_child(@ptrCast(scroll), row);
    gtk.g_object_set_data(@ptrCast(scroll), "row-box", @ptrCast(row));
    gtk.gtk_box_append(@ptrCast(section), scroll);
    gtk.gtk_box_append(@ptrCast(self.home_box), section);
}

pub fn spawnHomeArtLoader(self: *App) void {
    _ = self.home_art_gen.fetchAdd(1, .release);
    var jobs = std.array_list.AlignedManaged(ArtJob, null).init(self.allocator);
    const gen = self.home_art_gen.load(.acquire);
    const gen_ptr = &self.home_art_gen;

    var section = gtk.gtk_widget_get_first_child(self.home_box);
    while (section != null) : (section = gtk.gtk_widget_get_next_sibling(section)) {
        var section_child = gtk.gtk_widget_get_first_child(section);
        while (section_child != null) : (section_child = gtk.gtk_widget_get_next_sibling(section_child)) {
            const row = gtk.g_object_get_data(@ptrCast(section_child), "row-box");
            if (row != null) {
                collectArtJobsFromBox(@ptrCast(@alignCast(row)), &jobs);
            }
        }
    }

    if (jobs.items.len == 0) {
        jobs.deinit();
        return;
    }

    self.spawnArtThread(jobs, gen, gen_ptr);
}

fn onHomeCardClicked(button: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data));
    const id_ptr = gtk.g_object_get_data(@ptrCast(button), "item-id");
    if (id_ptr == null) return;
    const id: [*:0]const u8 = @ptrCast(id_ptr);
    const id_slice = std.mem.span(id);

    const albums = self.albums orelse return;
    for (albums.items, 0..) |album, i| {
        if (std.mem.eql(u8, album.id, id_slice)) {
            self.showAlbumDetail(i);
            return;
        }
    }
    self.showAlbumById(id_slice);
}
