import os
import sys
import time
import subprocess
import tempfile
import logging
import requests
from pathlib import Path
from faster_whisper import WhisperModel

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)

JELLYFIN_URL = os.environ["JELLYFIN_URL"].rstrip("/")
JELLYFIN_API_KEY = os.environ["JELLYFIN_API_KEY"]
MEDIA_ROOT = os.environ.get("MEDIA_ROOT", "/media")
WHISPER_MODEL = os.environ.get("WHISPER_MODEL", "base")
# "translate" => always output English; "transcribe" => keep source language
WHISPER_TASK = os.environ.get("WHISPER_TASK", "translate")
POLL_INTERVAL = int(os.environ.get("POLL_INTERVAL", "3600"))
DRY_RUN = os.environ.get("DRY_RUN", "").lower() in ("1", "true", "yes")

HEADERS = {"X-Emby-Token": JELLYFIN_API_KEY}


def jellyfin_get(path, **params):
    r = requests.get(f"{JELLYFIN_URL}{path}", headers=HEADERS, params=params, timeout=30)
    r.raise_for_status()
    return r.json()


def items_missing_subs():
    data = jellyfin_get(
        "/Items",
        Recursive=True,
        IncludeItemTypes="Movie,Episode",
        Fields="MediaStreams,Path",
        HasSubtitles=False,
    )
    return data.get("Items", [])


def local_path(jellyfin_path):
    """Map the Jellyfin server-side path to the container's NFS mount."""
    return Path(MEDIA_ROOT) / Path(jellyfin_path).relative_to("/")


def extract_audio(video_path, audio_path):
    subprocess.run(
        ["ffmpeg", "-y", "-i", str(video_path), "-vn", "-acodec", "pcm_s16le",
         "-ar", "16000", "-ac", "1", str(audio_path)],
        check=True,
        capture_output=True,
    )


def segments_to_srt(segments):
    lines = []
    for i, seg in enumerate(segments, start=1):
        start = format_ts(seg.start)
        end = format_ts(seg.end)
        lines.append(f"{i}\n{start} --> {end}\n{seg.text.strip()}\n")
    return "\n".join(lines)


def format_ts(seconds):
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = int(seconds % 60)
    ms = int((seconds % 1) * 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def transcribe(video_path, model):
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        audio_path = Path(f.name)
    try:
        extract_audio(video_path, audio_path)
        segments, _ = model.transcribe(str(audio_path), task=WHISPER_TASK, beam_size=5)
        return list(segments)
    finally:
        audio_path.unlink(missing_ok=True)


def refresh_item(item_id):
    requests.post(
        f"{JELLYFIN_URL}/Items/{item_id}/Refresh",
        headers=HEADERS,
        params={"MetadataRefreshMode": "Default", "ImageRefreshMode": "Default"},
        timeout=30,
    )


def process_item(item, model):
    item_id = item["Id"]
    name = item.get("Name", item_id)
    jf_path = item.get("Path", "")
    if not jf_path:
        log.warning("No path for %s, skipping", name)
        return

    video_path = local_path(jf_path)
    if not video_path.exists():
        log.warning("File not found on NFS: %s", video_path)
        return

    srt_path = video_path.with_suffix(".srt")
    if srt_path.exists():
        log.info("SRT already exists for %s, skipping", name)
        return

    if DRY_RUN:
        log.info("[dry-run] Would transcribe: %s → %s", video_path.name, srt_path.name)
        return

    log.info("Transcribing: %s", name)
    try:
        segments = transcribe(video_path, model)
        srt_path.write_text(segments_to_srt(segments), encoding="utf-8")
        log.info("Saved: %s", srt_path)
        refresh_item(item_id)
    except Exception as e:
        log.error("Failed to transcribe %s: %s", name, e)


def run_once(model):
    items = items_missing_subs()
    log.info("Found %d items missing subtitles", len(items))
    for item in items:
        process_item(item, model)


def main():
    log.info("Loading Whisper model: %s", WHISPER_MODEL)
    model = WhisperModel(WHISPER_MODEL, device="cpu", compute_type="int8")
    log.info("Model loaded. Poll interval: %ds", POLL_INTERVAL)

    if DRY_RUN:
        log.info("DRY RUN mode — no files will be written")
        run_once(model)
        return

    while True:
        try:
            run_once(model)
        except Exception as e:
            log.error("Poll cycle error: %s", e)
        log.info("Sleeping %ds until next poll", POLL_INTERVAL)
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
