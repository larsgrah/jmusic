const c = @import("../c.zig");
const gtk = c.gtk;

pub fn apply() void {
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
        \\/* Speaker picker */
        \\.speaker-popover { background-color: #1a1a1a; border: 1px solid #333; border-radius: 8px; }
        \\.speaker-row {
        \\  background: none; border: none; border-radius: 6px;
        \\  padding: 0; min-height: 36px;
        \\}
        \\.speaker-row:hover { background-color: rgba(255,255,255,0.08); }
        \\.speaker-row label { color: #e1e1e1; font-size: 13px; }
        \\.speaker-row image { color: #888; }
        \\.speaker-check { color: #d4a843; }
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
