const std = @import("std");
const c = @import("../c.zig");
const api = @import("../jellyfin/api.zig");
const models = @import("../jellyfin/models.zig");
const mpris = @import("mpris.zig");
const bg = @import("bg.zig");
const art = @import("art.zig");
const lyrics = @import("lyrics.zig");
const helpers = @import("helpers.zig");

const log = std.log.scoped(.playback);
const gtk = c.gtk;

const App = @import("window.zig").App;
const AudioCache = @import("window.zig").AudioCache;

pub fn playTrack(self: *App, index: usize) void {
    const tracks = self.tracks orelse return;
    if (index >= tracks.items.len) return;
    const track = tracks.items[index];

    // Bump generation to cancel stale async downloads
    _ = self.play_generation.fetchAdd(1, .release);

    self.playing_album_idx = self.current_album_idx;
    self.playing_playlist_id = self.current_playlist_id;

    // Sonos mode: send stream URL directly to speaker
    if (self.sonos_active) |active_idx| {
        const sc = self.sonos_client orelse return;
        const stream_url = self.client.getStreamUrl(track.id) catch return;
        defer self.allocator.free(stream_url);
        const ip = self.sonos_speakers[active_idx].ip();
        sc.setTransportUri(ip, stream_url, track.name, track.album_artist orelse track.album orelse "") catch return;
        sc.play(ip) catch return;
        self.sonos_playing = true;
        self.sonos_track_ended = false;
        self.sonos_position_secs = 0;
        // Use Jellyfin metadata for duration since Sonos reports 0 for streams
        self.sonos_duration_secs = if (track.durationSeconds()) |d| @intFromFloat(d) else 0;
        self.sonos_sub_secs = 0;
        self.sonos_poll_counter = 0;
        updateNowPlaying(self, track);
        gtk.gtk_button_set_icon_name(@ptrCast(self.play_btn), "media-playback-pause-symbolic");
        mpris.notifyPropertyChanged("PlaybackStatus");
        mpris.notifyPropertyChanged("Metadata");
        return;
    }

    const p = self.player orelse return;
    const gen = self.play_generation.load(.acquire);

    if (self.audio_cache.findSlot(track.id)) |slot| {
        var buf: [64]u8 = undefined;
        p.playFile(AudioCache.tempPath(&buf, slot));
        if (self.resume_seek) |frac| {
            self.resume_seek = null;
            p.seek(frac);
        }
        updateNowPlaying(self, track);
        prefetchAhead(self, index);
        preloadNextTrack(self);
    } else if (blk: {
        var dbuf: [320]u8 = undefined;
        break :blk self.disk_audio_cache.getPath(track.id, &dbuf);
    }) |disk_path| {
        const slot = self.audio_cache.allocSlot();
        var tbuf: [64]u8 = undefined;
        const tmp_path = AudioCache.tempPathSlice(&tbuf, slot);
        std.fs.copyFileAbsolute(disk_path, tmp_path, .{}) catch {
            startAsyncDownload(self, track, gen, index);
            return;
        };
        self.audio_cache.markReady(slot, track.id);
        var pbuf: [64]u8 = undefined;
        p.playFile(AudioCache.tempPath(&pbuf, slot));
        if (self.resume_seek) |frac| {
            self.resume_seek = null;
            p.seek(frac);
        }
        updateNowPlaying(self, track);
        prefetchAhead(self, index);
        preloadNextTrack(self);
    } else {
        startAsyncDownload(self, track, gen, index);
    }
}

