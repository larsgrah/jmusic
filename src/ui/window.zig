const std = @import("std");
const c = @import("../c.zig");
const api = @import("../jellyfin/api.zig");
const models = @import("../jellyfin/models.zig");
const Player = @import("../audio/player.zig").Player;
const mpris = @import("mpris.zig");
const bg = @import("bg.zig");
const DiskCache = @import("../audio/cache.zig").DiskCache;

const log = std.log.scoped(.ui);
const gtk = c.gtk;

const MAX_GRID_ITEMS = 60;
const PREFETCH_AHEAD = 10;

const main = @import("../main.zig");

// Track audio cache - maps track IDs to temp file paths
pub const AudioCache = struct {
    slots: [PREFETCH_AHEAD + 1]Slot = [_]Slot{.{}} ** (PREFETCH_AHEAD + 1),
    next_slot: usize = 0,
    mutex: std.Thread.Mutex = .{},

    pub const Slot = struct {
        track_id: ?[]const u8 = null,
        ready: bool = false,
    };

    pub fn tempPath(buf: *[64]u8, slot: usize) [*:0]const u8 {
        const s = std.fmt.bufPrint(buf, "/tmp/jmusic_{d}\x00", .{slot}) catch "/tmp/jmusic_0\x00";
        _ = s;
        return @ptrCast(buf);
    }

    pub fn tempPathSlice(buf: *[64]u8, slot: usize) []const u8 {
        return std.fmt.bufPrint(buf, "/tmp/jmusic_{d}", .{slot}) catch "/tmp/jmusic_0";
    }

    pub fn findSlot(self: *AudioCache, track_id: []const u8) ?usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.slots, 0..) |slot, i| {
            if (slot.track_id) |id| {
                if (std.mem.eql(u8, id, track_id) and slot.ready) return i;
            }
        }
        return null;
    }

    pub fn allocSlot(self: *AudioCache) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        const slot = self.next_slot;
        self.slots[slot] = .{};
        self.next_slot = (self.next_slot + 1) % self.slots.len;
        return slot;
    }

    pub fn markReady(self: *AudioCache, slot: usize, track_id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.slots[slot].track_id = track_id;
        self.slots[slot].ready = true;
    }
};

pub const RepeatMode = enum { off, all, one };

