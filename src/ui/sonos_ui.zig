const std = @import("std");
const c = @import("../c.zig");
const sonos = @import("../sonos.zig");
const helpers = @import("helpers.zig");
const playback = @import("playback.zig");
const mpris = @import("mpris.zig");

const log = std.log.scoped(.sonos_ui);
const gtk = c.gtk;
const App = @import("window.zig").App;
const g_signal_connect = helpers.g_signal_connect;

pub fn buildSpeakerButton(self: *App) *gtk.GtkWidget {
    self.sonos_btn = gtk.gtk_button_new_from_icon_name("audio-speakers-symbolic");
    gtk.gtk_widget_add_css_class(self.sonos_btn, "control-btn");
    gtk.gtk_button_set_has_frame(@ptrCast(self.sonos_btn), 0);

    self.sonos_popover = gtk.gtk_popover_new();
    gtk.gtk_widget_add_css_class(self.sonos_popover, "speaker-popover");
    gtk.gtk_widget_set_parent(self.sonos_popover, self.sonos_btn);

    self.sonos_list = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_set_size_request(self.sonos_list, 220, -1);
    gtk.gtk_popover_set_child(@ptrCast(self.sonos_popover), self.sonos_list);

    _ = g_signal_connect(self.sonos_btn, "clicked", &onSpeakerBtnClicked, self);

    return self.sonos_btn;
}

fn onSpeakerBtnClicked(_: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data));
    rebuildSpeakerList(self);
    gtk.gtk_popover_popup(@ptrCast(self.sonos_popover));
}

fn rebuildSpeakerList(self: *App) void {
    helpers.clearChildren(self.sonos_list, .box);

    // "This Computer" row
    const local_btn = gtk.gtk_button_new();
    gtk.gtk_button_set_has_frame(@ptrCast(local_btn), 0);
    gtk.gtk_widget_add_css_class(local_btn, "speaker-row");

    const local_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_set_margin_start(local_box, 8);
    gtk.gtk_widget_set_margin_end(local_box, 8);
    gtk.gtk_widget_set_margin_top(local_box, 4);
    gtk.gtk_widget_set_margin_bottom(local_box, 4);

    const local_icon = gtk.gtk_image_new_from_icon_name("computer-symbolic");
    gtk.gtk_box_append(@ptrCast(local_box), local_icon);
    const local_label = gtk.gtk_label_new("This Computer");
    gtk.gtk_label_set_xalign(@ptrCast(local_label), 0);
    gtk.gtk_widget_set_hexpand(local_label, 1);
    gtk.gtk_box_append(@ptrCast(local_box), local_label);

    if (self.sonos_active == null) {
        const check = gtk.gtk_image_new_from_icon_name("object-select-symbolic");
        gtk.gtk_widget_add_css_class(check, "speaker-check");
        gtk.gtk_box_append(@ptrCast(local_box), check);
    }

    gtk.gtk_button_set_child(@ptrCast(local_btn), local_box);
    _ = g_signal_connect(local_btn, "clicked", &onSelectLocal, self);
    gtk.gtk_box_append(@ptrCast(self.sonos_list), local_btn);

    if (self.sonos_speaker_count == 0) return;

    const sep = gtk.gtk_separator_new(gtk.GTK_ORIENTATION_HORIZONTAL);
    gtk.gtk_widget_set_margin_top(sep, 4);
    gtk.gtk_widget_set_margin_bottom(sep, 4);
    gtk.gtk_box_append(@ptrCast(self.sonos_list), sep);

    for (0..self.sonos_speaker_count) |i| {
        const speaker = &self.sonos_speakers[i];
        const is_active = self.sonos_active != null and self.sonos_active.? == i;
        const is_grouped = self.sonos_grouped[i];

        const btn = gtk.gtk_button_new();
        gtk.gtk_button_set_has_frame(@ptrCast(btn), 0);
        gtk.gtk_widget_add_css_class(btn, "speaker-row");

        const row = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 8);
        gtk.gtk_widget_set_margin_start(row, 8);
        gtk.gtk_widget_set_margin_end(row, 8);
        gtk.gtk_widget_set_margin_top(row, 4);
        gtk.gtk_widget_set_margin_bottom(row, 4);

        const icon = gtk.gtk_image_new_from_icon_name("audio-speakers-symbolic");
        gtk.gtk_box_append(@ptrCast(row), icon);

        const label = helpers.makeLabel(self.allocator, speaker.room());
        gtk.gtk_label_set_xalign(@ptrCast(label), 0);
        gtk.gtk_widget_set_hexpand(label, 1);
        gtk.gtk_box_append(@ptrCast(row), label);

        if (is_active or is_grouped) {
            const check = gtk.gtk_image_new_from_icon_name("object-select-symbolic");
            gtk.gtk_widget_add_css_class(check, "speaker-check");
            gtk.gtk_box_append(@ptrCast(row), check);
        }

        gtk.gtk_button_set_child(@ptrCast(btn), row);
        gtk.g_object_set_data(@ptrCast(btn), "idx", @ptrFromInt(i + 1));
        _ = g_signal_connect(btn, "clicked", &onSelectSonos, self);
        gtk.gtk_box_append(@ptrCast(self.sonos_list), btn);
    }
}

