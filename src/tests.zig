const std = @import("std");
const testing = std.testing;
const models = @import("jellyfin/models.zig");

// ---------------------------------------------------------------
// Model parsing
// ---------------------------------------------------------------
test "parseItemList - albums" {
    const json =
        \\{"Items":[
        \\  {"Id":"abc123","Name":"Test Album","AlbumArtist":"Test Artist","Type":"MusicAlbum",
        \\   "ParentId":"parent1","AlbumId":null,"Album":null,"IndexNumber":null,"RunTimeTicks":null},
        \\  {"Id":"def456","Name":"Another Album","AlbumArtist":null,"Type":"MusicAlbum",
        \\   "ParentId":null,"AlbumId":null,"Album":null,"IndexNumber":null,"RunTimeTicks":3000000000}
        \\],"TotalRecordCount":2}
    ;

    const result = try models.parseItemList(testing.allocator, json);
    defer testing.allocator.free(result.items);
    defer for (result.items) |item| {
        testing.allocator.free(item.id);
        testing.allocator.free(item.name);
        if (item.album_artist) |a| testing.allocator.free(a);
        testing.allocator.free(item.item_type);
        if (item.parent_id) |p| testing.allocator.free(p);
        if (item.album_id) |a| testing.allocator.free(a);
        if (item.album) |a| testing.allocator.free(a);
    };

    try testing.expectEqual(@as(usize, 2), result.items.len);
    try testing.expectEqual(@as(u32, 2), result.total_count);
    try testing.expectEqualStrings("abc123", result.items[0].id);
    try testing.expectEqualStrings("Test Album", result.items[0].name);
    try testing.expectEqualStrings("Test Artist", result.items[0].album_artist.?);
    try testing.expectEqualStrings("MusicAlbum", result.items[0].item_type);
    try testing.expectEqualStrings("parent1", result.items[0].parent_id.?);
    try testing.expect(result.items[1].album_artist == null);
    try testing.expectEqual(@as(?i64, 3000000000), result.items[1].run_time_ticks);
}

test "parseItemList - empty" {
    const json = \\{"Items":[],"TotalRecordCount":0}
    ;
    const result = try models.parseItemList(testing.allocator, json);
    defer testing.allocator.free(result.items);
    try testing.expectEqual(@as(usize, 0), result.items.len);
    try testing.expectEqual(@as(u32, 0), result.total_count);
}

test "parseItemList - ignores unknown fields" {
    const json =
        \\{"Items":[{"Id":"x","Name":"Y","Type":"Audio","SomeWeirdField":true,
        \\"ImageTags":{"Primary":"abc"},"UserData":{"PlayCount":5}}],
        \\"TotalRecordCount":1}
    ;
    const result = try models.parseItemList(testing.allocator, json);
    defer testing.allocator.free(result.items);
    defer for (result.items) |item| {
        testing.allocator.free(item.id);
        testing.allocator.free(item.name);
        testing.allocator.free(item.item_type);
    };
    try testing.expectEqual(@as(usize, 1), result.items.len);
    try testing.expectEqualStrings("x", result.items[0].id);
}

test "BaseItem.durationSeconds" {
    const item = models.BaseItem{
        .id = "a",
        .name = "b",
        .item_type = "Audio",
        .run_time_ticks = 600_000_000, // 60 seconds
    };
    const dur = item.durationSeconds().?;
    try testing.expectApproxEqAbs(@as(f64, 60.0), dur, 0.001);
}

test "BaseItem.durationSeconds - null ticks" {
    const item = models.BaseItem{
        .id = "a",
        .name = "b",
        .item_type = "Audio",
        .run_time_ticks = null,
    };
    try testing.expect(item.durationSeconds() == null);
}

// ---------------------------------------------------------------
// Audio cache slot management
// ---------------------------------------------------------------
const window = @import("ui/window.zig");

test "AudioCache - allocSlot round-robins" {
    var cache = window.AudioCache{};

    const s0 = cache.allocSlot();
    try testing.expectEqual(@as(usize, 0), s0);
    cache.slots[s0].track_id = "track0";
    cache.slots[s0].ready = true;

    const s1 = cache.allocSlot();
    try testing.expectEqual(@as(usize, 1), s1);

    // Wrap around
    var i: usize = 2;
    while (i < cache.slots.len) : (i += 1) {
        _ = cache.allocSlot();
    }
    const wrapped = cache.allocSlot();
    try testing.expectEqual(@as(usize, 0), wrapped);
    // Old slot 0 data should be cleared
    try testing.expect(cache.slots[0].track_id == null);
}

