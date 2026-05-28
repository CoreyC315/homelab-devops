# Manga Watch

Small manga release watcher for the homelab.

The first version checks configured RSS feeds, matches entries against a
watchlist, records seen chapters in SQLite, and sends matching magnet/torrent
URLs to qBittorrent.

## Commands

```sh
python -m manga_watch check
python -m manga_watch check --dry-run
python -m manga_watch serve
```

## Runtime Paths

- `CONFIG_PATH`: JSON config file, defaults to `/config/config.json`
- `STATE_PATH`: SQLite state file, defaults to `/state/manga-watch.sqlite`
- `DATA_PATH`: manga library path, defaults to `/data/manga`

## Watchlist Example

```json
{
  "qbittorrent": {
    "url": "http://qbittorrent.default.svc.cluster.local:8080",
    "category": "manga",
    "save_path": "/data/manga"
  },
  "series": [
    {
      "title": "Example Series",
      "aliases": ["Example Series", "ExampleSeries"],
      "rss_urls": ["https://example.invalid/rss"],
      "min_chapter": 1
    }
  ]
}
```

qBittorrent credentials are read from `QBITTORRENT_USERNAME` and
`QBITTORRENT_PASSWORD`.
