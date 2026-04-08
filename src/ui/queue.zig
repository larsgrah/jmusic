const std = @import("std");
const c = @import("../c.zig");
const models = @import("../jellyfin/models.zig");
const mpris = @import("mpris.zig");
const helpers = @import("helpers.zig");
const playback = @import("playback.zig");

const gtk = c.gtk;
const App = @import("window.zig").App;

const g_signal_connect = helpers.g_signal_connect;
const makeLabel = helpers.makeLabel;
const setLabelText = helpers.setLabelText;
const clearChildren = helpers.clearChildren;

pub fn buildQueuePanel(self: *App) void {
    self.queue_revealer = gtk.gtk_revealer_new();
    gtk.gtk_revealer_set_transition_type(@ptrCast(self.queue_revealer), gtk.GTK_REVEALER_TRANSITION_TYPE_SLIDE_LEFT);
    gtk.gtk_revealer_set_transition_duration(@ptrCast(self.queue_revealer), 200);
    gtk.gtk_revealer_set_reveal_child(@ptrCast(self.queue_revealer), 0);
    gtk.gtk_widget_set_halign(self.queue_revealer, gtk.GTK_ALIGN_END);
    gtk.gtk_widget_set_valign(self.queue_revealer, gtk.GTK_ALIGN_FILL);

    const queue_panel = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(queue_panel, "queue-panel");
    gtk.gtk_widget_set_size_request(queue_panel, 320, -1);

    const queue_header = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_set_margin_start(queue_header, 16);
    gtk.gtk_widget_set_margin_end(queue_header, 16);
    gtk.gtk_widget_set_margin_top(queue_header, 12);
    gtk.gtk_widget_set_margin_bottom(queue_header, 8);
    const queue_title = gtk.gtk_label_new("Queue");
    gtk.gtk_widget_add_css_class(queue_title, "queue-title");
    gtk.gtk_label_set_xalign(@ptrCast(queue_title), 0);
    gtk.gtk_widget_set_hexpand(queue_title, 1);
    gtk.gtk_box_append(@ptrCast(queue_header), queue_title);

    const clear_btn = gtk.gtk_button_new_with_label("Clear");
    gtk.gtk_widget_add_css_class(clear_btn, "queue-clear-btn");
    gtk.gtk_button_set_has_frame(@ptrCast(clear_btn), 0);
    _ = g_signal_connect(clear_btn, "clicked", &onClearQueue, self);
    gtk.gtk_box_append(@ptrCast(queue_header), clear_btn);
    gtk.gtk_box_append(@ptrCast(queue_panel), queue_header);

    const queue_scroll = gtk.gtk_scrolled_window_new();
    gtk.gtk_widget_set_vexpand(queue_scroll, 1);
    self.queue_list = gtk.gtk_list_box_new();
    gtk.gtk_widget_add_css_class(self.queue_list, "queue-list");
    gtk.gtk_list_box_set_selection_mode(@ptrCast(self.queue_list), gtk.GTK_SELECTION_SINGLE);
    _ = g_signal_connect(self.queue_list, "row-activated", &onQueueRowActivated, self);
    gtk.gtk_scrolled_window_set_child(@ptrCast(queue_scroll), self.queue_list);
    gtk.gtk_box_append(@ptrCast(queue_panel), queue_scroll);

    gtk.gtk_revealer_set_child(@ptrCast(self.queue_revealer), queue_panel);
}

pub fn rebuildQueueList(self: *App) void {
    clearChildren(self.queue_list, .listbox);
    const queue = self.track_queue orelse return;

    for (queue, 0..) |track, i| {
        const row_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 8);
        gtk.gtk_widget_add_css_class(row_box, "queue-row");

        if (i == self.queue_index) {
            gtk.gtk_widget_add_css_class(row_box, "queue-playing");
        }

        const name = makeLabel(self.allocator, track.name);
        gtk.gtk_widget_add_css_class(name, "queue-track-name");
        gtk.gtk_label_set_xalign(@ptrCast(name), 0);
        gtk.gtk_label_set_ellipsize(@ptrCast(name), 3);
        gtk.gtk_widget_set_hexpand(name, 1);
        gtk.gtk_box_append(@ptrCast(row_box), name);

        if (track.album_artist orelse track.album) |artist| {
            const a = makeLabel(self.allocator, artist);
            gtk.gtk_widget_add_css_class(a, "queue-artist");
            gtk.gtk_label_set_ellipsize(@ptrCast(a), 3);
            gtk.gtk_label_set_max_width_chars(@ptrCast(a), 12);
            gtk.gtk_box_append(@ptrCast(row_box), a);
        }

        const up = gtk.gtk_button_new_from_icon_name("go-up-symbolic");
        gtk.gtk_widget_add_css_class(up, "reorder-btn");
        gtk.gtk_button_set_has_frame(@ptrCast(up), 0);
        _ = g_signal_connect(up, "clicked", &onQueueMoveUp, self);
        gtk.gtk_box_append(@ptrCast(row_box), up);

        const down = gtk.gtk_button_new_from_icon_name("go-down-symbolic");
        gtk.gtk_widget_add_css_class(down, "reorder-btn");
        gtk.gtk_button_set_has_frame(@ptrCast(down), 0);
        _ = g_signal_connect(down, "clicked", &onQueueMoveDown, self);
        gtk.gtk_box_append(@ptrCast(row_box), down);

        const rm = gtk.gtk_button_new_from_icon_name("edit-delete-symbolic");
        gtk.gtk_widget_add_css_class(rm, "remove-btn");
        gtk.gtk_button_set_has_frame(@ptrCast(rm), 0);
        _ = g_signal_connect(rm, "clicked", &onQueueRemove, self);
        gtk.gtk_box_append(@ptrCast(row_box), rm);

        gtk.gtk_list_box_append(@ptrCast(self.queue_list), row_box);
    }
}