test "AudioCache - findSlot" {
    var cache = window.AudioCache{};

    // Not found when empty
    try testing.expect(cache.findSlot("track1") == null);

    // Add and find
    const slot = cache.allocSlot();
    cache.slots[slot].track_id = "track1";
    cache.slots[slot].ready = true;

    try testing.expectEqual(@as(?usize, 0), cache.findSlot("track1"));
    try testing.expect(cache.findSlot("track2") == null);
}

test "AudioCache - findSlot not ready" {
    var cache = window.AudioCache{};
    const slot = cache.allocSlot();
    cache.slots[slot].track_id = "track1";
    cache.slots[slot].ready = false;
    // Not ready = not found
    try testing.expect(cache.findSlot("track1") == null);
}

test "AudioCache - tempPathSlice" {
    var buf: [64]u8 = undefined;
    const path = window.AudioCache.tempPathSlice(&buf, 3);
    try testing.expectEqualStrings("/tmp/jmusic_3", path);
}

// ---------------------------------------------------------------
// Search matching
// ---------------------------------------------------------------
test "containsInsensitive - basic" {
    try testing.expect(window.containsInsensitive("Hello World", "hello"));
    try testing.expect(window.containsInsensitive("Hello World", "WORLD"));
    try testing.expect(window.containsInsensitive("Hello World", "lo Wo"));
    try testing.expect(!window.containsInsensitive("Hello", "xyz"));
    try testing.expect(window.containsInsensitive("anything", ""));
    try testing.expect(!window.containsInsensitive("", "something"));
    try testing.expect(!window.containsInsensitive("short", "this is longer than short"));
}

test "matchesSearch - matches name" {
    const album = models.BaseItem{
        .id = "1",
        .name = "Dark Side of the Moon",
        .album_artist = "Pink Floyd",
        .item_type = "MusicAlbum",
    };
    try testing.expect(window.matchesSearch(album, "dark"));
    try testing.expect(window.matchesSearch(album, "MOON"));
    try testing.expect(window.matchesSearch(album, "pink"));
    try testing.expect(!window.matchesSearch(album, "beatles"));
}

test "matchesSearch - no artist" {
    const album = models.BaseItem{
        .id = "1",
        .name = "Unknown Album",
        .item_type = "MusicAlbum",
    };
    try testing.expect(window.matchesSearch(album, "unknown"));
    try testing.expect(!window.matchesSearch(album, "artist"));
}

// ---------------------------------------------------------------
// Art cache paths
// ---------------------------------------------------------------
test "artCachePath" {
    // This test depends on HOME being set
    if (std.posix.getenv("HOME")) |home| {
        var buf: [300]u8 = undefined;
        const path = window.artCachePath(&buf, "abc123").?;
        const expected = try std.fmt.allocPrint(testing.allocator, "{s}/.cache/jmusic/art/abc123", .{home});
        defer testing.allocator.free(expected);
        try testing.expectEqualStrings(expected, path);
    }
}

// ---------------------------------------------------------------
// Time formatting
// ---------------------------------------------------------------
test "setTimeLabel formats correctly" {
    // We can't test the GTK label directly, but we can test the format logic
    // Extracted inline for testing
    const total: u32 = @intFromFloat(@max(@as(f32, 185.5), 0));
    const m = total / 60;
    const s = total % 60;
    try testing.expectEqual(@as(u32, 3), m);
    try testing.expectEqual(@as(u32, 5), s);

    var buf: [12]u8 = undefined;
    const sl = try std.fmt.bufPrint(&buf, "{d}:{d:0>2}", .{ m, s });
    try testing.expectEqualStrings("3:05", sl);
}

test "setTimeLabel zero" {
    const total: u32 = 0;
    const m = total / 60;
    const s = total % 60;
    var buf: [12]u8 = undefined;
    const sl = try std.fmt.bufPrint(&buf, "{d}:{d:0>2}", .{ m, s });
    try testing.expectEqualStrings("0:00", sl);
}

// ---------------------------------------------------------------
// Player state machine
// ---------------------------------------------------------------
const c = @import("c.zig");
const gtk = c.gtk;
const player_mod = @import("audio/player.zig");

// ---------------------------------------------------------------
// Art loading - widget tree traversal
// ---------------------------------------------------------------
fn initGtkForTest() void {
    _ = gtk.gtk_init();
}

