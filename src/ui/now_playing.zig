const std = @import("std");
const c = @import("../c.zig");
const helpers = @import("helpers.zig");
const playback = @import("playback.zig");
const queue = @import("queue.zig");
const sonos_ui = @import("sonos_ui.zig");
const lyrics = @import("lyrics.zig");

const gtk = c.gtk;
const App = @import("window.zig").App;
const g_signal_connect = helpers.g_signal_connect;

pub fn buildNowPlayingBar(self: *App) *gtk.GtkWidget {
    const bar = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(bar, "now-playing");

    const progress_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(progress_box, "np-progress");
    self.progress_scale = gtk.gtk_scale_new_with_range(gtk.GTK_ORIENTATION_HORIZONTAL, 0, 1, 0.001);
    gtk.gtk_scale_set_draw_value(@ptrCast(self.progress_scale), 0);
    gtk.gtk_widget_set_hexpand(self.progress_scale, 1);
    _ = g_signal_connect(self.progress_scale, "value-changed", &onProgressChanged, self);
    gtk.gtk_box_append(@ptrCast(progress_box), self.progress_scale);
    gtk.gtk_box_append(@ptrCast(bar), progress_box);

    const row = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_set_margin_start(row, 16);
    gtk.gtk_widget_set_margin_end(row, 16);
    gtk.gtk_widget_set_margin_top(row, 8);
    gtk.gtk_widget_set_margin_bottom(row, 10);

    // Left: clickable art + track info
    const left = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_set_size_request(left, 260, -1);

    const art_frame = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(art_frame, "np-art-placeholder");
    self.np_art = gtk.gtk_image_new_from_icon_name("audio-x-generic-symbolic");
    gtk.gtk_image_set_pixel_size(@ptrCast(self.np_art), 24);
    gtk.gtk_widget_set_size_request(self.np_art, 52, 52);
    gtk.gtk_box_append(@ptrCast(art_frame), self.np_art);
    gtk.gtk_box_append(@ptrCast(left), art_frame);

    const np_info = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 2);
    gtk.gtk_widget_set_valign(np_info, gtk.GTK_ALIGN_CENTER);
    self.np_title = gtk.gtk_label_new("Nothing playing");
    gtk.gtk_widget_add_css_class(self.np_title, "np-title");
    gtk.gtk_label_set_xalign(@ptrCast(self.np_title), 0);
    gtk.gtk_label_set_ellipsize(@ptrCast(self.np_title), 3);
    gtk.gtk_label_set_max_width_chars(@ptrCast(self.np_title), 28);
    gtk.gtk_box_append(@ptrCast(np_info), self.np_title);

    self.np_artist = gtk.gtk_label_new("");
    gtk.gtk_widget_add_css_class(self.np_artist, "np-artist");
    gtk.gtk_label_set_xalign(@ptrCast(self.np_artist), 0);
    gtk.gtk_label_set_ellipsize(@ptrCast(self.np_artist), 3);
    gtk.gtk_box_append(@ptrCast(np_info), self.np_artist);
    gtk.gtk_box_append(@ptrCast(left), np_info);

    const np_click_btn = gtk.gtk_button_new();
    gtk.gtk_widget_add_css_class(np_click_btn, "np-click-btn");
    gtk.gtk_button_set_has_frame(@ptrCast(np_click_btn), 0);
    gtk.gtk_button_set_child(@ptrCast(np_click_btn), left);
    _ = g_signal_connect(np_click_btn, "clicked", &onNpClicked, self);
    gtk.gtk_box_append(@ptrCast(row), np_click_btn);

    // Center: transport controls
    const center = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 16);
    gtk.gtk_widget_set_hexpand(center, 1);
    gtk.gtk_widget_set_halign(center, gtk.GTK_ALIGN_CENTER);

    self.shuffle_btn = gtk.gtk_button_new_from_icon_name("media-playlist-shuffle-symbolic");
    gtk.gtk_widget_add_css_class(self.shuffle_btn, "control-btn");
    _ = g_signal_connect(self.shuffle_btn, "clicked", &onShuffleToggle, self);
    gtk.gtk_box_append(@ptrCast(center), self.shuffle_btn);

    const prev_btn = gtk.gtk_button_new_from_icon_name("media-skip-backward-symbolic");
    gtk.gtk_widget_add_css_class(prev_btn, "control-btn");
    _ = g_signal_connect(prev_btn, "clicked", &onPrev, self);
    gtk.gtk_box_append(@ptrCast(center), prev_btn);

    self.play_btn = gtk.gtk_button_new_from_icon_name("media-playback-start-symbolic");
    gtk.gtk_widget_add_css_class(self.play_btn, "play-btn");
    gtk.gtk_widget_set_size_request(self.play_btn, 38, 38);
    gtk.gtk_widget_set_valign(self.play_btn, gtk.GTK_ALIGN_CENTER);
    gtk.gtk_widget_set_halign(self.play_btn, gtk.GTK_ALIGN_CENTER);
    gtk.gtk_widget_set_vexpand(self.play_btn, 0);
    gtk.gtk_widget_set_hexpand(self.play_btn, 0);
    gtk.gtk_box_append(@ptrCast(center), self.play_btn);

    const next_btn = gtk.gtk_button_new_from_icon_name("media-skip-forward-symbolic");
    gtk.gtk_widget_add_css_class(next_btn, "control-btn");
    _ = g_signal_connect(next_btn, "clicked", &onNext, self);
    gtk.gtk_box_append(@ptrCast(center), next_btn);

    self.repeat_btn = gtk.gtk_button_new_from_icon_name("media-playlist-repeat-symbolic");
    gtk.gtk_widget_add_css_class(self.repeat_btn, "control-btn");
    _ = g_signal_connect(self.repeat_btn, "clicked", &onRepeatToggle, self);
    gtk.gtk_box_append(@ptrCast(center), self.repeat_btn);

    gtk.gtk_box_append(@ptrCast(row), center);

    // Right: time + volume + queue toggle
    const right = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 6);
    gtk.gtk_widget_set_size_request(right, 280, -1);
    gtk.gtk_widget_set_halign(right, gtk.GTK_ALIGN_END);
    gtk.gtk_widget_set_valign(right, gtk.GTK_ALIGN_CENTER);

    self.time_current = gtk.gtk_label_new("0:00");
    gtk.gtk_widget_add_css_class(self.time_current, "time-label");
    gtk.gtk_box_append(@ptrCast(right), self.time_current);

    const sep = gtk.gtk_label_new("/");
    gtk.gtk_widget_add_css_class(sep, "time-label");
    gtk.gtk_box_append(@ptrCast(right), sep);

    self.time_total = gtk.gtk_label_new("0:00");
    gtk.gtk_widget_add_css_class(self.time_total, "time-label");
    gtk.gtk_box_append(@ptrCast(right), self.time_total);

    self.volume_btn = gtk.gtk_button_new_from_icon_name("audio-volume-high-symbolic");
    gtk.gtk_widget_add_css_class(self.volume_btn, "control-btn");
    _ = g_signal_connect(self.volume_btn, "clicked", &onVolumeMute, self);
    gtk.gtk_box_append(@ptrCast(right), self.volume_btn);

    self.volume_scale = gtk.gtk_scale_new_with_range(gtk.GTK_ORIENTATION_HORIZONTAL, 0, 1, 0.01);
    gtk.gtk_scale_set_draw_value(@ptrCast(self.volume_scale), 0);
    gtk.gtk_range_set_value(@ptrCast(self.volume_scale), self.config.volume orelse 1.0);
    gtk.gtk_widget_set_size_request(self.volume_scale, 80, -1);
    gtk.gtk_widget_add_css_class(self.volume_scale, "volume-scale");
    _ = g_signal_connect(self.volume_scale, "value-changed", &onVolumeChanged, self);
    gtk.gtk_box_append(@ptrCast(right), self.volume_scale);

    self.lyrics_btn = gtk.gtk_button_new_from_icon_name("accessories-dictionary-symbolic");
    gtk.gtk_widget_add_css_class(self.lyrics_btn, "control-btn");
    _ = g_signal_connect(self.lyrics_btn, "clicked", &lyrics.onToggleLyrics, self);
    gtk.gtk_box_append(@ptrCast(right), self.lyrics_btn);

    const speaker_btn = sonos_ui.buildSpeakerButton(self);
    gtk.gtk_box_append(@ptrCast(right), speaker_btn);

    self.queue_btn = gtk.gtk_button_new_from_icon_name("view-list-symbolic");
    gtk.gtk_widget_add_css_class(self.queue_btn, "control-btn");
    _ = g_signal_connect(self.queue_btn, "clicked", &queue.onToggleQueue, self);
    gtk.gtk_box_append(@ptrCast(right), self.queue_btn);

    gtk.gtk_box_append(@ptrCast(row), right);
    gtk.gtk_box_append(@ptrCast(bar), row);

    return bar;
}