fn onSelectLocal(_: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data));
    const was_playing = self.sonos_playing;

    if (self.sonos_active) |active_idx| {
        if (self.sonos_client) |sc| {
            sc.stopPlayback(self.sonos_speakers[active_idx].ip()) catch {};
            for (0..self.sonos_speaker_count) |i| {
                if (self.sonos_grouped[i]) {
                    sc.leaveGroup(self.sonos_speakers[i].ip()) catch {};
                }
            }
        }
    }

    self.sonos_active = null;
    self.sonos_playing = false;
    self.sonos_grouped = [_]bool{false} ** sonos.max_speakers;
    gtk.gtk_widget_remove_css_class(self.sonos_btn, "control-active");
    gtk.gtk_popover_popdown(@ptrCast(self.sonos_popover));

    // Resume current track locally at the same position
    if (was_playing) {
        const resume_secs = self.sonos_position_secs;
        const resume_dur = self.sonos_duration_secs;
        const queue = self.track_queue orelse return;
        if (self.queue_index < queue.len) {
            if (resume_secs > 0 and resume_dur > 0) {
                self.resume_seek = @as(f64, @floatFromInt(resume_secs)) / @as(f64, @floatFromInt(resume_dur));
            }
            playback.playTrack(self, self.queue_index);
        }
    }
}

fn onSelectSonos(btn: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data));
    const raw_idx = @intFromPtr(gtk.g_object_get_data(@ptrCast(btn), "idx"));
    if (raw_idx == 0) return;
    const idx: u8 = @intCast(raw_idx - 1);
    if (idx >= self.sonos_speaker_count) return;

    const sc = self.sonos_client orelse return;
    const speaker = &self.sonos_speakers[idx];

    if (self.sonos_active) |active_idx| {
        if (idx == active_idx) {
            // Clicking active speaker - switch back to local
            onSelectLocal(@ptrCast(btn), data);
            return;
        }

        // Toggle grouping
        if (self.sonos_grouped[idx]) {
            sc.leaveGroup(speaker.ip()) catch {};
            self.sonos_grouped[idx] = false;
        } else {
            const coord = self.sonos_speakers[active_idx].uuid();
            sc.joinGroup(speaker.ip(), coord) catch {};
            self.sonos_grouped[idx] = true;
        }
        rebuildSpeakerList(self);
        return;
    }

    // Switch to this Sonos speaker
    self.sonos_active = idx;
    gtk.gtk_widget_add_css_class(self.sonos_btn, "control-active");

    // If playing locally, transfer to Sonos
    const p = self.player orelse {
        gtk.gtk_popover_popdown(@ptrCast(self.sonos_popover));
        return;
    };

    if (p.state == .playing or p.state == .paused) {
        const queue = self.track_queue orelse {
            gtk.gtk_popover_popdown(@ptrCast(self.sonos_popover));
            return;
        };
        if (self.queue_index < queue.len) {
            const track = queue[self.queue_index];
            // Grab current position before stopping local player
            const local_secs: u32 = @intFromFloat(@max(0, p.getCursorSeconds()));
            p.stop();

            const stream_url = self.client.getStreamUrl(track.id) catch {
                gtk.gtk_popover_popdown(@ptrCast(self.sonos_popover));
                return;
            };
            defer self.allocator.free(stream_url);
            sc.setTransportUri(
                speaker.ip(),
                stream_url,
                track.name,
                track.album_artist orelse track.album orelse "",
            ) catch {};
            // Seek to where local playback was, then play
            if (local_secs > 0) sc.seek(speaker.ip(), local_secs) catch {};
            sc.play(speaker.ip()) catch {};
            self.sonos_playing = true;
            self.sonos_position_secs = local_secs;
            self.sonos_duration_secs = if (track.durationSeconds()) |d| @intFromFloat(d) else 0;
            self.sonos_sub_secs = 0;
            gtk.gtk_button_set_icon_name(@ptrCast(self.play_btn), "media-playback-pause-symbolic");
        }
    }

    // Sync volume slider with Sonos
    if (sc.getVolume(speaker.ip())) |vol| {
        self.updating_volume = true;
        gtk.gtk_range_set_value(@ptrCast(self.volume_scale), @as(f64, @floatFromInt(vol)) / 100.0);
        self.updating_volume = false;
    } else |_| {}

    gtk.gtk_popover_popdown(@ptrCast(self.sonos_popover));
}

pub fn startDiscovery(self: *App) void {
    var disc_client = sonos.Client.init(self.allocator);
    defer disc_client.deinit();
    self.sonos_speaker_count = disc_client.discover(&self.sonos_speakers);
    if (self.sonos_speaker_count > 0) {
        log.info("discovered {d} speakers", .{self.sonos_speaker_count});
    }
}