test "collectArtJobsFromBox finds art-id on pictures inside buttons" {
    initGtkForTest();

    // Build the same widget tree as addHomeSection:
    // row_box -> button -> card_box -> picture(needs-art, art-id="test123")
    const row_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 0);

    const card = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);
    const picture = gtk.gtk_picture_new();
    gtk.gtk_widget_set_name(picture, "needs-art");
    gtk.g_object_set_data(@ptrCast(picture), "art-id", @constCast(@ptrCast("test123")));
    gtk.gtk_box_append(@ptrCast(card), picture);

    const button = gtk.gtk_button_new();
    gtk.gtk_button_set_child(@ptrCast(button), card);
    gtk.gtk_box_append(@ptrCast(row_box), button);

    // Now test: can collectArtJobsFromBox find it?
    var jobs = std.array_list.AlignedManaged(window.ArtJob, null).init(testing.allocator);
    defer jobs.deinit();

    window.collectArtJobsFromBox(row_box, &jobs);

    // This should find 1 job
    try testing.expectEqual(@as(usize, 1), jobs.items.len);
    try testing.expectEqualStrings("test123", jobs.items[0].id);
}

test "collectArtJobsFromBox - button get_first_child vs get_child" {
    initGtkForTest();

    // Verify that GtkButton exposes its child via get_first_child
    const card = gtk.gtk_label_new("test");
    const button = gtk.gtk_button_new();
    gtk.gtk_button_set_child(@ptrCast(button), card);

    const via_first_child = gtk.gtk_widget_get_first_child(button);
    const via_button_get = gtk.gtk_button_get_child(@ptrCast(button));

    // If this fails, buttons need gtk_button_get_child instead of get_first_child
    try testing.expect(via_first_child != null or via_button_get != null);

    if (via_first_child == null) {
        // get_first_child doesn't work on buttons - this is the bug!
        try testing.expect(false); // FAIL: need to use gtk_button_get_child
    }
}

test "collectArtJobsFromBox finds multiple items" {
    initGtkForTest();

    const row_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 0);

    // Add 5 cards
    const ids = [_][]const u8{ "id1\x00", "id2\x00", "id3\x00", "id4\x00", "id5\x00" };
    for (ids) |id| {
        const card = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);
        const pic = gtk.gtk_picture_new();
        gtk.gtk_widget_set_name(pic, "needs-art");
        gtk.g_object_set_data(@ptrCast(pic), "art-id", @constCast(@ptrCast(id.ptr)));
        gtk.gtk_box_append(@ptrCast(card), pic);

        const btn = gtk.gtk_button_new();
        gtk.gtk_button_set_child(@ptrCast(btn), card);
        gtk.gtk_box_append(@ptrCast(row_box), btn);
    }

    var jobs = std.array_list.AlignedManaged(window.ArtJob, null).init(testing.allocator);
    defer jobs.deinit();

    window.collectArtJobsFromBox(row_box, &jobs);
    try testing.expectEqual(@as(usize, 5), jobs.items.len);
}

test "spawnHomeArtLoader finds jobs across sections via g_object_get_data row-box" {
    initGtkForTest();

    // Simulate: home_box -> section(box) -> [label, scrolled_window]
    // scrolled_window has "row-box" data pointing to the horizontal box
    const home_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);

    // Section 1
    const section1 = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);
    const label1 = gtk.gtk_label_new("Section 1");
    gtk.gtk_box_append(@ptrCast(section1), label1);

    const scroll1 = gtk.gtk_scrolled_window_new();
    const row1 = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 0);

    // Add a card to row1
    const card1 = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);
    const pic1 = gtk.gtk_picture_new();
    gtk.gtk_widget_set_name(pic1, "needs-art");
    gtk.g_object_set_data(@ptrCast(pic1), "art-id", @constCast(@ptrCast("album1\x00")));
    gtk.gtk_box_append(@ptrCast(card1), pic1);
    const btn1 = gtk.gtk_button_new();
    gtk.gtk_button_set_child(@ptrCast(btn1), card1);
    gtk.gtk_box_append(@ptrCast(row1), btn1);

    gtk.gtk_scrolled_window_set_child(@ptrCast(scroll1), row1);
    gtk.g_object_set_data(@ptrCast(scroll1), "row-box", @ptrCast(row1));
    gtk.gtk_box_append(@ptrCast(section1), scroll1);
    gtk.gtk_box_append(@ptrCast(home_box), section1);

    // Section 2
    const section2 = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);
    const label2 = gtk.gtk_label_new("Section 2");
    gtk.gtk_box_append(@ptrCast(section2), label2);

    const scroll2 = gtk.gtk_scrolled_window_new();
    const row2 = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 0);

    const card2 = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);
    const pic2 = gtk.gtk_picture_new();
    gtk.gtk_widget_set_name(pic2, "needs-art");
    gtk.g_object_set_data(@ptrCast(pic2), "art-id", @constCast(@ptrCast("album2\x00")));
    gtk.gtk_box_append(@ptrCast(card2), pic2);
    const btn2 = gtk.gtk_button_new();
    gtk.gtk_button_set_child(@ptrCast(btn2), card2);
    gtk.gtk_box_append(@ptrCast(row2), btn2);

    gtk.gtk_scrolled_window_set_child(@ptrCast(scroll2), row2);
    gtk.g_object_set_data(@ptrCast(scroll2), "row-box", @ptrCast(row2));
    gtk.gtk_box_append(@ptrCast(section2), scroll2);
    gtk.gtk_box_append(@ptrCast(home_box), section2);

    // Now simulate what spawnHomeArtLoader does
    var jobs = std.array_list.AlignedManaged(window.ArtJob, null).init(testing.allocator);
    defer jobs.deinit();

    var section = gtk.gtk_widget_get_first_child(home_box);
    while (section != null) : (section = gtk.gtk_widget_get_next_sibling(section)) {
        var section_child = gtk.gtk_widget_get_first_child(section);
        while (section_child != null) : (section_child = gtk.gtk_widget_get_next_sibling(section_child)) {
            const row_ptr = gtk.g_object_get_data(@ptrCast(section_child), "row-box");
            if (row_ptr != null) {
                window.collectArtJobsFromBox(@ptrCast(@alignCast(row_ptr)), &jobs);
            }
        }
    }

    // Should find both jobs across both sections
    try testing.expectEqual(@as(usize, 2), jobs.items.len);
    try testing.expectEqualStrings("album1", jobs.items[0].id);
    try testing.expectEqualStrings("album2", jobs.items[1].id);
}