pub fn startAsyncDownload(self: *App, track: models.BaseItem, gen: u32, index: usize) void {
    helpers.setLabelText(self.np_title, "Loading...");
    helpers.setLabelText(self.np_artist, "");

    const slot = self.audio_cache.allocSlot();
    const url = self.client.getStreamUrl(track.id) catch return;
    bg.run(self.allocator, self.client, struct {
        app: *App,
        url: []const u8,
        slot: usize,
        track_id: []const u8,
        track_name: []const u8,
        track_artist: ?[]const u8,
        track_album: ?[]const u8,
        gen: u32,
        index: usize,
        alloc: std.mem.Allocator,
        ok: bool = false,

        pub fn work(s: *@This(), client: *api.Client) void {
            var path_buf: [64]u8 = undefined;
            client.downloadToFile(s.url, AudioCache.tempPathSlice(&path_buf, s.slot)) catch return;
            s.ok = true;
        }

        pub fn done(s: *@This()) void {
            defer s.alloc.free(s.url);
            if (s.gen != s.app.play_generation.load(.acquire)) return;
            if (!s.ok) {
                helpers.setLabelText(s.app.np_title, "Download failed");
                gtk.gtk_button_set_icon_name(@ptrCast(s.app.play_btn), "media-playback-start-symbolic");
                return;
            }
            s.app.audio_cache.markReady(s.slot, s.track_id);

            // Copy to persistent disk cache
            var tmp_buf: [64]u8 = undefined;
            const tmp_src = AudioCache.tempPathSlice(&tmp_buf, s.slot);
            var disk_buf: [320]u8 = undefined;
            if (s.app.disk_audio_cache.putPath(s.track_id, &disk_buf)) |dest| {
                std.fs.copyFileAbsolute(tmp_src, dest, .{}) catch {};
                s.app.disk_audio_cache.evictIfNeeded();
            }

            const p2 = s.app.player orelse return;
            var z_buf: [64]u8 = undefined;
            p2.playFile(AudioCache.tempPath(&z_buf, s.slot));
            if (s.app.resume_seek) |frac| {
                s.app.resume_seek = null;
                p2.seek(frac);
            }
            p2.current_track_name = s.track_name;
            p2.current_artist = s.track_artist;
            p2.current_album = s.track_album;
            helpers.setLabelText(s.app.np_title, s.track_name);
            helpers.setLabelText(s.app.np_artist, s.track_artist orelse "");
            gtk.gtk_button_set_icon_name(@ptrCast(s.app.play_btn), "media-playback-pause-symbolic");
            s.app.highlightCurrentTrack();
            mpris.notifyPropertyChanged("PlaybackStatus");
            mpris.notifyPropertyChanged("Metadata");
            prefetchAhead(s.app, s.index);
            preloadNextTrack(s.app);
            s.app.refreshQueueIfVisible();
        }
    }{ .app = self, .url = url, .slot = slot, .track_id = track.id,
       .track_name = track.name, .track_artist = track.album_artist orelse track.album,
       .track_album = track.album, .gen = gen, .index = index, .alloc = self.allocator });
}

pub fn updateNowPlaying(self: *App, track: models.BaseItem) void {
    const p = self.player orelse return;
    p.current_track_name = track.name;
    p.current_artist = track.album_artist orelse track.album;
    p.current_album = track.album;

    helpers.setLabelText(self.np_title, track.name);
    helpers.setLabelText(self.np_artist, p.current_artist orelse "");
    gtk.gtk_button_set_icon_name(@ptrCast(self.play_btn), "media-playback-pause-symbolic");

    if (self.current_album_idx) |idx| {
        const albums = self.albums orelse return;
        if (idx < albums.items.len) {
            loadNpArt(self, albums.items[idx].id);
        }
    }

    self.highlightCurrentTrack();
    mpris.notifyPropertyChanged("PlaybackStatus");
    mpris.notifyPropertyChanged("Metadata");

    // Lyrics
    const dur_f64: f64 = track.durationSeconds() orelse 0;
    lyrics.fetchLyrics(self, track.name, track.album_artist orelse track.album orelse "", dur_f64);

    // Scrobble
    if (self.scrobbler_initialized) {
        const dur_secs: u32 = if (track.durationSeconds()) |d| @intFromFloat(d) else 0;
        self.scrobbler.nowPlaying(
            track.name,
            track.album_artist orelse track.album orelse "",
            track.album orelse "",
            dur_secs,
        );
    }

    // Discord Rich Presence
    const dur: ?u32 = if (track.durationSeconds()) |d| @intFromFloat(d) else null;
    self.discord_rpc.setActivity(
        track.name,
        track.album_artist orelse track.album orelse "",
        track.album orelse "",
        dur,
    );

    self.refreshQueueIfVisible();
}

