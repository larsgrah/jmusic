const std = @import("std");

const log = std.log.scoped(.discord);

const CLIENT_ID = "1491384392956772423";

pub const RichPresence = struct {
    socket: ?std.posix.socket_t = null,
    nonce: u32 = 0,

    pub fn init() RichPresence {
        return .{};
    }

    pub fn deinit(self: *RichPresence) void {
        self.disconnect();
    }

    pub fn setActivity(self: *RichPresence, track: []const u8, artist: []const u8, album: []const u8, duration_secs: ?u32) void {
        if (self.socket == null) self.connect();
        if (self.socket == null) return;

        self.nonce += 1;
        var buf: [1024]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        const w = stream.writer();

        // Build timestamp if we have duration
        var ts_buf: [64]u8 = undefined;
        const ts = if (duration_secs) |dur| blk: {
            const now = @divTrunc(std.time.milliTimestamp(), 1000);
            break :blk std.fmt.bufPrint(&ts_buf,
                \\,"timestamps":{{"start":{d},"end":{d}}}
            , .{ now, now + dur }) catch "";
        } else "";

        w.print(
            \\{{"cmd":"SET_ACTIVITY","args":{{"pid":{d},"activity":{{"details":"
        , .{std.c.getpid()}) catch return;
        jsonEscape(w, track) catch return;
        w.writeAll(
            \\","state":"
        ) catch return;
        jsonEscape(w, artist) catch return;
        w.print(
            \\"{s},"assets":{{"large_text":"
        , .{ts}) catch return;
        jsonEscape(w, album) catch return;
        w.print(
            \\","large_image":"jmusic"}},"type":2}}}},"nonce":"{d}"}}
        , .{self.nonce}) catch return;

        const payload = stream.getWritten();
        self.send(1, payload) catch {
            self.disconnect();
        };
    }

    pub fn clearActivity(self: *RichPresence) void {
        if (self.socket == null) return;
        self.nonce += 1;

        var buf: [256]u8 = undefined;
        const payload = std.fmt.bufPrint(&buf,
            \\{{"cmd":"SET_ACTIVITY","args":{{"pid":{d}}},"nonce":"{d}"}}
        , .{ std.c.getpid(), self.nonce }) catch return;

        self.send(1, payload) catch {
            self.disconnect();
        };
    }

    fn connect(self: *RichPresence) void {
        const uid = std.posix.getenv("XDG_RUNTIME_DIR") orelse "/run/user/1000";

        // Try ipc-0 through ipc-9
        for (0..10) |i| {
            var path_buf: [128]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/discord-ipc-{d}", .{ uid, i }) catch continue;
            path_buf[path.len] = 0;

            const sock = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0) catch continue;

            var addr: std.posix.sockaddr.un = .{ .path = undefined };
            @memcpy(addr.path[0..path.len], path);
            addr.path[path.len] = 0;

            std.posix.connect(sock, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un)) catch {
                std.posix.close(sock);
                continue;
            };

            self.socket = sock;

            // Handshake
            var hs_buf: [64]u8 = undefined;
            const handshake = std.fmt.bufPrint(&hs_buf,
                \\{{"v":1,"client_id":"{s}"}}
            , .{CLIENT_ID}) catch {
                self.disconnect();
                return;
            };
            self.send(0, handshake) catch {
                self.disconnect();
                return;
            };

            // Read handshake response before sending commands
            self.drain();

            log.info("connected to discord-ipc-{d}", .{i});
            return;
        }
    }

    fn send(self: *RichPresence, opcode: u32, payload: []const u8) !void {
        const sock = self.socket orelse return error.NotConnected;
        const len: u32 = @intCast(payload.len);

        // Frame: opcode (u32 LE) + length (u32 LE) + payload
        var header: [8]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], opcode, .little);
        std.mem.writeInt(u32, header[4..8], len, .little);

        _ = std.posix.write(sock, &header) catch return error.WriteFailed;
        _ = std.posix.write(sock, payload) catch return error.WriteFailed;
    }

    fn drain(self: *RichPresence) void {
        const sock = self.socket orelse return;
        // Read frame header + body
        var header: [8]u8 = undefined;
        _ = std.posix.read(sock, &header) catch return;
        const len = std.mem.readInt(u32, header[4..8], .little);
        var discard: [4096]u8 = undefined;
        var remaining = len;
        while (remaining > 0) {
            const to_read = @min(remaining, discard.len);
            const n = std.posix.read(sock, discard[0..to_read]) catch return;
            if (n == 0) return;
            remaining -= @intCast(n);
        }
    }

    fn disconnect(self: *RichPresence) void {
        if (self.socket) |sock| {
            std.posix.close(sock);
            self.socket = null;
        }
    }
};

fn jsonEscape(writer: anytype, input: []const u8) !void {
    for (input) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            else => try writer.writeByte(ch),
        }
    }
}
