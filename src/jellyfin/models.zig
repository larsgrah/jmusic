const std = @import("std");

pub const BaseItem = struct {
    id: []const u8,
    name: []const u8,
    album_artist: ?[]const u8 = null,
    item_type: []const u8,
    parent_id: ?[]const u8 = null,
    album_id: ?[]const u8 = null,
    album: ?[]const u8 = null,
    index_number: ?u32 = null,
    run_time_ticks: ?i64 = null,

    pub fn durationSeconds(self: BaseItem) ?f64 {
        const ticks = self.run_time_ticks orelse return null;
        return @as(f64, @floatFromInt(ticks)) / 10_000_000.0;
    }
};

pub const ItemList = struct {
    items: []BaseItem,
    total_count: u32,
};

// JSON field mapping: Jellyfin uses PascalCase
pub const json_options = std.json.ParseOptions{
    .ignore_unknown_fields = true,
};

pub fn parseItemList(allocator: std.mem.Allocator, body: []const u8) !ItemList {
    const RawItem = struct {
        Id: []const u8 = "",
        Name: []const u8 = "",
        AlbumArtist: ?[]const u8 = null,
        Type: []const u8 = "",
        ParentId: ?[]const u8 = null,
        AlbumId: ?[]const u8 = null,
        Album: ?[]const u8 = null,
        IndexNumber: ?u32 = null,
        RunTimeTicks: ?i64 = null,
    };
    const Envelope = struct {
        Items: []const RawItem = &.{},
        TotalRecordCount: u32 = 0,
    };

    const parsed = try std.json.parseFromSlice(Envelope, allocator, body, json_options);
    defer parsed.deinit();

    var items = try allocator.alloc(BaseItem, parsed.value.Items.len);
    for (parsed.value.Items, 0..) |raw, i| {
        items[i] = .{
            .id = try allocator.dupe(u8, raw.Id),
            .name = try allocator.dupe(u8, raw.Name),
            .album_artist = if (raw.AlbumArtist) |a| try allocator.dupe(u8, a) else null,
            .item_type = try allocator.dupe(u8, raw.Type),
            .parent_id = if (raw.ParentId) |p| try allocator.dupe(u8, p) else null,
            .album_id = if (raw.AlbumId) |a| try allocator.dupe(u8, a) else null,
            .album = if (raw.Album) |a| try allocator.dupe(u8, a) else null,
            .index_number = raw.IndexNumber,
            .run_time_ticks = raw.RunTimeTicks,
        };
    }

    return .{
        .items = items,
        .total_count = parsed.value.TotalRecordCount,
    };
}