pub fn preloadNextTrack(self: *App) void {
    const p = self.player orelse return;
    const queue = self.track_queue orelse return;
    if (self.queue_index + 1 >= queue.len) return;

    const next_track = queue[self.queue_index + 1];

    if (self.audio_cache.findSlot(next_track.id)) |slot| {
        var buf: [64]u8 = undefined;
        const path = AudioCache.tempPath(&buf, slot);
        p.preloadNext(path);
    }
}

pub fn prefetchAhead(self: *App, current_index: usize) void {
    const queue = self.track_queue orelse return;
    const PREFETCH_AHEAD = @import("window.zig").PREFETCH_AHEAD;
    const end = @min(current_index + 1 + PREFETCH_AHEAD, queue.len);

    const PrefetchJob = struct { url: []const u8, slot: usize, track_id: []const u8 };
    var jobs = std.array_list.AlignedManaged(PrefetchJob, null).init(self.allocator);

    for (queue[current_index + 1 .. end]) |track| {
        if (self.audio_cache.findSlot(track.id) != null) continue;

        const slot = self.audio_cache.allocSlot();
        const url = self.client.getStreamUrl(track.id) catch continue;
        jobs.append(.{ .url = url, .slot = slot, .track_id = track.id }) catch {
            self.allocator.free(url);
            continue;
        };
    }

    if (jobs.items.len == 0) {
        jobs.deinit();
        return;
    }

    const Ctx = struct {
        app: *App,
        base_url: []const u8,
        token: ?[]const u8,
        user_id: ?[]const u8,
        alloc: std.mem.Allocator,
        jobs: std.array_list.AlignedManaged(PrefetchJob, null),
    };
    const ctx = self.allocator.create(Ctx) catch {
        for (jobs.items) |j| self.allocator.free(j.url);
        jobs.deinit();
        return;
    };
    ctx.* = .{
        .app = self,
        .base_url = self.client.base_url,
        .token = self.client.token,
        .user_id = self.client.user_id,
        .alloc = self.allocator,
        .jobs = jobs,
    };

    const thread = std.Thread.spawn(.{}, prefetchThread, .{ctx}) catch {
        for (jobs.items) |j| self.allocator.free(j.url);
        jobs.deinit();
        self.allocator.destroy(ctx);
        return;
    };
    thread.detach();
}

fn prefetchThread(ctx: anytype) void {
    var client = api.Client.init(ctx.alloc, ctx.base_url);
    defer client.deinit();
    client.token = ctx.token;
    client.user_id = ctx.user_id;

    defer {
        for (ctx.jobs.items) |j| ctx.alloc.free(j.url);
        ctx.jobs.deinit();
        ctx.alloc.destroy(ctx);
    }

    for (ctx.jobs.items) |job| {
        var path_buf: [64]u8 = undefined;
        const path_slice = AudioCache.tempPathSlice(&path_buf, job.slot);

        // Check persistent disk cache first
        var disk_check: [320]u8 = undefined;
        if (ctx.app.disk_audio_cache.getPath(job.track_id, &disk_check)) |disk_path| {
            std.fs.copyFileAbsolute(disk_path, path_slice, .{}) catch {
                client.downloadToFile(job.url, path_slice) catch continue;
            };
        } else {
            client.downloadToFile(job.url, path_slice) catch |err| {
                log.warn("prefetch failed: {}", .{err});
                continue;
            };
        }

        ctx.app.audio_cache.markReady(job.slot, job.track_id);

        // Copy to persistent disk cache
        var disk_buf: [320]u8 = undefined;
        if (ctx.app.disk_audio_cache.putPath(job.track_id, &disk_buf)) |dest| {
            std.fs.copyFileAbsolute(path_slice, dest, .{}) catch {};
        }
    }
    ctx.app.disk_audio_cache.evictIfNeeded();
    _ = gtk.g_idle_add(&onPrefetchDone, ctx.app);
}