test "multiple sequential HTTP clients can fetch images" {
    // Integration test: verifies we can create multiple fresh HTTP clients
    // and fetch images sequentially (the pattern used by artLoaderThread)
    const api_mod = @import("jellyfin/api.zig");

    const urls = [_][]const u8{
        "https://jellyfin.kloud.video/Items/2ceda6c29be9b039bcaff7ae797a13d3/Images/Primary?maxWidth=160",
        "https://jellyfin.kloud.video/Items/2ceda6c29be9b039bcaff7ae797a13d3/Images/Primary?maxWidth=160",
        "https://jellyfin.kloud.video/Items/2ceda6c29be9b039bcaff7ae797a13d3/Images/Primary?maxWidth=160",
    };

    var success_count: usize = 0;
    for (urls) |url| {
        var client = api_mod.Client.init(testing.allocator, "https://jellyfin.kloud.video");
        defer client.deinit();
        const data = client.fetchBytes(url) catch |err| {
            std.debug.print("fetch {d} failed: {}\n", .{ success_count, err });
            continue;
        };
        defer testing.allocator.free(data);
        try testing.expect(data.len > 0);
        success_count += 1;
    }

    // All 3 should succeed
    try testing.expectEqual(@as(usize, 3), success_count);
}

test "g_object_get_data on label returns null for unknown key" {
    initGtkForTest();
    const label = gtk.gtk_label_new("test");
    const data = gtk.g_object_get_data(@ptrCast(label), "row-box");
    try testing.expect(data == null);
}

test "g_object_get_data on scrolled_window with row-box set" {
    initGtkForTest();
    const scroll = gtk.gtk_scrolled_window_new();
    const row = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_scrolled_window_set_child(@ptrCast(scroll), row);
    gtk.g_object_set_data(@ptrCast(scroll), "row-box", @ptrCast(row));

    const retrieved = gtk.g_object_get_data(@ptrCast(scroll), "row-box");
    try testing.expect(retrieved != null);
    try testing.expect(retrieved == @as(?*anyopaque, @ptrCast(row)));
}

test "Player State enum values" {
    try testing.expect(player_mod.State.stopped != player_mod.State.playing);
    try testing.expect(player_mod.State.playing != player_mod.State.paused);
}

// ---------------------------------------------------------------
// Sonos
// ---------------------------------------------------------------
const sonos = @import("sonos.zig");

test "sonos discover finds speakers" {
    var client = sonos.Client.init(testing.allocator);
    defer client.deinit();
    var speakers: [sonos.max_speakers]sonos.Speaker = undefined;
    const count = client.discover(&speakers);
    try testing.expect(count > 0);

    // Each speaker should have room name and IP
    for (speakers[0..count]) |s| {
        try testing.expect(s.ip_len > 0);
        try testing.expect(s.room_len > 0);
        std.debug.print("  {s} ({s}) @ {s}\n", .{ s.room(), s.model(), s.ip() });
    }
}

test "sonos get volume" {
    var client = sonos.Client.init(testing.allocator);
    defer client.deinit();
    var speakers: [sonos.max_speakers]sonos.Speaker = undefined;
    const count = client.discover(&speakers);
    if (count == 0) return error.SkipZigTest;

    const vol = try client.getVolume(speakers[0].ip());
    try testing.expect(vol <= 100);
    std.debug.print("  {s} volume: {d}\n", .{ speakers[0].room(), vol });
}
