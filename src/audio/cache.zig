const std = @import("std");
const log = std.log.scoped(.audio_cache);

// Persistent LRU audio cache on disk.
// Stores downloaded tracks in ~/.cache/jmusic/audio/{track_id}
// Evicts oldest files when total size exceeds the limit.

pub const DiskCache = struct {
    dir_path: []const u8,
    max_bytes: u64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, max_mb: u32) DiskCache {
        const xdg = std.posix.getenv("XDG_CACHE_HOME");
        const home = std.posix.getenv("HOME") orelse "/tmp";
        const base = xdg orelse home;
        const suffix = if (xdg != null) "/jmusic/audio" else "/.cache/jmusic/audio";

        var buf: [280]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}{s}", .{ base, suffix }) catch "/tmp/jmusic_audio";
        const duped = allocator.dupe(u8, path) catch "/tmp/jmusic_audio";

        // Ensure directory exists
        ensureDir(duped);

        return .{
            .dir_path = duped,
            .max_bytes = @as(u64, max_mb) * 1024 * 1024,
            .allocator = allocator,
        };
    }

    // Get the path for a cached track. Returns null if not cached.
    pub fn getPath(self: *DiskCache, track_id: []const u8, buf: *[320]u8) ?[]const u8 {
        const path = std.fmt.bufPrint(buf, "{s}/{s}", .{ self.dir_path, track_id }) catch return null;
        // Check if file exists
        std.fs.accessAbsolute(path, .{}) catch return null;
        // Touch the file (update mtime for LRU)
        const file = std.fs.openFileAbsolute(path, .{ .mode = .write_only }) catch return path;
        file.close();
        return path;
    }

    // Get the path where a track should be written.
    pub fn putPath(self: *DiskCache, track_id: []const u8, buf: *[320]u8) ?[]const u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ self.dir_path, track_id }) catch null;
    }

    // Called after writing a file. Evicts old entries if over limit.
    pub fn evictIfNeeded(self: *DiskCache) void {
        var dir = std.fs.openDirAbsolute(self.dir_path, .{ .iterate = true }) catch return;
        defer dir.close();

        const Entry = struct {
            name: [64]u8,
            name_len: u8,
            size: u64,
            mtime: i128,
        };

        var entries: [2048]Entry = undefined;
        var count: usize = 0;
        var total_size: u64 = 0;

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (count >= entries.len) break;

            const stat = dir.statFile(entry.name) catch continue;
            var e = &entries[count];
            const len = @min(entry.name.len, 64);
            @memcpy(e.name[0..len], entry.name[0..len]);
            e.name_len = @intCast(len);
            e.size = stat.size;
            e.mtime = stat.mtime;
            total_size += stat.size;
            count += 1;
        }

        if (total_size <= self.max_bytes) return;

        // Sort by mtime ascending (oldest first)
        std.mem.sort(Entry, entries[0..count], {}, struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                return a.mtime < b.mtime;
            }
        }.lessThan);

        // Evict oldest until under limit
        var i: usize = 0;
        while (total_size > self.max_bytes and i < count) : (i += 1) {
            const e = entries[i];
            const name = e.name[0..e.name_len];
            dir.deleteFile(name) catch continue;
            total_size -= e.size;
            log.info("evicted {s} ({d} KB)", .{ name, e.size / 1024 });
        }
    }

    fn ensureDir(path: []const u8) void {
        std.fs.makeDirAbsolute(path) catch |err| switch (err) {
            error.PathAlreadyExists => return,
            error.FileNotFound => {
                // Parent missing - create it
                if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep| {
                    ensureDir(path[0..sep]);
                    std.fs.makeDirAbsolute(path) catch return;
                }
            },
            else => return,
        };
    }
};