fn onPrefetchDone(data: ?*anyopaque) callconv(.c) c_int {
    const self: *App = @ptrCast(@alignCast(data));
    preloadNextTrack(self);
    return 0;
}

pub fn loadNpArt(self: *App, album_id: []const u8) void {
    const id_z = std.fmt.allocPrintSentinel(self.allocator, "{s}", .{album_id}, 0) catch return;
    bg.run(self.allocator, self.client, struct {
        app: *App,
        id: [:0]u8,
        alloc: std.mem.Allocator,
        data: ?[]const u8 = null,

        pub fn work(s: *@This(), client: *api.Client) void {
            s.data = art.loadCachedArt(s.alloc, s.id) orelse blk: {
                const url = client.getImageUrl(s.id, 120) catch return;
                defer s.alloc.free(url);
                const d = client.fetchBytes(url) catch return;
                art.saveCachedArt(s.id, d);
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
            if (texture == null) return;

            const parent = gtk.gtk_widget_get_parent(s.app.np_art);
            if (parent != null) {
                const picture = gtk.gtk_picture_new_for_paintable(@ptrCast(texture));
                gtk.gtk_widget_set_size_request(picture, 52, 52);
                gtk.gtk_picture_set_content_fit(@ptrCast(picture), gtk.GTK_CONTENT_FIT_COVER);
                const grandparent = gtk.gtk_widget_get_parent(parent);
                if (grandparent != null) {
                    gtk.gtk_box_remove(@ptrCast(grandparent), parent);
                    const new_frame = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);
                    gtk.gtk_widget_add_css_class(new_frame, "np-art-frame");
                    gtk.gtk_box_append(@ptrCast(new_frame), picture);
                    gtk.gtk_box_prepend(@ptrCast(grandparent), new_frame);
                    s.app.np_art = picture;
                }
            }
            gtk.g_object_unref(texture);
        }
    }{ .app = self, .id = id_z, .alloc = self.allocator });
}

pub fn playNext(self: *App) void {
    const queue = self.track_queue orelse return;
    if (self.queue_index + 1 < queue.len) {
        self.queue_index += 1;
        playQueueIndex(self);
    }
}

pub fn playPrev(self: *App) void {
    if (self.queue_index > 0) {
        self.queue_index -= 1;
        playQueueIndex(self);
    }
}

// Play whatever is at the current queue_index, looking up the track
// from track_queue (not tracks). Handles shuffle correctly.
fn playQueueIndex(self: *App) void {
    const queue = self.track_queue orelse return;
    if (self.queue_index >= queue.len) return;
    const track = queue[self.queue_index];

    // Find this track's index in self.tracks so playTrack works
    const tracks = self.tracks orelse return;
    for (tracks.items, 0..) |t, i| {
        if (std.mem.eql(u8, t.id, track.id)) {
            playTrack(self, i);
            return;
        }
    }
    // Track not in current tracks list (shouldn't happen normally)
    playTrack(self, self.queue_index);
}

pub fn doTogglePause(self: *App) void {
    if (self.sonos_active) |idx| {
        const sc = self.sonos_client orelse return;
        const ip = self.sonos_speakers[idx].ip();
        if (self.sonos_playing) {
            sc.pause(ip) catch {};
            self.sonos_playing = false;
        } else {
            sc.play(ip) catch {};
            self.sonos_playing = true;
        }
        const icon: [*:0]const u8 = if (self.sonos_playing) "media-playback-pause-symbolic" else "media-playback-start-symbolic";
        gtk.gtk_button_set_icon_name(@ptrCast(self.play_btn), icon);
        mpris.notifyPropertyChanged("PlaybackStatus");
        return;
    }

    const p = self.player orelse return;
    p.togglePause();
    const icon = switch (p.state) {
        .playing => "media-playback-pause-symbolic",
        .paused, .stopped => "media-playback-start-symbolic",
    };
    gtk.gtk_button_set_icon_name(@ptrCast(self.play_btn), icon);
    mpris.notifyPropertyChanged("PlaybackStatus");
    if (p.state == .playing) preloadNextTrack(self);
}

