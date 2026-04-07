# jmusic

A Jellyfin music player for Linux. GTK4 UI, gapless playback, offline caching, media key support.

![GPLv3](https://img.shields.io/badge/license-GPLv3-blue)

## Features

- Browse albums, playlists, recently played, favorites
- Gapless playback - sample-accurate crossover via miniaudio
- Persistent LRU audio cache with configurable size
- MPRIS D-Bus integration (media keys, playerctl, etc.)
- Prefetches upcoming tracks in the queue
- Shuffle, repeat (all/one), queue management
- Playlist creation, reorder, suggested tracks via Jellyfin instant mix
- Search across albums and artists

## Dependencies

- Zig 0.14+
- GTK4 (`libgtk-4-dev` / `gtk4-devel`)

miniaudio is bundled.

## Install

### Void Linux

Available in [void](https://github.com/larsgrah/void-custom/):

```
xbps-install -R /path/to/lars-void/hostdir/binpkgs jmusic
```

### Build from source

```
zig build run
```

## Config

Create `~/.config/jmusic/config.json`:

```json
{
  "server": "https://jellyfin.example.com",
  "username": "you",
  "password": "secret",
  "cache_size_mb": 512
}
```

Audio cache lives in `~/.cache/jmusic/audio/`, art in `~/.cache/jmusic/art/`.

## License

GPLv3, see [LICENSE](LICENSE).
