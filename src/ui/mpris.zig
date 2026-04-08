const std = @import("std");
const c = @import("../c.zig");
const Player = @import("../audio/player.zig").Player;
const helpers = @import("helpers.zig");

const log = std.log.scoped(.mpris);
const gtk = c.gtk;

const App = @import("window.zig").App;

const BUS_NAME = "org.mpris.MediaPlayer2.jmusic";
const OBJECT_PATH = "/org/mpris/MediaPlayer2";

const introspection_xml =
    \\<node>
    \\  <interface name="org.mpris.MediaPlayer2">
    \\    <method name="Raise"/>
    \\    <method name="Quit"/>
    \\    <property name="CanQuit" type="b" access="read"/>
    \\    <property name="CanRaise" type="b" access="read"/>
    \\    <property name="HasTrackList" type="b" access="read"/>
    \\    <property name="Identity" type="s" access="read"/>
    \\    <property name="SupportedUriSchemes" type="as" access="read"/>
    \\    <property name="SupportedMimeTypes" type="as" access="read"/>
    \\  </interface>
    \\  <interface name="org.mpris.MediaPlayer2.Player">
    \\    <method name="Play"/>
    \\    <method name="Pause"/>
    \\    <method name="PlayPause"/>
    \\    <method name="Stop"/>
    \\    <method name="Next"/>
    \\    <method name="Previous"/>
    \\    <method name="Seek">
    \\      <arg name="Offset" type="x" direction="in"/>
    \\    </method>
    \\    <property name="PlaybackStatus" type="s" access="read"/>
    \\    <property name="Metadata" type="a{sv}" access="read"/>
    \\    <property name="Position" type="x" access="read"/>
    \\    <property name="Volume" type="d" access="readwrite"/>
    \\    <property name="CanGoNext" type="b" access="read"/>
    \\    <property name="CanGoPrevious" type="b" access="read"/>
    \\    <property name="CanPlay" type="b" access="read"/>
    \\    <property name="CanPause" type="b" access="read"/>
    \\    <property name="CanSeek" type="b" access="read"/>
    \\    <property name="CanControl" type="b" access="read"/>
    \\    <property name="Rate" type="d" access="read"/>
    \\    <property name="MinimumRate" type="d" access="read"/>
    \\    <property name="MaximumRate" type="d" access="read"/>
    \\  </interface>
    \\</node>
;

var mpris_player: ?*Player = null;
var mpris_app: ?*App = null;
var mpris_connection: ?*gtk.GDBusConnection = null;
var node_info: ?*gtk.GDBusNodeInfo = null;
var owner_id: c_uint = 0;

pub fn init(app: *App) void {
    mpris_app = app;
    mpris_player = app.player;

    node_info = gtk.g_dbus_node_info_new_for_xml(introspection_xml, null);
    if (node_info == null) {
        log.err("failed to parse MPRIS introspection XML", .{});
        return;
    }

    owner_id = gtk.g_bus_own_name(
        gtk.G_BUS_TYPE_SESSION,
        BUS_NAME,
        gtk.G_BUS_NAME_OWNER_FLAGS_NONE,
        &onBusAcquired,
        null,
        null,
        null,
        null,
    );

    log.info("MPRIS registered as {s}", .{BUS_NAME});
}

pub fn deinit() void {
    if (owner_id != 0) {
        gtk.g_bus_unown_name(owner_id);
        owner_id = 0;
    }
    if (node_info) |n| {
        gtk.g_dbus_node_info_unref(n);
        node_info = null;
    }
}

pub fn notifyPropertyChanged(prop_name: [*:0]const u8) void {
    const conn = mpris_connection orelse return;

    const builder = gtk.g_variant_builder_new(gtk.g_variant_type_checked_("a{sv}"));
    if (builder == null) return;

    const val = getPlayerProperty(prop_name);
    if (val != null) {
        gtk.g_variant_builder_add(builder, "{sv}", prop_name, val);
    }

    const empty = gtk.g_variant_builder_new(gtk.g_variant_type_checked_("as"));
    if (empty == null) {
        gtk.g_variant_builder_unref(builder);
        return;
    }

    _ = gtk.g_dbus_connection_emit_signal(
        conn,
        null,
        OBJECT_PATH,
        "org.freedesktop.DBus.Properties",
        "PropertiesChanged",
        gtk.g_variant_new(
            "(sa{sv}as)",
            "org.mpris.MediaPlayer2.Player",
            builder,
            empty,
        ),
        null,
    );
}