pub fn setQueue(self: *App, items: []const models.BaseItem, start_index: usize) void {
    if (self.track_queue_owned) {
        if (self.track_queue) |old| self.allocator.free(old);
    }
    self.track_queue = self.allocator.dupe(models.BaseItem, items) catch {
        self.track_queue = null;
        self.track_queue_owned = false;
        return;
    };
    self.track_queue_owned = true;
    self.queue_index = start_index;
    self.refreshQueueIfVisible();
}

pub fn shuffleQueue(self: *App) void {
    var queue = self.track_queue orelse return;
    if (queue.len <= 1) return;

    const current_idx = self.queue_index;
    var prng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
    const rand = prng.random();

    if (current_idx != 0) {
        const tmp = queue[0];
        queue[0] = queue[current_idx];
        queue[current_idx] = tmp;
        self.queue_index = 0;
    }

    var i: usize = queue.len - 1;
    while (i > 1) : (i -= 1) {
        const j = rand.intRangeAtMost(usize, 1, i);
        const tmp = queue[i];
        queue[i] = queue[j];
        queue[j] = tmp;
    }
}

pub fn insertNextInQueue(self: *App, track: models.BaseItem) void {
    var queue = self.track_queue orelse {
        setQueue(self, &.{track}, 0);
        return;
    };

    const insert_pos = self.queue_index + 1;
    const new_queue = self.allocator.alloc(models.BaseItem, queue.len + 1) catch return;
    @memcpy(new_queue[0..insert_pos], queue[0..insert_pos]);
    new_queue[insert_pos] = track;
    if (insert_pos < queue.len) {
        @memcpy(new_queue[insert_pos + 1 ..], queue[insert_pos..]);
    }

    if (self.track_queue_owned) self.allocator.free(queue);
    self.track_queue = new_queue;
    self.track_queue_owned = true;

    if (gtk.gtk_revealer_get_reveal_child(@ptrCast(self.queue_revealer)) != 0) {
        self.rebuildQueueList();
    }
}

pub fn checkTrackEnd(data: ?*anyopaque) callconv(.c) c_int {
    const self: *App = @ptrCast(@alignCast(data));

    // Sonos track end detection (set by transport state poll in updateProgress)
    if (self.sonos_active != null) {
        if (!self.sonos_track_ended) return 1;
        self.sonos_track_ended = false;

        const queue = self.track_queue orelse return 1;
        if (self.repeat == .one) {
            self.sonos_position_secs = 0;
            self.sonos_sub_secs = 0;
            if (self.sonos_active) |idx| {
                if (self.sonos_client) |sc| {
                    sc.seek(self.sonos_speakers[idx].ip(), 0) catch {};
                    sc.play(self.sonos_speakers[idx].ip()) catch {};
                }
            }
            return 1;
        }
        if (self.queue_index + 1 < queue.len) {
            self.queue_index += 1;
            _ = self.play_generation.fetchAdd(1, .release);
            playQueueIndex(self);
        } else if (self.repeat == .all) {
            self.queue_index = 0;
            _ = self.play_generation.fetchAdd(1, .release);
            playQueueIndex(self);
        } else {
            self.sonos_playing = false;
            gtk.gtk_button_set_icon_name(@ptrCast(self.play_btn), "media-playback-start-symbolic");
            mpris.notifyPropertyChanged("PlaybackStatus");
        }
        return 1;
    }

    const p = self.player orelse return 1;
    if (p.state != .playing) return 1;

    const need_advance = p.isAtEnd() or p.nextHasStarted();
    if (!need_advance) return 1;

    // Repeat one - restart the same track
    if (self.repeat == .one) {
        p.seek(0);
        _ = c.ma.ma_sound_start(p.sound.?);
        return 1;
    }

    const queue = self.track_queue orelse return 1;

    if (self.queue_index + 1 >= queue.len) {
        if (self.repeat == .all) {
            self.queue_index = 0;
            _ = self.play_generation.fetchAdd(1, .release);
            playQueueIndex(self);
            return 1;
        }
        if (p.isAtEnd() and !p.hasScheduledNext()) {
            p.state = .stopped;
            gtk.gtk_button_set_icon_name(@ptrCast(self.play_btn), "media-playback-start-symbolic");
            mpris.notifyPropertyChanged("PlaybackStatus");
        }
        return 1;
    }

    self.queue_index += 1;
    _ = self.play_generation.fetchAdd(1, .release);
    if (p.advanceGapless()) {
        const track = queue[self.queue_index];
        updateNowPlaying(self, track);
        preloadNextTrack(self);
    } else {
        playQueueIndex(self);
    }

    return 1;
}

