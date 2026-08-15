# Teyvat Hardening — Execution Log

> Live log of the actual execution of `teyvat-hardening-plan.md`, started **2026-08-14**.
> Written incrementally as phases complete — each phase section is appended when its
> acceptance criteria pass, same convention as `ousia/phase-*-notes.md`.
> Owner requirement recorded up front: **DNS continuity — `jellyfin.lan` and every
> other `*.lan`/`*.local` service hostname must keep working throughout.**

---

## Phase 0 — Blocking pre-requisites (COMPLETE 2026-08-14)

All six gates resolved. Three findings **deviate from the plan's assumptions** — recorded here because later phases act on the corrected facts.

1. **ArgoCD install method: raw manifests, out-of-repo** (confirmed live: `kubectl.kubernetes.io/last-applied-configuration` present, no Helm release labels, image `quay.io/argoproj/argocd:v3.2.4`). Matches the PNEUMA DELTAS finding. Consequence: no KSOPS repo-server patch (it would be untracked drift on an unmanaged Deployment, silently wiped by any future ArgoCD manifest re-apply) → **the plan's documented out-of-band fallback is the chosen path for Phase 2** (see Phase 2 section for the exact shape).

2. **MetalLB pool `.50-.55` — only `.53` is free.** The plan assumed `.51`/`.55` free; live state:
   `.50` ingress-nginx · `.51` suwayomi · `.52` seerr · `.54` komga · `.55` litellm (new since the ousia build).
   Note suwayomi's Service *annotation* still requests `.52` but MetalLB actually assigned `.51` (seerr got `.52` first) — the annotation is stale/ignored, cleanup queued for Phase 7. **Temp Gateway staging IP = `.53`** (plan's Open Decision #4, resolved live).

3. **kube-router NetworkPolicy enforcement: CONFIRMED, again, on the current node set** (the PNEUMA DELTAS confirmation predates the pneuma→ousia node swap, so it was re-proven): busybox httpd pod + client in a throwaway ns; baseline HTTP fetch succeeded; after a default-deny ingress policy the same fetch was blocked within seconds. Gotcha worth recording: **kube-router REJECTs (connection refused) rather than DROPs (timeout)** — a naive "refused vs timeout" reading of a netpol test will mislead you; prove it with a baseline-then-deny pair on a real listener, not a bare port probe.

4. **Longhorn gate = 2/2, not 3/3** (per PNEUMA DELTAS): `ousia` (like `pneuma` before it) is deliberately not a Longhorn node. Live: aether-worker + nahida-worker both Ready/schedulable, `defaultClassReplicaCount: 2` in both the SC and `longhorn-app.yaml`. New PVCs (MinIO) will be replica-2. Gate open.

5. **Resource headroom** (`kubectl top nodes` baseline 2026-08-14): aether 4% CPU / **62% mem**, nahida 8% CPU / **84% mem (tight — watch when adding workloads)**, ousia 0%/5% (30G now, but GPU-tainted — general workloads won't land there). Control-plane VM `.201` headroom NOT yet re-checked (deltas flagged it at 5G/4c after past apiserver starvation) — **must check before Phase 13 (Kyverno's 3 controllers)**.

6. **Version pins**: re-verified against live sources via a parallel verification pass (helm v4.2.4 + repo indexes + upstream docs); results recorded in `versions.lock.md` (Phase 1 deliverable).

### Drift discovered vs. the plan (things the plan doesn't know)

