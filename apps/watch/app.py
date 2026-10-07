"""watch — tiny video library over a folder of downloads.

Top-level subfolders of MEDIA_DIR are tabs. Thumbnails/durations are generated with
ffmpeg and cached in CACHE_DIR. Files are served as-is (HTTP range) — no live transcoding.

A background job (AUTO_CONVERT, default on) rewrites files phones can't play properly into
h264 + AAC mp4: video is copied untouched when it is already h264 (only audio is re-encoded),
otherwise re-encoded. The result replaces the original only after its duration checks out.
"""
import hashlib
import json
import os
import subprocess
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import uvicorn
from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

MEDIA = Path(os.environ.get("MEDIA_DIR", "/media")).resolve()
CACHE = Path(os.environ.get("CACHE_DIR", "/cache")).resolve()
EXTS = {".mp4", ".m4v", ".mov", ".webm", ".mkv"}
AUTO_CONVERT = os.environ.get("AUTO_CONVERT", "true").lower() == "true"
SETTLE_SECONDS = int(os.environ.get("SETTLE_SECONDS", "120"))  # don't touch files MeTube may still be writing
# What plays everywhere (incl. phones): h264 video + AAC (or no) audio. Notably mp3/opus/ac3 audio
# inside an mp4 is silent on many phones even though desktop browsers play it.
GOOD_VIDEO, GOOD_AUDIO = {"h264"}, {"aac"}
converting = {"path": None}

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
    return hashlib.sha1(f"v2|{p.relative_to(MEDIA)}|{st.st_size}|{st.st_mtime_ns}".encode()).hexdigest()


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
        acodec = next((s.get("codec_name") for s in info.get("streams", []) if s.get("codec_type") == "audio"), None)
        t = thumb_path(p)
        subprocess.run(
            ["ffmpeg", "-y", "-v", "error", "-ss", str(min(max(dur * 0.1, 0.5), 10)), "-i", str(p),
             "-frames:v", "1", "-vf", "scale=480:-2", "-q:v", "4", str(t)],
            capture_output=True, timeout=120)
        if not t.exists():  # very short clips: retry from the start
            subprocess.run(["ffmpeg", "-y", "-v", "error", "-i", str(p), "-frames:v", "1",
                            "-vf", "scale=480:-2", "-q:v", "4", str(t)], capture_output=True, timeout=120)
        meta_path(p).write_text(json.dumps({"duration": dur, "codec": vcodec, "acodec": acodec}))
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


def needs_fix(m: dict) -> bool:
    if not m or m.get("error") or not m.get("codec"):
        return False
    return m["codec"] not in GOOD_VIDEO or (m.get("acodec") is not None and m["acodec"] not in GOOD_AUDIO)


def probe_duration(p: Path) -> float:
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(p)],
                         capture_output=True, text=True, timeout=60).stdout.strip()
    return float(out or 0)


def convert(p: Path, m: dict):
    """Rewrite p as h264+AAC mp4. Never destroys the original unless the result verifies."""
    tmp = p.with_name(f".{p.stem}.converting.mp4")  # hidden => ignored by scan()
    try:
        cmd = ["nice", "-n", "19", "ffmpeg", "-y", "-v", "error", "-i", str(p), "-map", "0:v:0", "-map", "0:a:0?"]
        cmd += (["-c:v", "copy"] if m["codec"] in GOOD_VIDEO else
                ["-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-pix_fmt", "yuv420p", "-threads", "2"])
        cmd += ["-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart", str(tmp)]
        print(f"converting {p.name}: video={m['codec']} audio={m.get('acodec')}", flush=True)
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=6 * 3600)
        if r.returncode != 0 or not tmp.exists() or tmp.stat().st_size == 0:
            raise RuntimeError(r.stderr[-300:] or "ffmpeg failed")
        want, got = m.get("duration") or 0, probe_duration(tmp)
        if want and abs(got - want) > max(1.5, want * 0.03):
            raise RuntimeError(f"duration mismatch {got:.1f}s vs {want:.1f}s")
        st = p.stat()
        dest = p.with_suffix(".mp4")
        if dest != p and dest.exists():
            dest = p.with_name(p.stem + " (converted).mp4")
        for c in (thumb_path(p), meta_path(p)):
            c.unlink(missing_ok=True)
        os.replace(tmp, dest)
        os.utime(dest, ns=(st.st_atime_ns, st.st_mtime_ns))  # keep original ordering in the library
        if dest != p:
            p.unlink()
        print(f"converted {p.name} -> {dest.name}", flush=True)
    except Exception as e:
        print(f"convert FAILED for {p.name}: {e}", flush=True)
        tmp.unlink(missing_ok=True)
        (CACHE / f"{key(p)}.fail").write_text(str(e))  # don't retry forever; rebuilt key on any file change
    finally:
        converting["path"] = None


def converter_loop():
    while True:
        try:
            for p in list(scan()):
                if not meta_path(p).exists() or (CACHE / f"{key(p)}.fail").exists():
                    continue
                if time.time() - p.stat().st_mtime < SETTLE_SECONDS:
                    continue
                try:
                    m = json.loads(meta_path(p).read_text())
                except Exception:
                    continue
                if needs_fix(m):
                    converting["path"] = str(p.relative_to(MEDIA))
                    convert(p, m)
        except Exception as e:
            print(f"converter loop error: {e}", flush=True)
        time.sleep(30)


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
        codec, rel = m.get("codec"), str(p.relative_to(MEDIA))
        items.append({
            "path": str(p.relative_to(MEDIA)), "name": p.stem, "folder": f,
            "size": st.st_size, "mtime": st.st_mtime,
            "duration": m.get("duration"), "codec": codec, "acodec": m.get("acodec"),
            "compat": (not needs_fix(m)) if codec else None,
            "converting": converting["path"] == rel,
            "failed": (CACHE / f"{key(p)}.fail").exists(),
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
    if AUTO_CONVERT:
        threading.Thread(target=converter_loop, daemon=True).start()
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT", "8080")))
