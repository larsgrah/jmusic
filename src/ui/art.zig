const std = @import("std");
const c = @import("../c.zig");
const api = @import("../jellyfin/api.zig");

const gtk = c.gtk;

pub const ArtJob = struct { id: []const u8, widget: *gtk.GtkWidget };

pub fn collectArtJobsFromBox(row_box: *gtk.GtkWidget, jobs: *std.array_list.AlignedManaged(ArtJob, null)) void {
    // row_box contains buttons, each button has a card box, first child is picture
    var btn = gtk.gtk_widget_get_first_child(row_box);
    while (btn != null) : (btn = gtk.gtk_widget_get_next_sibling(btn)) {
        const card_box = gtk.gtk_widget_get_first_child(btn) orelse continue;
        const picture = gtk.gtk_widget_get_first_child(card_box) orelse continue;

        const wname = gtk.gtk_widget_get_name(picture);
        if (wname == null) continue;
        const name_slice = std.mem.span(@as([*:0]const u8, @ptrCast(wname)));
        if (!std.mem.eql(u8, name_slice, "needs-art")) continue;

        const id_ptr = gtk.g_object_get_data(@ptrCast(picture), "art-id");
        if (id_ptr == null) continue;
        const id: [*:0]const u8 = @ptrCast(id_ptr);
        gtk.gtk_widget_set_name(picture, "art-loading");
        jobs.append(.{ .id = std.mem.span(id), .widget = picture.? }) catch {};
    }
}

pub fn artCachePath(buf: *[300]u8, item_id: []const u8) ?[]const u8 {
    const xdg = std.posix.getenv("XDG_CACHE_HOME");
    const home = std.posix.getenv("HOME");
    const base = xdg orelse (home orelse return null);
    const prefix = if (xdg != null) "/jmusic/art/" else "/.cache/jmusic/art/";
    return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ base, prefix, item_id }) catch null;
}

pub fn loadCachedArt(allocator: std.mem.Allocator, item_id: []const u8) ?[]const u8 {
    var buf: [300]u8 = undefined;
    const path = artCachePath(&buf, item_id) orelse return null;
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    return file.readToEndAlloc(allocator, 2 * 1024 * 1024) catch null;
}

pub fn saveCachedArt(item_id: []const u8, data: []const u8) void {
    var dir_buf: [280]u8 = undefined;
    const xdg = std.posix.getenv("XDG_CACHE_HOME");
    const home = std.posix.getenv("HOME");
    const base = xdg orelse (home orelse return);
    const prefix = if (xdg != null) "/jmusic/art" else "/.cache/jmusic/art";
    const dir_path = std.fmt.bufPrint(&dir_buf, "{s}{s}", .{ base, prefix }) catch return;
    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        error.FileNotFound => {
            const parent_prefix = if (xdg != null) "/jmusic" else "/.cache/jmusic";
            var parent_buf: [260]u8 = undefined;
            const parent = std.fmt.bufPrint(&parent_buf, "{s}{s}", .{ base, parent_prefix }) catch return;
            std.fs.makeDirAbsolute(parent) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => return,
            };
            std.fs.makeDirAbsolute(dir_path) catch return;
        },
        else => return,
    };

    var buf: [300]u8 = undefined;
    const path = artCachePath(&buf, item_id) orelse return;
    const file = std.fs.createFileAbsolute(path, .{}) catch return;
    defer file.close();
    file.writeAll(data) catch {};
}

pub fn applyTexture(widget: *gtk.GtkWidget, data: []const u8) void {
    const gbytes = gtk.g_bytes_new(data.ptr, data.len);
    defer gtk.g_bytes_unref(gbytes);
    var err: ?*gtk.GError = null;
    const texture = gtk.gdk_texture_new_from_bytes(gbytes, &err);
    if (texture == null) return;
    gtk.gtk_picture_set_paintable(@ptrCast(widget), @ptrCast(texture));
    gtk.g_object_unref(texture);
}
