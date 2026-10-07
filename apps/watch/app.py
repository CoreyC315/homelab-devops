"""watch — tiny video library over a folder of downloads.

Top-level subfolders of MEDIA_DIR are tabs. Thumbnails/durations are generated with
ffmpeg and cached in CACHE_DIR. Files are served as-is (HTTP range) — no transcoding.
"""
import hashlib
import json
import os
import subprocess
import threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import uvicorn
from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

MEDIA = Path(os.environ.get("MEDIA_DIR", "/media")).resolve()
CACHE = Path(os.environ.get("CACHE_DIR", "/cache")).resolve()
EXTS = {".mp4", ".m4v", ".mov", ".webm", ".mkv"}
BROWSER_OK = {"h264", "vp8", "vp9", "av1"}  # codecs most browsers play; hevc is flagged

CACHE.mkdir(parents=True, exist_ok=True)
app = FastAPI()
pool = ThreadPoolExecutor(max_workers=2)
pending, lock = set(), threading.Lock()


def safe(rel: str) -> Path:
    p = (MEDIA / rel).resolve()
    if MEDIA not in p.parents or p.suffix.lower() not in EXTS or not p.is_file():
        raise HTTPException(404)
    if any(part.startswith(".") for part in p.relative_to(MEDIA).parts):
        raise HTTPException(404)
    return p


def key(p: Path) -> str:
    st = p.stat()
    return hashlib.sha1(f"{p.relative_to(MEDIA)}|{st.st_size}|{st.st_mtime_ns}".encode()).hexdigest()


def meta_path(p):
    return CACHE / f"{key(p)}.json"


def thumb_path(p):
    return CACHE / f"{key(p)}.jpg"


def build(p: Path):
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-print_format", "json", "-show_format", "-show_streams", str(p)],
            capture_output=True, text=True, timeout=60).stdout
        info = json.loads(out or "{}")
        dur = float(info.get("format", {}).get("duration") or 0)
        vcodec = next((s.get("codec_name") for s in info.get("streams", []) if s.get("codec_type") == "video"), None)
        t = thumb_path(p)
        subprocess.run(
            ["ffmpeg", "-y", "-v", "error", "-ss", str(min(max(dur * 0.1, 0.5), 10)), "-i", str(p),
             "-frames:v", "1", "-vf", "scale=480:-2", "-q:v", "4", str(t)],
            capture_output=True, timeout=120)
        if not t.exists():  # very short clips: retry from the start
            subprocess.run(["ffmpeg", "-y", "-v", "error", "-i", str(p), "-frames:v", "1",
                            "-vf", "scale=480:-2", "-q:v", "4", str(t)], capture_output=True, timeout=120)
        meta_path(p).write_text(json.dumps({"duration": dur, "codec": vcodec}))
    except Exception as e:  # never let one bad file break the library
        print(f"build failed for {p}: {e}", flush=True)
        meta_path(p).write_text(json.dumps({"duration": 0, "codec": None, "error": True}))
    finally:
        with lock:
            pending.discard(str(p))


def ensure(p: Path):
    if meta_path(p).exists():
        return
    with lock:
        if str(p) in pending:
            return
        pending.add(str(p))
    pool.submit(build, p)


def scan():
    for p in MEDIA.rglob("*"):
        if p.suffix.lower() in EXTS and p.is_file() and not any(part.startswith(".") for part in p.relative_to(MEDIA).parts):
            yield p


def folder_of(p: Path) -> str:
    parts = p.relative_to(MEDIA).parts
    return parts[0] if len(parts) > 1 else ""


@app.get("/api/videos")
def videos(folder: str | None = Query(None)):
    items, counts = [], {}
    for p in scan():
        f = folder_of(p)
        counts[f] = counts.get(f, 0) + 1
        if folder is not None and f != folder:
            continue
        st = p.stat()
        ensure(p)
        m = {}
        if meta_path(p).exists():
            try:
                m = json.loads(meta_path(p).read_text())
            except Exception:
                pass
        codec = m.get("codec")
        items.append({
            "path": str(p.relative_to(MEDIA)), "name": p.stem, "folder": f,
            "size": st.st_size, "mtime": st.st_mtime,
            "duration": m.get("duration"), "codec": codec,
            "compat": codec in BROWSER_OK if codec else None,
            "ready": bool(m) and thumb_path(p).exists(),
        })
    items.sort(key=lambda i: i["mtime"], reverse=True)
    folders = sorted(k for k in counts if k)
    return {"items": items, "folders": [{"name": f, "count": counts[f]} for f in folders],
            "unsorted": counts.get("", 0), "total": sum(counts.values())}


@app.get("/thumb")
def thumb(path: str):
    p = safe(path)
    t = thumb_path(p)
    if not t.exists():
        raise HTTPException(404)
    return FileResponse(t, media_type="image/jpeg", headers={"Cache-Control": "public, max-age=86400"})


@app.get("/video")
def video(path: str):
    return FileResponse(safe(path))  # Starlette handles Range requests


@app.delete("/api/videos")
def delete(path: str):
    p = safe(path)
    for c in (thumb_path(p), meta_path(p)):
        c.unlink(missing_ok=True)
    p.unlink()
    return {"deleted": path}


app.mount("/", StaticFiles(directory=Path(__file__).parent / "static", html=True), name="static")

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT", "8080")))