pub fn updateProgress(data: ?*anyopaque) callconv(.c) c_int {
    const self: *App = @ptrCast(@alignCast(data));

    // Sonos progress polling
    if (self.sonos_active) |idx| {
        if (!self.sonos_playing) return 1;

        // Interpolate between polls (add 0.25s per 250ms tick)
        self.sonos_sub_secs += 0.25;
        if (self.sonos_sub_secs >= 1.0) {
            self.sonos_sub_secs -= 1.0;
            self.sonos_position_secs += 1;
        }

        // Poll Sonos every ~1 second (every 4th tick)
        self.sonos_poll_counter += 1;
        if (self.sonos_poll_counter >= 4) {
            self.sonos_poll_counter = 0;
            if (self.sonos_client) |sc| {
                if (sc.getPositionInfo(self.sonos_speakers[idx].ip())) |pos| {
                    self.sonos_position_secs = pos.position_secs;
                    // Sonos reports 0 duration for HTTP streams - keep Jellyfin value
                    if (pos.duration_secs > 0) self.sonos_duration_secs = pos.duration_secs;
                    self.sonos_sub_secs = 0;
                    // Detect track end via transport state
                    if (pos.transport_state == .stopped and self.sonos_playing) {
                        self.sonos_track_ended = true;
                    }
                } else |_| {}
            }
        }

        const pos_f: f32 = @floatFromInt(self.sonos_position_secs);
        const dur_f: f32 = @floatFromInt(self.sonos_duration_secs);
        const frac: f64 = if (dur_f > 0) @as(f64, pos_f + self.sonos_sub_secs) / @as(f64, dur_f) else 0;

        self.updating_progress = true;
        gtk.gtk_range_set_value(@ptrCast(self.progress_scale), frac);
        self.updating_progress = false;

        helpers.setTimeLabel(self.time_current, pos_f + self.sonos_sub_secs);
        helpers.setTimeLabel(self.time_total, dur_f);

        if (self.scrobbler_initialized) self.scrobbler.checkScrobble(self.sonos_position_secs);
        lyrics.updateLyricsHighlight(self, pos_f + self.sonos_sub_secs);
        return 1;
    }

    const p = self.player orelse return 1;

    if (p.state == .playing or p.state == .paused) {
        const cursor = p.getCursorSeconds();
        const length = p.getLengthSeconds();
        const frac: f64 = if (length > 0) @as(f64, cursor) / @as(f64, length) else 0;

        self.updating_progress = true;
        gtk.gtk_range_set_value(@ptrCast(self.progress_scale), frac);
        self.updating_progress = false;

        helpers.setTimeLabel(self.time_current, cursor);
        helpers.setTimeLabel(self.time_total, length);

        if (self.scrobbler_initialized and p.state == .playing) {
            self.scrobbler.checkScrobble(@intFromFloat(@max(0, cursor)));
        }
        lyrics.updateLyricsHighlight(self, cursor);
    }

    return 1;
}