fn onBusAcquired(connection: ?*gtk.GDBusConnection, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    mpris_connection = connection;
    const ni = node_info orelse return;

    const base_iface = gtk.g_dbus_node_info_lookup_interface(ni, "org.mpris.MediaPlayer2");
    if (base_iface != null) {
        const vtable = &base_vtable;
        _ = gtk.g_dbus_connection_register_object(
            connection, OBJECT_PATH, base_iface, vtable, null, null, null,
        );
    }

    const player_iface = gtk.g_dbus_node_info_lookup_interface(ni, "org.mpris.MediaPlayer2.Player");
    if (player_iface != null) {
        const vtable = &player_vtable;
        _ = gtk.g_dbus_connection_register_object(
            connection, OBJECT_PATH, player_iface, vtable, null, null, null,
        );
    }
}

// ---------------------------------------------------------------
// Base interface (org.mpris.MediaPlayer2)
// ---------------------------------------------------------------
const base_vtable = gtk.GDBusInterfaceVTable{
    .method_call = &baseMethodCall,
    .get_property = &baseGetProperty,
    .set_property = null,
    .padding = .{ null, null, null, null, null, null, null, null },
};

fn baseMethodCall(
    _: ?*gtk.GDBusConnection, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8,
    method: [*c]const u8, _: ?*gtk.GVariant, invocation: ?*gtk.GDBusMethodInvocation, _: ?*anyopaque,
) callconv(.c) void {
    const name = std.mem.span(@as([*:0]const u8, @ptrCast(method)));
    if (std.mem.eql(u8, name, "Raise")) {
        if (mpris_app) |app| gtk.gtk_window_present(@ptrCast(app.window));
    } else if (std.mem.eql(u8, name, "Quit")) {
        // no-op for now
    }
    gtk.g_dbus_method_invocation_return_value(invocation, null);
}

fn baseGetProperty(
    _: ?*gtk.GDBusConnection, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8,
    property: [*c]const u8, _: [*c][*c]gtk.GError, _: ?*anyopaque,
) callconv(.c) ?*gtk.GVariant {
    const name = std.mem.span(@as([*:0]const u8, @ptrCast(property)));
    if (std.mem.eql(u8, name, "CanQuit")) return gtk.g_variant_new_boolean(1);
    if (std.mem.eql(u8, name, "CanRaise")) return gtk.g_variant_new_boolean(1);
    if (std.mem.eql(u8, name, "HasTrackList")) return gtk.g_variant_new_boolean(0);
    if (std.mem.eql(u8, name, "Identity")) return gtk.g_variant_new_string("jmusic");
    if (std.mem.eql(u8, name, "SupportedUriSchemes")) {
        const empty: [*c]const [*c]const u8 = @ptrCast(&[_:null]?[*:0]const u8{null});
        return gtk.g_variant_new_strv(empty, 0);
    }
    if (std.mem.eql(u8, name, "SupportedMimeTypes")) {
        const empty: [*c]const [*c]const u8 = @ptrCast(&[_:null]?[*:0]const u8{null});
        return gtk.g_variant_new_strv(empty, 0);
    }
    return null;
}

// ---------------------------------------------------------------
// Player interface (org.mpris.MediaPlayer2.Player)
// ---------------------------------------------------------------
const player_vtable = gtk.GDBusInterfaceVTable{
    .method_call = &playerMethodCall,
    .get_property = &playerGetProperty,
    .set_property = null,
    .padding = .{ null, null, null, null, null, null, null, null },
};

fn playerMethodCall(
    _: ?*gtk.GDBusConnection, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8,
    method: [*c]const u8, _: ?*gtk.GVariant, invocation: ?*gtk.GDBusMethodInvocation, _: ?*anyopaque,
) callconv(.c) void {
    const name = std.mem.span(@as([*:0]const u8, @ptrCast(method)));
    const app = mpris_app orelse {
        gtk.g_dbus_method_invocation_return_value(invocation, null);
        return;
    };

    if (std.mem.eql(u8, name, "PlayPause") or std.mem.eql(u8, name, "Play") or std.mem.eql(u8, name, "Pause")) {
        app.doTogglePause();
    } else if (std.mem.eql(u8, name, "Next")) {
        app.playNext();
    } else if (std.mem.eql(u8, name, "Previous")) {
        app.playPrev();
    } else if (std.mem.eql(u8, name, "Stop")) {
        if (app.player) |p| {
            p.stop();
            helpers.setLabelText(app.np_title, "Nothing playing");
            helpers.setLabelText(app.np_artist, "");
            gtk.gtk_button_set_icon_name(@ptrCast(app.play_btn), "media-playback-start-symbolic");
            notifyPropertyChanged("PlaybackStatus");
        }
    }

    gtk.g_dbus_method_invocation_return_value(invocation, null);
}

