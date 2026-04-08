const std = @import("std");
const c = @import("../c.zig");
const api = @import("../jellyfin/api.zig");
const models = @import("../jellyfin/models.zig");
const Player = @import("../audio/player.zig").Player;
const mpris = @import("mpris.zig");
const bg = @import("bg.zig");
const DiskCache = @import("../audio/cache.zig").DiskCache;
const css = @import("css.zig");
const art_mod = @import("art.zig");
const playback = @import("playback.zig");
const home = @import("home.zig");
const detail = @import("detail.zig");
const queue_mod = @import("queue.zig");
const settings = @import("settings.zig");
const now_playing = @import("now_playing.zig");
const sonos_ui = @import("sonos_ui.zig");
const lyrics_mod = @import("lyrics.zig");
const artists_mod = @import("artists.zig");
const search_mod = @import("search.zig");
pub const helpers = @import("helpers.zig");

const log = std.log.scoped(.ui);
const gtk = c.gtk;

const MAX_GRID_ITEMS = 60;
pub const PREFETCH_AHEAD = 10;

const main = @import("../main.zig");
const sonos = main.sonos;
const discord = main.discord;
const scrobble = main.scrobble;

// Re-export for tests
const g_signal_connect = helpers.g_signal_connect;
const makeLabel = helpers.makeLabel;
const setObjString = helpers.setObjString;
const setLabelText = helpers.setLabelText;
const clearChildren = helpers.clearChildren;
pub const matchesSearch = helpers.matchesSearch;
pub const containsInsensitive = helpers.containsInsensitive;
pub const ArtJob = art_mod.ArtJob;
pub const collectArtJobsFromBox = art_mod.collectArtJobsFromBox;
pub const artCachePath = art_mod.artCachePath;

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
    track_queue: ?[]models.BaseItem = null,
    track_queue_owned: bool = false,
    queue_index: usize = 0,
    current_album_idx: ?usize = null,
    current_playlist_idx: ?usize = null,
    playing_album_idx: ?usize = null,
    playing_playlist_id: ?[]const u8 = null,
    audio_cache: AudioCache = .{},
    disk_audio_cache: DiskCache = undefined,
    grid_art_gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    home_art_gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    deduped_albums: ?[]models.BaseItem = null,
    artists: ?models.ItemList = null,
    artists_loaded: bool = false,
    artist_albums: ?models.ItemList = null,
    current_artist: ?models.BaseItem = null,
    detail_load_gen: u32 = 0,

    // Navigation
    nav_stack: [32][*:0]const u8 = undefined,
    nav_pos: i32 = -1,
    nav_len: i32 = 0,
    nav_inhibit: bool = false,

    // Widgets
    window: *gtk.GtkWidget = undefined,
    search_entry: *gtk.GtkWidget = undefined,
    back_btn: *gtk.GtkWidget = undefined,
    content_stack: *gtk.GtkWidget = undefined,
    album_grid: *gtk.GtkWidget = undefined,
    sidebar_playlists: *gtk.GtkWidget = undefined,
    home_box: *gtk.GtkWidget = undefined,
    detail_art: *gtk.GtkWidget = undefined,
    detail_type_label: *gtk.GtkWidget = undefined,
    detail_title: *gtk.GtkWidget = undefined,
    detail_artist: *gtk.GtkWidget = undefined,
    track_list_box: *gtk.GtkWidget = undefined,
    artist_list: *gtk.GtkWidget = undefined,
    search_results_box: *gtk.GtkWidget = undefined,
    search_artists: ?models.ItemList = null,
    search_tracks: ?models.ItemList = null,
    search_gen: u32 = 0,
    current_playlist_id: ?[]const u8 = null,
    playlist_cache: std.StringHashMap(models.ItemList) = undefined,
    playlist_cache_mutex: std.Thread.Mutex = .{},
    album_track_cache: std.StringHashMap(models.ItemList) = undefined,
    album_track_cache_mutex: std.Thread.Mutex = .{},
    suggestions_box: *gtk.GtkWidget = undefined,
    shuffle_btn: *gtk.GtkWidget = undefined,
    repeat_btn: *gtk.GtkWidget = undefined,
    volume_scale: *gtk.GtkWidget = undefined,
    volume_btn: *gtk.GtkWidget = undefined,
    queue_revealer: *gtk.GtkWidget = undefined,
    queue_list: *gtk.GtkWidget = undefined,
    queue_btn: *gtk.GtkWidget = undefined,
    settings_server: *gtk.GtkWidget = undefined,
    settings_user: *gtk.GtkWidget = undefined,
    settings_pass: *gtk.GtkWidget = undefined,
    settings_cache: *gtk.GtkWidget = undefined,
    settings_lb_token: *gtk.GtkWidget = undefined,
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
    updating_volume: bool = false,

    // Sonos
    sonos_client: ?*sonos.Client = null,
    sonos_speakers: [sonos.max_speakers]sonos.Speaker = undefined,
    sonos_speaker_count: u8 = 0,
    sonos_active: ?u8 = null,
    sonos_grouped: [sonos.max_speakers]bool = [_]bool{false} ** sonos.max_speakers,
    sonos_btn: *gtk.GtkWidget = undefined,
    sonos_popover: *gtk.GtkWidget = undefined,
    sonos_list: *gtk.GtkWidget = undefined,
    sonos_playing: bool = false,
    sonos_position_secs: u32 = 0,
    sonos_duration_secs: u32 = 0,
    sonos_sub_secs: f32 = 0,
    sonos_poll_counter: u8 = 0,
    sonos_track_ended: bool = false,
    resume_seek: ?f64 = null,
    discord_rpc: discord.RichPresence = discord.RichPresence.init(),

    // Lyrics
    lyrics_revealer: *gtk.GtkWidget = undefined,
    lyrics_scroll: *gtk.GtkWidget = undefined,
    lyrics_list: *gtk.GtkWidget = undefined,
    lyrics_lines: ?[]lyrics_mod.LyricLine = null,
    lyrics_current_idx: ?usize = null,
    lyrics_btn: *gtk.GtkWidget = undefined,
    scrobbler: scrobble.Scrobbler = undefined,
    scrobbler_initialized: bool = false,

    // ---------------------------------------------------------------
    // Build
    // ---------------------------------------------------------------
    pub fn build(self: *App, gtk_app: *gtk.GtkApplication) void {
        css.apply();

        self.window = gtk.gtk_application_window_new(gtk_app);
        gtk.gtk_window_set_title(@ptrCast(self.window), "jmusic");
        gtk.gtk_window_set_default_size(@ptrCast(self.window), 1200, 750);

        const outer = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);
        gtk.gtk_window_set_child(@ptrCast(self.window), outer);

        const root = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 0);
        gtk.gtk_widget_set_vexpand(root, 1);
        gtk.gtk_box_append(@ptrCast(outer), root);

        // Sidebar
        const sidebar = self.buildSidebar();
        gtk.gtk_box_append(@ptrCast(root), sidebar);

        // Right side
        const right = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);
        gtk.gtk_widget_set_hexpand(right, 1);

        // Header
        const header_widget = self.buildHeader();
        gtk.gtk_box_append(@ptrCast(right), header_widget);

        // Content stack
        self.content_stack = gtk.gtk_stack_new();
        gtk.gtk_widget_set_vexpand(self.content_stack, 1);
        gtk.gtk_widget_set_hexpand(self.content_stack, 1);
        gtk.gtk_stack_set_transition_type(@ptrCast(self.content_stack), gtk.GTK_STACK_TRANSITION_TYPE_CROSSFADE);
        gtk.gtk_stack_set_transition_duration(@ptrCast(self.content_stack), 150);
        gtk.gtk_stack_set_hhomogeneous(@ptrCast(self.content_stack), 1);
        gtk.gtk_stack_set_vhomogeneous(@ptrCast(self.content_stack), 1);

        // Pages
        const home_scroll = gtk.gtk_scrolled_window_new();
        gtk.gtk_widget_set_vexpand(home_scroll, 1);
        self.home_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);
        gtk.gtk_scrolled_window_set_child(@ptrCast(home_scroll), self.home_box);
        _ = gtk.gtk_stack_add_named(@ptrCast(self.content_stack), home_scroll, "home");

        const albums_page = self.buildAlbumsPage();
        _ = gtk.gtk_stack_add_named(@ptrCast(self.content_stack), albums_page, "albums");

        const search_page = search_mod.buildSearchPage(self);
        _ = gtk.gtk_stack_add_named(@ptrCast(self.content_stack), search_page, "search");

        const artists_page = artists_mod.buildArtistsPage(self);
        _ = gtk.gtk_stack_add_named(@ptrCast(self.content_stack), artists_page, "artists");

        const detail_page = detail.buildDetailPage(self);
        _ = gtk.gtk_stack_add_named(@ptrCast(self.content_stack), detail_page, "detail");

        const settings_page = settings.buildSettingsPage(self);
        _ = gtk.gtk_stack_add_named(@ptrCast(self.content_stack), settings_page, "settings");

        // Content + queue overlay
        const middle = gtk.gtk_overlay_new();
        gtk.gtk_widget_set_vexpand(middle, 1);
        gtk.gtk_widget_set_hexpand(middle, 1);
        gtk.gtk_overlay_set_child(@ptrCast(middle), self.content_stack);

        queue_mod.buildQueuePanel(self);
        gtk.gtk_overlay_add_overlay(@ptrCast(middle), self.queue_revealer);

        lyrics_mod.buildLyricsPanel(self);
        gtk.gtk_overlay_add_overlay(@ptrCast(middle), self.lyrics_revealer);

        gtk.gtk_box_append(@ptrCast(right), middle);
        gtk.gtk_box_append(@ptrCast(root), right);

        // Now playing bar
        const np_bar = now_playing.buildNowPlayingBar(self);
        gtk.gtk_box_append(@ptrCast(outer), np_bar);

        // Mouse back/forward
        const click = gtk.gtk_gesture_click_new();
        gtk.gtk_gesture_single_set_button(@ptrCast(click), 0);
        _ = g_signal_connect(@as(*anyopaque, @ptrCast(click)), "pressed", &onMouseButton, self);
        gtk.gtk_widget_add_controller(self.window, @ptrCast(click));

        // Keyboard shortcuts
        const key_ctrl = gtk.gtk_event_controller_key_new();
        _ = g_signal_connect(@as(*anyopaque, @ptrCast(key_ctrl)), "key-pressed", &onKeyPressed, self);
        gtk.gtk_widget_add_controller(self.window, @ptrCast(key_ctrl));

        self.navPush("home");

        _ = g_signal_connect(self.search_entry, "search-changed", &onSearchChanged, self);
        _ = g_signal_connect(self.back_btn, "clicked", &onBack, self);
        _ = g_signal_connect(self.play_btn, "clicked", &now_playing.onPlayPause, self);

        _ = g_signal_connect(self.window, "close-request", &onWindowClose, self);
        gtk.gtk_widget_set_visible(self.window, 1);

        _ = gtk.g_idle_add(&initBackendIdle, self);
        self.progress_timer = gtk.g_timeout_add(250, &playback.updateProgress, self);
        _ = gtk.g_timeout_add(16, &playback.checkTrackEnd, self);
    }

    fn buildSidebar(self: *App) *gtk.GtkWidget {
        const sidebar = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);
        gtk.gtk_widget_add_css_class(sidebar, "sidebar");
        gtk.gtk_widget_set_size_request(sidebar, 200, -1);
        gtk.gtk_widget_set_hexpand(sidebar, 0);

        const logo = gtk.gtk_label_new("jmusic");
        gtk.gtk_widget_add_css_class(logo, "sidebar-logo");
        gtk.gtk_label_set_xalign(@ptrCast(logo), 0);
        gtk.gtk_box_append(@ptrCast(sidebar), logo);

        const nav_items = [_]struct { label: [*:0]const u8, cb: *const anyopaque }{
            .{ .label = "Home", .cb = &onNavHome },
            .{ .label = "Search", .cb = &onNavSearch },
            .{ .label = "Albums", .cb = &onNavAlbums },
            .{ .label = "Artists", .cb = &onNavArtists },
        };
        for (nav_items) |item| {
            const btn = gtk.gtk_button_new_with_label(item.label);
            gtk.gtk_widget_add_css_class(btn, "sidebar-item");
            gtk.gtk_button_set_has_frame(@ptrCast(btn), 0);
            gtk.gtk_widget_set_halign(btn, gtk.GTK_ALIGN_FILL);
            const btn_child = gtk.gtk_button_get_child(@ptrCast(btn));
            if (btn_child != null) gtk.gtk_label_set_xalign(@ptrCast(btn_child), 0);
            _ = g_signal_connect(btn, "clicked", item.cb, self);
            gtk.gtk_box_append(@ptrCast(sidebar), btn);
        }

        const divider = gtk.gtk_separator_new(gtk.GTK_ORIENTATION_HORIZONTAL);
        gtk.gtk_widget_add_css_class(divider, "sidebar-divider");
        gtk.gtk_box_append(@ptrCast(sidebar), divider);

        const pl_header = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 0);
        const pl_label = gtk.gtk_label_new("Playlists");
        gtk.gtk_widget_add_css_class(pl_label, "sidebar-section");
        gtk.gtk_label_set_xalign(@ptrCast(pl_label), 0);
        gtk.gtk_widget_set_hexpand(pl_label, 1);
        gtk.gtk_box_append(@ptrCast(pl_header), pl_label);

        const new_pl_btn = gtk.gtk_button_new_from_icon_name("list-add-symbolic");
        gtk.gtk_widget_add_css_class(new_pl_btn, "sidebar-add-btn");
        gtk.gtk_button_set_has_frame(@ptrCast(new_pl_btn), 0);
        _ = g_signal_connect(new_pl_btn, "clicked", &detail.onNewPlaylist, self);
        gtk.gtk_box_append(@ptrCast(pl_header), new_pl_btn);
        gtk.gtk_box_append(@ptrCast(sidebar), pl_header);

        const pl_scroll = gtk.gtk_scrolled_window_new();
        gtk.gtk_widget_set_vexpand(pl_scroll, 1);
        self.sidebar_playlists = gtk.gtk_list_box_new();
        gtk.gtk_widget_add_css_class(self.sidebar_playlists, "sidebar-list");
        gtk.gtk_list_box_set_selection_mode(@ptrCast(self.sidebar_playlists), gtk.GTK_SELECTION_SINGLE);
        _ = g_signal_connect(self.sidebar_playlists, "row-activated", &detail.onPlaylistActivated, self);
        gtk.gtk_scrolled_window_set_child(@ptrCast(pl_scroll), self.sidebar_playlists);
        gtk.gtk_box_append(@ptrCast(sidebar), pl_scroll);

        return sidebar;
    }

    fn buildHeader(self: *App) *gtk.GtkWidget {
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

        const profile_btn = gtk.gtk_button_new_from_icon_name("avatar-default-symbolic");
        gtk.gtk_widget_add_css_class(profile_btn, "profile-btn");
        _ = g_signal_connect(profile_btn, "clicked", &onProfileClicked, self);
        gtk.gtk_box_append(@ptrCast(header), profile_btn);

        return header;
    }

    fn buildAlbumsPage(self: *App) *gtk.GtkWidget {
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

        return albums_box;
    }

    // ---------------------------------------------------------------
    // Init
    // ---------------------------------------------------------------
    fn initBackendIdle(data: ?*anyopaque) callconv(.c) c_int {
        const self: *App = @ptrCast(@alignCast(data));

        self.player = Player.create(self.allocator) catch |err| {
            log.err("audio init failed: {}", .{err});
            return 0;
        };

        // Apply saved volume to audio engine
        if (self.config.volume) |vol| {
            _ = c.ma.ma_engine_set_volume(&self.player.?.engine, @floatCast(vol));
        }

        // Scrobbler
        self.scrobbler = scrobble.Scrobbler.init(self.allocator);
        self.scrobbler.lastfm_api_key = self.config.lastfm_api_key;
        self.scrobbler.lastfm_secret = self.config.lastfm_secret;
        self.scrobbler.lastfm_session = self.config.lastfm_session_key;
        self.scrobbler.listenbrainz_token = self.config.listenbrainz_token;
        self.scrobbler_initialized = true;
        if (self.scrobbler.enabled()) log.info("scrobbling enabled", .{});

        // Sonos client for main-thread transport commands
        if (self.allocator.create(sonos.Client)) |sc| {
            sc.* = sonos.Client.init(self.allocator);
            self.sonos_client = sc;
        } else |_| {}

        mpris.init(self);

        // Load cached data immediately so UI is populated fast
        if (api.Client.readCacheFile(self.allocator, "albums.json", 168)) |cached| {
            defer self.allocator.free(cached);
            if (models.parseItemList(self.allocator, cached)) |list| {
                self.albums = list;
                self.filterAlbums("");
                log.info("loaded {d} albums from cache", .{list.items.len});
            } else |_| {}
        }

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

        self.home_recent = bg_client.getRecentlyPlayed(50) catch null;
        self.home_added = bg_client.getRecentlyAdded(20) catch null;
        self.home_random = bg_client.getRandomAlbums(20) catch null;
        self.home_favorites = bg_client.getFavoriteAlbums(20) catch null;
        self.playlists = bg_client.getPlaylists() catch null;

        _ = gtk.g_idle_add(&onHomeReady, self);

        if (self.playlists) |pls| {
            for (pls.items) |playlist| {
                const tracks = bg_client.getPlaylistTracks(playlist.id) catch continue;
                self.playlist_cache_mutex.lock();
                self.playlist_cache.put(playlist.id, tracks) catch {};
                self.playlist_cache_mutex.unlock();
            }
            log.info("prefetched {d} playlist contents", .{pls.items.len});
        }

        const albums = bg_client.getAlbums() catch |err| {
            log.err("failed to load albums: {}", .{err});
            return;
        };
        log.info("loaded {d} albums", .{albums.items.len});
        self.albums = albums;
        _ = gtk.g_idle_add(&onAlbumsReady, self);

        _ = bg_client.fetchAndCacheAlbums() catch {};

        // Discover Sonos speakers on the network
        sonos_ui.startDiscovery(self);
    }

    fn onHomeReady(data: ?*anyopaque) callconv(.c) c_int {
        const self: *App = @ptrCast(@alignCast(data));
        home.buildHomePage(self);
        self.populatePlaylists();
        setLabelText(self.np_title, "Nothing playing");
        return 0;
    }

    fn onAlbumsReady(data: ?*anyopaque) callconv(.c) c_int {
        const self: *App = @ptrCast(@alignCast(data));
        self.filterAlbums("");
        return 0;
    }

    // ---------------------------------------------------------------
    // Album grid
    // ---------------------------------------------------------------
    pub fn filterAlbums(self: *App, query: []const u8) void {
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

        self.spawnArtLoader();
    }

    fn addAlbumCard(self: *App, album: models.BaseItem, index: usize) void {
        const card = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);
        gtk.gtk_widget_add_css_class(card, "album-card");

        const pic = gtk.gtk_picture_new();
        gtk.gtk_widget_add_css_class(pic, "grid-art");
        gtk.gtk_widget_set_size_request(pic, 160, 160);
        gtk.gtk_widget_set_vexpand(pic, 0);
        gtk.gtk_widget_set_hexpand(pic, 0);
        gtk.gtk_picture_set_content_fit(@ptrCast(pic), gtk.GTK_CONTENT_FIT_COVER);
        gtk.gtk_widget_set_name(pic, "needs-art");
        gtk.gtk_box_append(@ptrCast(card), pic);

        const title = makeLabel(self.allocator, album.name);
        gtk.gtk_widget_add_css_class(title, "album-title");
        gtk.gtk_label_set_xalign(@ptrCast(title), 0);
        gtk.gtk_label_set_ellipsize(@ptrCast(title), 3);
        gtk.gtk_label_set_max_width_chars(@ptrCast(title), 22);
        gtk.gtk_box_append(@ptrCast(card), title);

        if (album.album_artist) |artist_name| {
            const artist = makeLabel(self.allocator, artist_name);
            gtk.gtk_widget_add_css_class(artist, "album-artist");
            gtk.gtk_label_set_xalign(@ptrCast(artist), 0);
            gtk.gtk_label_set_ellipsize(@ptrCast(artist), 3);
            gtk.gtk_label_set_max_width_chars(@ptrCast(artist), 22);
            gtk.gtk_box_append(@ptrCast(card), artist);
        }

        const button = gtk.gtk_button_new();
        gtk.gtk_widget_add_css_class(button, "flat");
        gtk.gtk_widget_add_css_class(button, "album-card-btn");
        gtk.gtk_widget_set_valign(button, gtk.GTK_ALIGN_START);
        gtk.gtk_button_set_child(@ptrCast(button), card);
        gtk.g_object_set_data(@ptrCast(button), "idx", @ptrFromInt(index + 1));
        _ = g_signal_connect(button, "clicked", &onAlbumCardClicked, self);

        gtk.gtk_flow_box_append(@ptrCast(self.album_grid), button);
    }

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

    pub fn spawnArtThread(self: *App, jobs: std.array_list.AlignedManaged(ArtJob, null), gen: u32, gen_ptr: *std.atomic.Value(u32)) void {
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

        var client = api.Client.init(ctx.alloc, ctx.base_url);
        defer client.deinit();

        for (ctx.jobs.items) |job| {
            if (ctx.gen_ptr.load(.acquire) != ctx.gen) return;

            const img_data = art_mod.loadCachedArt(ctx.alloc, job.id) orelse blk: {
                const img_url = std.fmt.allocPrint(ctx.alloc, "{s}/Items/{s}/Images/Primary?maxWidth=160", .{ ctx.base_url, job.id }) catch continue;
                defer ctx.alloc.free(img_url);

                const data = client.fetchBytes(img_url) catch {
                    client.http.deinit();
                    client.http = .{ .allocator = ctx.alloc };
                    const retry = client.fetchBytes(img_url) catch continue;
                    art_mod.saveCachedArt(job.id, retry);
                    break :blk retry;
                };
                art_mod.saveCachedArt(job.id, data);
                break :blk data;
            };

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

    // ---------------------------------------------------------------
    // Delegates
    // ---------------------------------------------------------------
    pub fn showAlbumDetail(self: *App, idx: usize) void { detail.showAlbumDetail(self, idx); }
    pub fn showAlbumById(self: *App, id: []const u8) void { detail.showAlbumById(self, id); }
    pub fn openPlaylistById(self: *App, id: []const u8) void { detail.openPlaylistById(self, id); }
    pub fn playTrack(self: *App, index: usize) void { playback.playTrack(self, index); }
    pub fn playNext(self: *App) void { playback.playNext(self); }
    pub fn playPrev(self: *App) void { playback.playPrev(self); }
    pub fn doTogglePause(self: *App) void { playback.doTogglePause(self); }
    pub fn setQueue(self: *App, items: []const models.BaseItem, start_index: usize) void { playback.setQueue(self, items, start_index); }
    pub fn shuffleQueue(self: *App) void { playback.shuffleQueue(self); }
    pub fn insertNextInQueue(self: *App, track: models.BaseItem) void { playback.insertNextInQueue(self, track); }
    pub fn rebuildQueueList(self: *App) void { queue_mod.rebuildQueueList(self); }

    pub fn freeLyrics(self: *App) void {
        if (self.lyrics_lines) |lines| {
            for (lines) |line| self.allocator.free(line.text);
            self.allocator.free(lines);
            self.lyrics_lines = null;
        }
        self.lyrics_current_idx = null;
    }

    pub fn refreshQueueIfVisible(self: *App) void {
        if (gtk.gtk_revealer_get_reveal_child(@ptrCast(self.queue_revealer)) != 0) {
            self.rebuildQueueList();
        }
    }

    pub fn highlightCurrentTrack(self: *App) void {
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

    pub fn populatePlaylists(self: *App) void {
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

    // ---------------------------------------------------------------
    // Navigation
    // ---------------------------------------------------------------
    fn navPush(self: *App, page: [*:0]const u8) void {
        if (self.nav_inhibit) return;
        if (self.nav_pos >= 0 and self.nav_pos < @as(i32, @intCast(self.nav_stack.len))) {
            if (self.nav_stack[@intCast(self.nav_pos)] == page) return;
        }
        if (self.nav_pos + 1 >= @as(i32, @intCast(self.nav_stack.len))) {
            for (0..self.nav_stack.len - 1) |ni| {
                self.nav_stack[ni] = self.nav_stack[ni + 1];
            }
            self.nav_stack[self.nav_stack.len - 1] = page;
            self.nav_len = @intCast(self.nav_stack.len);
        } else {
            self.nav_pos += 1;
            self.nav_stack[@intCast(self.nav_pos)] = page;
            self.nav_len = self.nav_pos + 1;
        }
    }

    pub fn navigateTo(self: *App, page: [*:0]const u8) void {
        self.navPush(page);
        gtk.gtk_stack_set_visible_child_name(@ptrCast(self.content_stack), page);
        const is_browse = std.mem.orderZ(u8, page, "home") == .eq or std.mem.orderZ(u8, page, "albums") == .eq or std.mem.orderZ(u8, page, "artists") == .eq or std.mem.orderZ(u8, page, "search") == .eq;
        gtk.gtk_widget_set_visible(self.back_btn, if (is_browse) 0 else 1);
    }

    fn navGoBack(self: *App) void {
        if (self.nav_pos <= 0) return;

        // If viewing album opened from artist detail, go back to that artist
        if (self.current_artist) |artist| {
            if (self.artist_albums == null) {
                // Don't push to nav stack - just restore artist content
                self.nav_inhibit = true;
                artists_mod.showArtistDetail(self, artist);
                self.nav_inhibit = false;
                return;
            }
            // On artist detail itself - clear and do normal back
            self.current_artist = null;
            self.artist_albums = null;
        }

        self.nav_pos -= 1;
        const page = self.nav_stack[@intCast(self.nav_pos)];
        self.nav_inhibit = true;
        gtk.gtk_stack_set_visible_child_name(@ptrCast(self.content_stack), page);
        const is_browse = std.mem.orderZ(u8, page, "home") == .eq or std.mem.orderZ(u8, page, "albums") == .eq or std.mem.orderZ(u8, page, "artists") == .eq or std.mem.orderZ(u8, page, "search") == .eq;
        gtk.gtk_widget_set_visible(self.back_btn, if (is_browse) 0 else 1);
        self.nav_inhibit = false;
    }

    fn navGoForward(self: *App) void {
        if (self.nav_pos + 1 >= self.nav_len) return;
        self.nav_pos += 1;
        const page = self.nav_stack[@intCast(self.nav_pos)];
        self.nav_inhibit = true;
        gtk.gtk_stack_set_visible_child_name(@ptrCast(self.content_stack), page);
        const is_browse = std.mem.orderZ(u8, page, "home") == .eq or std.mem.orderZ(u8, page, "albums") == .eq or std.mem.orderZ(u8, page, "artists") == .eq or std.mem.orderZ(u8, page, "search") == .eq;
        gtk.gtk_widget_set_visible(self.back_btn, if (is_browse) 0 else 1);
        self.nav_inhibit = false;
    }

    // ---------------------------------------------------------------
    // Signal handlers (nav + search)
    // ---------------------------------------------------------------
    fn onKeyPressed(_: *gtk.GtkEventControllerKey, keyval: c_uint, _: c_uint, state: c_uint, data: ?*anyopaque) callconv(.c) c_int {
        const self: *App = @ptrCast(@alignCast(data));
        const ctrl = (state & gtk.GDK_CONTROL_MASK) != 0;

        switch (keyval) {
            gtk.GDK_KEY_space => {
                // Don't capture space when search entry is focused
                if (gtk.gtk_widget_has_focus(self.search_entry) != 0) return 0;
                self.doTogglePause();
                return 1;
            },
            gtk.GDK_KEY_Left => {
                if (ctrl) {
                    self.playPrev();
                } else {
                    // Seek back 5s
                    if (self.sonos_active) |idx| {
                        const pos = if (self.sonos_position_secs > 5) self.sonos_position_secs - 5 else 0;
                        if (self.sonos_client) |sc| sc.seek(self.sonos_speakers[idx].ip(), pos) catch {};
                        self.sonos_position_secs = pos;
                        self.sonos_sub_secs = 0;
                    } else if (self.player) |p| {
                        const len = p.getLengthSeconds();
                        if (len > 0) {
                            const cur = p.getCursorSeconds();
                            const target = if (cur > 5) cur - 5 else 0;
                            p.seek(@as(f64, target) / @as(f64, len));
                        }
                    }
                }
                return 1;
            },
            gtk.GDK_KEY_Right => {
                if (ctrl) {
                    self.playNext();
                } else {
                    // Seek forward 5s
                    if (self.sonos_active) |idx| {
                        const pos = self.sonos_position_secs + 5;
                        if (self.sonos_client) |sc| sc.seek(self.sonos_speakers[idx].ip(), pos) catch {};
                        self.sonos_position_secs = pos;
                        self.sonos_sub_secs = 0;
                    } else if (self.player) |p| {
                        const len = p.getLengthSeconds();
                        if (len > 0) {
                            const cur = p.getCursorSeconds();
                            const target = @min(cur + 5, len);
                            p.seek(@as(f64, target) / @as(f64, len));
                        }
                    }
                }
                return 1;
            },
            gtk.GDK_KEY_plus, gtk.GDK_KEY_equal => {
                const vol = gtk.gtk_range_get_value(@ptrCast(self.volume_scale));
                gtk.gtk_range_set_value(@ptrCast(self.volume_scale), @min(1.0, vol + 0.05));
                return 1;
            },
            gtk.GDK_KEY_minus => {
                const vol = gtk.gtk_range_get_value(@ptrCast(self.volume_scale));
                gtk.gtk_range_set_value(@ptrCast(self.volume_scale), @max(0.0, vol - 0.05));
                return 1;
            },
            else => return 0,
        }
    }

    fn onWindowClose(_: *gtk.GtkWidget, data: ?*anyopaque) callconv(.c) c_int {
        const self: *App = @ptrCast(@alignCast(data));
        settings.saveConfig(self);
        return 0; // allow close to proceed
    }

    fn onMouseButton(gesture: *gtk.GtkGestureClick, _: c_int, _: f64, _: f64, data: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        const btn = gtk.gtk_gesture_single_get_current_button(@ptrCast(gesture));
        if (btn == 8) self.navGoBack();
        if (btn == 9) self.navGoForward();
    }

    fn onBack(_: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        self.navGoBack();
    }

    fn onSearchChanged(entry: *gtk.GtkSearchEntry, data: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        const raw: [*c]const u8 = gtk.gtk_editable_get_text(@ptrCast(entry));
        const query = std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
        if (query.len == 0) {
            self.navigateTo("home");
            return;
        }
        self.navigateTo("search");
        search_mod.runSearch(self, query);
    }

    fn onAlbumCardClicked(button: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        const raw = @intFromPtr(gtk.g_object_get_data(@ptrCast(button), "idx"));
        if (raw == 0) return;
        self.showAlbumDetail(raw - 1);
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

    fn onNavArtists(_: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        artists_mod.loadArtists(self);
        self.navigateTo("artists");
    }

    fn onProfileClicked(_: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        self.navigateTo("settings");
    }
};

