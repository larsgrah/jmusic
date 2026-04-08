const std = @import("std");

const log = std.log.scoped(.sonos);

pub const max_speakers = 32;

pub const Speaker = struct {
    ip_buf: [46]u8 = undefined,
    ip_len: u8 = 0,
    uuid_buf: [80]u8 = undefined,
    uuid_len: u8 = 0,
    room_buf: [128]u8 = undefined,
    room_len: u8 = 0,
    model_buf: [64]u8 = undefined,
    model_len: u8 = 0,

    pub fn ip(self: *const Speaker) []const u8 {
        return self.ip_buf[0..self.ip_len];
    }

    pub fn uuid(self: *const Speaker) []const u8 {
        return self.uuid_buf[0..self.uuid_len];
    }

    pub fn room(self: *const Speaker) []const u8 {
        return self.room_buf[0..self.room_len];
    }

    pub fn model(self: *const Speaker) []const u8 {
        return self.model_buf[0..self.model_len];
    }
};

pub const TransportState = enum { playing, paused, stopped, unknown };

pub const PositionInfo = struct {
    duration_secs: u32,
    position_secs: u32,
    transport_state: TransportState = .unknown,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    http: std.http.Client,

    pub fn init(allocator: std.mem.Allocator) Client {
        return .{
            .allocator = allocator,
            .http = .{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *Client) void {
        self.http.deinit();
    }

    // -- Discovery --

    pub fn discover(self: *Client, results: *[max_speakers]Speaker) u8 {
        const count = ssdpScan(results);
        for (results[0..count]) |*speaker| {
            self.fetchDescription(speaker) catch |err| {
                log.warn("failed to fetch description for {s}: {}", .{ speaker.ip(), err });
            };
        }
        return count;
    }

    fn fetchDescription(self: *Client, speaker: *Speaker) !void {
        var url_buf: [128]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "http://{s}:1400/xml/device_description.xml", .{speaker.ip()});

        const body = try self.httpGet(url);
        defer self.allocator.free(body);

        if (xmlTagValue(body, "roomName")) |room| {
            const len = @min(room.len, speaker.room_buf.len);
            @memcpy(speaker.room_buf[0..len], room[0..len]);
            speaker.room_len = @intCast(len);
        }
        if (xmlTagValue(body, "modelName")) |model_str| {
            const len = @min(model_str.len, speaker.model_buf.len);
            @memcpy(speaker.model_buf[0..len], model_str[0..len]);
            speaker.model_len = @intCast(len);
        }
        if (xmlTagValue(body, "UDN")) |udn| {
            // UDN is "uuid:RINCON_..." - strip the "uuid:" prefix
            const raw = if (std.mem.startsWith(u8, udn, "uuid:")) udn[5..] else udn;
            const len = @min(raw.len, speaker.uuid_buf.len);
            @memcpy(speaker.uuid_buf[0..len], raw[0..len]);
            speaker.uuid_len = @intCast(len);
        }
    }

    // -- Transport controls --

    pub fn setTransportUri(self: *Client, speaker_ip: []const u8, uri: []const u8, title: []const u8, artist: []const u8) !void {
        // Build DIDL-Lite metadata
        var meta_buf: [2048]u8 = undefined;
        var meta_stream = std.io.fixedBufferStream(&meta_buf);
        const mw = meta_stream.writer();
        try mw.writeAll("<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\" " ++
            "xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" " ++
            "xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\">" ++
            "<item id=\"1\" parentID=\"0\" restricted=\"1\">" ++
            "<dc:title>");
        try xmlEscapeWrite(mw, title);
        try mw.writeAll("</dc:title><dc:creator>");
        try xmlEscapeWrite(mw, artist);
        try mw.writeAll("</dc:creator>" ++
            "<upnp:class>object.item.audioItem.musicTrack</upnp:class>" ++
            "<res protocolInfo=\"http-get:*:audio/mpeg:*\">");
        try xmlEscapeWrite(mw, uri);
        try mw.writeAll("</res></item></DIDL-Lite>");
        const metadata = meta_stream.getWritten();

        // Build inner SOAP body with escaped URI and double-escaped metadata
        var inner_buf: [4096]u8 = undefined;
        var inner_stream = std.io.fixedBufferStream(&inner_buf);
        const iw = inner_stream.writer();
        try iw.writeAll("<InstanceID>0</InstanceID><CurrentURI>");
        try xmlEscapeWrite(iw, uri);
        try iw.writeAll("</CurrentURI><CurrentURIMetaData>");
        try xmlEscapeWrite(iw, metadata);
        try iw.writeAll("</CurrentURIMetaData>");

        const result = try self.soapAction(speaker_ip, av_transport_path, av_transport_svc, "SetAVTransportURI", inner_stream.getWritten());
        self.allocator.free(result);
    }

    pub fn play(self: *Client, speaker_ip: []const u8) !void {
        const result = try self.soapAction(speaker_ip, av_transport_path, av_transport_svc, "Play", "<InstanceID>0</InstanceID><Speed>1</Speed>");
        self.allocator.free(result);
    }

    pub fn pause(self: *Client, speaker_ip: []const u8) !void {
        const result = try self.soapAction(speaker_ip, av_transport_path, av_transport_svc, "Pause", "<InstanceID>0</InstanceID>");
        self.allocator.free(result);
    }

    pub fn stopPlayback(self: *Client, speaker_ip: []const u8) !void {
        const result = try self.soapAction(speaker_ip, av_transport_path, av_transport_svc, "Stop", "<InstanceID>0</InstanceID>");
        self.allocator.free(result);
    }

    pub fn seek(self: *Client, speaker_ip: []const u8, seconds: u32) !void {
        var time_buf: [16]u8 = undefined;
        const time_str = formatTime(&time_buf, seconds);
        var inner_buf: [128]u8 = undefined;
        const inner = try std.fmt.bufPrint(&inner_buf, "<InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>{s}</Target>", .{time_str});
        const result = try self.soapAction(speaker_ip, av_transport_path, av_transport_svc, "Seek", inner);
        self.allocator.free(result);
    }

    pub fn getPositionInfo(self: *Client, speaker_ip: []const u8) !PositionInfo {
        const result = try self.soapAction(speaker_ip, av_transport_path, av_transport_svc, "GetPositionInfo", "<InstanceID>0</InstanceID>");
        defer self.allocator.free(result);

        // Also get transport state to detect track end
        const state_result = self.soapAction(speaker_ip, av_transport_path, av_transport_svc, "GetTransportInfo", "<InstanceID>0</InstanceID>") catch null;
        defer if (state_result) |sr| self.allocator.free(sr);

        var state: TransportState = .unknown;
        if (state_result) |sr| {
            if (xmlTagValue(sr, "CurrentTransportState")) |s| {
                if (std.mem.eql(u8, s, "PLAYING")) state = .playing
                else if (std.mem.eql(u8, s, "PAUSED_PLAYBACK")) state = .paused
                else if (std.mem.eql(u8, s, "STOPPED")) state = .stopped;
            }
        }

        return .{
            .duration_secs = if (xmlTagValue(result, "TrackDuration")) |d| parseTime(d) orelse 0 else 0,
            .position_secs = if (xmlTagValue(result, "RelTime")) |t| parseTime(t) orelse 0 else 0,
            .transport_state = state,
        };
    }

    // -- Volume --

    pub fn getVolume(self: *Client, speaker_ip: []const u8) !u8 {
        const result = try self.soapAction(speaker_ip, rendering_path, rendering_svc, "GetVolume", "<InstanceID>0</InstanceID><Channel>Master</Channel>");
        defer self.allocator.free(result);
        const val_str = xmlTagValue(result, "CurrentVolume") orelse return error.ParseError;
        return std.fmt.parseInt(u8, val_str, 10) catch return error.ParseError;
    }

    pub fn setVolume(self: *Client, speaker_ip: []const u8, volume: u8) !void {
        var inner_buf: [128]u8 = undefined;
        const inner = try std.fmt.bufPrint(&inner_buf, "<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>{d}</DesiredVolume>", .{volume});
        const result = try self.soapAction(speaker_ip, rendering_path, rendering_svc, "SetVolume", inner);
        self.allocator.free(result);
    }

    // -- Grouping --

    pub fn joinGroup(self: *Client, speaker_ip: []const u8, coordinator_uuid: []const u8) !void {
        var uri_buf: [128]u8 = undefined;
        const rincon_uri = try std.fmt.bufPrint(&uri_buf, "x-rincon:{s}", .{coordinator_uuid});
        var inner_buf: [256]u8 = undefined;
        var stream = std.io.fixedBufferStream(&inner_buf);
        const w = stream.writer();
        try w.writeAll("<InstanceID>0</InstanceID><CurrentURI>");
        try xmlEscapeWrite(w, rincon_uri);
        try w.writeAll("</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>");
        const result = try self.soapAction(speaker_ip, av_transport_path, av_transport_svc, "SetAVTransportURI", stream.getWritten());
        self.allocator.free(result);
    }

    pub fn leaveGroup(self: *Client, speaker_ip: []const u8) !void {
        const result = try self.soapAction(speaker_ip, av_transport_path, av_transport_svc, "BecomeCoordinatorOfStandaloneGroup", "<InstanceID>0</InstanceID>");
        self.allocator.free(result);
    }

    // -- Internal --

    const av_transport_path = "/MediaRenderer/AVTransport/Control";
    const av_transport_svc = "AVTransport";
    const rendering_path = "/MediaRenderer/RenderingControl/Control";
    const rendering_svc = "RenderingControl";

    fn soapAction(self: *Client, speaker_ip: []const u8, path: []const u8, service: []const u8, action: []const u8, body_inner: []const u8) ![]const u8 {
        var url_buf: [256]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "http://{s}:1400{s}", .{ speaker_ip, path });

        const body = try std.fmt.allocPrint(self.allocator,
            \\<?xml version="1.0" encoding="utf-8"?>
            \\<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
            \\<s:Body><u:{s} xmlns:u="urn:schemas-upnp-org:service:{s}:1">{s}</u:{s}></s:Body></s:Envelope>
        , .{ action, service, body_inner, action });
        defer self.allocator.free(body);

        var soap_hdr_buf: [256]u8 = undefined;
        const soap_hdr = try std.fmt.bufPrint(&soap_hdr_buf, "\"urn:schemas-upnp-org:service:{s}:1#{s}\"", .{ service, action });

        return self.httpPost(url, body, soap_hdr);
    }

    fn httpPost(self: *Client, url: []const u8, body: []const u8, soap_action_hdr: []const u8) ![]const u8 {
        const uri = try std.Uri.parse(url);
        var req = try self.http.request(.POST, uri, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/xml; charset=utf-8" },
                .{ .name = "SOAPAction", .value = soap_action_hdr },
            },
            .headers = .{ .accept_encoding = .{ .override = "identity" } },
        });
        defer req.deinit();

        const mut_body = try self.allocator.dupe(u8, body);
        defer self.allocator.free(mut_body);
        try req.sendBodyComplete(mut_body);

        var redirect_buf: [4096]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);
        if (response.head.status != .ok) {
            log.err("SOAP {s} -> {d}", .{ url, @intFromEnum(response.head.status) });
            return error.SoapError;
        }

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.allocator);
        var reader = response.reader(&.{});
        reader.appendRemaining(self.allocator, &buf, .unlimited) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ReadFailed => return error.SoapError,
            error.StreamTooLong => unreachable,
        };
        return try buf.toOwnedSlice(self.allocator);
    }

    fn httpGet(self: *Client, url: []const u8) ![]const u8 {
        const uri = try std.Uri.parse(url);
        var req = try self.http.request(.GET, uri, .{
            .headers = .{ .accept_encoding = .{ .override = "identity" } },
        });
        defer req.deinit();
        try req.sendBodiless();

        var redirect_buf: [4096]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);
        if (response.head.status != .ok) return error.HttpError;

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.allocator);
        var reader = response.reader(&.{});
        reader.appendRemaining(self.allocator, &buf, .unlimited) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ReadFailed => return error.HttpError,
            error.StreamTooLong => unreachable,
        };
        return try buf.toOwnedSlice(self.allocator);
    }
};

