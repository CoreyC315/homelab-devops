import argparse
import datetime as dt
import html
import http.server
import json
import os
import re
import sqlite3
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from http import HTTPStatus
from pathlib import Path


CHAPTER_RE = re.compile(
    r"(?:chapter|chap|ch\.?|c)\s*([0-9]+(?:\.[0-9]+)?)",
    re.IGNORECASE,
)
NUMBER_RE = re.compile(r"([0-9]+(?:\.[0-9]+)?)")


def now_iso():
    return dt.datetime.now(dt.UTC).isoformat(timespec="seconds")


def load_config(path):
    with open(path, "r", encoding="utf-8") as config_file:
        return json.load(config_file)


def init_db(path):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(path)
    db.execute(
        """
        create table if not exists downloads (
            id integer primary key autoincrement,
            series text not null,
            chapter text not null,
            title text not null,
            url text not null,
            guid text,
            status text not null,
            created_at text not null,
            unique(series, chapter, url)
        )
        """
    )
    db.commit()
    return db


def request_text(url, timeout=30):
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "manga-watch/0.1"},
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read().decode(response.headers.get_content_charset() or "utf-8")


def parse_rss(feed_text):
    root = ET.fromstring(feed_text)
    entries = []
    for item in root.findall(".//item"):
        title = text_of(item, "title")
        link = text_of(item, "link")
        guid = text_of(item, "guid") or link or title
        enclosure = item.find("enclosure")
        enclosure_url = enclosure.get("url") if enclosure is not None else None
        entries.append(
            {
                "title": html.unescape(title or "").strip(),
                "url": (enclosure_url or link or "").strip(),
                "guid": html.unescape(guid or "").strip(),
            }
        )
    return entries


def text_of(element, tag):
    child = element.find(tag)
    if child is None or child.text is None:
        return ""
    return child.text


def normalize(value):
    return re.sub(r"[^a-z0-9]+", " ", value.lower()).strip()


def title_matches(entry_title, aliases):
    normalized_title = normalize(entry_title)
    return any(normalize(alias) in normalized_title for alias in aliases)


def extract_chapter(title, aliases):
    chapter_match = CHAPTER_RE.search(title)
    if chapter_match:
        return chapter_match.group(1)

    normalized_title = normalize(title)
    for alias in aliases:
        normalized_alias = normalize(alias)
        if normalized_alias in normalized_title:
            tail = normalized_title.split(normalized_alias, 1)[1]
            number_match = NUMBER_RE.search(tail)
            if number_match:
                return number_match.group(1)

    number_match = NUMBER_RE.search(title)
    return number_match.group(1) if number_match else None


def chapter_sort_key(chapter):
    try:
        return float(chapter)
    except ValueError:
        return -1.0


def already_downloaded(db, series, chapter):
    row = db.execute(
        "select 1 from downloads where series = ? and chapter = ? limit 1",
        (series, chapter),
    ).fetchone()
    return row is not None


def record_download(db, series, chapter, entry, status):
    db.execute(
        """
        insert or ignore into downloads
            (series, chapter, title, url, guid, status, created_at)
        values (?, ?, ?, ?, ?, ?, ?)
        """,
        (
            series,
            chapter,
            entry["title"],
            entry["url"],
            entry["guid"],
            status,
            now_iso(),
        ),
    )
    db.commit()


def qbittorrent_add(config, entry, save_path):
    qbit = config["qbittorrent"]
    base_url = qbit["url"].rstrip("/")
    cookie_jar = {}

    login_body = urllib.parse.urlencode(
        {
            "username": os.environ.get("QBITTORRENT_USERNAME", qbit.get("username", "")),
            "password": os.environ.get("QBITTORRENT_PASSWORD", qbit.get("password", "")),
        }
    ).encode()
    login_request = urllib.request.Request(
        f"{base_url}/api/v2/auth/login",
        data=login_body,
        method="POST",
    )
    with urllib.request.urlopen(login_request, timeout=30) as response:
        cookie = response.headers.get("Set-Cookie")
        if cookie:
            cookie_jar["Cookie"] = cookie.split(";", 1)[0]

    add_body = urllib.parse.urlencode(
        {
            "urls": entry["url"],
            "category": qbit.get("category", "manga"),
            "savepath": save_path,
            "paused": "false",
        }
    ).encode()
    add_request = urllib.request.Request(
        f"{base_url}/api/v2/torrents/add",
        data=add_body,
        headers=cookie_jar,
        method="POST",
    )
    with urllib.request.urlopen(add_request, timeout=30) as response:
        return response.status


def scan_series(db, config, series, dry_run=False):
    aliases = series.get("aliases") or [series["title"]]
    save_path = series.get("save_path") or config["qbittorrent"].get("save_path") or "/data/manga"
    min_chapter = series.get("min_chapter")
    candidates = []

    for feed_url in series.get("rss_urls", []):
        print(f"checking feed={feed_url} series={series['title']}")
        try:
            feed_text = request_text(feed_url)
            candidates.extend(parse_rss(feed_text))
        except (urllib.error.URLError, TimeoutError, ET.ParseError) as exc:
            print(f"feed error series={series['title']} feed={feed_url} error={exc}", file=sys.stderr)

    for entry in sorted(candidates, key=lambda item: item["title"]):
        if not entry["url"] or not title_matches(entry["title"], aliases):
            continue

        chapter = extract_chapter(entry["title"], aliases)
        if not chapter:
            print(f"skip no-chapter title={entry['title']}")
            continue

        if min_chapter is not None and chapter_sort_key(chapter) < float(min_chapter):
            continue

        if already_downloaded(db, series["title"], chapter):
            print(f"skip existing series={series['title']} chapter={chapter}")
            continue

        if dry_run:
            print(f"dry-run would add series={series['title']} chapter={chapter} url={entry['url']}")
            continue

        status = qbittorrent_add(config, entry, save_path)
        print(f"added series={series['title']} chapter={chapter} qbit_status={status}")
        record_download(db, series["title"], chapter, entry, "sent")


def check(args):
    config_path = os.environ.get("CONFIG_PATH", "/config/config.json")
    state_path = os.environ.get("STATE_PATH", "/state/manga-watch.sqlite")
    config = load_config(config_path)
    db = init_db(state_path)

    dry_run = args.dry_run or os.environ.get("DRY_RUN", "").lower() == "true"
    for series in config.get("series", []):
        scan_series(db, config, series, dry_run=dry_run)


class HealthHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in {"/", "/healthz"}:
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"status": "ok", "time": now_iso()}).encode())

    def log_message(self, format, *args):
        print(format % args)


def serve(args):
    server = http.server.ThreadingHTTPServer(("0.0.0.0", args.port), HealthHandler)
    print(f"manga-watch health server listening on :{args.port}")
    server.serve_forever()


def main():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    check_parser = subparsers.add_parser("check")
    check_parser.add_argument("--dry-run", action="store_true")
    check_parser.set_defaults(func=check)

    serve_parser = subparsers.add_parser("serve")
    serve_parser.add_argument("--port", type=int, default=8080)
    serve_parser.set_defaults(func=serve)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