pub const App = struct {
    allocator: std.mem.Allocator,
    client: *api.Client,
    player: ?*Player = null,
    config: *const main.Config = undefined,

    // Data
    albums: ?models.ItemList = null,
    playlists: ?models.ItemList = null,
    home_recent: ?models.ItemList = null,
    home_added: ?models.ItemList = null,
    home_random: ?models.ItemList = null,
    home_favorites: ?models.ItemList = null,
    tracks: ?models.ItemList = null,
    track_queue: ?[]models.BaseItem = null, // owned copy - independent of displayed tracks
    track_queue_owned: bool = false,
    queue_index: usize = 0,
    current_album_idx: ?usize = null,
    current_playlist_idx: ?usize = null,
    // What's currently PLAYING (for now-playing click)
    playing_album_idx: ?usize = null,
    playing_playlist_id: ?[]const u8 = null,
    audio_cache: AudioCache = .{},
    disk_audio_cache: DiskCache = undefined,
    grid_art_gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    home_art_gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    deduped_albums: ?[]models.BaseItem = null,

    // Navigation history
    nav_stack: [32][*:0]const u8 = undefined,
    nav_pos: i32 = -1,
    nav_len: i32 = 0,
    nav_inhibit: bool = false,

    // Layout
    window: *gtk.GtkWidget = undefined,
    search_entry: *gtk.GtkWidget = undefined,
    back_btn: *gtk.GtkWidget = undefined,
    content_stack: *gtk.GtkWidget = undefined,
    album_grid: *gtk.GtkWidget = undefined,
    sidebar_playlists: *gtk.GtkWidget = undefined,
    home_box: *gtk.GtkWidget = undefined,

    // Album detail
    detail_art: *gtk.GtkWidget = undefined,
    detail_title: *gtk.GtkWidget = undefined,
    detail_artist: *gtk.GtkWidget = undefined,
    track_list_box: *gtk.GtkWidget = undefined,

    // Playlist editing
    current_playlist_id: ?[]const u8 = null,
    // Cached playlist contents: playlist_id -> ItemList
    playlist_cache: std.StringHashMap(models.ItemList) = undefined,
    playlist_cache_mutex: std.Thread.Mutex = .{},
    album_track_cache: std.StringHashMap(models.ItemList) = undefined,
    album_track_cache_mutex: std.Thread.Mutex = .{},
    suggestions_box: *gtk.GtkWidget = undefined,

    // Transport
    shuffle_btn: *gtk.GtkWidget = undefined,
    repeat_btn: *gtk.GtkWidget = undefined,

    // Volume
    volume_scale: *gtk.GtkWidget = undefined,
    volume_btn: *gtk.GtkWidget = undefined,

    // Queue panel
    queue_revealer: *gtk.GtkWidget = undefined,
    queue_list: *gtk.GtkWidget = undefined,
    queue_btn: *gtk.GtkWidget = undefined,

    // Settings
    settings_server: *gtk.GtkWidget = undefined,
    settings_user: *gtk.GtkWidget = undefined,
    settings_pass: *gtk.GtkWidget = undefined,
    settings_cache: *gtk.GtkWidget = undefined,

    // Now playing
    np_art: *gtk.GtkWidget = undefined,
    np_title: *gtk.GtkWidget = undefined,
    np_artist: *gtk.GtkWidget = undefined,
    play_btn: *gtk.GtkWidget = undefined,
    progress_scale: *gtk.GtkWidget = undefined,
    time_current: *gtk.GtkWidget = undefined,
    time_total: *gtk.GtkWidget = undefined,

    progress_timer: c_uint = 0,
    play_generation: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    shuffle: bool = false,
    repeat: RepeatMode = .off,
    updating_progress: bool = false,

    // ---------------------------------------------------------------
    // Build the entire widget tree
    // ---------------------------------------------------------------
    pub fn build(self: *App, gtk_app: *gtk.GtkApplication) void {
        applyCSS();

        self.window = gtk.gtk_application_window_new(gtk_app);
        gtk.gtk_window_set_title(@ptrCast(self.window), "jmusic");
        gtk.gtk_window_set_default_size(@ptrCast(self.window), 1200, 750);

        // Root: vertical(top area, now-playing bar)
        const outer = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);
        gtk.gtk_window_set_child(@ptrCast(self.window), outer);

        // Top area: sidebar + right side
        const root = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 0);
        gtk.gtk_widget_set_vexpand(root, 1);
        gtk.gtk_box_append(@ptrCast(outer), root);

        // -- Sidebar --
        const sidebar = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);
        gtk.gtk_widget_add_css_class(sidebar, "sidebar");
        gtk.gtk_widget_set_size_request(sidebar, 200, -1);
        gtk.gtk_widget_set_hexpand(sidebar, 0);

        // Logo
        const logo = gtk.gtk_label_new("jmusic");
        gtk.gtk_widget_add_css_class(logo, "sidebar-logo");
        gtk.gtk_label_set_xalign(@ptrCast(logo), 0);
        gtk.gtk_box_append(@ptrCast(sidebar), logo);

        // Nav buttons
        const nav_items = [_]struct { label: [*:0]const u8, cb: *const anyopaque }{
            .{ .label = "Home", .cb = &onNavHome },
            .{ .label = "Search", .cb = &onNavSearch },
            .{ .label = "Albums", .cb = &onNavAlbums },
        };
        for (nav_items) |item| {
            const btn = gtk.gtk_button_new_with_label(item.label);
            gtk.gtk_widget_add_css_class(btn, "sidebar-item");
            gtk.gtk_button_set_has_frame(@ptrCast(btn), 0);
            gtk.gtk_widget_set_halign(btn, gtk.GTK_ALIGN_FILL);
            // Left-align the label inside the button
            const btn_child = gtk.gtk_button_get_child(@ptrCast(btn));
            if (btn_child != null) gtk.gtk_label_set_xalign(@ptrCast(btn_child), 0);
            _ = g_signal_connect(btn, "clicked", item.cb, self);
            gtk.gtk_box_append(@ptrCast(sidebar), btn);
        }

        // Divider
        const divider = gtk.gtk_separator_new(gtk.GTK_ORIENTATION_HORIZONTAL);
        gtk.gtk_widget_add_css_class(divider, "sidebar-divider");
        gtk.gtk_box_append(@ptrCast(sidebar), divider);

        // Playlists section header with + button
        const pl_header = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 0);
        const pl_label = gtk.gtk_label_new("Playlists");
        gtk.gtk_widget_add_css_class(pl_label, "sidebar-section");
        gtk.gtk_label_set_xalign(@ptrCast(pl_label), 0);
        gtk.gtk_widget_set_hexpand(pl_label, 1);
        gtk.gtk_box_append(@ptrCast(pl_header), pl_label);

        const new_pl_btn = gtk.gtk_button_new_from_icon_name("list-add-symbolic");
        gtk.gtk_widget_add_css_class(new_pl_btn, "sidebar-add-btn");
        gtk.gtk_button_set_has_frame(@ptrCast(new_pl_btn), 0);
        _ = g_signal_connect(new_pl_btn, "clicked", &onNewPlaylist, self);
        gtk.gtk_box_append(@ptrCast(pl_header), new_pl_btn);

        gtk.gtk_box_append(@ptrCast(sidebar), pl_header);

        const pl_scroll = gtk.gtk_scrolled_window_new();
        gtk.gtk_widget_set_vexpand(pl_scroll, 1);
        self.sidebar_playlists = gtk.gtk_list_box_new();
        gtk.gtk_widget_add_css_class(self.sidebar_playlists, "sidebar-list");
        gtk.gtk_list_box_set_selection_mode(@ptrCast(self.sidebar_playlists), gtk.GTK_SELECTION_SINGLE);
        _ = g_signal_connect(self.sidebar_playlists, "row-activated", &onPlaylistActivated, self);
        gtk.gtk_scrolled_window_set_child(@ptrCast(pl_scroll), self.sidebar_playlists);
        gtk.gtk_box_append(@ptrCast(sidebar), pl_scroll);

        gtk.gtk_box_append(@ptrCast(root), sidebar);

        // -- Right side: header + content + now playing --
        const right = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);
        gtk.gtk_widget_set_hexpand(right, 1);

        // Header
        const header = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 12);
        gtk.gtk_widget_add_css_class(header, "header-bar");

        self.back_btn = gtk.gtk_button_new_from_icon_name("go-previous-symbolic");
        gtk.gtk_widget_add_css_class(self.back_btn, "back-btn");
        gtk.gtk_widget_set_visible(self.back_btn, 0);
        gtk.gtk_box_append(@ptrCast(header), self.back_btn);

        self.search_entry = gtk.gtk_search_entry_new();
        gtk.gtk_widget_set_hexpand(self.search_entry, 1);
        gtk.gtk_search_entry_set_placeholder_text(@ptrCast(self.search_entry), "Search your library...");
        gtk.gtk_box_append(@ptrCast(header), self.search_entry);

        // Profile button (top right)
        const profile_btn = gtk.gtk_button_new_from_icon_name("avatar-default-symbolic");
        gtk.gtk_widget_add_css_class(profile_btn, "profile-btn");
        _ = g_signal_connect(profile_btn, "clicked", &onProfileClicked, self);
        gtk.gtk_box_append(@ptrCast(header), profile_btn);

        gtk.gtk_box_append(@ptrCast(right), header);

        // Content stack
        self.content_stack = gtk.gtk_stack_new();
        gtk.gtk_widget_set_vexpand(self.content_stack, 1);
        gtk.gtk_widget_set_hexpand(self.content_stack, 1);
        gtk.gtk_stack_set_transition_type(@ptrCast(self.content_stack), gtk.GTK_STACK_TRANSITION_TYPE_CROSSFADE);
        gtk.gtk_stack_set_transition_duration(@ptrCast(self.content_stack), 150);
        gtk.gtk_stack_set_hhomogeneous(@ptrCast(self.content_stack), 1);
        gtk.gtk_stack_set_vhomogeneous(@ptrCast(self.content_stack), 1);

        // Home page - horizontal scroll sections
        const home_scroll = gtk.gtk_scrolled_window_new();
        gtk.gtk_widget_set_vexpand(home_scroll, 1);
        self.home_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);
        gtk.gtk_scrolled_window_set_child(@ptrCast(home_scroll), self.home_box);
        _ = gtk.gtk_stack_add_named(@ptrCast(self.content_stack), home_scroll, "home");

        // Albums page (grid)
        const albums_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);
        const albums_title = gtk.gtk_label_new("Albums");
        gtk.gtk_widget_add_css_class(albums_title, "section-title");
        gtk.gtk_label_set_xalign(@ptrCast(albums_title), 0);
        gtk.gtk_box_append(@ptrCast(albums_box), albums_title);

        const grid_scroll = gtk.gtk_scrolled_window_new();
        gtk.gtk_widget_set_vexpand(grid_scroll, 1);
        self.album_grid = gtk.gtk_flow_box_new();
        gtk.gtk_flow_box_set_homogeneous(@ptrCast(self.album_grid), 0);
        gtk.gtk_flow_box_set_column_spacing(@ptrCast(self.album_grid), 4);
        gtk.gtk_flow_box_set_row_spacing(@ptrCast(self.album_grid), 4);
        gtk.gtk_flow_box_set_max_children_per_line(@ptrCast(self.album_grid), 8);
        gtk.gtk_flow_box_set_min_children_per_line(@ptrCast(self.album_grid), 2);
        gtk.gtk_flow_box_set_selection_mode(@ptrCast(self.album_grid), gtk.GTK_SELECTION_NONE);
        gtk.gtk_scrolled_window_set_child(@ptrCast(grid_scroll), self.album_grid);
        gtk.gtk_box_append(@ptrCast(albums_box), grid_scroll);
        _ = gtk.gtk_stack_add_named(@ptrCast(self.content_stack), albums_box, "albums");

        // Album detail page
        const detail_page = self.buildDetailPage();
        _ = gtk.gtk_stack_add_named(@ptrCast(self.content_stack), detail_page, "detail");

        // Settings page
        const settings_page = self.buildSettingsPage();
        _ = gtk.gtk_stack_add_named(@ptrCast(self.content_stack), settings_page, "settings");

        // Content area with queue overlay
        const middle = gtk.gtk_overlay_new();
        gtk.gtk_widget_set_vexpand(middle, 1);
        gtk.gtk_widget_set_hexpand(middle, 1);
        gtk.gtk_overlay_set_child(@ptrCast(middle), self.content_stack);

        // Queue panel - overlaid on the right, hidden by default
        self.queue_revealer = gtk.gtk_revealer_new();
        gtk.gtk_revealer_set_transition_type(@ptrCast(self.queue_revealer), gtk.GTK_REVEALER_TRANSITION_TYPE_SLIDE_LEFT);
        gtk.gtk_revealer_set_transition_duration(@ptrCast(self.queue_revealer), 200);
        gtk.gtk_revealer_set_reveal_child(@ptrCast(self.queue_revealer), 0);
        gtk.gtk_widget_set_halign(self.queue_revealer, gtk.GTK_ALIGN_END);
        gtk.gtk_widget_set_valign(self.queue_revealer, gtk.GTK_ALIGN_FILL);

        const queue_panel = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);
        gtk.gtk_widget_add_css_class(queue_panel, "queue-panel");
        gtk.gtk_widget_set_size_request(queue_panel, 320, -1);

        const queue_header = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 8);
        gtk.gtk_widget_set_margin_start(queue_header, 16);
        gtk.gtk_widget_set_margin_end(queue_header, 16);
        gtk.gtk_widget_set_margin_top(queue_header, 12);
        gtk.gtk_widget_set_margin_bottom(queue_header, 8);
        const queue_title = gtk.gtk_label_new("Queue");
        gtk.gtk_widget_add_css_class(queue_title, "queue-title");
        gtk.gtk_label_set_xalign(@ptrCast(queue_title), 0);
        gtk.gtk_widget_set_hexpand(queue_title, 1);
        gtk.gtk_box_append(@ptrCast(queue_header), queue_title);

        const clear_btn = gtk.gtk_button_new_with_label("Clear");
        gtk.gtk_widget_add_css_class(clear_btn, "queue-clear-btn");
        gtk.gtk_button_set_has_frame(@ptrCast(clear_btn), 0);
        _ = g_signal_connect(clear_btn, "clicked", &onClearQueue, self);
        gtk.gtk_box_append(@ptrCast(queue_header), clear_btn);
        gtk.gtk_box_append(@ptrCast(queue_panel), queue_header);

        const queue_scroll = gtk.gtk_scrolled_window_new();
        gtk.gtk_widget_set_vexpand(queue_scroll, 1);
        self.queue_list = gtk.gtk_list_box_new();
        gtk.gtk_widget_add_css_class(self.queue_list, "queue-list");
        gtk.gtk_list_box_set_selection_mode(@ptrCast(self.queue_list), gtk.GTK_SELECTION_SINGLE);
        _ = g_signal_connect(self.queue_list, "row-activated", &onQueueRowActivated, self);
        gtk.gtk_scrolled_window_set_child(@ptrCast(queue_scroll), self.queue_list);
        gtk.gtk_box_append(@ptrCast(queue_panel), queue_scroll);

        gtk.gtk_revealer_set_child(@ptrCast(self.queue_revealer), queue_panel);
        gtk.gtk_overlay_add_overlay(@ptrCast(middle), self.queue_revealer);

        gtk.gtk_box_append(@ptrCast(right), middle);
        gtk.gtk_box_append(@ptrCast(root), right);

        // Now playing bar - full width, below sidebar+content
        const np_bar = self.buildNowPlayingBar();
        gtk.gtk_box_append(@ptrCast(outer), np_bar);

        // Mouse back/forward buttons
        const click = gtk.gtk_gesture_click_new();
        gtk.gtk_gesture_single_set_button(@ptrCast(click), 0); // listen to all buttons
        _ = g_signal_connect(@as(*anyopaque, @ptrCast(click)), "pressed", &onMouseButton, self);
        gtk.gtk_widget_add_controller(self.window, @ptrCast(click));

        // Push initial page
        self.navPush("home");

        // Signals
        _ = g_signal_connect(self.search_entry, "search-changed", &onSearchChanged, self);
        _ = g_signal_connect(self.back_btn, "clicked", &onBack, self);
        _ = g_signal_connect(self.play_btn, "clicked", &onPlayPause, self);

        gtk.gtk_widget_set_visible(self.window, 1);

        _ = gtk.g_idle_add(&initBackendIdle, self);
        self.progress_timer = gtk.g_timeout_add(250, &updateProgress, self);
        // Fast timer for gapless end-of-track detection
        _ = gtk.g_timeout_add(16, &checkTrackEnd, self);
    }

    fn buildSettingsPage(self: *App) *gtk.GtkWidget {
        const page = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 16);
        gtk.gtk_widget_add_css_class(page, "settings-page");
        gtk.gtk_widget_set_margin_start(page, 40);
        gtk.gtk_widget_set_margin_end(page, 40);
        gtk.gtk_widget_set_margin_top(page, 32);

        const title = gtk.gtk_label_new("Settings");
        gtk.gtk_widget_add_css_class(title, "settings-title");
        gtk.gtk_label_set_xalign(@ptrCast(title), 0);
        gtk.gtk_box_append(@ptrCast(page), title);

        // Server URL
        const server_label = gtk.gtk_label_new("Jellyfin Server URL");
        gtk.gtk_widget_add_css_class(server_label, "settings-label");
        gtk.gtk_label_set_xalign(@ptrCast(server_label), 0);
        gtk.gtk_box_append(@ptrCast(page), server_label);

        self.settings_server = gtk.gtk_entry_new();
        gtk.gtk_widget_add_css_class(self.settings_server, "settings-entry");
        gtk.gtk_entry_set_placeholder_text(@ptrCast(self.settings_server), "https://jellyfin.example.com");
        // Pre-fill from config
        {
            var buf: [256]u8 = undefined;
            const len = @min(self.config.server.len, buf.len - 1);
            @memcpy(buf[0..len], self.config.server[0..len]);
            buf[len] = 0;
            gtk.gtk_editable_set_text(@ptrCast(self.settings_server), @ptrCast(&buf));
        }
        gtk.gtk_box_append(@ptrCast(page), self.settings_server);

        // Username
        const user_label = gtk.gtk_label_new("Username");
        gtk.gtk_widget_add_css_class(user_label, "settings-label");
        gtk.gtk_label_set_xalign(@ptrCast(user_label), 0);
        gtk.gtk_box_append(@ptrCast(page), user_label);

        self.settings_user = gtk.gtk_entry_new();
        gtk.gtk_widget_add_css_class(self.settings_user, "settings-entry");
        {
            var buf: [256]u8 = undefined;
            const len = @min(self.config.username.len, buf.len - 1);
            @memcpy(buf[0..len], self.config.username[0..len]);
            buf[len] = 0;
            gtk.gtk_editable_set_text(@ptrCast(self.settings_user), @ptrCast(&buf));
        }
        gtk.gtk_box_append(@ptrCast(page), self.settings_user);

        // Password
        const pass_label = gtk.gtk_label_new("Password");
        gtk.gtk_widget_add_css_class(pass_label, "settings-label");
        gtk.gtk_label_set_xalign(@ptrCast(pass_label), 0);
        gtk.gtk_box_append(@ptrCast(page), pass_label);

        self.settings_pass = gtk.gtk_password_entry_new();
        gtk.gtk_widget_add_css_class(self.settings_pass, "settings-entry");
        gtk.gtk_password_entry_set_show_peek_icon(@ptrCast(self.settings_pass), 1);
        {
            var buf: [256]u8 = undefined;
            const len = @min(self.config.password.len, buf.len - 1);
            @memcpy(buf[0..len], self.config.password[0..len]);
            buf[len] = 0;
            gtk.gtk_editable_set_text(@ptrCast(self.settings_pass), @ptrCast(&buf));
        }
        gtk.gtk_box_append(@ptrCast(page), self.settings_pass);

        // Cache size
        const cache_label = gtk.gtk_label_new("Audio cache size (MB)");
        gtk.gtk_widget_add_css_class(cache_label, "settings-label");
        gtk.gtk_label_set_xalign(@ptrCast(cache_label), 0);
        gtk.gtk_box_append(@ptrCast(page), cache_label);

        self.settings_cache = gtk.gtk_spin_button_new_with_range(0, 4096, 64);
        gtk.gtk_widget_add_css_class(self.settings_cache, "settings-entry");
        gtk.gtk_spin_button_set_value(@ptrCast(self.settings_cache), @floatFromInt(self.config.cache_size_mb));
        gtk.gtk_box_append(@ptrCast(page), self.settings_cache);

        // Save button
        const save_btn = gtk.gtk_button_new_with_label("Save");
        gtk.gtk_widget_add_css_class(save_btn, "settings-save-btn");
        gtk.gtk_widget_set_halign(save_btn, gtk.GTK_ALIGN_START);
        _ = g_signal_connect(save_btn, "clicked", &onSettingsSave, self);
        gtk.gtk_box_append(@ptrCast(page), save_btn);

        return page;
    }

    fn buildDetailPage(self: *App) *gtk.GtkWidget {
        const page = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);
        gtk.gtk_widget_set_hexpand(page, 1);

        // Header with art + info
        const header = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 24);
        gtk.gtk_widget_add_css_class(header, "detail-header");

        self.detail_art = gtk.gtk_picture_new();
        gtk.gtk_widget_set_size_request(self.detail_art, 220, 220);
        gtk.gtk_widget_add_css_class(self.detail_art, "detail-art");
        gtk.gtk_box_append(@ptrCast(header), self.detail_art);

        const info = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 4);
        gtk.gtk_widget_set_valign(info, gtk.GTK_ALIGN_END);
        gtk.gtk_widget_set_hexpand(info, 1);

        const type_lbl = gtk.gtk_label_new("ALBUM");
        gtk.gtk_widget_add_css_class(type_lbl, "type-label");
        gtk.gtk_label_set_xalign(@ptrCast(type_lbl), 0);
        gtk.gtk_box_append(@ptrCast(info), type_lbl);

        self.detail_title = gtk.gtk_label_new("");
        gtk.gtk_widget_add_css_class(self.detail_title, "detail-title");
        gtk.gtk_label_set_xalign(@ptrCast(self.detail_title), 0);
        gtk.gtk_label_set_ellipsize(@ptrCast(self.detail_title), 3);
        gtk.gtk_label_set_max_width_chars(@ptrCast(self.detail_title), 40);
        gtk.gtk_box_append(@ptrCast(info), self.detail_title);

        self.detail_artist = gtk.gtk_label_new("");
        gtk.gtk_widget_add_css_class(self.detail_artist, "detail-artist");
        gtk.gtk_label_set_xalign(@ptrCast(self.detail_artist), 0);
        gtk.gtk_box_append(@ptrCast(info), self.detail_artist);

        const spacer = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);
        gtk.gtk_widget_set_size_request(spacer, -1, 12);
        gtk.gtk_box_append(@ptrCast(info), spacer);

        const play_all = gtk.gtk_button_new_with_label("Play");
        gtk.gtk_widget_add_css_class(play_all, "play-all-btn");
        gtk.gtk_widget_set_halign(play_all, gtk.GTK_ALIGN_START);
        _ = g_signal_connect(play_all, "clicked", &onPlayAll, self);
        gtk.gtk_box_append(@ptrCast(info), play_all);

        gtk.gtk_box_append(@ptrCast(header), info);
        gtk.gtk_box_append(@ptrCast(page), header);

        // Track list + suggestions in a scrollable area
        const track_scroll = gtk.gtk_scrolled_window_new();
        gtk.gtk_widget_set_vexpand(track_scroll, 1);
        gtk.gtk_widget_set_hexpand(track_scroll, 1);

        const track_container = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);
        gtk.gtk_widget_set_hexpand(track_container, 1);

        self.track_list_box = gtk.gtk_list_box_new();
        gtk.gtk_widget_add_css_class(self.track_list_box, "track-list");
        gtk.gtk_list_box_set_selection_mode(@ptrCast(self.track_list_box), gtk.GTK_SELECTION_SINGLE);
        _ = g_signal_connect(self.track_list_box, "row-activated", &onTrackActivated, self);
        gtk.gtk_box_append(@ptrCast(track_container), self.track_list_box);

        // Suggestions section (hidden until a playlist is open)
        self.suggestions_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);
        gtk.gtk_widget_set_visible(self.suggestions_box, 0);
        gtk.gtk_box_append(@ptrCast(track_container), self.suggestions_box);

        gtk.gtk_scrolled_window_set_child(@ptrCast(track_scroll), track_container);
        gtk.gtk_box_append(@ptrCast(page), track_scroll);

        return page;
    }

    fn buildNowPlayingBar(self: *App) *gtk.GtkWidget {
        const bar = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);
        gtk.gtk_widget_add_css_class(bar, "now-playing");

        // Thin progress bar at top
        const progress_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 0);
        gtk.gtk_widget_add_css_class(progress_box, "np-progress");
        self.progress_scale = gtk.gtk_scale_new_with_range(gtk.GTK_ORIENTATION_HORIZONTAL, 0, 1, 0.001);
        gtk.gtk_scale_set_draw_value(@ptrCast(self.progress_scale), 0);
        gtk.gtk_widget_set_hexpand(self.progress_scale, 1);
        _ = g_signal_connect(self.progress_scale, "value-changed", &onProgressChanged, self);
        gtk.gtk_box_append(@ptrCast(progress_box), self.progress_scale);
        gtk.gtk_box_append(@ptrCast(bar), progress_box);

        // Main row: info | controls | time
        const row = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 0);
        gtk.gtk_widget_set_margin_start(row, 16);
        gtk.gtk_widget_set_margin_end(row, 16);
        gtk.gtk_widget_set_margin_top(row, 8);
        gtk.gtk_widget_set_margin_bottom(row, 10);

        // Left: clickable art + track info -> opens source album/playlist
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

        // Wrap in a button
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

        // Right: time + queue toggle
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

        // Volume
        self.volume_btn = gtk.gtk_button_new_from_icon_name("audio-volume-high-symbolic");
        gtk.gtk_widget_add_css_class(self.volume_btn, "control-btn");
        _ = g_signal_connect(self.volume_btn, "clicked", &onVolumeMute, self);
        gtk.gtk_box_append(@ptrCast(right), self.volume_btn);

        self.volume_scale = gtk.gtk_scale_new_with_range(gtk.GTK_ORIENTATION_HORIZONTAL, 0, 1, 0.01);
        gtk.gtk_scale_set_draw_value(@ptrCast(self.volume_scale), 0);
        gtk.gtk_range_set_value(@ptrCast(self.volume_scale), 1.0);
        gtk.gtk_widget_set_size_request(self.volume_scale, 80, -1);
        gtk.gtk_widget_add_css_class(self.volume_scale, "volume-scale");
        _ = g_signal_connect(self.volume_scale, "value-changed", &onVolumeChanged, self);
        gtk.gtk_box_append(@ptrCast(right), self.volume_scale);

        // Queue toggle
        self.queue_btn = gtk.gtk_button_new_from_icon_name("view-list-symbolic");
        gtk.gtk_widget_add_css_class(self.queue_btn, "control-btn");
        _ = g_signal_connect(self.queue_btn, "clicked", &onToggleQueue, self);
        gtk.gtk_box_append(@ptrCast(right), self.queue_btn);

        gtk.gtk_box_append(@ptrCast(row), right);
        gtk.gtk_box_append(@ptrCast(bar), row);

        return bar;
    }

    // ---------------------------------------------------------------
    // Album grid
    // ---------------------------------------------------------------
    fn initBackendIdle(data: ?*anyopaque) callconv(.c) c_int {
        const self: *App = @ptrCast(@alignCast(data));

        // Init audio engine synchronously (fast, no network)
        self.player = Player.create(self.allocator) catch |err| {
            log.err("audio init failed: {}", .{err});
            return 0;
        };

        // MPRIS media key integration
        global_app = self;
        mpris.init(self.player.?, .{
            .play_pause = &mprisPlayPause,
            .next = &mprisNext,
            .prev = &mprisPrev,
            .stop = &mprisStop,
            .raise = &mprisRaise,
        });

        // Do all network on a background thread
        const thread = std.Thread.spawn(.{}, initThread, .{self}) catch {
            log.err("failed to spawn init thread", .{});
            return 0;
        };
        thread.detach();
        return 0;
    }

    fn initThread(self: *App) void {
        var bg_client = api.Client.init(self.allocator, self.client.base_url);
        defer bg_client.deinit();

        bg_client.authenticate(self.config.username, self.config.password) catch |err| {
            log.err("auth failed: {}", .{err});
            const StatusCb = struct {
                app: *App,
                fn apply(data: ?*anyopaque) callconv(.c) c_int {
                    const s: *@This() = @ptrCast(@alignCast(data));
                    setLabelText(s.app.np_title, "Auth failed - check Settings");
                    std.heap.c_allocator.destroy(s);
                    return 0;
                }
            };
            const cb = std.heap.c_allocator.create(StatusCb) catch return;
            cb.* = .{ .app = self };
            _ = gtk.g_idle_add(&StatusCb.apply, cb);
            return;
        };

        self.client.token = bg_client.token;
        self.client.user_id = bg_client.user_id;

        // Home page data first - small, fast
        self.home_recent = bg_client.getRecentlyPlayed(50) catch null;
        self.home_added = bg_client.getRecentlyAdded(20) catch null;
        self.home_random = bg_client.getRandomAlbums(20) catch null;
        self.home_favorites = bg_client.getFavoriteAlbums(20) catch null;
        self.playlists = bg_client.getPlaylists() catch null;

        // Show home page immediately
        _ = gtk.g_idle_add(&onHomeReady, self);

        // Prefetch playlist contents into memory
        if (self.playlists) |pls| {
            for (pls.items) |playlist| {
                const tracks = bg_client.getPlaylistTracks(playlist.id) catch continue;
                self.playlist_cache_mutex.lock();
                self.playlist_cache.put(playlist.id, tracks) catch {};
                self.playlist_cache_mutex.unlock();
            }
            log.info("prefetched {d} playlist contents", .{pls.items.len});
        }

        // Full album list
        const albums = bg_client.getAlbums() catch |err| {
            log.err("failed to load albums: {}", .{err});
            return;
        };
        log.info("loaded {d} albums", .{albums.items.len});
        self.albums = albums;
        _ = gtk.g_idle_add(&onAlbumsReady, self);

        _ = bg_client.fetchAndCacheAlbums() catch {};
    }

    fn onHomeReady(data: ?*anyopaque) callconv(.c) c_int {
        const self: *App = @ptrCast(@alignCast(data));
        self.buildHomePage();
        self.populatePlaylists();
        setLabelText(self.np_title, "Nothing playing");
        return 0;
    }

    fn onAlbumsReady(data: ?*anyopaque) callconv(.c) c_int {
        const self: *App = @ptrCast(@alignCast(data));
        // Pre-populate albums grid if user hasn't navigated there yet
        self.filterAlbums("");
        return 0;
    }

    fn buildHomePage(self: *App) void {
        clearChildren(self.home_box, .box);

        // Continue Listening - deduplicate recently played songs by album
        if (self.home_recent) |recent| {
            if (recent.items.len > 0) {
                self.addHomeSection("Continue Listening", self.dedupeByAlbum(recent.items));
            }
        }

        // Recently Added
        if (self.home_added) |added| {
            if (added.items.len > 0) {
                self.addHomeSection("Recently Added", added.items);
            }
        }

        // Favorites
        if (self.home_favorites) |favs| {
            if (favs.items.len > 0) {
                self.addHomeSection("Favorites", favs.items);
            }
        }

        // Discover
        if (self.home_random) |random| {
            if (random.items.len > 0) {
                self.addHomeSection("Discover", random.items);
            }
        }

        // Load art for home sections
        self.spawnHomeArtLoader();
    }

    fn dedupeByAlbum(self: *App, songs: []models.BaseItem) []models.BaseItem {
        if (self.deduped_albums) |old| self.allocator.free(old);
        self.deduped_albums = null;

        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();

        var result = self.allocator.alloc(models.BaseItem, @min(songs.len, 20)) catch return &.{};
        var count: usize = 0;

        for (songs) |song| {
            if (count >= 20) break;
            const album_id = song.album_id orelse song.parent_id orelse continue;
            if (seen.contains(album_id)) continue;
            seen.put(album_id, {}) catch continue;

            result[count] = .{
                .id = album_id,
                .name = song.album orelse song.name,
                .album_artist = song.album_artist,
                .item_type = "MusicAlbum",
            };
            count += 1;
        }

        self.deduped_albums = result;
        return result[0..count];
    }

    fn addHomeSection(self: *App, title: [*:0]const u8, items: []models.BaseItem) void {
        const section = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);
        gtk.gtk_widget_add_css_class(section, "home-section");

        const label = gtk.gtk_label_new(title);
        gtk.gtk_widget_add_css_class(label, "section-title");
        gtk.gtk_label_set_xalign(@ptrCast(label), 0);
        gtk.gtk_box_append(@ptrCast(section), label);

        // Horizontal scrolling row
        const scroll = gtk.gtk_scrolled_window_new();
        gtk.gtk_scrolled_window_set_policy(@ptrCast(scroll), gtk.GTK_POLICY_AUTOMATIC, gtk.GTK_POLICY_NEVER);
        gtk.gtk_widget_set_size_request(scroll, -1, 230);

        const row = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 12);
        gtk.gtk_widget_add_css_class(row, "home-row");
        gtk.gtk_widget_set_margin_start(row, 20);
        gtk.gtk_widget_set_margin_end(row, 20);

        for (items) |item| {
            const card = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);
            gtk.gtk_widget_add_css_class(card, "album-card");

            // Art
            const art = gtk.gtk_picture_new();
            gtk.gtk_widget_add_css_class(art, "grid-art");
            gtk.gtk_widget_set_size_request(art, 150, 150);
            gtk.gtk_widget_set_vexpand(art, 0);
            gtk.gtk_widget_set_hexpand(art, 0);
            gtk.gtk_picture_set_content_fit(@ptrCast(art), gtk.GTK_CONTENT_FIT_COVER);
            // Store item ID on picture for art loading
            if (std.fmt.allocPrintSentinel(self.allocator, "{s}", .{item.id}, 0)) |z|
                setObjString(@ptrCast(art), "art-id", z)
            else |_| {}
            gtk.gtk_widget_set_name(art, "needs-art");
            gtk.gtk_box_append(@ptrCast(card), art);

            const name = makeLabel(self.allocator, item.name);
            gtk.gtk_widget_add_css_class(name, "album-title");
            gtk.gtk_label_set_xalign(@ptrCast(name), 0);
            gtk.gtk_label_set_ellipsize(@ptrCast(name), 3);
            gtk.gtk_label_set_max_width_chars(@ptrCast(name), 18);
            gtk.gtk_box_append(@ptrCast(card), name);

            if (item.album_artist) |artist_name| {
                const artist = makeLabel(self.allocator, artist_name);
                gtk.gtk_widget_add_css_class(artist, "album-artist");
                gtk.gtk_label_set_xalign(@ptrCast(artist), 0);
                gtk.gtk_label_set_ellipsize(@ptrCast(artist), 3);
                gtk.gtk_label_set_max_width_chars(@ptrCast(artist), 18);
                gtk.gtk_box_append(@ptrCast(card), artist);
            }

            const button = gtk.gtk_button_new();
            gtk.gtk_widget_add_css_class(button, "flat");
            gtk.gtk_widget_add_css_class(button, "album-card-btn");
            gtk.gtk_widget_set_valign(button, gtk.GTK_ALIGN_START);
            gtk.gtk_button_set_child(@ptrCast(button), card);

            // Store null-terminated album ID on the button
            if (std.fmt.allocPrintSentinel(self.allocator, "{s}", .{item.id}, 0)) |z|
                setObjString(@ptrCast(button), "item-id", z)
            else |_| {}
            _ = g_signal_connect(button, "clicked", &onHomeCardClicked, self);

            gtk.gtk_box_append(@ptrCast(row), button);
        }

        gtk.gtk_scrolled_window_set_child(@ptrCast(scroll), row);
        // Tag scroll with its row box so the art loader can find it
        gtk.g_object_set_data(@ptrCast(scroll), "row-box", @ptrCast(row));
        gtk.gtk_box_append(@ptrCast(section), scroll);
        gtk.gtk_box_append(@ptrCast(self.home_box), section);
    }

    fn spawnHomeArtLoader(self: *App) void {
        _ = self.home_art_gen.fetchAdd(1, .release);
        var jobs = std.array_list.AlignedManaged(ArtJob, null).init(self.allocator);
        const gen = self.home_art_gen.load(.acquire);
        const gen_ptr = &self.home_art_gen;

        var section = gtk.gtk_widget_get_first_child(self.home_box);
        while (section != null) : (section = gtk.gtk_widget_get_next_sibling(section)) {
            var section_child = gtk.gtk_widget_get_first_child(section);
            while (section_child != null) : (section_child = gtk.gtk_widget_get_next_sibling(section_child)) {
                const row = gtk.g_object_get_data(@ptrCast(section_child), "row-box");
                if (row != null) {
                    collectArtJobsFromBox(@ptrCast(@alignCast(row)), &jobs);
                }
            }
        }

        if (jobs.items.len == 0) {
            jobs.deinit();
            return;
        }

        self.spawnArtThread(jobs, gen, gen_ptr);
    }

    fn populatePlaylists(self: *App) void {
        clearChildren(self.sidebar_playlists, .listbox);
        const pls = self.playlists orelse return;
        for (pls.items) |playlist| {
            const label = makeLabel(self.allocator, playlist.name);
            gtk.gtk_widget_add_css_class(label, "sidebar-playlist-item");
            gtk.gtk_label_set_xalign(@ptrCast(label), 0);
            gtk.gtk_label_set_ellipsize(@ptrCast(label), 3);
            gtk.gtk_list_box_append(@ptrCast(self.sidebar_playlists), label);
        }
        log.info("loaded {d} playlists", .{pls.items.len});
    }

    fn filterAlbums(self: *App, query: []const u8) void {
        clearChildren(self.album_grid, .flowbox);
        _ = self.grid_art_gen.fetchAdd(1, .release);

        const albums = self.albums orelse return;
        var count: usize = 0;

        for (albums.items, 0..) |album, i| {
            if (count >= MAX_GRID_ITEMS) break;
            if (query.len == 0 or matchesSearch(album, query)) {
                self.addAlbumCard(album, i);
                count += 1;
            }
        }

        // Load art on background thread
        self.spawnArtLoader();
    }

    fn addAlbumCard(self: *App, album: models.BaseItem, index: usize) void {
        const card = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);
        gtk.gtk_widget_add_css_class(card, "album-card");

        // Art picture - starts as placeholder, loaded lazily
        const art = gtk.gtk_picture_new();
        gtk.gtk_widget_add_css_class(art, "grid-art");
        gtk.gtk_widget_set_size_request(art, 160, 160);
        gtk.gtk_widget_set_vexpand(art, 0);
        gtk.gtk_widget_set_hexpand(art, 0);
        gtk.gtk_picture_set_content_fit(@ptrCast(art), gtk.GTK_CONTENT_FIT_COVER);
        // Tag with "needs-art" so the idle loader finds it
        gtk.gtk_widget_set_name(art, "needs-art");
        gtk.gtk_box_append(@ptrCast(card), art);

        // Title
        const title = makeLabel(self.allocator, album.name);
        gtk.gtk_widget_add_css_class(title, "album-title");
        gtk.gtk_label_set_xalign(@ptrCast(title), 0);
        gtk.gtk_label_set_ellipsize(@ptrCast(title), 3);
        gtk.gtk_label_set_max_width_chars(@ptrCast(title), 22);
        gtk.gtk_box_append(@ptrCast(card), title);

        // Artist
        if (album.album_artist) |artist_name| {
            const artist = makeLabel(self.allocator, artist_name);
            gtk.gtk_widget_add_css_class(artist, "album-artist");
            gtk.gtk_label_set_xalign(@ptrCast(artist), 0);
            gtk.gtk_label_set_ellipsize(@ptrCast(artist), 3);
            gtk.gtk_label_set_max_width_chars(@ptrCast(artist), 22);
            gtk.gtk_box_append(@ptrCast(card), artist);
        }

        // Wrap in clickable button
        const button = gtk.gtk_button_new();
        gtk.gtk_widget_add_css_class(button, "flat");
        gtk.gtk_widget_add_css_class(button, "album-card-btn");
        gtk.gtk_widget_set_valign(button, gtk.GTK_ALIGN_START);
        gtk.gtk_button_set_child(@ptrCast(button), card);
        gtk.g_object_set_data(@ptrCast(button), "idx", @ptrFromInt(index + 1));
        _ = g_signal_connect(button, "clicked", &onAlbumCardClicked, self);

        gtk.gtk_flow_box_append(@ptrCast(self.album_grid), button);
    }

    // ---------------------------------------------------------------
    // Album detail
    // ---------------------------------------------------------------
    fn showAlbumDetail(self: *App, album_index: usize) void {
        const albums = self.albums orelse return;
        if (album_index >= albums.items.len) return;
        const album = albums.items[album_index];
        self.current_album_idx = album_index;
        self.current_playlist_idx = null;
        self.current_playlist_id = null;
        gtk.gtk_widget_set_visible(self.suggestions_box, 0);

        setLabelText(self.detail_title, album.name);
        setLabelText(self.detail_artist, album.album_artist orelse "Unknown Artist");
        gtk.gtk_picture_set_paintable(@ptrCast(self.detail_art), null);
        clearChildren(self.track_list_box, .listbox);
        self.navigateTo("detail");

        // Art from disk cache is fast
        self.loadArtAsync(album.id, self.detail_art, 300);

        // Check track cache first
        self.album_track_cache_mutex.lock();
        const cached = self.album_track_cache.get(album.id);
        self.album_track_cache_mutex.unlock();

        if (cached) |tracks| {
            self.tracks = tracks;
            for (tracks.items) |track| {
                self.addTrackRow(track);
            }
            self.highlightCurrentTrack();
        } else {
            self.loadDetailAsync(album.id, false);
        }
    }

    // Background art loading for grid cards
    fn spawnArtLoader(self: *App) void {
        const albums = self.albums orelse return;
        _ = self.grid_art_gen.fetchAdd(1, .release);
        const gen = self.grid_art_gen.load(.acquire);

        var jobs = std.array_list.AlignedManaged(ArtJob, null).init(self.allocator);

        var child = gtk.gtk_widget_get_first_child(self.album_grid);
        while (child != null) : (child = gtk.gtk_widget_get_next_sibling(child)) {
            const btn = gtk.gtk_widget_get_first_child(child) orelse continue;
            const card_box = gtk.gtk_widget_get_first_child(btn) orelse continue;
            const picture = gtk.gtk_widget_get_first_child(card_box) orelse continue;

            const name = gtk.gtk_widget_get_name(picture);
            if (name == null) continue;
            const name_slice = std.mem.span(@as([*:0]const u8, @ptrCast(name)));
            if (!std.mem.eql(u8, name_slice, "needs-art")) continue;

            const raw_idx = @intFromPtr(gtk.g_object_get_data(@ptrCast(btn), "idx"));
            if (raw_idx == 0) continue;
            const album_idx = raw_idx - 1;
            if (album_idx >= albums.items.len) continue;

            gtk.gtk_widget_set_name(picture, "art-loading");
            jobs.append(.{ .id = albums.items[album_idx].id, .widget = picture }) catch continue;
        }

        self.spawnArtThread(jobs, gen, &self.grid_art_gen);
    }

    fn spawnArtThread(self: *App, jobs: std.array_list.AlignedManaged(ArtJob, null), gen: u32, gen_ptr: *std.atomic.Value(u32)) void {
        if (jobs.items.len == 0) {
            var j = jobs;
            j.deinit();
            return;
        }

        const Ctx = struct {
            base_url: []const u8,
            alloc: std.mem.Allocator,
            jobs: std.array_list.AlignedManaged(ArtJob, null),
            gen: u32,
            gen_ptr: *std.atomic.Value(u32),
        };
        const ctx = self.allocator.create(Ctx) catch {
            var j = jobs;
            j.deinit();
            return;
        };
        ctx.* = .{
            .base_url = self.client.base_url,
            .alloc = self.allocator,
            .jobs = jobs,
            .gen = gen,
            .gen_ptr = gen_ptr,
        };

        const thread = std.Thread.spawn(.{}, artLoaderThread, .{ctx}) catch {
            var j = jobs;
            j.deinit();
            self.allocator.destroy(ctx);
            return;
        };
        thread.detach();
    }

    fn artLoaderThread(ctx: anytype) void {
        defer {
            ctx.jobs.deinit();
            ctx.alloc.destroy(ctx);
        }

        // Single HTTP client for all fetches - connection reuse via keep-alive
        var client = api.Client.init(ctx.alloc, ctx.base_url);
        defer client.deinit();

        for (ctx.jobs.items) |job| {
            if (ctx.gen_ptr.load(.acquire) != ctx.gen) return;

            const img_data = loadCachedArt(ctx.alloc, job.id) orelse blk: {
                const img_url = std.fmt.allocPrint(ctx.alloc, "{s}/Items/{s}/Images/Primary?maxWidth=160", .{ ctx.base_url, job.id }) catch continue;
                defer ctx.alloc.free(img_url);

                const data = client.fetchBytes(img_url) catch {
                    // Connection might be stale - retry with fresh client
                    client.http.deinit();
                    client.http = .{ .allocator = ctx.alloc };
                    const retry = client.fetchBytes(img_url) catch continue;
                    saveCachedArt(job.id, retry);
                    break :blk retry;
                };
                saveCachedArt(job.id, data);
                break :blk data;
            };

            // Post to main thread
            const ArtCb = struct {
                widget: *gtk.GtkWidget,
                data: []const u8,
                alloc: std.mem.Allocator,

                fn apply(data_ptr: ?*anyopaque) callconv(.c) c_int {
                    const self: *@This() = @ptrCast(@alignCast(data_ptr));
                    defer {
                        gtk.g_object_unref(self.widget);
                        self.alloc.free(self.data);
                        self.alloc.destroy(self);
                    }

                    const gbytes = gtk.g_bytes_new(self.data.ptr, self.data.len);
                    defer gtk.g_bytes_unref(gbytes);
                    var err: ?*gtk.GError = null;
                    const texture = gtk.gdk_texture_new_from_bytes(gbytes, &err);
                    if (texture != null) {
                        gtk.gtk_picture_set_paintable(@ptrCast(self.widget), @ptrCast(texture));
                        gtk.g_object_unref(texture);
                    }
                    return 0;
                }
            };

            const cb = ctx.alloc.create(ArtCb) catch {
                ctx.alloc.free(img_data);
                continue;
            };
            _ = gtk.g_object_ref(job.widget);
            cb.* = .{ .widget = job.widget, .data = img_data, .alloc = ctx.alloc };
            _ = gtk.g_idle_add(&ArtCb.apply, cb);
        }
    }

    fn addTrackRow(self: *App, track: models.BaseItem) void {
        self.addTrackRowInner(track, self.current_playlist_id != null);
    }

    fn addTrackRowInner(self: *App, track: models.BaseItem, is_playlist: bool) void {
        const row_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 12);
        gtk.gtk_widget_add_css_class(row_box, "track-row");

        // Track number
        if (track.index_number) |num| {
            var buf: [8]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{num}) catch "?";
            buf[s.len] = 0;
            const lbl = gtk.gtk_label_new(@ptrCast(s.ptr));
            gtk.gtk_widget_add_css_class(lbl, "track-number");
            gtk.gtk_label_set_xalign(@ptrCast(lbl), 1);
            gtk.gtk_widget_set_size_request(lbl, 28, -1);
            gtk.gtk_box_append(@ptrCast(row_box), lbl);
        }

        // Title
        const title = makeLabel(self.allocator, track.name);
        gtk.gtk_widget_add_css_class(title, "track-name");
        gtk.gtk_label_set_xalign(@ptrCast(title), 0);
        gtk.gtk_label_set_ellipsize(@ptrCast(title), 3);
        gtk.gtk_widget_set_hexpand(title, 1);
        gtk.gtk_box_append(@ptrCast(row_box), title);

        // Duration
        if (track.durationSeconds()) |dur| {
            const mins = @as(u32, @intFromFloat(dur)) / 60;
            const secs = @as(u32, @intFromFloat(dur)) % 60;
            var buf: [12]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}:{d:0>2}", .{ mins, secs }) catch "?:??";
            buf[s.len] = 0;
            const lbl = gtk.gtk_label_new(@ptrCast(s.ptr));
            gtk.gtk_widget_add_css_class(lbl, "track-duration");
            gtk.gtk_box_append(@ptrCast(row_box), lbl);
        }

        // "Play Next" button - adds to queue after current track
        const pn_btn = gtk.gtk_button_new_from_icon_name("media-playlist-consecutive-symbolic");
        gtk.gtk_widget_add_css_class(pn_btn, "play-next-btn");
        gtk.gtk_button_set_has_frame(@ptrCast(pn_btn), 0);
        gtk.gtk_widget_set_tooltip_text(pn_btn, "Play next");
        // Store track data via index into self.tracks
        _ = g_signal_connect(pn_btn, "clicked", &onPlayNextClicked, self);
        gtk.gtk_box_append(@ptrCast(row_box), pn_btn);

        // Playlist reorder controls
        if (is_playlist) {
            const up_btn = gtk.gtk_button_new_from_icon_name("go-up-symbolic");
            gtk.gtk_widget_add_css_class(up_btn, "reorder-btn");
            gtk.gtk_button_set_has_frame(@ptrCast(up_btn), 0);
            _ = g_signal_connect(up_btn, "clicked", &onMoveTrackUp, self);
            gtk.gtk_box_append(@ptrCast(row_box), up_btn);

            const down_btn = gtk.gtk_button_new_from_icon_name("go-down-symbolic");
            gtk.gtk_widget_add_css_class(down_btn, "reorder-btn");
            gtk.gtk_button_set_has_frame(@ptrCast(down_btn), 0);
            _ = g_signal_connect(down_btn, "clicked", &onMoveTrackDown, self);
            gtk.gtk_box_append(@ptrCast(row_box), down_btn);

            const rm_btn = gtk.gtk_button_new_from_icon_name("edit-delete-symbolic");
            gtk.gtk_widget_add_css_class(rm_btn, "remove-btn");
            gtk.gtk_button_set_has_frame(@ptrCast(rm_btn), 0);
            // Store track ID for removal
            const tid_z = std.fmt.allocPrintSentinel(self.allocator, "{s}", .{track.id}, 0) catch null;
            if (tid_z) |z| setObjString(@ptrCast(rm_btn), "track-id", z);
            _ = g_signal_connect(rm_btn, "clicked", &onRemoveTrack, self);
            gtk.gtk_box_append(@ptrCast(row_box), rm_btn);
        }

        gtk.gtk_list_box_append(@ptrCast(self.track_list_box), row_box);
    }

    fn onMoveTrackUp(button: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        const pl_id = self.current_playlist_id orelse return;
        const tracks = self.tracks orelse return;

        // Find which row this button is in
        const row_box = gtk.gtk_widget_get_parent(@ptrCast(button)) orelse return;
        const list_row = gtk.gtk_widget_get_parent(row_box) orelse return;
        const idx: usize = @intCast(gtk.gtk_list_box_row_get_index(@ptrCast(list_row)));
        if (idx == 0 or idx >= tracks.items.len) return;

        self.doPlaylistAction(pl_id, tracks.items[idx].id, @intCast(idx - 1), .move);
    }

    fn onMoveTrackDown(button: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        const pl_id = self.current_playlist_id orelse return;
        const tracks = self.tracks orelse return;

        const row_box = gtk.gtk_widget_get_parent(@ptrCast(button)) orelse return;
        const list_row = gtk.gtk_widget_get_parent(row_box) orelse return;
        const idx: usize = @intCast(gtk.gtk_list_box_row_get_index(@ptrCast(list_row)));
        if (idx + 1 >= tracks.items.len) return;

        self.doPlaylistAction(pl_id, tracks.items[idx].id, @intCast(idx + 1), .move);
    }

    fn onRemoveTrack(button: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        const pl_id = self.current_playlist_id orelse return;

        const id_ptr = gtk.g_object_get_data(@ptrCast(button), "track-id");
        if (id_ptr == null) return;
        const track_id = std.mem.span(@as([*:0]const u8, @ptrCast(id_ptr)));

        self.doPlaylistAction(pl_id, track_id, 0, .remove);
    }

    const PlAction = enum { move, remove, add };

    fn doPlaylistAction(self: *App, pl_id: []const u8, item_id: []const u8, new_index: u32, action: PlAction) void {
        const pl_z = std.fmt.allocPrintSentinel(self.allocator, "{s}", .{pl_id}, 0) catch return;
        const item_z = std.fmt.allocPrintSentinel(self.allocator, "{s}", .{item_id}, 0) catch return;
        bg.run(self.allocator, self.client, struct {
            app: *App,
            pl_id: [:0]u8,
            item_id: [:0]u8,
            new_index: u32,
            action: PlAction,
            alloc: std.mem.Allocator,

            ok: bool = true,

            pub fn work(s: *@This(), client: *api.Client) void {
                switch (s.action) {
                    .move => client.movePlaylistItem(s.pl_id, s.item_id, s.new_index) catch {
                        s.ok = false;
                    },
                    .remove => client.removeFromPlaylist(s.pl_id, &.{s.item_id}) catch {
                        s.ok = false;
                    },
                    .add => client.addToPlaylist(s.pl_id, &.{s.item_id}) catch {
                        s.ok = false;
                    },
                }
            }

            pub fn done(s: *@This()) void {
                defer s.alloc.free(s.pl_id);
                defer s.alloc.free(s.item_id);
                if (!s.ok) {
                    setLabelText(s.app.np_title, "Playlist update failed");
                    return;
                }
                s.app.refreshPlaylist();
            }
        }{ .app = self, .pl_id = pl_z, .item_id = item_z, .new_index = new_index, .action = action, .alloc = self.allocator });
    }

    fn refreshPlaylist(self: *App) void {
        const pl_id = self.current_playlist_id orelse return;
        self.loadDetailAsync(pl_id, true);
    }

    fn loadArtAsync(self: *App, item_id: []const u8, target: *gtk.GtkWidget, size: u32) void {
        const id_z = std.fmt.allocPrintSentinel(self.allocator, "{s}", .{item_id}, 0) catch return;
        _ = gtk.g_object_ref(target);
        bg.run(self.allocator, self.client, struct {
            widget: *gtk.GtkWidget,
            id: [:0]u8,
            size: u32,
            alloc: std.mem.Allocator,
            data: ?[]const u8 = null,

            pub fn work(s: *@This(), client: *api.Client) void {
                s.data = loadCachedArt(s.alloc, s.id) orelse blk: {
                    const url = client.getImageUrl(s.id, s.size) catch return;
                    defer s.alloc.free(url);
                    const d = client.fetchBytes(url) catch return;
                    saveCachedArt(s.id, d);
                    break :blk d;
                };
            }

            pub fn done(s: *@This()) void {
                defer s.alloc.free(s.id);
                defer gtk.g_object_unref(s.widget);
                if (s.data) |d| {
                    defer s.alloc.free(d);
                    applyTexture(s.widget, d);
                }
            }
        }{ .widget = target, .id = id_z, .size = size, .alloc = self.allocator });
    }

    // ---------------------------------------------------------------
    // Playback
    // ---------------------------------------------------------------
    fn playTrack(self: *App, index: usize) void {
        const tracks = self.tracks orelse return;
        if (index >= tracks.items.len) return;
        const track = tracks.items[index];
        const p = self.player orelse return;

        // Bump generation to cancel stale async downloads
        _ = self.play_generation.fetchAdd(1, .release);
        const gen = self.play_generation.load(.acquire);

        self.playing_album_idx = self.current_album_idx;
        self.playing_playlist_id = self.current_playlist_id;

        if (self.audio_cache.findSlot(track.id)) |slot| {
            var buf: [64]u8 = undefined;
            p.playFile(AudioCache.tempPath(&buf, slot));
            self.updateNowPlaying(track);
            self.prefetchAhead(index);
            self.preloadNextTrack();
        } else if (blk: {
            var dbuf: [320]u8 = undefined;
            break :blk self.disk_audio_cache.getPath(track.id, &dbuf);
        }) |disk_path| {
            // On persistent disk cache - copy to temp slot for miniaudio
            const slot = self.audio_cache.allocSlot();
            var tbuf: [64]u8 = undefined;
            const tmp_path = AudioCache.tempPathSlice(&tbuf, slot);
            std.fs.copyFileAbsolute(disk_path, tmp_path, .{}) catch {
                // Fall through to download
                self.startAsyncDownload(track, gen, index);
                return;
            };
            self.audio_cache.markReady(slot, track.id);
            var pbuf: [64]u8 = undefined;
            p.playFile(AudioCache.tempPath(&pbuf, slot));
            self.updateNowPlaying(track);
            self.prefetchAhead(index);
            self.preloadNextTrack();
        } else {
            self.startAsyncDownload(track, gen, index);
        }
    }

    fn startAsyncDownload(self: *App, track: models.BaseItem, gen: u32, index: usize) void {
            setLabelText(self.np_title, "Loading...");
            setLabelText(self.np_artist, "");

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
                    // Stale - user clicked a different track
                    if (s.gen != s.app.play_generation.load(.acquire)) return;
                    if (!s.ok) {
                        setLabelText(s.app.np_title, "Download failed");
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
                    p2.current_track_name = s.track_name;
                    p2.current_artist = s.track_artist;
                    p2.current_album = s.track_album;
                    setLabelText(s.app.np_title, s.track_name);
                    setLabelText(s.app.np_artist, s.track_artist orelse "");
                    gtk.gtk_button_set_icon_name(@ptrCast(s.app.play_btn), "media-playback-pause-symbolic");
                    s.app.highlightCurrentTrack();
                    mpris.notifyPropertyChanged("PlaybackStatus");
                    mpris.notifyPropertyChanged("Metadata");
                    s.app.prefetchAhead(s.index);
                    s.app.preloadNextTrack();
                    s.app.refreshQueueIfVisible();
                }
            }{ .app = self, .url = url, .slot = slot, .track_id = track.id,
               .track_name = track.name, .track_artist = track.album_artist orelse track.album,
               .track_album = track.album, .gen = gen, .index = index, .alloc = self.allocator });
    }

    fn setQueue(self: *App, items: []const models.BaseItem, start_index: usize) void {
        // Free old owned queue
        if (self.track_queue_owned) {
            if (self.track_queue) |old| self.allocator.free(old);
        }
        // Dupe so it's independent of the displayed track list
        self.track_queue = self.allocator.dupe(models.BaseItem, items) catch {
            self.track_queue = null;
            self.track_queue_owned = false;
            return;
        };
        self.track_queue_owned = true;
        self.queue_index = start_index;
        self.refreshQueueIfVisible();
    }

    fn refreshQueueIfVisible(self: *App) void {
        if (gtk.gtk_revealer_get_reveal_child(@ptrCast(self.queue_revealer)) != 0) {
            self.rebuildQueueList();
        }
    }

    fn updateNowPlaying(self: *App, track: models.BaseItem) void {
        const p = self.player orelse return;
        p.current_track_name = track.name;
        p.current_artist = track.album_artist orelse track.album;
        p.current_album = track.album;

        setLabelText(self.np_title, track.name);
        setLabelText(self.np_artist, p.current_artist orelse "");
        gtk.gtk_button_set_icon_name(@ptrCast(self.play_btn), "media-playback-pause-symbolic");

        if (self.current_album_idx) |idx| {
            const albums = self.albums orelse return;
            if (idx < albums.items.len) {
                self.loadNpArt(albums.items[idx].id);
            }
        }

        self.highlightCurrentTrack();
        mpris.notifyPropertyChanged("PlaybackStatus");
        mpris.notifyPropertyChanged("Metadata");

        self.refreshQueueIfVisible();
    }

    fn highlightCurrentTrack(self: *App) void {
        const displayed = self.tracks orelse return;
        const queue = self.track_queue orelse return;

        var playing_display_idx: ?usize = null;
        if (self.queue_index < queue.len) {
            const playing_id = queue[self.queue_index].id;
            for (displayed.items, 0..) |item, i| {
                if (std.mem.eql(u8, item.id, playing_id)) {
                    playing_display_idx = i;
                    break;
                }
            }
        }

        var child = gtk.gtk_widget_get_first_child(self.track_list_box);
        var i: usize = 0;
        while (child != null) : (child = gtk.gtk_widget_get_next_sibling(child)) {
            const inner = gtk.gtk_list_box_row_get_child(@ptrCast(child));
            if (inner != null) {
                if (playing_display_idx != null and i == playing_display_idx.?) {
                    gtk.gtk_widget_add_css_class(inner, "track-playing");
                } else {
                    gtk.gtk_widget_remove_css_class(inner, "track-playing");
                }
            }
            i += 1;
        }

        if (playing_display_idx) |idx| {
            const row = gtk.gtk_list_box_get_row_at_index(@ptrCast(self.track_list_box), @intCast(idx));
            if (row != null) {
                gtk.gtk_list_box_select_row(@ptrCast(self.track_list_box), row);
            }
        } else {
            gtk.gtk_list_box_unselect_all(@ptrCast(self.track_list_box));
        }
    }

    fn preloadNextTrack(self: *App) void {
        const p = self.player orelse return;
        const queue = self.track_queue orelse return;
        if (self.queue_index + 1 >= queue.len) return;

        const next_track = queue[self.queue_index + 1];

        // Check if the next track's audio file is already cached
        if (self.audio_cache.findSlot(next_track.id)) |slot| {
            var buf: [64]u8 = undefined;
            const path = AudioCache.tempPath(&buf, slot);
            p.preloadNext(path);
        }
    }

    fn prefetchAhead(self: *App, current_index: usize) void {
        const queue = self.track_queue orelse return;
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
                    // Disk cache hit but copy failed - download instead
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
        self.preloadNextTrack();
        return 0;
    }

    fn loadNpArt(self: *App, album_id: []const u8) void {
        const id_z = std.fmt.allocPrintSentinel(self.allocator, "{s}", .{album_id}, 0) catch return;
        bg.run(self.allocator, self.client, struct {
            app: *App,
            id: [:0]u8,
            alloc: std.mem.Allocator,
            data: ?[]const u8 = null,

            pub fn work(s: *@This(), client: *api.Client) void {
                s.data = loadCachedArt(s.alloc, s.id) orelse blk: {
                    const url = client.getImageUrl(s.id, 120) catch return;
                    defer s.alloc.free(url);
                    const d = client.fetchBytes(url) catch return;
                    saveCachedArt(s.id, d);
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

    fn playNext(self: *App) void {
        const queue = self.track_queue orelse return;
        if (self.queue_index + 1 < queue.len) {
            self.queue_index += 1;
            self.playTrack(self.queue_index);
        }
    }

    fn playPrev(self: *App) void {
        if (self.queue_index > 0) {
            self.queue_index -= 1;
            self.playTrack(self.queue_index);
        }
    }

    // ---------------------------------------------------------------
    // Signal handlers
    // ---------------------------------------------------------------
    fn onSearchChanged(entry: *gtk.GtkSearchEntry, data: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        const raw: [*c]const u8 = gtk.gtk_editable_get_text(@ptrCast(entry));
        const query = std.mem.span(@as([*:0]const u8, @ptrCast(raw)));

        self.navigateTo("albums");
        self.filterAlbums(query);
    }

    fn onHomeCardClicked(button: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        const id_ptr = gtk.g_object_get_data(@ptrCast(button), "item-id");
        if (id_ptr == null) return;
        const id: [*:0]const u8 = @ptrCast(id_ptr);
        const id_slice = std.mem.span(id);

        // Find album index in the full album list
        const albums = self.albums orelse return;
        for (albums.items, 0..) |album, i| {
            if (std.mem.eql(u8, album.id, id_slice)) {
                self.showAlbumDetail(i);
                return;
            }
        }
        // Not found in albums - might be a deduped recent play
        // Try fetching tracks directly using the ID as album
        self.showAlbumById(id_slice);
    }

    fn showAlbumById(self: *App, album_id: []const u8) void {
        setLabelText(self.detail_title, "");
        setLabelText(self.detail_artist, "");
        gtk.gtk_picture_set_paintable(@ptrCast(self.detail_art), null);
        self.current_album_idx = null;
        self.current_playlist_idx = null;
        self.current_playlist_id = null;
        gtk.gtk_widget_set_visible(self.suggestions_box, 0);
        clearChildren(self.track_list_box, .listbox);
        self.navigateTo("detail");

        self.loadArtAsync(album_id, self.detail_art, 300);

        // Check cache
        self.album_track_cache_mutex.lock();
        const cached = self.album_track_cache.get(album_id);
        self.album_track_cache_mutex.unlock();

        if (cached) |tracks| {
            self.tracks = tracks;
            if (tracks.items.len > 0) {
                setLabelText(self.detail_title, tracks.items[0].album orelse "Unknown");
                setLabelText(self.detail_artist, tracks.items[0].album_artist orelse "");
            }
            for (tracks.items) |track| {
                self.addTrackRow(track);
            }
            self.highlightCurrentTrack();
        } else {
            self.loadDetailAsync(album_id, false);
        }
    }

    fn onAlbumCardClicked(button: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        const raw = @intFromPtr(gtk.g_object_get_data(@ptrCast(button), "idx"));
        if (raw == 0) return;
        self.showAlbumDetail(raw - 1);
    }

    fn navPush(self: *App, page: [*:0]const u8) void {
        if (self.nav_inhibit) return;
        // Don't push duplicates
        if (self.nav_pos >= 0 and self.nav_pos < @as(i32, @intCast(self.nav_stack.len))) {
            if (self.nav_stack[@intCast(self.nav_pos)] == page) return;
        }
        if (self.nav_pos + 1 >= @as(i32, @intCast(self.nav_stack.len))) {
            // Stack full - shift everything down
            for (0..self.nav_stack.len - 1) |i| {
                self.nav_stack[i] = self.nav_stack[i + 1];
            }
            self.nav_stack[self.nav_stack.len - 1] = page;
            self.nav_len = @intCast(self.nav_stack.len);
        } else {
            self.nav_pos += 1;
            self.nav_stack[@intCast(self.nav_pos)] = page;
            self.nav_len = self.nav_pos + 1;
        }
    }

    fn navigateTo(self: *App, page: [*:0]const u8) void {
        self.navPush(page);
        gtk.gtk_stack_set_visible_child_name(@ptrCast(self.content_stack), page);
        const is_browse = std.mem.orderZ(u8, page, "home") == .eq or std.mem.orderZ(u8, page, "albums") == .eq;
        gtk.gtk_widget_set_visible(self.back_btn, if (is_browse) 0 else 1);
    }

    fn navGoBack(self: *App) void {
        if (self.nav_pos <= 0) return;
        self.nav_pos -= 1;
        const page = self.nav_stack[@intCast(self.nav_pos)];
        self.nav_inhibit = true;
        gtk.gtk_stack_set_visible_child_name(@ptrCast(self.content_stack), page);
        const is_browse = std.mem.orderZ(u8, page, "home") == .eq or std.mem.orderZ(u8, page, "albums") == .eq;
        gtk.gtk_widget_set_visible(self.back_btn, if (is_browse) 0 else 1);
        self.nav_inhibit = false;
    }

    fn navGoForward(self: *App) void {
        if (self.nav_pos + 1 >= self.nav_len) return;
        self.nav_pos += 1;
        const page = self.nav_stack[@intCast(self.nav_pos)];
        self.nav_inhibit = true;
        gtk.gtk_stack_set_visible_child_name(@ptrCast(self.content_stack), page);
        const is_browse = std.mem.orderZ(u8, page, "home") == .eq or std.mem.orderZ(u8, page, "albums") == .eq;
        gtk.gtk_widget_set_visible(self.back_btn, if (is_browse) 0 else 1);
        self.nav_inhibit = false;
    }

    fn onMouseButton(gesture: *gtk.GtkGestureClick, _: c_int, _: f64, _: f64, data: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        const btn = gtk.gtk_gesture_single_get_current_button(@ptrCast(gesture));
        if (btn == 8) self.navGoBack(); // mouse back
        if (btn == 9) self.navGoForward(); // mouse forward
    }

    fn onBack(_: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        self.navGoBack();
    }

    fn onNpClicked(_: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        if (self.playing_album_idx) |idx| {
            self.showAlbumDetail(idx);
        } else if (self.playing_playlist_id) |pl_id| {
            self.openPlaylistById(pl_id);
        }
    }

    fn openPlaylistById(self: *App, pl_id: []const u8) void {
        var name: []const u8 = "Playlist";
        if (self.playlists) |pls| {
            for (pls.items) |item| {
                if (std.mem.eql(u8, item.id, pl_id)) {
                    name = item.name;
                    break;
                }
            }
        }

        setLabelText(self.detail_title, name);
        setLabelText(self.detail_artist, "Playlist");
        gtk.gtk_picture_set_paintable(@ptrCast(self.detail_art), null);
        self.current_playlist_id = pl_id;
        clearChildren(self.track_list_box, .listbox);
        gtk.gtk_widget_set_visible(self.suggestions_box, 0);
        self.navigateTo("detail");

        self.playlist_cache_mutex.lock();
        const cached_opt = self.playlist_cache.get(pl_id);
        self.playlist_cache_mutex.unlock();
        if (cached_opt) |cached| {
            self.tracks = cached;
            for (cached.items) |track| {
                self.addTrackRow(track);
            }
            self.highlightCurrentTrack();
            self.loadSuggestionsAsync(pl_id);
            return;
        }

        // Otherwise load async
        self.loadDetailAsync(pl_id, true);
    }

    fn loadDetailAsync(self: *App, id: []const u8, is_playlist: bool) void {
        const Ctx = struct {
            app: *App,
            id: []const u8,
            is_playlist: bool,
            base_url: []const u8,
            token: ?[]const u8,
            user_id: ?[]const u8,
            username: ?[]const u8,
            password: ?[]const u8,
            alloc: std.mem.Allocator,
        };
        const ctx = self.allocator.create(Ctx) catch return;
        ctx.* = .{
            .app = self,
            .id = id,
            .is_playlist = is_playlist,
            .base_url = self.client.base_url,
            .token = self.client.token,
            .user_id = self.client.user_id,
            .username = self.client.username,
            .password = self.client.password,
            .alloc = self.allocator,
        };
        const thread = std.Thread.spawn(.{}, detailLoadThread, .{ctx}) catch {
            self.allocator.destroy(ctx);
            return;
        };
        thread.detach();
    }

    fn detailLoadThread(ctx: anytype) void {
        defer ctx.alloc.destroy(ctx);

        var client = api.Client.init(ctx.alloc, ctx.base_url);
        defer client.deinit();
        client.token = ctx.token;
        client.user_id = ctx.user_id;
        client.username = ctx.username;
        client.password = ctx.password;

        const tracks = if (ctx.is_playlist)
            client.getPlaylistTracks(ctx.id)
        else
            client.getAlbumTracks(ctx.id);

        const result = tracks catch return;

        // Post to main thread
        const Cb = struct {
            app: *App,
            tracks: models.ItemList,
            id: []const u8,
            is_playlist: bool,
            alloc: std.mem.Allocator,

            fn apply(data: ?*anyopaque) callconv(.c) c_int {
                const self: *@This() = @ptrCast(@alignCast(data));
                defer self.alloc.destroy(self);

                // Check we're still viewing the same thing
                if (self.is_playlist) {
                    if (self.app.current_playlist_id == null) return 0;
                    if (!std.mem.eql(u8, self.app.current_playlist_id.?, self.id)) return 0;
                }

                // Cache the result
                if (self.is_playlist) {
                    self.app.playlist_cache_mutex.lock();
                    self.app.playlist_cache.put(self.id, self.tracks) catch {};
                    self.app.playlist_cache_mutex.unlock();
                } else {
                    self.app.album_track_cache_mutex.lock();
                    self.app.album_track_cache.put(self.id, self.tracks) catch {};
                    self.app.album_track_cache_mutex.unlock();
                }

                self.app.tracks = self.tracks;
                clearChildren(self.app.track_list_box, .listbox);
                for (self.tracks.items) |track| {
                    self.app.addTrackRow(track);
                }
                self.app.highlightCurrentTrack();

                if (self.is_playlist) {
                    self.app.loadSuggestionsAsync(self.id);
                }
                return 0;
            }
        };

        const cb = ctx.alloc.create(Cb) catch return;
        cb.* = .{
            .app = ctx.app,
            .tracks = result,
            .id = ctx.id,
            .is_playlist = ctx.is_playlist,
            .alloc = ctx.alloc,
        };
        _ = gtk.g_idle_add(&Cb.apply, cb);
    }

    fn onNavHome(_: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        self.navigateTo("home");
    }

    fn onNavSearch(_: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        self.navigateTo("albums");
        _ = gtk.gtk_widget_grab_focus(self.search_entry);
    }

    fn onNavAlbums(_: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        self.navigateTo("albums");
    }

    fn onProfileClicked(_: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        self.navigateTo("settings");
    }

    fn onPlaylistActivated(_: *gtk.GtkListBox, row: *gtk.GtkListBoxRow, data: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        const index: usize = @intCast(gtk.gtk_list_box_row_get_index(row));
        const pls = self.playlists orelse return;
        if (index >= pls.items.len) return;
        const playlist = pls.items[index];

        setLabelText(self.detail_title, playlist.name);
        setLabelText(self.detail_artist, "Playlist");
        gtk.gtk_picture_set_paintable(@ptrCast(self.detail_art), null);

        self.navigateTo("detail");

        self.current_album_idx = null;
        self.current_playlist_idx = index;
        self.current_playlist_id = playlist.id;

        clearChildren(self.track_list_box, .listbox);
        gtk.gtk_widget_set_visible(self.suggestions_box, 0);

        self.playlist_cache_mutex.lock();
        const pl_cached = self.playlist_cache.get(playlist.id);
        self.playlist_cache_mutex.unlock();
        if (pl_cached) |cached| {
            self.tracks = cached;
            for (cached.items) |track| {
                self.addTrackRow(track);
            }
            self.highlightCurrentTrack();
        } else {
            self.loadDetailAsync(playlist.id, true);
        }
        self.loadSuggestionsAsync(playlist.id);
    }

    fn onNewPlaylist(_: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));

        // Find next free number
        const pls = self.playlists;
        var num: u32 = 1;
        while (num < 100) : (num += 1) {
            var name_buf: [32]u8 = undefined;
            const candidate = std.fmt.bufPrint(&name_buf, "New Playlist #{d}", .{num}) catch break;
            var taken = false;
            if (pls) |p| {
                for (p.items) |item| {
                    if (item.name.len == candidate.len and std.mem.eql(u8, item.name, candidate)) {
                        taken = true;
                        break;
                    }
                }
            }
            if (!taken) break;
        }

        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "New Playlist #{d}", .{num}) catch return;
        const name_z = std.fmt.allocPrintSentinel(self.allocator, "{s}", .{name}, 0) catch return;

        // Show empty playlist immediately, create on server async
        self.current_playlist_id = null;
        self.current_playlist_idx = null;
        self.current_album_idx = null;
        setLabelText(self.detail_title, name);
        setLabelText(self.detail_artist, "Playlist");
        gtk.gtk_picture_set_paintable(@ptrCast(self.detail_art), null);
        clearChildren(self.track_list_box, .listbox);
        self.tracks = null;
        self.navigateTo("detail");
        gtk.gtk_widget_set_visible(self.suggestions_box, 0);

        bg.run(self.allocator, self.client, struct {
            app: *App,
            name: [:0]u8,
            alloc: std.mem.Allocator,
            new_id: ?[]const u8 = null,

            pub fn work(s: *@This(), client: *api.Client) void {
                s.new_id = client.createPlaylist(s.name) catch null;
                // Refresh playlists
                s.app.playlists = client.getPlaylists() catch null;
            }

            pub fn done(s: *@This()) void {
                defer s.alloc.free(s.name);
                if (s.new_id) |id| {
                    s.app.current_playlist_id = id;
                    log.info("created playlist: {s}", .{id});
                }
                s.app.populatePlaylists();
            }
        }{ .app = self, .name = name_z, .alloc = self.allocator });
    }

    fn loadSuggestionsAsync(self: *App, playlist_id: []const u8) void {
        const Ctx = struct {
            app: *App,
            pl_id: []const u8,
            base_url: []const u8,
            token: ?[]const u8,
            user_id: ?[]const u8,
            username: ?[]const u8,
            password: ?[]const u8,
            alloc: std.mem.Allocator,
        };
        const ctx = self.allocator.create(Ctx) catch return;
        ctx.* = .{
            .app = self, .pl_id = playlist_id,
            .base_url = self.client.base_url, .token = self.client.token,
            .user_id = self.client.user_id, .username = self.client.username,
            .password = self.client.password, .alloc = self.allocator,
        };
        const thread = std.Thread.spawn(.{}, suggestionsThread, .{ctx}) catch {
            self.allocator.destroy(ctx);
            return;
        };
        thread.detach();
    }

    fn suggestionsThread(ctx: anytype) void {
        defer ctx.alloc.destroy(ctx);

        var client = api.Client.init(ctx.alloc, ctx.base_url);
        defer client.deinit();
        client.token = ctx.token;
        client.user_id = ctx.user_id;
        client.username = ctx.username;
        client.password = ctx.password;

        const mix = client.getInstantMix(ctx.pl_id, 10) catch return;

        const Cb = struct {
            app: *App,
            mix: models.ItemList,
            pl_id: []const u8,
            alloc: std.mem.Allocator,

            fn apply(data: ?*anyopaque) callconv(.c) c_int {
                const self: *@This() = @ptrCast(@alignCast(data));
                defer self.alloc.destroy(self);
                if (self.app.current_playlist_id) |current| {
                    if (std.mem.eql(u8, current, self.pl_id)) {
                        self.app.buildSuggestionsUI(self.mix);
                    }
                }
                return 0;
            }
        };

        const cb = ctx.alloc.create(Cb) catch return;
        cb.* = .{ .app = ctx.app, .mix = mix, .pl_id = ctx.pl_id, .alloc = ctx.alloc };
        _ = gtk.g_idle_add(&Cb.apply, cb);
    }

    fn buildSuggestionsUI(self: *App, mix: models.ItemList) void {
        clearChildren(self.suggestions_box, .box);

        if (mix.items.len == 0) {
            gtk.gtk_widget_set_visible(self.suggestions_box, 0);
            return;
        }

        gtk.gtk_widget_set_visible(self.suggestions_box, 1);

        // Header
        const header = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 8);
        gtk.gtk_widget_set_margin_start(header, 16);
        gtk.gtk_widget_set_margin_top(header, 16);
        gtk.gtk_widget_set_margin_bottom(header, 4);
        const title = gtk.gtk_label_new("Suggested tracks");
        gtk.gtk_widget_add_css_class(title, "suggestion-title");
        gtk.gtk_label_set_xalign(@ptrCast(title), 0);
        gtk.gtk_box_append(@ptrCast(header), title);
        gtk.gtk_box_append(@ptrCast(self.suggestions_box), header);

        // Suggestion rows
        const list = gtk.gtk_list_box_new();
        gtk.gtk_widget_add_css_class(list, "track-list");
        gtk.gtk_list_box_set_selection_mode(@ptrCast(list), gtk.GTK_SELECTION_NONE);

        for (mix.items) |track| {
            const row_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 12);
            gtk.gtk_widget_add_css_class(row_box, "track-row");
            gtk.gtk_widget_add_css_class(row_box, "suggestion-row");

            const name_label = makeLabel(self.allocator, track.name);
            gtk.gtk_widget_add_css_class(name_label, "track-name");
            gtk.gtk_label_set_xalign(@ptrCast(name_label), 0);
            gtk.gtk_label_set_ellipsize(@ptrCast(name_label), 3);
            gtk.gtk_widget_set_hexpand(name_label, 1);
            gtk.gtk_box_append(@ptrCast(row_box), name_label);

            if (track.album_artist) |artist| {
                const artist_label = makeLabel(self.allocator, artist);
                gtk.gtk_widget_add_css_class(artist_label, "track-duration");
                gtk.gtk_box_append(@ptrCast(row_box), artist_label);
            }

            // Add button to add this track to the playlist
            const add_btn = gtk.gtk_button_new_from_icon_name("list-add-symbolic");
            gtk.gtk_widget_add_css_class(add_btn, "suggestion-add-btn");
            gtk.gtk_button_set_has_frame(@ptrCast(add_btn), 0);

            // Store track ID on button
            const track_id_z = std.fmt.allocPrintSentinel(self.allocator, "{s}", .{track.id}, 0) catch null;
            if (track_id_z) |z| {
                setObjString(@ptrCast(add_btn), "track-id", z);
            }
            _ = g_signal_connect(add_btn, "clicked", &onAddSuggestion, self);
            gtk.gtk_box_append(@ptrCast(row_box), add_btn);

            gtk.gtk_list_box_append(@ptrCast(list), row_box);
        }

        gtk.gtk_box_append(@ptrCast(self.suggestions_box), list);
    }

    fn onAddSuggestion(button: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        const pl_id = self.current_playlist_id orelse return;

        const id_ptr = gtk.g_object_get_data(@ptrCast(button), "track-id");
        if (id_ptr == null) return;
        const track_id = std.mem.span(@as([*:0]const u8, @ptrCast(id_ptr)));

        // Remove the suggestion row immediately (optimistic)
        const row = gtk.gtk_widget_get_parent(@ptrCast(button));
        if (row != null) {
            const list_row = gtk.gtk_widget_get_parent(row.?);
            if (list_row != null) {
                const list_parent = gtk.gtk_widget_get_parent(list_row.?);
                if (list_parent != null) {
                    gtk.gtk_list_box_remove(@ptrCast(list_parent), list_row);
                }
            }
        }

        // Add to playlist async, refresh when done
        self.doPlaylistAction(pl_id, track_id, 0, .add);
    }

    fn onSettingsSave(_: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        const server = std.mem.span(@as([*:0]const u8, @ptrCast(gtk.gtk_editable_get_text(@ptrCast(self.settings_server)))));
        const username = std.mem.span(@as([*:0]const u8, @ptrCast(gtk.gtk_editable_get_text(@ptrCast(self.settings_user)))));
        const password = std.mem.span(@as([*:0]const u8, @ptrCast(gtk.gtk_editable_get_text(@ptrCast(self.settings_pass)))));

        // Write config
        const home = std.posix.getenv("HOME") orelse return;
        const path = std.fmt.allocPrint(self.allocator, "{s}/.config/jmusic/config.json", .{home}) catch return;
        defer self.allocator.free(path);

        const cache_mb: u32 = @intFromFloat(gtk.gtk_spin_button_get_value(@ptrCast(self.settings_cache)));

        const json = std.fmt.allocPrint(
            self.allocator,
            "{{\"server\":\"{s}\",\"username\":\"{s}\",\"password\":\"{s}\",\"cache_size_mb\":{d}}}\n",
            .{ server, username, password, cache_mb },
        ) catch return;
        defer self.allocator.free(json);

        const file = std.fs.createFileAbsolute(path, .{}) catch return;
        defer file.close();
        file.writeAll(json) catch return;

        // Apply cache size immediately
        self.disk_audio_cache.max_bytes = @as(u64, cache_mb) * 1024 * 1024;
        self.disk_audio_cache.evictIfNeeded();

        log.info("config saved (cache: {d}MB)", .{cache_mb});
        self.navigateTo("home");
    }

    fn onTrackActivated(_: *gtk.GtkListBox, row: *gtk.GtkListBoxRow, data: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        const index: usize = @intCast(gtk.gtk_list_box_row_get_index(row));
        const tracks = self.tracks orelse return;
        if (index >= tracks.items.len) return;

        // Don't restart the same track
        if (self.track_queue != null and self.queue_index == index) {
            const p = self.player orelse return;
            if (p.state == .playing or p.state == .paused) return;
        }

        self.setQueue(tracks.items, index);
        self.playTrack(index);
    }

    fn onPlayNextClicked(button: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        const tracks = self.tracks orelse return;

        // Find which row this button is in
        const row_box = gtk.gtk_widget_get_parent(@ptrCast(button)) orelse return;
        const list_row = gtk.gtk_widget_get_parent(row_box) orelse return;
        const idx: usize = @intCast(gtk.gtk_list_box_row_get_index(@ptrCast(list_row)));
        if (idx >= tracks.items.len) return;

        self.insertNextInQueue(tracks.items[idx]);
        log.info("queued: {s}", .{tracks.items[idx].name});
    }

    fn onShuffleToggle(_: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        self.shuffle = !self.shuffle;

        if (self.shuffle) {
            gtk.gtk_widget_add_css_class(self.shuffle_btn, "control-active");
            // Shuffle the queue, keeping current track at current position
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

    fn shuffleQueue(self: *App) void {
        var queue = self.track_queue orelse return;
        if (queue.len <= 1) return;

        // Simple Fisher-Yates shuffle, but keep the current track in place
        const current_idx = self.queue_index;
        var prng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
        const rand = prng.random();

        // Move current track to position 0, shuffle the rest
        if (current_idx != 0) {
            const tmp = queue[0];
            queue[0] = queue[current_idx];
            queue[current_idx] = tmp;
            self.queue_index = 0;
        }

        // Shuffle positions 1..len
        var i: usize = queue.len - 1;
        while (i > 1) : (i -= 1) {
            const j = rand.intRangeAtMost(usize, 1, i);
            const tmp = queue[i];
            queue[i] = queue[j];
            queue[j] = tmp;
        }
    }

    fn onVolumeChanged(_: *gtk.GtkRange, data: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        const p = self.player orelse return;
        if (!p.initialized) return;
        const vol: f32 = @floatCast(gtk.gtk_range_get_value(@ptrCast(self.volume_scale)));
        _ = c.ma.ma_engine_set_volume(&p.engine, vol);

        // Update icon
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
            // Mute - store previous volume on the button
            gtk.g_object_set_data(@ptrCast(self.volume_btn), "prev-vol",
                @ptrFromInt(@as(usize, @intFromFloat(current * 100))));
            gtk.gtk_range_set_value(@ptrCast(self.volume_scale), 0);
        } else {
            // Unmute - restore previous volume
            const prev = @intFromPtr(gtk.g_object_get_data(@ptrCast(self.volume_btn), "prev-vol"));
            const restore: f64 = if (prev > 0) @as(f64, @floatFromInt(prev)) / 100.0 else 1.0;
            gtk.gtk_range_set_value(@ptrCast(self.volume_scale), restore);
        }
    }

    fn onToggleQueue(_: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        const revealed = gtk.gtk_revealer_get_reveal_child(@ptrCast(self.queue_revealer));
        gtk.gtk_revealer_set_reveal_child(@ptrCast(self.queue_revealer), if (revealed != 0) 0 else 1);
        if (revealed == 0) self.rebuildQueueList();
    }

    fn onClearQueue(_: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        const p = self.player orelse return;
        p.stop();
        if (self.track_queue_owned) {
            if (self.track_queue) |old| self.allocator.free(old);
        }
        self.track_queue = null;
        self.track_queue_owned = false;
        self.rebuildQueueList();
        setLabelText(self.np_title, "Nothing playing");
        setLabelText(self.np_artist, "");
        gtk.gtk_button_set_icon_name(@ptrCast(self.play_btn), "media-playback-start-symbolic");
    }

    fn onQueueRowActivated(_: *gtk.GtkListBox, row: *gtk.GtkListBoxRow, data: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        const index: usize = @intCast(gtk.gtk_list_box_row_get_index(row));
        const queue = self.track_queue orelse return;
        if (index >= queue.len) return;
        self.queue_index = index;
        self.playTrack(index);
        self.rebuildQueueList();
    }

    fn onQueueMoveUp(button: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        var queue = self.track_queue orelse return;
        const row_box = gtk.gtk_widget_get_parent(@ptrCast(button)) orelse return;
        const list_row = gtk.gtk_widget_get_parent(row_box) orelse return;
        const idx: usize = @intCast(gtk.gtk_list_box_row_get_index(@ptrCast(list_row)));
        if (idx == 0 or idx >= queue.len) return;

        const tmp = queue[idx];
        queue[idx] = queue[idx - 1];
        queue[idx - 1] = tmp;

        // Adjust playing index if affected
        if (self.queue_index == idx) {
            self.queue_index -= 1;
        } else if (self.queue_index == idx - 1) {
            self.queue_index += 1;
        }
        self.rebuildQueueList();
    }

    fn onQueueMoveDown(button: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        var queue = self.track_queue orelse return;
        const row_box = gtk.gtk_widget_get_parent(@ptrCast(button)) orelse return;
        const list_row = gtk.gtk_widget_get_parent(row_box) orelse return;
        const idx: usize = @intCast(gtk.gtk_list_box_row_get_index(@ptrCast(list_row)));
        if (idx + 1 >= queue.len) return;

        const tmp = queue[idx];
        queue[idx] = queue[idx + 1];
        queue[idx + 1] = tmp;

        if (self.queue_index == idx) {
            self.queue_index += 1;
        } else if (self.queue_index == idx + 1) {
            self.queue_index -= 1;
        }
        self.rebuildQueueList();
    }

    fn onQueueRemove(button: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        var queue = self.track_queue orelse return;
        const row_box = gtk.gtk_widget_get_parent(@ptrCast(button)) orelse return;
        const list_row = gtk.gtk_widget_get_parent(row_box) orelse return;
        const idx: usize = @intCast(gtk.gtk_list_box_row_get_index(@ptrCast(list_row)));
        if (idx >= queue.len) return;

        // Shift items
        var i: usize = idx;
        while (i + 1 < queue.len) : (i += 1) queue[i] = queue[i + 1];

        // Shrink the slice (we own it)
        self.track_queue = queue[0 .. queue.len - 1];

        if (self.queue_index > idx) {
            self.queue_index -= 1;
        } else if (self.queue_index == idx and self.queue_index >= queue.len - 1) {
            // Removed the playing track at end
            if (self.queue_index > 0) self.queue_index -= 1;
        }
        self.rebuildQueueList();
    }

    pub fn rebuildQueueList(self: *App) void {
        clearChildren(self.queue_list, .listbox);
        const queue = self.track_queue orelse return;

        for (queue, 0..) |track, i| {
            const row_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 8);
            gtk.gtk_widget_add_css_class(row_box, "queue-row");

            // Playing indicator
            if (i == self.queue_index) {
                gtk.gtk_widget_add_css_class(row_box, "queue-playing");
            }

            // Track name
            const name = makeLabel(self.allocator, track.name);
            gtk.gtk_widget_add_css_class(name, "queue-track-name");
            gtk.gtk_label_set_xalign(@ptrCast(name), 0);
            gtk.gtk_label_set_ellipsize(@ptrCast(name), 3);
            gtk.gtk_widget_set_hexpand(name, 1);
            gtk.gtk_box_append(@ptrCast(row_box), name);

            // Artist
            if (track.album_artist orelse track.album) |artist| {
                const a = makeLabel(self.allocator, artist);
                gtk.gtk_widget_add_css_class(a, "queue-artist");
                gtk.gtk_label_set_ellipsize(@ptrCast(a), 3);
                gtk.gtk_label_set_max_width_chars(@ptrCast(a), 12);
                gtk.gtk_box_append(@ptrCast(row_box), a);
            }

            // Up/down/remove
            const up = gtk.gtk_button_new_from_icon_name("go-up-symbolic");
            gtk.gtk_widget_add_css_class(up, "reorder-btn");
            gtk.gtk_button_set_has_frame(@ptrCast(up), 0);
            _ = g_signal_connect(up, "clicked", &onQueueMoveUp, self);
            gtk.gtk_box_append(@ptrCast(row_box), up);

            const down = gtk.gtk_button_new_from_icon_name("go-down-symbolic");
            gtk.gtk_widget_add_css_class(down, "reorder-btn");
            gtk.gtk_button_set_has_frame(@ptrCast(down), 0);
            _ = g_signal_connect(down, "clicked", &onQueueMoveDown, self);
            gtk.gtk_box_append(@ptrCast(row_box), down);

            const rm = gtk.gtk_button_new_from_icon_name("edit-delete-symbolic");
            gtk.gtk_widget_add_css_class(rm, "remove-btn");
            gtk.gtk_button_set_has_frame(@ptrCast(rm), 0);
            _ = g_signal_connect(rm, "clicked", &onQueueRemove, self);
            gtk.gtk_box_append(@ptrCast(row_box), rm);

            gtk.gtk_list_box_append(@ptrCast(self.queue_list), row_box);
        }
    }

    // Insert a track right after the current position in the queue
    pub fn insertNextInQueue(self: *App, track: models.BaseItem) void {
        var queue = self.track_queue orelse {
            // No queue - create one with just this track
            self.setQueue(&.{track}, 0);
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

        // Rebuild if visible
        if (gtk.gtk_revealer_get_reveal_child(@ptrCast(self.queue_revealer)) != 0) {
            self.rebuildQueueList();
        }
    }

    fn onPlayAll(_: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        const tracks = self.tracks orelse return;
        if (tracks.items.len == 0) return;
        self.setQueue(tracks.items, 0);
        self.playTrack(0);
    }

    fn onPlayPause(_: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        self.doTogglePause();
    }

    pub fn doTogglePause(self: *App) void {
        const p = self.player orelse return;
        p.togglePause();
        const icon = switch (p.state) {
            .playing => "media-playback-pause-symbolic",
            .paused, .stopped => "media-playback-start-symbolic",
        };
        gtk.gtk_button_set_icon_name(@ptrCast(self.play_btn), icon);
        mpris.notifyPropertyChanged("PlaybackStatus");
        if (p.state == .playing) self.preloadNextTrack();
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
        const p = self.player orelse return;
        const val = gtk.gtk_range_get_value(@ptrCast(self.progress_scale));
        p.seek(val);
        // Re-schedule gapless since seek invalidated timing
        self.preloadNextTrack();
    }

    fn updateProgress(data: ?*anyopaque) callconv(.c) c_int {
        const self: *App = @ptrCast(@alignCast(data));
        const p = self.player orelse return 1;

        if (p.state == .playing or p.state == .paused) {
            const cursor = p.getCursorSeconds();
            const length = p.getLengthSeconds();
            const frac: f64 = if (length > 0) @as(f64, cursor) / @as(f64, length) else 0;

            self.updating_progress = true;
            gtk.gtk_range_set_value(@ptrCast(self.progress_scale), frac);
            self.updating_progress = false;

            setTimeLabel(self.time_current, cursor);
            setTimeLabel(self.time_total, length);
        }


        return 1;
    }

    fn checkTrackEnd(data: ?*anyopaque) callconv(.c) c_int {
        const self: *App = @ptrCast(@alignCast(data));
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
                // Wrap to beginning
                self.queue_index = 0;
                _ = self.play_generation.fetchAdd(1, .release);
                self.playTrack(0);
                return 1;
            }
            // Last track, no repeat - stop
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
            self.updateNowPlaying(track);
            self.preloadNextTrack();
        } else {
            self.playTrack(self.queue_index);
        }

        return 1;
    }

    // ---------------------------------------------------------------
    // CSS
    // ---------------------------------------------------------------
    fn applyCSS() void {
        const css =
            \\/* Base */
            \\window { background-color: #0f0f0f; color: #e1e1e1; }
            \\
            \\/* Sidebar */
            \\.sidebar { background-color: #070707; padding: 0; border-right: 1px solid #1a1a1a; min-width: 200px; }
            \\.sidebar-logo {
            \\  color: #d4a843; font-size: 20px; font-weight: bold;
            \\  padding: 20px 20px 16px;
            \\}
            \\.sidebar-item {
            \\  color: #b3b3b3; font-size: 13px; padding: 6px 16px;
            \\  background: none; border: none; border-radius: 0;
            \\}
            \\.sidebar-item label { text-align: left; }
            \\.sidebar-item:hover { color: #fff; background-color: #1a1a1a; }
            \\.sidebar-divider { margin: 8px 16px; background-color: #1a1a1a; min-height: 1px; }
            \\.sidebar-section {
            \\  color: #7a7a7a; font-size: 11px; font-weight: bold;
            \\  padding: 12px 20px 6px;
            \\}
            \\.sidebar-list { background: transparent; }
            \\.sidebar-list row { background: transparent; padding: 0; border-radius: 4px; margin: 0 8px; }
            \\.sidebar-list row:hover { background-color: #1a1a1a; }
            \\.sidebar-list row:selected { background-color: #1a1a1a; }
            \\.sidebar-playlist-item { color: #b3b3b3; font-size: 13px; padding: 6px 12px; }
            \\.sidebar-add-btn { color: #7a7a7a; min-width: 28px; min-height: 28px; padding: 0; margin-right: 12px; }
            \\.sidebar-add-btn:hover { color: #fff; }
            \\
            \\/* Profile */
            \\.profile-btn {
            \\  background-color: #333; border: none; border-radius: 16px;
            \\  min-width: 32px; min-height: 32px; padding: 0; color: #aaa;
            \\}
            \\.profile-btn:hover { background-color: #444; color: #fff; }
            \\
            \\/* Settings */
            \\.settings-page { background-color: #0f0f0f; }
            \\.settings-title { color: #fff; font-size: 28px; font-weight: bold; margin-bottom: 8px; }
            \\.settings-label { color: #aaa; font-size: 13px; font-weight: bold; margin-top: 8px; }
            \\.settings-entry {
            \\  background-color: #1a1a1a; color: #fff; border: 1px solid #333;
            \\  border-radius: 6px; padding: 8px 12px; min-height: 36px; font-size: 14px;
            \\}
            \\.settings-entry:focus { border-color: #d4a843; }
            \\.settings-save-btn {
            \\  background-color: #d4a843; color: #000; border-radius: 20px;
            \\  padding: 8px 32px; font-weight: bold; font-size: 14px;
            \\  border: none; min-height: 36px; margin-top: 16px;
            \\}
            \\.settings-save-btn:hover { background-color: #e8bc5a; }
            \\
            \\/* Home sections */
            \\.home-section { padding: 0 0 8px; }
            \\.home-row { padding: 4px 0; }
            \\
            \\/* Header */
            \\.header-bar { padding: 12px 20px; background-color: #0f0f0f; }
            \\
            \\.back-btn {
            \\  background: none; border: none; color: #888;
            \\  min-width: 36px; min-height: 36px; border-radius: 18px; padding: 0;
            \\}
            \\.back-btn:hover { color: #fff; background-color: rgba(255,255,255,0.1); }
            \\
            \\/* Search */
            \\searchentry {
            \\  background-color: #2a2a2a; color: #fff;
            \\  border: 2px solid transparent; border-radius: 24px;
            \\  min-height: 40px; padding: 0 16px; font-size: 14px;
            \\}
            \\searchentry:focus { border-color: #d4a843; background-color: #333; }
            \\searchentry image { color: #666; }
            \\
            \\.section-title { color: #fff; font-size: 22px; font-weight: bold; padding: 8px 20px 12px; }
            \\
            \\/* Album grid */
            \\flowbox { padding: 0 12px; background: transparent; }
            \\flowboxchild { padding: 4px; background: transparent; border: none; outline: none; }
            \\
            \\.album-card-btn {
            \\  background: transparent; border: none; border-radius: 8px;
            \\  padding: 0; outline: none;
            \\}
            \\.album-card-btn:hover { background-color: #1a1a1a; }
            \\.album-card { padding: 10px; border-radius: 8px; }
            \\
            \\.art-placeholder {
            \\  background-color: #1a1a1a; border-radius: 6px;
            \\  min-width: 160px; min-height: 160px;
            \\}
            \\.art-placeholder image { color: #333; }
            \\
            \\.grid-art { background-color: #1a1a1a; border-radius: 6px; border: none; outline: none; }
            \\.album-title { color: #fff; font-size: 13px; font-weight: bold; margin-top: 8px; }
            \\.album-artist { color: #7a7a7a; font-size: 12px; margin-top: 2px; }
            \\
            \\/* Album detail */
            \\.detail-header {
            \\  padding: 32px 24px;
            \\  background-image: linear-gradient(to bottom, #252525, #0f0f0f);
            \\}
            \\.detail-art { border-radius: 6px; border: none; outline: none; }
            \\.type-label { color: #fff; font-size: 11px; font-weight: bold; }
            \\.detail-title { color: #fff; font-size: 32px; font-weight: bold; }
            \\.detail-artist { color: #a0a0a0; font-size: 16px; margin-top: 4px; }
            \\
            \\button.play-all-btn {
            \\  background: #d4a843; color: #000; border-radius: 20px;
            \\  padding: 6px 28px; font-weight: bold; font-size: 13px;
            \\  border: none; min-height: 36px; outline: none;
            \\  box-shadow: none; background-image: none;
            \\}
            \\button.play-all-btn:hover { background: #e8bc5a; background-image: none; }
            \\button.play-all-btn:focus { outline: none; box-shadow: none; }
            \\button.play-all-btn:active { background: #c09530; background-image: none; }
            \\
            \\/* Track list */
            \\.track-list { background-color: #0f0f0f; padding: 0 16px; }
            \\.track-list row { padding: 0; background-color: #0f0f0f; border-radius: 4px; margin: 1px 0; }
            \\.track-list row:hover { background-color: rgba(255,255,255,0.06); }
            \\.track-list row:selected { background-color: rgba(255,255,255,0.1); }
            \\.track-row { padding: 10px 16px; min-height: 36px; }
            \\.track-number { color: #7a7a7a; font-size: 14px; min-width: 28px; }
            \\.track-name { color: #e1e1e1; font-size: 14px; }
            \\.track-duration { color: #7a7a7a; font-size: 13px; }
            \\.track-playing .track-name { color: #d4a843; }
            \\.track-playing .track-number { color: #d4a843; }
            \\.suggestion-title { color: #fff; font-size: 18px; font-weight: bold; }
            \\.suggestion-row { opacity: 0.7; }
            \\.suggestion-row:hover { opacity: 1; }
            \\.suggestion-add-btn { color: #d4a843; min-width: 28px; padding: 0; }
            \\.suggestion-add-btn:hover { color: #e8bc5a; }
            \\.play-next-btn { color: #555; min-width: 24px; min-height: 24px; padding: 0; }
            \\.play-next-btn:hover { color: #d4a843; }
            \\.reorder-btn { color: #555; min-width: 24px; min-height: 24px; padding: 0; }
            \\.reorder-btn:hover { color: #fff; }
            \\.remove-btn { color: #555; min-width: 24px; min-height: 24px; padding: 0; }
            \\.remove-btn:hover { color: #e94560; }
            \\
            \\/* Queue panel */
            \\.queue-panel { background-color: #0a0a0a; border-left: 1px solid #1a1a1a; }
            \\.queue-title { color: #fff; font-size: 18px; font-weight: bold; }
            \\.queue-clear-btn { color: #7a7a7a; font-size: 12px; }
            \\.queue-clear-btn:hover { color: #fff; }
            \\.queue-list { background: transparent; }
            \\.queue-list row { background: transparent; padding: 0; margin: 0 8px; border-radius: 4px; }
            \\.queue-list row:hover { background-color: rgba(255,255,255,0.06); }
            \\.queue-row { padding: 6px 8px; min-height: 32px; }
            \\.queue-playing { background-color: rgba(212,168,67,0.1); }
            \\.queue-playing .queue-track-name { color: #d4a843; }
            \\.queue-track-name { color: #e1e1e1; font-size: 13px; }
            \\.queue-artist { color: #7a7a7a; font-size: 12px; }
            \\
            \\/* Now playing bar */
            \\.now-playing { background-color: #181818; border-top: 1px solid #282828; }
            \\
            \\.np-progress scale { margin: 0; padding: 0; }
            \\.np-progress scale trough { background-color: #3a3a3a; min-height: 3px; border-radius: 2px; border: none; }
            \\.np-progress scale highlight { background-color: #d4a843; min-height: 3px; border-radius: 2px; }
            \\.np-progress scale slider {
            \\  background-color: #fff; min-width: 0px; min-height: 0px;
            \\  border-radius: 6px; border: none; margin: 0; padding: 0; opacity: 0;
            \\}
            \\.np-progress:hover scale slider { min-width: 12px; min-height: 12px; margin: -5px 0; opacity: 1; }
            \\.np-progress:hover scale highlight { background-color: #d4a843; }
            \\
            \\.np-click-btn { background: none; border: none; padding: 0; border-radius: 6px; }
            \\.np-click-btn:hover { background-color: rgba(255,255,255,0.05); }
            \\.np-title { color: #fff; font-size: 13px; font-weight: bold; }
            \\.np-artist { color: #7a7a7a; font-size: 12px; }
            \\
            \\.np-art-placeholder {
            \\  background-color: #282828; border-radius: 4px;
            \\  min-width: 52px; min-height: 52px;
            \\}
            \\.np-art-placeholder image { color: #444; }
            \\.np-art-frame { border-radius: 4px; min-width: 52px; min-height: 52px; }
            \\
            \\/* Transport */
            \\.control-btn {
            \\  background: none; border: none; color: #b3b3b3;
            \\  min-width: 32px; min-height: 32px; border-radius: 16px;
            \\  padding: 0; outline: none; box-shadow: none;
            \\}
            \\.control-btn:hover { color: #fff; }
            \\.control-btn:focus { outline: none; box-shadow: none; }
            \\.control-active { color: #d4a843; }
            \\.control-active:hover { color: #e8bc5a; }
            \\
            \\button.play-btn {
            \\  background: #d4a843; color: #000; border-radius: 19px;
            \\  min-width: 38px; min-height: 38px;
            \\  border: none; padding: 0; outline: none; box-shadow: none;
            \\  -gtk-icon-size: 18px; background-image: none;
            \\}
            \\button.play-btn:hover { background: #e8bc5a; background-image: none; }
            \\button.play-btn:focus { outline: none; box-shadow: none; }
            \\button.play-btn:active { background: #c09530; background-image: none; }
            \\
            \\.time-label { color: #7a7a7a; font-size: 11px; min-width: 36px; }
            \\.volume-scale trough { background-color: #3a3a3a; min-height: 3px; border-radius: 2px; border: none; }
            \\.volume-scale highlight { background-color: #b3b3b3; min-height: 3px; border-radius: 2px; }
            \\.volume-scale slider { background-color: #fff; min-width: 8px; min-height: 8px; border-radius: 4px; border: none; margin: -3px 0; }
            \\.volume-scale:hover highlight { background-color: #d4a843; }
            \\
            \\/* Scrollbar */
            \\scrollbar { background: transparent; }
            \\scrollbar slider { background-color: rgba(255,255,255,0.15); border-radius: 4px; min-width: 8px; }
            \\scrollbar slider:hover { background-color: rgba(255,255,255,0.3); }
        ;
        const provider = gtk.gtk_css_provider_new();
        gtk.gtk_css_provider_load_from_string(provider, css);
        gtk.gtk_style_context_add_provider_for_display(
            gtk.gdk_display_get_default(),
            @ptrCast(provider),
            gtk.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
    }
};

// ---------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------
// MPRIS static callbacks
var global_app: ?*App = null;

fn mprisPlayPause() void {
    const app = global_app orelse return;
    app.doTogglePause();
}

fn mprisNext() void {
    const app = global_app orelse return;
    app.playNext();
}

fn mprisPrev() void {
    const app = global_app orelse return;
    app.playPrev();
}

fn mprisStop() void {
    const app = global_app orelse return;
    const p = app.player orelse return;
    p.stop();
    setLabelText(app.np_title, "Nothing playing");
    setLabelText(app.np_artist, "");
    gtk.gtk_button_set_icon_name(@ptrCast(app.play_btn), "media-playback-start-symbolic");
    mpris.notifyPropertyChanged("PlaybackStatus");
}

fn mprisRaise() void {
    const app = global_app orelse return;
    gtk.gtk_window_present(@ptrCast(app.window));
}

fn g_signal_connect(
    instance: *anyopaque,
    signal: [*:0]const u8,
    callback: *const anyopaque,
    data: ?*anyopaque,
) c_ulong {
    return gtk.g_signal_connect_data(
        @ptrCast(instance),
        signal,
        @ptrCast(callback),
        data,
        null,
        0,
    );
}

fn makeLabel(allocator: std.mem.Allocator, text: []const u8) *gtk.GtkWidget {
    const z = std.fmt.allocPrintSentinel(allocator, "{s}", .{text}, 0) catch return gtk.gtk_label_new("?");
    defer allocator.free(z);
    return gtk.gtk_label_new(z.ptr);
}

// Store a heap-allocated string on a GObject, freed automatically on widget destroy.
fn setObjString(obj: *anyopaque, key: [*:0]const u8, value: [:0]const u8) void {
    gtk.g_object_set_data_full(
        @ptrCast(@alignCast(obj)),
        key,
        @constCast(@ptrCast(value.ptr)),
        &cFreeNotify,
    );
}

fn cFreeNotify(data: ?*anyopaque) callconv(.c) void {
    if (data) |ptr| std.c.free(ptr);
}

fn setLabelText(label: *gtk.GtkWidget, text: []const u8) void {
    // Use a stack buffer for short strings, fall back to a fixed truncation
    var buf: [256]u8 = undefined;
    const len = @min(text.len, buf.len - 1);
    @memcpy(buf[0..len], text[0..len]);
    buf[len] = 0;
    gtk.gtk_label_set_text(@ptrCast(label), @ptrCast(&buf));
}

fn setTimeLabel(label: *gtk.GtkWidget, seconds: f32) void {
    const total = @as(u32, @intFromFloat(@max(seconds, 0)));
    const m = total / 60;
    const s = total % 60;
    var buf: [12]u8 = undefined;
    const sl = std.fmt.bufPrint(&buf, "{d}:{d:0>2}", .{ m, s }) catch return;
    buf[sl.len] = 0;
    gtk.gtk_label_set_text(@ptrCast(label), @ptrCast(buf[0..sl.len :0].ptr));
}

const WidgetType = enum { flowbox, listbox, box };

fn clearChildren(widget: *gtk.GtkWidget, wtype: WidgetType) void {
    var child = gtk.gtk_widget_get_first_child(widget);
    while (child != null) {
        const next = gtk.gtk_widget_get_next_sibling(child);
        switch (wtype) {
            .flowbox => gtk.gtk_flow_box_remove(@ptrCast(widget), child),
            .listbox => gtk.gtk_list_box_remove(@ptrCast(widget), child),
            .box => gtk.gtk_box_remove(@ptrCast(widget), child),
        }
        child = next;
    }
}

pub const ArtJob = struct { id: []const u8, widget: *gtk.GtkWidget };

pub fn collectArtJobsFromBox(row_box: *gtk.GtkWidget, jobs: *std.array_list.AlignedManaged(ArtJob, null)) void {
    // row_box contains buttons, each button has a card box, first child is picture
    var btn = gtk.gtk_widget_get_first_child(row_box);
    while (btn != null) : (btn = gtk.gtk_widget_get_next_sibling(btn)) {
        const card_box = gtk.gtk_widget_get_first_child(btn) orelse continue;
        const picture = gtk.gtk_widget_get_first_child(card_box) orelse continue;

        const wname = gtk.gtk_widget_get_name(picture);
        if (wname == null) continue;
        const name_slice = std.mem.span(@as([*:0]const u8, @ptrCast(wname)));
        if (!std.mem.eql(u8, name_slice, "needs-art")) continue;

        const id_ptr = gtk.g_object_get_data(@ptrCast(picture), "art-id");
        if (id_ptr == null) continue;
        const id: [*:0]const u8 = @ptrCast(id_ptr);
        gtk.gtk_widget_set_name(picture, "art-loading");
        jobs.append(.{ .id = std.mem.span(id), .widget = picture.? }) catch {};
    }
}

pub fn artCachePath(buf: *[300]u8, item_id: []const u8) ?[]const u8 {
    const xdg = std.posix.getenv("XDG_CACHE_HOME");
    const home = std.posix.getenv("HOME");
    const base = xdg orelse (home orelse return null);
    const prefix = if (xdg != null) "/jmusic/art/" else "/.cache/jmusic/art/";
    return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ base, prefix, item_id }) catch null;
}

fn loadCachedArt(allocator: std.mem.Allocator, item_id: []const u8) ?[]const u8 {
    var buf: [300]u8 = undefined;
    const path = artCachePath(&buf, item_id) orelse return null;
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    return file.readToEndAlloc(allocator, 2 * 1024 * 1024) catch null;
}

fn saveCachedArt(item_id: []const u8, data: []const u8) void {
    var dir_buf: [280]u8 = undefined;
    const xdg = std.posix.getenv("XDG_CACHE_HOME");
    const home = std.posix.getenv("HOME");
    const base = xdg orelse (home orelse return);
    const prefix = if (xdg != null) "/jmusic/art" else "/.cache/jmusic/art";
    const dir_path = std.fmt.bufPrint(&dir_buf, "{s}{s}", .{ base, prefix }) catch return;
    // Create parent dirs recursively
    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        error.FileNotFound => {
            // Parent doesn't exist - create the jmusic dir first
            const parent_prefix = if (xdg != null) "/jmusic" else "/.cache/jmusic";
            var parent_buf: [260]u8 = undefined;
            const parent = std.fmt.bufPrint(&parent_buf, "{s}{s}", .{ base, parent_prefix }) catch return;
            std.fs.makeDirAbsolute(parent) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => return,
            };
            std.fs.makeDirAbsolute(dir_path) catch return;
        },
        else => return,
    };

    var buf: [300]u8 = undefined;
    const path = artCachePath(&buf, item_id) orelse return;
    const file = std.fs.createFileAbsolute(path, .{}) catch return;
    defer file.close();
    file.writeAll(data) catch {};
}

fn applyTexture(widget: *gtk.GtkWidget, data: []const u8) void {
    const gbytes = gtk.g_bytes_new(data.ptr, data.len);
    defer gtk.g_bytes_unref(gbytes);
    var err: ?*gtk.GError = null;
    const texture = gtk.gdk_texture_new_from_bytes(gbytes, &err);
    if (texture == null) return;
    gtk.gtk_picture_set_paintable(@ptrCast(widget), @ptrCast(texture));
    gtk.g_object_unref(texture);
}


pub fn matchesSearch(album: models.BaseItem, query: []const u8) bool {
    if (containsInsensitive(album.name, query)) return true;
    if (album.album_artist) |artist| {
        if (containsInsensitive(artist, query)) return true;
    }
    return false;
}

pub fn containsInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (0..needle.len) |j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

