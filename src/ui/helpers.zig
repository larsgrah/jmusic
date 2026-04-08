const std = @import("std");
const c = @import("../c.zig");
const models = @import("../jellyfin/models.zig");

const gtk = c.gtk;

pub fn g_signal_connect(
    instance: *anyopaque,
    signal: [*:0]const u8,
    callback: *const anyopaque,
    data: ?*anyopaque,
) c_ulong {
    return gtk.g_signal_connect_data(
        @ptrCast(instance),
        signal,
        @ptrCast(callback),
        data,
        null,
        0,
    );
}

pub fn makeLabel(allocator: std.mem.Allocator, text: []const u8) *gtk.GtkWidget {
    const z = std.fmt.allocPrintSentinel(allocator, "{s}", .{text}, 0) catch return gtk.gtk_label_new("?");
    defer allocator.free(z);
    return gtk.gtk_label_new(z.ptr);
}

// Store a heap-allocated string on a GObject, freed automatically on widget destroy.
pub fn setObjString(obj: *anyopaque, key: [*:0]const u8, value: [:0]const u8) void {
    gtk.g_object_set_data_full(
        @ptrCast(@alignCast(obj)),
        key,
        @constCast(@ptrCast(value.ptr)),
        &cFreeNotify,
    );
}

fn cFreeNotify(data: ?*anyopaque) callconv(.c) void {
    if (data) |ptr| std.c.free(ptr);
}

pub fn setLabelText(label: *gtk.GtkWidget, text: []const u8) void {
    var buf: [256]u8 = undefined;
    const len = @min(text.len, buf.len - 1);
    @memcpy(buf[0..len], text[0..len]);
    buf[len] = 0;
    gtk.gtk_label_set_text(@ptrCast(label), @ptrCast(&buf));
}

pub fn setTimeLabel(label: *gtk.GtkWidget, seconds: f32) void {
    const total = @as(u32, @intFromFloat(@max(seconds, 0)));
    const m = total / 60;
    const s = total % 60;
    var buf: [12]u8 = undefined;
    const sl = std.fmt.bufPrint(&buf, "{d}:{d:0>2}", .{ m, s }) catch return;
    buf[sl.len] = 0;
    gtk.gtk_label_set_text(@ptrCast(label), @ptrCast(buf[0..sl.len :0].ptr));
}

pub const WidgetType = enum { flowbox, listbox, box };

pub fn clearChildren(widget: *gtk.GtkWidget, wtype: WidgetType) void {
    var child = gtk.gtk_widget_get_first_child(widget);
    while (child != null) {
        const next = gtk.gtk_widget_get_next_sibling(child);
        switch (wtype) {
            .flowbox => gtk.gtk_flow_box_remove(@ptrCast(widget), child),
            .listbox => gtk.gtk_list_box_remove(@ptrCast(widget), child),
            .box => gtk.gtk_box_remove(@ptrCast(widget), child),
        }
        child = next;
    }
}

pub fn matchesSearch(album: models.BaseItem, query: []const u8) bool {
    if (containsInsensitive(album.name, query)) return true;
    if (album.album_artist) |artist| {
        if (containsInsensitive(artist, query)) return true;
    }
    return false;
}

pub fn containsInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (0..needle.len) |j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}
