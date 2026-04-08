const std = @import("std");
const c = @import("../c.zig");
const helpers = @import("helpers.zig");

const log = std.log.scoped(.settings);
const gtk = c.gtk;
const App = @import("window.zig").App;
const g_signal_connect = helpers.g_signal_connect;

var lastfm_auth_token: ?[]const u8 = null;
var lastfm_status_label: ?*gtk.GtkWidget = null;

pub fn buildSettingsPage(self: *App) *gtk.GtkWidget {
    const scroll = gtk.gtk_scrolled_window_new();
    gtk.gtk_widget_set_vexpand(scroll, 1);

    const page = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 16);
    gtk.gtk_widget_add_css_class(page, "settings-page");
    gtk.gtk_widget_set_margin_start(page, 40);
    gtk.gtk_widget_set_margin_end(page, 40);
    gtk.gtk_widget_set_margin_top(page, 32);
    gtk.gtk_widget_set_margin_bottom(page, 32);

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

    // -- Scrobbling --
    const scrobble_divider = gtk.gtk_separator_new(gtk.GTK_ORIENTATION_HORIZONTAL);
    gtk.gtk_widget_set_margin_top(scrobble_divider, 8);
    gtk.gtk_box_append(@ptrCast(page), scrobble_divider);

    const scrobble_title = gtk.gtk_label_new("Scrobbling");
    gtk.gtk_widget_add_css_class(scrobble_title, "settings-title");
    gtk.gtk_label_set_xalign(@ptrCast(scrobble_title), 0);
    gtk.gtk_box_append(@ptrCast(page), scrobble_title);

    // Last.fm
    const lastfm_row = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_set_valign(lastfm_row, gtk.GTK_ALIGN_CENTER);

    const lastfm_icon = gtk.gtk_label_new("Last.fm");
    gtk.gtk_widget_add_css_class(lastfm_icon, "settings-label");
    gtk.gtk_widget_set_size_request(lastfm_icon, 100, -1);
    gtk.gtk_box_append(@ptrCast(lastfm_row), lastfm_icon);

    const lastfm_status = gtk.gtk_label_new(if (self.config.lastfm_session_key != null) "Connected" else "Not connected");
    gtk.gtk_widget_add_css_class(lastfm_status, "settings-label");
    gtk.gtk_widget_set_hexpand(lastfm_status, 1);
    gtk.gtk_label_set_xalign(@ptrCast(lastfm_status), 0);
    if (self.config.lastfm_session_key != null) gtk.gtk_widget_add_css_class(lastfm_status, "control-active");
    lastfm_status_label = lastfm_status;
    gtk.gtk_box_append(@ptrCast(lastfm_row), lastfm_status);

    if (self.config.lastfm_session_key == null) {
        const connect_btn = gtk.gtk_button_new_with_label("Connect");
        gtk.gtk_widget_add_css_class(connect_btn, "settings-save-btn");
        _ = g_signal_connect(connect_btn, "clicked", &onLastfmConnect, self);
        gtk.gtk_box_append(@ptrCast(lastfm_row), connect_btn);
    }

    gtk.gtk_box_append(@ptrCast(page), lastfm_row);

    // ListenBrainz
    const lb_label = gtk.gtk_label_new("ListenBrainz Token");
    gtk.gtk_widget_add_css_class(lb_label, "settings-label");
    gtk.gtk_label_set_xalign(@ptrCast(lb_label), 0);
    gtk.gtk_box_append(@ptrCast(page), lb_label);

    self.settings_lb_token = gtk.gtk_entry_new();
    gtk.gtk_widget_add_css_class(self.settings_lb_token, "settings-entry");
    gtk.gtk_entry_set_placeholder_text(@ptrCast(self.settings_lb_token), "Paste token from listenbrainz.org/settings");
    if (self.config.listenbrainz_token) |tok| setEntryText(self.settings_lb_token, tok);
    gtk.gtk_box_append(@ptrCast(page), self.settings_lb_token);

    // Save
    const save_btn = gtk.gtk_button_new_with_label("Save");
    gtk.gtk_widget_add_css_class(save_btn, "settings-save-btn");
    gtk.gtk_widget_set_halign(save_btn, gtk.GTK_ALIGN_START);
    _ = g_signal_connect(save_btn, "clicked", &onSettingsSave, self);
    gtk.gtk_box_append(@ptrCast(page), save_btn);

    gtk.gtk_scrolled_window_set_child(@ptrCast(scroll), page);
    return scroll;
}

fn setEntryText(widget: *gtk.GtkWidget, text: []const u8) void {
    var buf: [256]u8 = undefined;
    const len = @min(text.len, buf.len - 1);
    @memcpy(buf[0..len], text[0..len]);
    buf[len] = 0;
    gtk.gtk_editable_set_text(@ptrCast(widget), @ptrCast(&buf));
}