// -- SSDP discovery (UDP, no Client needed) --

fn ssdpScan(results: *[max_speakers]Speaker) u8 {
    const sock = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0) catch |err| {
        log.err("ssdp socket: {}", .{err});
        return 0;
    };
    defer std.posix.close(sock);

    // 3s receive timeout
    const tv: std.posix.timeval = .{ .sec = 3, .usec = 0 };
    std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch return 0;

    const msg =
        "M-SEARCH * HTTP/1.1\r\n" ++
        "HOST: 239.255.255.250:1900\r\n" ++
        "MAN: \"ssdp:discover\"\r\n" ++
        "MX: 2\r\n" ++
        "ST: urn:schemas-upnp-org:device:ZonePlayer:1\r\n" ++
        "\r\n";

    const dest = std.net.Address.initIp4(.{ 239, 255, 255, 250 }, 1900);
    _ = std.posix.sendto(sock, msg, 0, &dest.any, dest.getOsSockLen()) catch |err| {
        log.err("ssdp sendto: {}", .{err});
        return 0;
    };

    var count: u8 = 0;
    var recv_buf: [2048]u8 = undefined;
    while (count < max_speakers) {
        var src_addr: std.posix.sockaddr.storage = undefined;
        var src_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
        const len = std.posix.recvfrom(sock, &recv_buf, 0, @ptrCast(&src_addr), &src_len) catch break;
        const data = recv_buf[0..len];

        // Only accept Sonos devices
        if (std.mem.indexOf(u8, data, "Sonos") == null) continue;

        const speaker_ip = extractLocationIp(data) orelse continue;

        // Dedup by IP
        var dup = false;
        for (results[0..count]) |*s| {
            if (std.mem.eql(u8, s.ip(), speaker_ip)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;

        var speaker = &results[count];
        speaker.* = .{};
        @memcpy(speaker.ip_buf[0..speaker_ip.len], speaker_ip);
        speaker.ip_len = @intCast(speaker_ip.len);
        count += 1;
    }

    log.info("ssdp: found {d} speakers", .{count});
    return count;
}

// -- Helpers --

fn extractLocationIp(data: []const u8) ?[]const u8 {
    // Find "LOCATION: http://" (case-insensitive for LOCATION)
    var i: usize = 0;
    while (i + 17 < data.len) : (i += 1) {
        if (std.ascii.startsWithIgnoreCase(data[i..], "LOCATION:")) {
            var pos = i + 9;
            // Skip whitespace
            while (pos < data.len and data[pos] == ' ') pos += 1;
            // Expect http://
            if (pos + 7 >= data.len) return null;
            if (!std.mem.eql(u8, data[pos..][0..7], "http://")) return null;
            pos += 7;
            // IP ends at ':'
            const ip_start = pos;
            while (pos < data.len and data[pos] != ':' and data[pos] != '/') pos += 1;
            if (pos == ip_start) return null;
            return data[ip_start..pos];
        }
    }
    return null;
}

fn xmlTagValue(data: []const u8, tag: []const u8) ?[]const u8 {
    // Find <tag>value</tag> - simple non-recursive search
    var open_buf: [64]u8 = undefined;
    const open = std.fmt.bufPrint(&open_buf, "<{s}>", .{tag}) catch return null;
    var close_buf: [64]u8 = undefined;
    const close = std.fmt.bufPrint(&close_buf, "</{s}>", .{tag}) catch return null;

    const start = std.mem.indexOf(u8, data, open) orelse return null;
    const val_start = start + open.len;
    const end = std.mem.indexOf(u8, data[val_start..], close) orelse return null;
    return data[val_start..][0..end];
}

fn xmlEscapeWrite(writer: anytype, input: []const u8) !void {
    for (input) |ch| {
        switch (ch) {
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '&' => try writer.writeAll("&amp;"),
            '"' => try writer.writeAll("&quot;"),
            else => try writer.writeByte(ch),
        }
    }
}

fn parseTime(str: []const u8) ?u32 {
    // Parse H:MM:SS or HH:MM:SS
    var parts = [3]u32{ 0, 0, 0 };
    var idx: usize = 0;
    var current: u32 = 0;
    for (str) |ch| {
        if (ch == ':') {
            if (idx >= 2) return null;
            parts[idx] = current;
            idx += 1;
            current = 0;
        } else if (ch >= '0' and ch <= '9') {
            current = current * 10 + (ch - '0');
        } else {
            return null;
        }
    }
    parts[idx] = current;
    if (idx != 2) return null;
    return parts[0] * 3600 + parts[1] * 60 + parts[2];
}

fn formatTime(buf: *[16]u8, total_secs: u32) []const u8 {
    const h = total_secs / 3600;
    const m = (total_secs % 3600) / 60;
    const s = total_secs % 60;
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ h, m, s }) catch "0:00:00";
}