fn onNpClicked(_: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data));
    if (self.playing_album_idx) |idx| {
        self.showAlbumDetail(idx);
    } else if (self.playing_playlist_id) |pl_id| {
        self.openPlaylistById(pl_id);
    }
}

pub fn onPlayPause(_: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data));
    self.doTogglePause();
}

fn onNext(_: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data));
    self.playNext();
}

fn onPrev(_: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data));
    self.playPrev();
}

fn onProgressChanged(_: *gtk.GtkRange, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data));
    if (self.updating_progress) return;
    const val = gtk.gtk_range_get_value(@ptrCast(self.progress_scale));

    if (self.sonos_active) |idx| {
        const secs: u32 = @intFromFloat(val * @as(f64, @floatFromInt(self.sonos_duration_secs)));
        if (self.sonos_client) |sc| {
            sc.seek(self.sonos_speakers[idx].ip(), secs) catch {};
        }
        self.sonos_position_secs = secs;
        self.sonos_sub_secs = 0;
        return;
    }

    const p = self.player orelse return;
    p.seek(val);
    playback.preloadNextTrack(self);
}

fn onShuffleToggle(_: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data));
    self.shuffle = !self.shuffle;

    if (self.shuffle) {
        gtk.gtk_widget_add_css_class(self.shuffle_btn, "control-active");
        self.shuffleQueue();
    } else {
        gtk.gtk_widget_remove_css_class(self.shuffle_btn, "control-active");
    }
    self.refreshQueueIfVisible();
}