pub fn onToggleQueue(_: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data));
    const revealed = gtk.gtk_revealer_get_reveal_child(@ptrCast(self.queue_revealer));
    gtk.gtk_revealer_set_reveal_child(@ptrCast(self.queue_revealer), if (revealed != 0) 0 else 1);
    if (revealed == 0) rebuildQueueList(self);
}

fn onClearQueue(_: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data));
    const p = self.player orelse return;
    p.stop();
    if (self.track_queue_owned) {
        if (self.track_queue) |old| self.allocator.free(old);
    }
    self.track_queue = null;
    self.track_queue_owned = false;
    rebuildQueueList(self);
    setLabelText(self.np_title, "Nothing playing");
    setLabelText(self.np_artist, "");
    gtk.gtk_button_set_icon_name(@ptrCast(self.play_btn), "media-playback-start-symbolic");
}

fn onQueueRowActivated(_: *gtk.GtkListBox, row: *gtk.GtkListBoxRow, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data));
    const index: usize = @intCast(gtk.gtk_list_box_row_get_index(row));
    const queue = self.track_queue orelse return;
    if (index >= queue.len) return;
    self.queue_index = index;
    self.playTrack(index);
    rebuildQueueList(self);
}

fn onQueueMoveUp(button: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data));
    var queue = self.track_queue orelse return;
    const row_box = gtk.gtk_widget_get_parent(@ptrCast(button)) orelse return;
    const list_row = gtk.gtk_widget_get_parent(row_box) orelse return;
    const idx: usize = @intCast(gtk.gtk_list_box_row_get_index(@ptrCast(list_row)));
    if (idx == 0 or idx >= queue.len) return;

    const tmp = queue[idx];
    queue[idx] = queue[idx - 1];
    queue[idx - 1] = tmp;

    if (self.queue_index == idx) {
        self.queue_index -= 1;
    } else if (self.queue_index == idx - 1) {
        self.queue_index += 1;
    }
    rebuildQueueList(self);
}

fn onQueueMoveDown(button: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data));
    var queue = self.track_queue orelse return;
    const row_box = gtk.gtk_widget_get_parent(@ptrCast(button)) orelse return;
    const list_row = gtk.gtk_widget_get_parent(row_box) orelse return;
    const idx: usize = @intCast(gtk.gtk_list_box_row_get_index(@ptrCast(list_row)));
    if (idx + 1 >= queue.len) return;

    const tmp = queue[idx];
    queue[idx] = queue[idx + 1];
    queue[idx + 1] = tmp;

    if (self.queue_index == idx) {
        self.queue_index += 1;
    } else if (self.queue_index == idx + 1) {
        self.queue_index -= 1;
    }
    rebuildQueueList(self);
}

fn onQueueRemove(button: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data));
    var queue = self.track_queue orelse return;
    const row_box = gtk.gtk_widget_get_parent(@ptrCast(button)) orelse return;
    const list_row = gtk.gtk_widget_get_parent(row_box) orelse return;
    const idx: usize = @intCast(gtk.gtk_list_box_row_get_index(@ptrCast(list_row)));
    if (idx >= queue.len) return;

    var i: usize = idx;
    while (i + 1 < queue.len) : (i += 1) queue[i] = queue[i + 1];

    self.track_queue = queue[0 .. queue.len - 1];

    if (self.queue_index > idx) {
        self.queue_index -= 1;
    } else if (self.queue_index == idx and self.queue_index >= queue.len - 1) {
        if (self.queue_index > 0) self.queue_index -= 1;
    }
    rebuildQueueList(self);
}
