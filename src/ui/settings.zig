const std = @import("std");
const c = @import("../c.zig");
const helpers = @import("helpers.zig");

const log = std.log.scoped(.settings);
const gtk = c.gtk;
const App = @import("window.zig").App;
const g_signal_connect = helpers.g_signal_connect;

pub fn buildSettingsPage(self: *App) *gtk.GtkWidget {
    const page = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 16);
    gtk.gtk_widget_add_css_class(page, "settings-page");
    gtk.gtk_widget_set_margin_start(page, 40);
    gtk.gtk_widget_set_margin_end(page, 40);
    gtk.gtk_widget_set_margin_top(page, 32);

    const title = gtk.gtk_label_new("Settings");
    gtk.gtk_widget_add_css_class(title, "settings-title");
    gtk.gtk_label_set_xalign(@ptrCast(title), 0);
    gtk.gtk_box_append(@ptrCast(page), title);

    const server_label = gtk.gtk_label_new("Jellyfin Server URL");
    gtk.gtk_widget_add_css_class(server_label, "settings-label");
    gtk.gtk_label_set_xalign(@ptrCast(server_label), 0);
    gtk.gtk_box_append(@ptrCast(page), server_label);

    self.settings_server = gtk.gtk_entry_new();
    gtk.gtk_widget_add_css_class(self.settings_server, "settings-entry");
    gtk.gtk_entry_set_placeholder_text(@ptrCast(self.settings_server), "https://jellyfin.example.com");
    setEntryText(self.settings_server, self.config.server);
    gtk.gtk_box_append(@ptrCast(page), self.settings_server);

    const user_label = gtk.gtk_label_new("Username");
    gtk.gtk_widget_add_css_class(user_label, "settings-label");
    gtk.gtk_label_set_xalign(@ptrCast(user_label), 0);
    gtk.gtk_box_append(@ptrCast(page), user_label);

    self.settings_user = gtk.gtk_entry_new();
    gtk.gtk_widget_add_css_class(self.settings_user, "settings-entry");
    setEntryText(self.settings_user, self.config.username);
    gtk.gtk_box_append(@ptrCast(page), self.settings_user);

    const pass_label = gtk.gtk_label_new("Password");
    gtk.gtk_widget_add_css_class(pass_label, "settings-label");
    gtk.gtk_label_set_xalign(@ptrCast(pass_label), 0);
    gtk.gtk_box_append(@ptrCast(page), pass_label);

    self.settings_pass = gtk.gtk_password_entry_new();
    gtk.gtk_widget_add_css_class(self.settings_pass, "settings-entry");
    gtk.gtk_password_entry_set_show_peek_icon(@ptrCast(self.settings_pass), 1);
    setEntryText(self.settings_pass, self.config.password);
    gtk.gtk_box_append(@ptrCast(page), self.settings_pass);

    const cache_label = gtk.gtk_label_new("Audio cache size (MB)");
    gtk.gtk_widget_add_css_class(cache_label, "settings-label");
    gtk.gtk_label_set_xalign(@ptrCast(cache_label), 0);
    gtk.gtk_box_append(@ptrCast(page), cache_label);

    self.settings_cache = gtk.gtk_spin_button_new_with_range(0, 4096, 64);
    gtk.gtk_widget_add_css_class(self.settings_cache, "settings-entry");
    gtk.gtk_spin_button_set_value(@ptrCast(self.settings_cache), @floatFromInt(self.config.cache_size_mb));
    gtk.gtk_box_append(@ptrCast(page), self.settings_cache);

    const save_btn = gtk.gtk_button_new_with_label("Save");
    gtk.gtk_widget_add_css_class(save_btn, "settings-save-btn");
    gtk.gtk_widget_set_halign(save_btn, gtk.GTK_ALIGN_START);
    _ = g_signal_connect(save_btn, "clicked", &onSettingsSave, self);
    gtk.gtk_box_append(@ptrCast(page), save_btn);

    return page;
}

fn setEntryText(widget: *gtk.GtkWidget, text: []const u8) void {
    var buf: [256]u8 = undefined;
    const len = @min(text.len, buf.len - 1);
    @memcpy(buf[0..len], text[0..len]);
    buf[len] = 0;
    gtk.gtk_editable_set_text(@ptrCast(widget), @ptrCast(&buf));
}

pub fn onSettingsSave(_: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data));
    const server = std.mem.span(@as([*:0]const u8, @ptrCast(gtk.gtk_editable_get_text(@ptrCast(self.settings_server)))));
    const username = std.mem.span(@as([*:0]const u8, @ptrCast(gtk.gtk_editable_get_text(@ptrCast(self.settings_user)))));
    const password = std.mem.span(@as([*:0]const u8, @ptrCast(gtk.gtk_editable_get_text(@ptrCast(self.settings_pass)))));

    const home = std.posix.getenv("HOME") orelse return;
    const path = std.fmt.allocPrint(self.allocator, "{s}/.config/jmusic/config.json", .{home}) catch return;
    defer self.allocator.free(path);

    const cache_mb: u32 = @intFromFloat(gtk.gtk_spin_button_get_value(@ptrCast(self.settings_cache)));

    const json = std.fmt.allocPrint(
        self.allocator,
        "{{\"server\":\"{s}\",\"username\":\"{s}\",\"password\":\"{s}\",\"cache_size_mb\":{d}}}\n",
        .{ server, username, password, cache_mb },
    ) catch return;
    defer self.allocator.free(json);

    const file = std.fs.createFileAbsolute(path, .{}) catch return;
    defer file.close();
    file.writeAll(json) catch return;

    self.disk_audio_cache.max_bytes = @as(u64, cache_mb) * 1024 * 1024;
    self.disk_audio_cache.evictIfNeeded();

    log.info("config saved (cache: {d}MB)", .{cache_mb});
    self.navigateTo("home");
}
