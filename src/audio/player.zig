const std = @import("std");
const c = @import("../c.zig");

const log = std.log.scoped(.audio);

pub const State = enum {
    stopped,
    playing,
    paused,
};

pub const Player = struct {
    allocator: std.mem.Allocator,
    engine: c.ma.ma_engine = undefined,
    sound: ?*c.ma.ma_sound = null,
    next_sound: ?*c.ma.ma_sound = null,
    state: State = .stopped,
    initialized: bool = false,
    normalize: bool = true,

    current_track_name: ?[]const u8 = null,
    current_artist: ?[]const u8 = null,
    current_album: ?[]const u8 = null,

    pub fn create(allocator: std.mem.Allocator) !*Player {
        const self = try allocator.create(Player);
        self.* = .{ .allocator = allocator };

        var config = c.ma.ma_engine_config_init();
        config.channels = 2;
        config.sampleRate = 48000;

        const result = c.ma.ma_engine_init(&config, &self.engine);
        if (result != c.ma.MA_SUCCESS) {
            log.err("failed to init audio engine: {d}", .{result});
            allocator.destroy(self);
            return error.AudioInitFailed;
        }
        self.initialized = true;
        log.info("audio engine ready", .{});
        return self;
    }

    pub fn destroy(self: *Player, allocator: std.mem.Allocator) void {
        self.stop();
        self.freeNextSound();
        if (self.initialized) {
            c.ma.ma_engine_uninit(&self.engine);
        }
        allocator.destroy(self);
    }

    pub fn playFile(self: *Player, path: [*:0]const u8) void {
        if (!self.initialized) return;
        self.stop();

        // Check if next_sound was preloaded for this path
        // (caller should have called preloadNext before)
        if (self.next_sound) |ns| {
            self.sound = ns;
            self.next_sound = null;
            const start = c.ma.ma_sound_start(self.sound.?);
            if (start != c.ma.MA_SUCCESS) {
                log.err("failed to start preloaded sound: {d}", .{start});
                self.freeSound();
                return;
            }
            self.state = .playing;
            log.info("playing (preloaded)", .{});
            return;
        }

        // Cold start - init from file
        self.sound = self.initSoundFromFile(path);
        if (self.sound == null) return;

        const start = c.ma.ma_sound_start(self.sound.?);
        if (start != c.ma.MA_SUCCESS) {
            log.err("failed to start: {d}", .{start});
            self.freeSound();
            return;
        }

        self.state = .playing;
        log.info("playing", .{});
    }

    // Schedule the next track to start at the exact frame the current one ends.
    // Both sounds use absolute engine time, so the transition is sample-accurate.
    pub fn preloadNext(self: *Player, path: [*:0]const u8) void {
        if (!self.initialized) return;
        // Don't schedule while paused - engine time drifts from sound cursor
        if (self.state != .playing) return;
        self.freeNextSound();

        const current = self.sound orelse return;

        self.next_sound = self.initSoundDecoded(path);
        const ns = self.next_sound orelse return;

        // Get current sound's length and how far we've played
        var sound_length: u64 = 0;
        _ = c.ma.ma_sound_get_length_in_pcm_frames(current, &sound_length);

        // ma_sound uses absolute engine time internally.
        // Get the time the current sound started (its absolute start time)
        // and add its total length to find when it ends.
        const engine_time = c.ma.ma_engine_get_time_in_pcm_frames(&self.engine);
        var cursor: u64 = 0;
        _ = c.ma.ma_sound_get_cursor_in_pcm_frames(current, &cursor);

        // Absolute time when current track ends = now + remaining frames
        const remaining = if (sound_length > cursor) sound_length - cursor else 0;
        const end_time = engine_time + remaining;

        // Schedule next sound to start at that exact frame
        c.ma.ma_sound_set_start_time_in_pcm_frames(ns, end_time);
        // Also schedule current to stop at the same time (clean cutoff)
        c.ma.ma_sound_set_stop_time_in_pcm_frames(current, end_time);

        // Start the next sound now - it won't actually produce audio until end_time
        const result = c.ma.ma_sound_start(ns);
        if (result != c.ma.MA_SUCCESS) {
            log.err("failed to schedule next sound: {d}", .{result});
            self.freeNextSound();
            return;
        }

        log.info("next track scheduled: {d} frames from now", .{remaining});
    }

    // Called by UI poll when current track has ended.
    // The next sound is already playing (was scheduled), just swap the pointers.
    pub fn advanceGapless(self: *Player) bool {
        const ns = self.next_sound orelse return false;

        // Current has ended, next is already producing audio
        if (self.sound) |s| {
            c.ma.ma_sound_uninit(s);
            self.allocator.destroy(s);
        }

        self.sound = ns;
        self.next_sound = null;
        self.state = .playing;
        log.info("gapless advance (swap)", .{});
        return true;
    }

    pub fn togglePause(self: *Player) void {
        const s = self.sound orelse return;
        switch (self.state) {
            .playing => {
                // Cancel any scheduled stop/next before pausing
                self.cancelScheduled();
                _ = c.ma.ma_sound_stop(s);
                self.state = .paused;
            },
            .paused => {
                _ = c.ma.ma_sound_start(s);
                self.state = .playing;
            },
            .stopped => {},
        }
    }

    pub fn stop(self: *Player) void {
        self.cancelScheduled();
        self.freeSound();
        self.state = .stopped;
    }

    pub fn seek(self: *Player, fraction: f64) void {
        self.cancelScheduled();
        const s = self.sound orelse return;
        var length: u64 = 0;
        _ = c.ma.ma_sound_get_length_in_pcm_frames(s, &length);
        const target: u64 = @intFromFloat(@as(f64, @floatFromInt(length)) * @max(0.0, @min(1.0, fraction)));
        _ = c.ma.ma_sound_seek_to_pcm_frame(s, target);
    }

    pub fn isAtEnd(self: *Player) bool {
        const s = self.sound orelse return false;
        return c.ma.ma_sound_at_end(s) == c.ma.MA_TRUE;
    }

    // Check if the scheduled next sound has started playing
    // (the transition happened in the audio engine)
    pub fn nextHasStarted(self: *Player) bool {
        const ns = self.next_sound orelse return false;
        var cursor: u64 = 0;
        _ = c.ma.ma_sound_get_cursor_in_pcm_frames(ns, &cursor);
        return cursor > 0;
    }

    pub fn hasScheduledNext(self: *Player) bool {
        return self.next_sound != null;
    }

    pub fn getProgress(self: *Player) ?f32 {
        const s = self.sound orelse return null;
        var cursor: f32 = 0;
        var length: f32 = 0;
        _ = c.ma.ma_sound_get_cursor_in_seconds(s, &cursor);
        _ = c.ma.ma_sound_get_length_in_seconds(s, &length);
        if (length <= 0) return null;
        return cursor / length;
    }

    pub fn getCursorSeconds(self: *Player) f32 {
        const s = self.sound orelse return 0;
        var cursor: f32 = 0;
        _ = c.ma.ma_sound_get_cursor_in_seconds(s, &cursor);
        return cursor;
    }

    pub fn getLengthSeconds(self: *Player) f32 {
        const s = self.sound orelse return 0;
        var length: f32 = 0;
        _ = c.ma.ma_sound_get_length_in_seconds(s, &length);
        return length;
    }

    fn initSoundFromFile(self: *Player, path: [*:0]const u8) ?*c.ma.ma_sound {
        return self.initSoundFromFileFlags(path, c.ma.MA_SOUND_FLAG_NO_SPATIALIZATION);
    }

    fn initSoundDecoded(self: *Player, path: [*:0]const u8) ?*c.ma.ma_sound {
        // Pre-decode entire file into memory for zero-latency start
        return self.initSoundFromFileFlags(path, c.ma.MA_SOUND_FLAG_NO_SPATIALIZATION | c.ma.MA_SOUND_FLAG_DECODE);
    }

    fn initSoundFromFileFlags(self: *Player, path: [*:0]const u8, flags: u32) ?*c.ma.ma_sound {
        const sound = self.allocator.create(c.ma.ma_sound) catch return null;

        const result = c.ma.ma_sound_init_from_file(
            &self.engine,
            path,
            flags,
            null,
            null,
            sound,
        );
        if (result != c.ma.MA_SUCCESS) {
            log.err("failed to load sound: {d}", .{result});
            self.allocator.destroy(sound);
            return null;
        }

        if (self.normalize) {
            const gain = computeNormGain(path);
            if (gain != 1.0) {
                c.ma.ma_sound_set_volume(sound, gain);
                log.info("normalization gain: {d:.2}", .{gain});
            }
        }

        return sound;
    }

    // Scan file for peak amplitude and compute gain to normalize to target level.
    // Uses a separate decoder to avoid interfering with playback.
    fn computeNormGain(path: [*:0]const u8) f32 {
        const target_peak: f32 = 0.5; // ~-6dB, leaves headroom

        var decoder: c.ma.ma_decoder = undefined;
        if (c.ma.ma_decoder_init_file(path, null, &decoder) != c.ma.MA_SUCCESS) return 1.0;
        defer _ = c.ma.ma_decoder_uninit(&decoder);

        var peak: f32 = 0.0;
        var buf: [4096]f32 = undefined; // 2048 stereo frames
        const frames_per_read: u64 = buf.len / 2; // 2 channels

        // Sample first 30s max (at 48kHz = ~1.4M frames)
        const max_frames: u64 = 48000 * 30;
        var total_read: u64 = 0;

        while (total_read < max_frames) {
            var frames_read: u64 = 0;
            if (c.ma.ma_decoder_read_pcm_frames(&decoder, &buf, frames_per_read, &frames_read) != c.ma.MA_SUCCESS) break;
            if (frames_read == 0) break;

            const samples = buf[0 .. frames_read * 2];
            for (samples) |sample| {
                const abs = @abs(sample);
                if (abs > peak) peak = abs;
            }
            total_read += frames_read;
        }

        if (peak < 0.001) return 1.0; // silence
        if (peak >= target_peak) return target_peak / peak;
        return 1.0; // already quieter than target
    }

    fn cancelScheduled(self: *Player) void {
        // Stop and free the scheduled next sound
        self.freeNextSound();
        // Clear the stop time on current sound so it doesn't auto-stop
        if (self.sound) |s| {
            c.ma.ma_sound_set_stop_time_in_pcm_frames(s, @as(u64, std.math.maxInt(u64)));
        }
    }

    fn freeSound(self: *Player) void {
        if (self.sound) |s| {
            _ = c.ma.ma_sound_stop(s);
            c.ma.ma_sound_uninit(s);
            self.allocator.destroy(s);
            self.sound = null;
        }
    }

    fn freeNextSound(self: *Player) void {
        if (self.next_sound) |s| {
            _ = c.ma.ma_sound_stop(s);
            c.ma.ma_sound_uninit(s);
            self.allocator.destroy(s);
            self.next_sound = null;
        }
    }
};