- **Phase 1 is already done, differently** (PNEUMA DELTAS): KPS was freshly installed at **87.5.1** GitOps-managed (`monitoring.yaml` → `apps/monitoring/`), superseding the planned 61.3.2→86.x upgrade; loki-stack no longer exists (archived, never adopted) → **P9/P10 are greenfield, no parallel-run/retirement; P11 shrinks to datasource rewiring + dashboards**. `nfs-driver-app.yaml` also already in GitOps. What remains of P1: `versions.lock.md` only.
- **Three orphaned, dead ingresses** in `default`: `filestash-ingress` (files.local), `overseerr-ingress` (overseerr.local), `pihole-ingress` (pihole.local → a `pihole-dns` Service that doesn't exist). All three carry tracking-ids of ArgoCD Applications that were deleted (non-cascading) — the live app list has no filestash/overseerr/pihole. filestash-service and overseerr Services exist with **zero endpoints**. All three 503 via nginx today (verified). **Excluded from the P6 HTTPRoute migration** — dead config doesn't get ported. Flagged for owner-approved cleanup.
- **subgen / whisper-jellyfin**: both scaled 0/0 (retiring per furina-cutover-checklist). Their floating `:latest` tags remain in manifests — P13 scope note.
- **P6 cutover list grew** vs. the plan's table: + `litellm` (llm.local/.lan), + `open-webui` (ai.local/.lan — the plan knew it as "ai.local" only), + `homelable` (homelable.local/.lan, new app 2026-08-14), + `.lan` twins on argo/glance/komga/prowlarr/qbit/radarr/seerr/sonarr/suwayomi that the plan's table listed as ".local (+ .lan)" guesses — live Ingress rules are the source of truth used.

### DNS / reachability baseline (owner requirement)

- **Pi-hole runs OUTSIDE the cluster** at `192.168.1.102` (confirmed via resolvectl on the desktop; the in-cluster pihole ingress is dead cruft, above). **Nothing in this migration can affect LAN name resolution itself** — only what answers on `.50`.
- All `*.lan` names resolve to `192.168.1.50` and answer (200/302/307 per app — redirects are login pages). Exceptions (pre-existing, not regressions): `llm.lan` and `suwayomi.lan` are not in Pi-hole DNS (their `.local` twins and direct LB IPs carry the traffic today).
- `*.local` names: not resolvable from Linux boxes (systemd-resolved sends `.local` to mDNS by design) — they work from the owner's Mac. Verified resolver-independently via `curl --resolve <host>:443:192.168.1.50`: **every live app answers correctly by Host header**, so `.local`/`.lan` parity holds at the HTTP layer regardless of client resolver.
- Bare-IP catch-all `https://192.168.1.50/` → Jellyfin redirect (302) — the mobile-app path the P6 hostless HTTPRoute must preserve.
- Full table: captured 2026-08-14 pre-migration (Phase 0 scratch, re-run at P6/P7 gates for comparison).

---
## Phase 1 — versions.lock.md (COMPLETE 2026-08-14; adoption already done)

The plan's adoption work was already done differently (see Phase 0 drift notes): KPS
87.5.1 fresh-installed under GitOps 2026-07-02, loki-stack archived (never adopted),
nfs-driver already GitOps-managed. Remaining deliverable was `versions.lock.md` —
created at repo root from the 12-way live verification pass. Highlights vs. the plan's
2026-06-16 guesses:

- **Gateway API pinned v1.5.1** (not latest v1.6.1) — Envoy Gateway v1.8's compat
  matrix pairs with v1.5.1; matrix-matched beats newest.
- **Envoy Gateway v1.8.3** — but the plan's CRD-skip value keys were in the WRONG
  chart: `gateway-helm` only has a single `crds.enabled` bool; the per-group keys
  live in the separate `gateway-crds-helm` chart (both default false — the plan's
  values as written would have installed zero Envoy CRDs and crashlooped). Corrected
  recipe verified by local render.
- **cert-manager: stepwise to v1.21.1** (7 minors; plan thought 1.20.x was latest).
  Upstream policy confirmed: no minor-skipping.
- **MinIO chart repo moved**: charts.min.io (live, still serves 5.4.0); helm.min.io
  now serves only AIStor charts. Vendoring turned out unnecessary. Replicas bug
  #21480 did not reproduce under helm4 (renders 1 correctly) — both keys still set.
- **Loki 17.4.11** (grafana-community; grafana.github.io's `loki` is now Enterprise
  Logs lineage — a pin from there would deploy the wrong product). Several required
  keys the plan lacked: `write/read/backend.replicas: 0` (chart validation fails
  otherwise), `bucketNames.{chunks,ruler}` required, compactor retention under
  `loki.compactor.*` not top-level, and the default chart ships ~9GB of memcached
  (chunksCache+resultsCache) that must be disabled for this cluster.
- **Trivy Operator: the plan's OCI source is abandoned upstream** (stale at 0.32.1)
  — pinned 0.35.0 from the HTTP repo instead.
- **Velero plugin v1.14.2** — the chart's own example tag (v1.13.1) is incompatible
  with its bundled Velero 1.18; compat table checked.
- **ntfy `?template=alertmanager` verified functionally against live ntfy.sh** (a
  test POST rendered the Alertmanager template) + AM v0.33.0 `url_file` support
  confirmed → the P12 secret-URL pattern is sound.

## Phase 2 — SOPS/age, out-of-band variant (COMPLETE 2026-08-14)

Per the Phase 0 decision (ArgoCD unmanaged → no repo-server patch), executed the
plan's sanctioned fallback, upgraded to keep ciphertext in Git: age keypair generated
(private key at `~/.config/sops/age/keys.txt` on the admin box — **owner: back this
up**), public recipient in `.sops.yaml`, `sops-age` Secret created out-of-band in
`argocd` ns so a future KSOPS adoption needs no re-key. Encrypt→commit→`sops -d |
kubectl apply` workflow documented in `Documentation/teyvat-sops.md`. Roundtrip
validated (stringData ciphered, metadata diffable, decrypt clean). SOPS files will
live under `kubernetes/secrets/` — a path no ArgoCD Application renders, so prune
can never eat them and ArgoCD never sees ciphertext.