fn onLastfmConnect(_: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data));
    if (!self.scrobbler_initialized) return;

    if (lastfm_auth_token != null) {
        // Step 2: user clicked again after authorizing in browser
        const session = self.scrobbler.lastfmGetSession(lastfm_auth_token.?) catch {
            if (lastfm_status_label) |lbl| helpers.setLabelText(lbl, "Auth failed - try again");
            lastfm_auth_token = null;
            return;
        };
        self.scrobbler.lastfm_session = session;
        if (lastfm_status_label) |lbl| {
            helpers.setLabelText(lbl, "Connected");
            gtk.gtk_widget_add_css_class(lbl, "control-active");
        }
        lastfm_auth_token = null;
        log.info("last.fm authenticated", .{});
        // Auto-save config
        saveConfig(self);
        return;
    }

    // Step 1: get token and open browser
    const token = self.scrobbler.lastfmGetToken() catch {
        if (lastfm_status_label) |lbl| helpers.setLabelText(lbl, "Failed to get token");
        return;
    };
    lastfm_auth_token = token;

    const api_key = self.config.lastfm_api_key orelse return;
    const auth_url = std.fmt.allocPrint(self.allocator, "https://www.last.fm/api/auth/?api_key={s}&token={s}", .{ api_key, token }) catch return;
    defer self.allocator.free(auth_url);

    const auth_url_z = std.fmt.allocPrintSentinel(self.allocator, "{s}", .{auth_url}, 0) catch return;
    defer self.allocator.free(auth_url_z);

    var child = std.process.Child.init(&.{ "xdg-open", auth_url_z }, self.allocator);
    _ = child.spawnAndWait() catch {};

    if (lastfm_status_label) |lbl| helpers.setLabelText(lbl, "Authorize in browser, then click Connect again");
}

pub fn saveConfig(self: *App) void {
    const home = std.posix.getenv("HOME") orelse return;
    const path = std.fmt.allocPrint(self.allocator, "{s}/.config/jmusic/config.json", .{home}) catch return;
    defer self.allocator.free(path);

    const server = std.mem.span(@as([*:0]const u8, @ptrCast(gtk.gtk_editable_get_text(@ptrCast(self.settings_server)))));
    const username = std.mem.span(@as([*:0]const u8, @ptrCast(gtk.gtk_editable_get_text(@ptrCast(self.settings_user)))));
    const password = std.mem.span(@as([*:0]const u8, @ptrCast(gtk.gtk_editable_get_text(@ptrCast(self.settings_pass)))));
    const lb_token = std.mem.span(@as([*:0]const u8, @ptrCast(gtk.gtk_editable_get_text(@ptrCast(self.settings_lb_token)))));
    const cache_mb: u32 = @intFromFloat(gtk.gtk_spin_button_get_value(@ptrCast(self.settings_cache)));

    var buf: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const w = stream.writer();

    const vol = gtk.gtk_range_get_value(@ptrCast(self.volume_scale));
    w.print("{{\"server\":\"{s}\",\"username\":\"{s}\",\"password\":\"{s}\",\"cache_size_mb\":{d},\"volume\":{d:.2}", .{ server, username, password, cache_mb, vol }) catch return;
    if (self.config.lastfm_api_key) |key| w.print(",\"lastfm_api_key\":\"{s}\"", .{key}) catch {};
    if (self.config.lastfm_secret) |sec| w.print(",\"lastfm_secret\":\"{s}\"", .{sec}) catch {};
    // Session key might be on config or scrobbler (if just authenticated)
    const session_key = if (self.scrobbler_initialized and self.scrobbler.lastfm_session != null)
        self.scrobbler.lastfm_session
    else
        self.config.lastfm_session_key;
    if (session_key) |sk| w.print(",\"lastfm_session_key\":\"{s}\"", .{sk}) catch {};
    if (lb_token.len > 0) w.print(",\"listenbrainz_token\":\"{s}\"", .{lb_token}) catch {};
    w.writeAll("}\n") catch return;

    const file = std.fs.createFileAbsolute(path, .{}) catch return;
    defer file.close();
    file.writeAll(stream.getWritten()) catch return;

    self.disk_audio_cache.max_bytes = @as(u64, cache_mb) * 1024 * 1024;
    self.disk_audio_cache.evictIfNeeded();
    log.info("config saved", .{});
}

pub fn onSettingsSave(_: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data));

    // Update listenbrainz token in scrobbler
    const lb_token = std.mem.span(@as([*:0]const u8, @ptrCast(gtk.gtk_editable_get_text(@ptrCast(self.settings_lb_token)))));
    if (lb_token.len > 0 and self.scrobbler_initialized) {
        self.scrobbler.listenbrainz_token = self.allocator.dupe(u8, lb_token) catch null;
    }

    saveConfig(self);
    self.navigateTo("home");
}