fn onRepeatToggle(_: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data));
    self.repeat = switch (self.repeat) {
        .off => .all,
        .all => .one,
        .one => .off,
    };
    switch (self.repeat) {
        .off => {
            gtk.gtk_widget_remove_css_class(self.repeat_btn, "control-active");
            gtk.gtk_button_set_icon_name(@ptrCast(self.repeat_btn), "media-playlist-repeat-symbolic");
        },
        .all => {
            gtk.gtk_widget_add_css_class(self.repeat_btn, "control-active");
            gtk.gtk_button_set_icon_name(@ptrCast(self.repeat_btn), "media-playlist-repeat-symbolic");
        },
        .one => {
            gtk.gtk_widget_add_css_class(self.repeat_btn, "control-active");
            gtk.gtk_button_set_icon_name(@ptrCast(self.repeat_btn), "media-playlist-repeat-song-symbolic");
        },
    }
}

fn onVolumeChanged(_: *gtk.GtkRange, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data));
    if (self.updating_volume) return;
    const vol: f64 = gtk.gtk_range_get_value(@ptrCast(self.volume_scale));

    if (self.sonos_active) |idx| {
        const sonos_vol: u8 = @intFromFloat(@min(100.0, vol * 100));
        if (self.sonos_client) |sc| {
            sc.setVolume(self.sonos_speakers[idx].ip(), sonos_vol) catch {};
        }
    } else {
        const p = self.player orelse return;
        if (!p.initialized) return;
        _ = c.ma.ma_engine_set_volume(&p.engine, @floatCast(vol));
    }

    const icon = if (vol < 0.01)
        "audio-volume-muted-symbolic"
    else if (vol < 0.33)
        "audio-volume-low-symbolic"
    else if (vol < 0.66)
        "audio-volume-medium-symbolic"
    else
        "audio-volume-high-symbolic";
    gtk.gtk_button_set_icon_name(@ptrCast(self.volume_btn), icon);
}

fn onVolumeMute(_: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data));
    const current = gtk.gtk_range_get_value(@ptrCast(self.volume_scale));
    if (current > 0.01) {
        gtk.g_object_set_data(@ptrCast(self.volume_btn), "prev-vol",
            @ptrFromInt(@as(usize, @intFromFloat(current * 100))));
        gtk.gtk_range_set_value(@ptrCast(self.volume_scale), 0);
    } else {
        const prev = @intFromPtr(gtk.g_object_get_data(@ptrCast(self.volume_btn), "prev-vol"));
        const restore: f64 = if (prev > 0) @as(f64, @floatFromInt(prev)) / 100.0 else 1.0;
        gtk.gtk_range_set_value(@ptrCast(self.volume_scale), restore);
    }
}