fn getPlayerProperty(property: [*:0]const u8) ?*gtk.GVariant {
    const name = std.mem.span(property);
    const player = mpris_player orelse return null;

    if (std.mem.eql(u8, name, "PlaybackStatus")) {
        return gtk.g_variant_new_string(switch (player.state) {
            .playing => "Playing",
            .paused => "Paused",
            .stopped => "Stopped",
        });
    }
    if (std.mem.eql(u8, name, "CanControl")) return gtk.g_variant_new_boolean(1);
    if (std.mem.eql(u8, name, "CanPlay")) return gtk.g_variant_new_boolean(1);
    if (std.mem.eql(u8, name, "CanPause")) return gtk.g_variant_new_boolean(1);
    if (std.mem.eql(u8, name, "CanGoNext")) return gtk.g_variant_new_boolean(1);
    if (std.mem.eql(u8, name, "CanGoPrevious")) return gtk.g_variant_new_boolean(1);
    if (std.mem.eql(u8, name, "CanSeek")) return gtk.g_variant_new_boolean(1);
    if (std.mem.eql(u8, name, "Rate")) return gtk.g_variant_new_double(1.0);
    if (std.mem.eql(u8, name, "MinimumRate")) return gtk.g_variant_new_double(1.0);
    if (std.mem.eql(u8, name, "MaximumRate")) return gtk.g_variant_new_double(1.0);
    if (std.mem.eql(u8, name, "Volume")) return gtk.g_variant_new_double(1.0);
    if (std.mem.eql(u8, name, "Position")) {
        const pos_us: i64 = @intFromFloat(player.getCursorSeconds() * 1_000_000);
        return gtk.g_variant_new_int64(pos_us);
    }
    if (std.mem.eql(u8, name, "Metadata")) {
        return buildMetadata(player);
    }
    return null;
}

fn playerGetProperty(
    _: ?*gtk.GDBusConnection, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8,
    property: [*c]const u8, _: [*c][*c]gtk.GError, _: ?*anyopaque,
) callconv(.c) ?*gtk.GVariant {
    return getPlayerProperty(@ptrCast(property));
}

fn buildMetadata(player: *Player) ?*gtk.GVariant {
    const builder = gtk.g_variant_builder_new(gtk.g_variant_type_checked_("a{sv}"));
    if (builder == null) return null;

    gtk.g_variant_builder_add(builder, "{sv}", "mpris:trackid",
        gtk.g_variant_new_object_path("/org/mpris/MediaPlayer2/Track/1"));

    if (player.current_track_name) |title| {
        var buf: [256]u8 = undefined;
        const len = @min(title.len, buf.len - 1);
        @memcpy(buf[0..len], title[0..len]);
        buf[len] = 0;
        gtk.g_variant_builder_add(builder, "{sv}", "xesam:title",
            gtk.g_variant_new_string(@ptrCast(&buf)));
    }

    if (player.current_artist) |artist| {
        var buf: [256]u8 = undefined;
        const len = @min(artist.len, buf.len - 1);
        @memcpy(buf[0..len], artist[0..len]);
        buf[len] = 0;
        const arr: [*c]const [*c]const u8 = @ptrCast(&[_:null]?[*:0]const u8{
            @ptrCast(&buf),
            null,
        });
        gtk.g_variant_builder_add(builder, "{sv}", "xesam:artist",
            gtk.g_variant_new_strv(arr, 1));
    }

    if (player.current_album) |album| {
        var buf: [256]u8 = undefined;
        const len = @min(album.len, buf.len - 1);
        @memcpy(buf[0..len], album[0..len]);
        buf[len] = 0;
        gtk.g_variant_builder_add(builder, "{sv}", "xesam:album",
            gtk.g_variant_new_string(@ptrCast(&buf)));
    }

    const length_us: i64 = @intFromFloat(player.getLengthSeconds() * 1_000_000);
    gtk.g_variant_builder_add(builder, "{sv}", "mpris:length",
        gtk.g_variant_new_int64(length_us));

    return gtk.g_variant_builder_end(builder);
}
