# manga-watch — ARCHIVED 2026-06-03

## What it was
A custom Python service that polled torrent RSS feeds, matched entries against a
watchlist, recorded seen chapters in SQLite, and pushed magnet/torrent URLs to
qBittorrent. A `serve` health endpoint + a weekly `check` CronJob.

## Why archived
Superseded by the **Suwayomi → cbz-maker → Komga** pipeline, which does the job
more robustly: Suwayomi auto-downloads new chapters directly from web sources
(Weeb Central / MangaDex) into `/data/manga`, cbz-maker normalizes filenames +
injects ComicInfo, and Komga serves them. No torrent/RSS matching needed.

See the runbook: `~/Homelab/claude-logs/2026-06-03-suwayomi-auto-download.md`.

## Deployment status when archived
**Never deployed.** The k8s manifests, the ArgoCD Application, and the GitHub
Actions image workflow were all uncommitted/untracked and never applied — there
were no manga-watch resources in the cluster. Only the app source under `app/`
was previously committed (at the old path `apps/manga-watch/`).

## Contents
- `app/` — Python source + Dockerfile (was `apps/manga-watch/`)
- `manifests/` — Kubernetes manifests (was `kubernetes/apps/manga-watch/`)
- `argocd-application.yaml` — ArgoCD Application (was `kubernetes/infrastructure/manga-watch.yaml`)
- `github-workflow-manga-watch-image.yml` — CI image build (was `.github/workflows/manga-watch-image.yml`)

## To restore (if ever needed)
1. Move `app/` back to `apps/manga-watch/` and the workflow back to
   `.github/workflows/` (fix the build `context:` path if changed).
2. Move `manifests/` back to `kubernetes/apps/manga-watch/` and
   `argocd-application.yaml` back to `kubernetes/infrastructure/manga-watch.yaml`.
3. Create the `manga-watch-secret` (qBittorrent creds) out-of-band.
4. Commit to `main`; ArgoCD picks up the new Application.
