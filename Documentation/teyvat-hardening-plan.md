Confirmed key facts: Loki grafana-community chart 17.4.4 is the correct lineage and supports `deploymentMode: Monolithic` (renamed at chart 12.0.0). The critique's "re-pin to 6.x" is factually wrong — the DRAFT pin was right, only the appVersion needs verifying-at-apply. Tempo chart 1.24.4 / appVersion 2.9, port 3200 confirmed. Both chart families have moved to grafana-community repos. I have enough verified ground truth. Let me also confirm the image-tag audit conclusion before finalizing.

The repo audit is decisive:
- **`:latest`/floating tags: only 6 across 5 apps** — `ollama:latest` (x2), `open-webui:main`, `subgen:latest`, `whisper-jellyfin:latest`, `alpine/git:latest` (obsidian-sync cronjob). Everything else is pinned. The DRAFT's "all of default is :latest" is wrong; the critique is right.
- **`resources:` appears in many files but mostly in `*-storage.yaml`** (PVC resource requests, not container limits). Container-level limits/probes are sparse — probes only in open-webui, ollama, flaresolverr. So the real Kyverno Enforce blocker is limits/probes, as the critique says.

I have verified the two disqualifying claims and the contested facts. Producing the final plan now.

# Operation Teyvat Hardening — Master Implementation Plan (FINAL)

> Status: AWAITING OWNER REVIEW of this doc, then execution begins at Phase 0 (read-only). Owner decisions LOCKED 2026-06-16: §12 #9 → **ntfy.sh hosted**; §12 #14 → **Option B (manifest-only Velero)**; §12 #12 → **Audit → soak → Enforce app namespaces** (pin 5 floating images + add limits/probes first). Remaining §12 items keep their stated defaults; #4/#11 resolved live in Phase 0.
> Authored: 2026-06-16. Cluster: Teyvat, k0s v1.35.2, 4 nodes (.201 controller; .211/.212/.213 workers). GitOps via ArgoCD app-of-apps (`infrastructure` root → `kubernetes/infrastructure/`). Deploy model: commit to `main`, ArgoCD auto-syncs (prune + self-heal). Repo root: `/Users/ccampbell/dev/homelab-devops`.
>
> **Hard constraints (non-negotiable):** no new VMs/cluster; do NOT touch k0s control plane / k0sctl / node config; do NOT replace MetalLB (L2, pool `192.168.1.50-.55`, ingress `.50` wired into Pi-hole DNS); do NOT change/reinstall the CNI; ArgoCD GitOps only (no manual `kubectl apply` beyond bootstrap + the documented out-of-band secret exceptions); existing apps stay up (Ingress→HTTPRoute cutover keeps old Ingress until verified); no plaintext secrets in Git (new ones SOPS-encrypted); pin every Helm chart + image and record in `versions.lock.md`.

---

## 0. Executive Summary

Modernize the running Teyvat cluster across five tracks without rebuilding it: (1) replace retired Ingress NGINX with **Gateway API + Envoy Gateway** on the same MetalLB IP `.50`; (2) re-platform observability onto **MinIO + standalone Loki (S3) + Tempo (S3) + Grafana Alloy** and bump kube-prometheus-stack; (3) add **Kyverno + Trivy Operator + per-namespace NetworkPolicies + SOPS/age**; (4) add **PrometheusRules + Alertmanager → ntfy**; (5) add **Velero** namespace DR (stretch).

Guiding principle: **strangler-fig migration** — every legacy component stays serving until its replacement is verified, then the legacy is removed in a separate, revertible commit. Highest-risk cutover is Ingress NGINX → Gateway because it owns LB IP `.50`. We run both controllers on two IPs and move `.50` last, in two commits with a release gate between them.

A new ArgoCD **sync-wave convention** orders CRDs → controllers → cluster-scoped resources → routes/policies (repo currently only uses waves 0/1 for cert-manager).

### Corrections folded in from review (read before executing)

- **Loki pin is CONFIRMED CORRECT (not 6.x).** The grafana-community `loki` chart **17.4.4** is the modern lineage and DOES support `deploymentMode: Monolithic` (the `SingleBinary`→`Monolithic` rename landed at community chart **12.0.0**; 17.x is past that). Verified via artifacthub grafana-community/loki and Grafana docs. The critique's "re-pin to 6.x" was itself mistaken — keep 17.4.x. The only open item is the exact **appVersion (grafana/loki image)** for the pinned 17.4.x, which is **VERIFY at execution** via `helm show chart`.
- **The "all `:latest`" premise is FALSE — corrected.** Repo audit: only **6 floating tags across 5 apps** — `ollama/ollama:latest` (×2), `ghcr.io/open-webui/open-webui:main`, `mccloud/subgen:latest`, `starrider315/whisper-jellyfin:latest`, plus `alpine/git:latest` in the `obsidian-sync` CronJob. Everything else is pinned (jellyfin 10.11.8, qbittorrent 5.1.4-r2-ls446, gluetun v3.41.0, sonarr/radarr/prowlarr ls-pinned, suwayomi v2.2.2100, komga 1.24.4, glance v0.8.4, flaresolverr v3.3.21, jellyseerr 2.7.3). The real Kyverno Enforce blocker is **missing resource limits / probes** (container probes exist only in open-webui, ollama, flaresolverr; most apps have no container-level limits), NOT `:latest`. Kyverno scoping (Phase 13) is re-framed accordingly.
- **Grafana AND Prometheus BOTH have nginx Ingresses in repo** (`stack.yaml`: `grafana.ingress.enabled:true` → `grafana.local`; `prometheus.ingress.enabled:true` → `prometheus.local`). The DRAFT's "Grafana has no Ingress" was wrong. Both are **cutovers** (route first, then disable chart Ingress), and `prometheus.local` is added to the cutover list (§Phase 6).
- **Ingress NGINX pins `.50` via `controller.service.loadBalancerIP`** (confirmed `kubernetes/infrastructure/ingress-nginx.yaml:17`), NOT the `metallb.io/loadBalancerIPs` annotation. The `.50` flip (Phase 7) is therefore split into **two commits with a release-verified gate** to avoid a duplicate-IP race leaving Envoy `<pending>`.
- **MetalLB pool spans `.50-.55`** (confirmed `metallb-config.yaml:8`). Current claims: `.50` ingress-nginx, `.52` suwayomi (stray on both Service AND Ingress), `.53` seerr, `.54` komga. **`.51` and `.55` appear free** — VERIFY live before Phase 5.
- **ArgoCD install method is a PHASE-0 BLOCKER** for the entire SOPS track (Open Decision #11 promoted), with a documented out-of-band fallback.

---

## 1. Dependency Graph & Ordering Rationale

```
PRE  Phase 0  BLOCKING PRE-REQS (resolve before any commit):
              - Determine how ArgoCD is installed (Helm/manifests/kustomize) -> dictates KSOPS wiring
              - Verify MetalLB pool .50-.55 live + which IPs free (.51/.55 expected)
              - Verify kube-router NetworkPolicy enforcement actually drops traffic (test ns)
              - Confirm all 3 workers Ready (Longhorn replica=node-count gate for new PVCs)
              - Re-verify EVERY version pin via `helm show chart/values` (the Loki/Tempo gate)
                         │
     Phase 1  Adopt orphaned apps into GitOps + create versions.lock.md
              (kube-prometheus-stack, loki-stack, nfs-csi-driver) — no functional change
                         │
SEC  Phase 2  SOPS/age + KSOPS in ArgoCD repo-server (root of trust)
        │     (needed before any new Secret: MinIO/ntfy/Velero/S3 creds)
        ▼
NET  Phase 3  Gateway API standard CRDs v1.5.x (wave -5, SSA)
        ▼
     Phase 4  Envoy Gateway controller + GatewayClass (wave -4/-3, value-based CRD skip)
        ▼
     Phase 5  cert-manager bump (CRD-first, stepwise) + enableGatewayAPI
        │     + shared Gateway on TEMP IP .51 + listener Certificate (wave -1)
        ▼
     Phase 6  Per-app HTTPRoute cutover (Grafana→Jellyfin→ArgoCD→rest; +prometheus.local)
        ▼     (legacy Ingress stays up the whole time; routes in app namespaces)
     Phase 7  TWO-COMMIT flip to .50 + retire Ingress NGINX (release gate between)
                                                                      │
OBS  Phase 8  MinIO single-node (buckets loki/tempo/velero) ──────────┘ (needs SOPS)
        ▼            (MinIO + buckets BEFORE Loki/Tempo/Velero S3 writes)
     Phase 9  Loki Monolithic(S3) + Tempo(S3) in ns `observability` ALONGSIDE loki-stack
        ▼
     Phase 10 Grafana Alloy DaemonSet (logs + OTLP traces; metrics stay with KPS)
        ▼
     Phase 11 Bump KPS 61.3.2 -> 86.x (CRD-first), rewire datasources, retire loki-stack
              │
ALR  Phase 12 PrometheusRules + Alertmanager -> ntfy (needs SOPS token, KPS bumped)
              │
SEC  Phase 13 Kyverno (Audit) -> soak -> per-ns Enforce (blocker = limits/probes, not :latest)
        ▼
     Phase 14 Trivy Operator
        ▼
     Phase 15 NetworkPolicies (default-deny + DNS/Longhorn/NFS/gateway/scrape allows) — LAST
DR   Phase 16 Velero (stretch) — needs MinIO (P8) + SOPS (P2); CSI mode needs external-snapshotter
```

**Hard ordering constraints (the "why X precedes Y"):**

| Constraint | Reason |
|---|---|
| ArgoCD install method known (P0) before SOPS (P2) | Cannot author the repo-server KSOPS patch without knowing the install topology; fallback is out-of-band secrets. |
| SOPS/KSOPS (P2) before any new Secret | MinIO/ntfy/Velero/S3 creds must be SOPS-encrypted in Git; the decryptor must exist or ArgoCD renders ciphertext. |
| Gateway API CRDs (P3) before Envoy Gateway (P4) | We own standard CRDs so the chart installs without pulling experimental CRDs; CRDs must pre-exist. |
| Envoy Gateway + GatewayClass (P4) before Gateway (P5) | `Gateway.spec.gatewayClassName` must resolve to an Accepted GatewayClass. |
| cert-manager v1.20 CRDs + `enableGatewayAPI` (P5) before any HTTPRoute TLS | cert-manager only mints listener certs with the flag on and CRDs present; CRD bump is CRD-first/stepwise. |
| HTTPRoutes verified (P6) before retiring Ingress (P7) | Strangler-fig: never remove the serving path until the replacement is proven. |
| `.50` released by Ingress NGINX (P7 commit 1) before Envoy claims it (P7 commit 2) | MetalLB refuses duplicate IP; one-commit flip races to `<pending>`. |
| MinIO + buckets (P8) before Loki/Tempo/Velero S3 (P9/P16) | All write to pre-created buckets; missing bucket = silent failure/crashloop. |
| New Loki/Tempo serving (P9) + Alloy shipping (P10) before retiring loki-stack (P11) | Parallel-run; don't delete Promtail/loki-stack until Alloy logs confirmed in new Loki. |
| KPS bump (P11) before Alertmanager ntfy (P12) | Receiver + PrometheusRules go into new KPS values; operator CRDs must be bumped first. |
| Kyverno Audit soak (P13) before Enforce | Audit-first prevents blocking running workloads (missing limits/probes on most apps). |
| NetworkPolicies (P15) LAST | Default-deny breaks DNS/storage/scrape/VPN if any allow is missing; apply only after every comms path is enumerated and the rest of the stack is stable. |
| external-snapshotter present (P16) before CSI-mode Velero | k0s does not ship `snapshot.storage.k8s.io` CRDs/controller; CSI restore needs them. |

---

## 2. New Sync-Wave Convention

Existing repo uses only `"0"` (cert-manager) and `"1"` (cert-manager-issuers). We extend with negative waves (all lower than `"0"`, so new infra lands before existing apps). Format unchanged: `argocd.argoproj.io/sync-wave: "<int>"` (quoted).

| Wave | Purpose |
|---|---|
| `"-5"` | CRDs everything depends on (Gateway API standard CRDs; cert-manager v1.20 CRDs; KPS operator CRDs; Kyverno CRDs). |
| `"-4"` | Cluster controllers that own those CRDs/RBAC (Envoy Gateway, Kyverno). |
| `"-3"` | GatewayClass; cert-manager controller (existing `"0"` — see note). |
| `"-2"` | cert-manager CA chain + ClusterIssuers (existing `"1"`). |
| `"-1"` | Shared Gateway + listener Certificate. |
| `"0"` | Default apps (current behavior). |
| `"1"+` | HTTPRoutes, NetworkPolicies (applied last within an app group). |

> NOTE: Do **not** renumber the existing cert-manager waves (`"0"`/`"1"`) — changing them risks a re-sync ripple. New infra uses negative waves.

---

## 3. Target Repo Layout (new dirs/files)

```
versions.lock.md                                  # P1 (NEW, repo root)
.sops.yaml                                        # P2 (NEW, repo root)

kubernetes/infrastructure/
  gateway-api-crds.yaml                           # P3 (Application, wave -5, vendored standard-install)
  envoy-gateway.yaml                              # P4 (Application, wave -4)
  minio.yaml                                      # P8 (Application; chart vendored/mirrored)
  loki-s3.yaml                                    # P9 (Application; ns observability)
  tempo.yaml                                      # P9 (Application; ns observability)
  alloy.yaml                                      # P10 (Application; ns observability)
  kyverno.yaml                                    # P13 (Application, wave -4)
  kyverno-policies.yaml                           # P13 (Application; hand-written ClusterPolicies)
  trivy-operator.yaml                             # P14 (Application)
  external-snapshotter.yaml                       # P16 (Application; only if CSI mode chosen)
  velero.yaml                                     # P16 (Application)
  monitoring-stack.yaml                           # P1 (adopt live KPS @ 61.3.2)
  monitoring-loki-stack-LEGACY.yaml               # P1 (adopt live loki-stack @ 2.10.2; deleted P11)

kubernetes/apps/
  gateway/
    gatewayclass.yaml                             # GatewayClass envoy-gateway (wave -3)
    envoyproxy.yaml                               # EnvoyProxy infra (MetalLB IP pin; .51 then .50)
    shared-gateway.yaml                           # Gateway "teyvat-gateway" (wave -1)
    gateway-certificate.yaml                      # cert-manager Certificate (*.local + *.lan)
    referencegrants/                              # ONLY if any route lands cross-namespace (see decision)
  cert-manager/
    local-ca.yaml                                 # EXISTING (kept; reuse homelab-local-ca)
  <each app>/httproute.yaml                       # P6 — HTTPRoute IN THE APP'S OWN NAMESPACE
  minio/
    minio-root-creds.sops.yaml                    # P8 (SOPS)
  observability/
    minio-s3-loki.sops.yaml  minio-s3-tempo.sops.yaml   # P9 (SOPS)
    alloy-config.yaml                             # P10 external ConfigMap
  security/
    sops-age-secret.NOTE.md                       # doc only; Secret created out-of-band
    networkpolicies/                              # P15 (per-namespace files)
  velero/
    velero-s3-creds.sops.yaml  schedule.yaml  volumesnapshotclass.yaml   # P16
  monitoring/
    stack.yaml (EXISTING; bumped P11)
    loki.yaml  (EXISTING loki-stack; DELETED P11)
    dashboard-*.yaml (existing 5) + new dashboards (P11/P14)
```

> **HTTPRoute placement decision (reconciles DRAFT §3 vs Phase 6 contradiction):** HTTPRoutes live **in each app's own namespace**, with `parentRefs` pointing across to the shared Gateway (allowed by Gateway `allowedRoutes.namespaces.from: All`). Same-namespace `backendRef` needs **no ReferenceGrant**. ReferenceGrants are added under `apps/gateway/referencegrants/` ONLY if a specific route must reference a Service in another namespace.

---

## 4. Consolidated `versions.lock.md` (deliverable, created P1)

**Every number below is dated 2026-06-16 and MUST be re-verified at apply time** via `helm show chart <repo>/<chart> --version <X>` + `helm show values`. Items marked **VERIFY** are explicitly not confidently pinned — check the live source, do not invent a substitute.

| Component | Chart | Chart version | Image / appVersion | Source |
|---|---|---|---|---|
| **Retire** | | | | |
| Ingress NGINX | `ingress-nginx` | 4.10.1 (retired upstream Mar 2026) | — | kubernetes.github.io/ingress-nginx |
| loki-stack | `loki-stack` | 2.10.2 (deprecated; Promtail EOL Mar 2026) | — | grafana.github.io/helm-charts |
| **Bump** | | | | |
| cert-manager | `cert-manager` | **v1.20.x** (from v1.14.5) — **VERIFY latest patch + supported upgrade path from 1.14** | appVersion = chart | `oci://quay.io/jetstack/charts/cert-manager` (alt charts.jetstack.io) |
| kube-prometheus-stack | `kube-prometheus-stack` | **86.x** (from 61.3.2) — **VERIFY latest 86.x patch** | operator ~v0.91.x, grafana ~v13, node-exporter, kube-state-metrics (all bundled — VERIFY) | prometheus-community.github.io/helm-charts |
| **Verify, NOT bumped here** | | | | |
| Longhorn | `longhorn` | currently ~1.7.2 — **out of scope; do not bump without owner approval** | — | charts.longhorn.io |
| csi-driver-nfs | `csi-driver-nfs` | currently ~v4.9.0 — **out of scope** | — | kubernetes-csi/csi-driver-nfs |
| MetalLB | (raw) | **DO NOT TOUCH — hard constraint** | — | metallb/metallb |
| **New — Gateway** | | | | |
| Gateway API CRDs | (raw, standard channel) | **v1.5.x** — **VERIFY latest non-rc (v1.5.1/.2); do NOT use v1.6.0-rc** | — | github.com/kubernetes-sigs/gateway-api `…/standard-install.yaml` (VENDOR into repo) |
| Envoy Gateway | `gateway-helm` | **v1.8.x** — **VERIFY latest patch + k8s 1.35 support matrix** | envoyproxy distroless ~v1.38.x (pin via EnvoyProxy) | `oci://docker.io/envoyproxy/gateway-helm` |
| **New — Observability** | | | | |
| MinIO | `minio` (community) | **5.4.0** (frozen/EOL — pin hard) — **VERIFY rendered StatefulSet replicas:1 (chart bug #21480 renders 16)** | `quay.io/minio/minio:RELEASE.<VERIFY>` ; mc init `quay.io/minio/mc:<VERIFY from 5.4.0 values>` | **VENDOR or controlled OCI mirror** (helm.min.io now serves paid AIStor; community repo archived) |
| Loki | `loki` (grafana-community) | **17.4.x** (CONFIRMED lineage; supports `deploymentMode: Monolithic`) — **VERIFY exact patch + appVersion via `helm show`** | grafana/loki appVersion **VERIFY** | grafana-community/helm-charts (`oci://ghcr.io/grafana-community/helm-charts/loki` — VERIFY OCI path) |
| Tempo | `tempo` (single-binary) | **1.24.x** — **VERIFY patch + appVersion (~grafana/tempo 2.9.x) + HTTP port** | HTTP/query port **3200** (changed from 3100 — derive from pinned chart, don't assert) | grafana-community/helm-charts (VERIFY repo post-migration) |
| Grafana Alloy | `alloy` | **1.x** — **VERIFY latest patch + appVersion (grafana/alloy)** | grafana/alloy **VERIFY** | grafana.github.io/helm-charts (VERIFY post-migration repo) |
| **New — Security** | | | | |
| SOPS | (binary) | **VERIFY latest v3.x** | — | github.com/getsops/sops |
| age | (binary) | **VERIFY latest v1.x** | — | github.com/FiloSottile/age |
| KSOPS | (ArgoCD initContainer image) | **VERIFY latest v4.x** | `viaductoss/ksops:<VERIFY>` | github.com/viaduct-ai/kustomize-sops |
| Kyverno | `kyverno` | **3.8.x** — **VERIFY final (non-rc) + k8s 1.35 support** | app ~v1.18.x | kyverno.github.io/kyverno |
| Kyverno policies | (hand-written ClusterPolicies — recommended; no chart dep) | n/a | n/a | this repo |
| Trivy Operator | `trivy-operator` | **0.33.x** — **VERIFY latest patch** | app ~0.31.x | `oci://ghcr.io/aquasecurity/helm-charts/trivy-operator` |
| **New — DR** | | | | |
| external-snapshotter | (raw CRDs+controller) | **VERIFY latest; only if CSI mode** | — | kubernetes-csi/external-snapshotter |
| Velero | `velero` | **VERIFY latest 12.x** | `velero/velero:<VERIFY>` | vmware-tanzu.github.io/helm-charts |
| velero-plugin-for-aws | (initContainer) | — | `velero/velero-plugin-for-aws:<VERIFY — documented compat ceiling ~v1.13.x→Velero 1.17.x; CONFIRM against chosen chart/Velero before pinning>` | vmware-tanzu/velero |

**Self-pinned (no chart):** cert-manager `ClusterIssuer homelab-local-ca` (existing, reused for all Gateway certs).

---

## 5. Deliverables → Phase Map

| Deliverable | Produced in | Form |
|---|---|---|
| `versions.lock.md` | **P1**, updated every phase | repo-root table (§4) |
| Ingress→HTTPRoute migration log | **P6/P7** | `Documentation/teyvat-hardening-migration-log.md` (per-app: route applied → verified → Ingress removed) |
| **3 Grafana dashboards** + screenshot checklist | **P11** (gateway, observability-pipeline) + **after P14** (security-posture, needs Kyverno/Trivy data) | ConfigMaps in `apps/monitoring/` + checklist (§Phase 11). Trivy import (17813) is the operator's own dashboard, counted SEPARATELY (not one of the 3). |
| Resilience report (CrashLoop alert proof + Velero drill) | **P12** + **P16** | `Documentation/teyvat-resilience-report.md` |
| SOPS doc | **P2** | `Documentation/teyvat-sops.md` |
| Trivy/Kyverno policy-report evidence | **P13/P14** | PolicyReport + Trivy dashboard screenshots into resilience/security report |

---

## PHASE 0 — Blocking pre-requisites (no commits until all pass)

These were latent assumptions in the DRAFT; they are now explicit gates.

1. **ArgoCD install method** — inspect the live install (`kubectl -n argocd get deploy argocd-repo-server -o yaml`, check `helm list -A`, look for a kustomization). Record whether it is Helm-managed, manifest/kustomize, or installed out-of-repo. This dictates HOW Phase 2 patches the repo-server. **Fallback (documented):** if the repo-server cannot be cleanly patched, the few new secrets (MinIO/ntfy/Velero/S3) are created **out-of-band via `kubectl`**, consistent with the existing `protonvpn-secret` pattern — explicitly noting this bends "no manual kubectl beyond bootstrap." SOPS-in-Git remains the goal; this is the escape hatch.
2. **MetalLB pool/free IPs** — `kubectl get ipaddresspool -n metallb-system -o yaml` (confirm `.50-.55`), `kubectl get svc -A | grep 192.168.1.5`. Confirm staging IP **`.51` is unclaimed** (current claims: `.50` ingress-nginx, `.52` suwayomi, `.53` seerr, `.54` komga; `.51`/`.55` expected free). If `.51` is taken, pick another free pool IP for staging.
3. **kube-router NetworkPolicy enforcement** — apply a deny-all in a throwaway namespace and confirm traffic is actually dropped. If the NP controller is disabled, default-deny is a silent no-op (dangerous — you'd think you're protected and aren't). Record the result; it gates Phase 15.
4. **All 3 workers Ready** — `kubectl get nodes`. New PVCs (MinIO/Loki/Tempo) inherit Longhorn `defaultClassReplicaCount: 3`; a worker down during P8/P9 rollout = permanently degraded volumes (user memory). Gate P8/P9 on 3/3 Ready.
5. **Resource headroom budget** — `kubectl top nodes` baseline. Net-new always-on workloads: Envoy GW, MinIO, Loki, Tempo, Alloy ×3, Kyverno (3 controllers), Trivy Operator + scan jobs, Velero. This cluster has a documented CPU-spike outage history (sonarr ffprobe loop). Record headroom; gate Trivy scan scheduling and Loki/Tempo compaction load (P9/P14) on it.
6. **Re-verify EVERY version pin** — run `helm show chart`/`helm show values` for every chart in §4. The Loki/Tempo schema in particular must be validated against the actually-pinned chart (the DRAFT's Loki 17.4.x is confirmed correct lineage, but appVersion + exact values keys must be read from `helm show`, not memory).

---

## PHASE 1 — Adopt orphaned apps into GitOps + create `versions.lock.md`

**Goal:** Bring `kube-prometheus-stack`, `loki-stack`, and `nfs-csi-driver` under the `infrastructure` root app so later edits are GitOps-reconciled. **Zero functional change.**

**Files:**
- `kubernetes/infrastructure/monitoring-stack.yaml` + `monitoring-loki-stack-LEGACY.yaml` — thin ArgoCD Applications pinned to the **live** chart versions (KPS 61.3.2, loki-stack 2.10.2) and matching live values exactly, so first sync is a **no-op adoption**.
- `versions.lock.md` — populated from §4.

**Dashboard-prune hazard (resolved):** the live `monitoring` ns has **5 dashboard ConfigMaps + a logs dashboard** that are themselves orphaned. With `prune: true`, an adopting Application that renders only the chart will **DELETE** those ConfigMaps. **Mitigation steps:**
1. Map current ownership: `kubectl get cm -n monitoring -l grafana_dashboard -o yaml` — check `ownerReferences`/`managed-by` and how they are applied today (raw manifests vs sidecar-provisioned).
2. Ensure the adoption render **includes every live ConfigMap** (point the adopting app at the existing directory containing them, or add them to the rendered set).
3. `helm template` the pinned chart + `kubectl diff`/manual diff vs live BEFORE the first commit.
4. **Acceptance check:** "all 5 existing dashboards survive adoption" (count ConfigMaps before/after).

**Steps:** snapshot live state (`kubectl get applications -A -o yaml`, `helm list -A`, `kubectl get all,cm -n monitoring`) → author adopting Applications matching live → commit → confirm Synced/Healthy with **no resource changes / no pod restarts** → commit `versions.lock.md`.

**Acceptance:** new Applications Synced/Healthy; `monitoring` pods unchanged (same ages); all 5 dashboards present.

**Rollback / blast radius:** LOW (adoption only). **Gotcha:** with `prune:true`, anything not in the rendered manifest is deleted — diff before commit.

---

## PHASE 2 — SOPS/age + KSOPS in ArgoCD repo-server

**Goal:** Encrypted-secrets-in-Git so all later new Secrets ship SOPS-encrypted. Root of trust = age key (the only thing NOT in Git). **Prerequisite: Phase 0 #1 resolved.**

**Versions:** SOPS, age, KSOPS image — all **VERIFY latest** (§4).

**Files:**
- `.sops.yaml` (repo root): `creation_rules` matching `.*\.sops\.ya?ml$`, `encrypted_regex: '^(data|stringData)$'`, `age:` = the PUBLIC recipient.
- ArgoCD repo-server wiring (form depends on Phase 0 #1): KSOPS init container, `sops-age` Secret mounted at `/home/argocd/.config/sops/age`, env `SOPS_AGE_KEY_FILE` + `XDG_CONFIG_HOME`; `argocd-cm` `kustomize.buildOptions: "--enable-alpha-plugins --enable-exec"`. Implies SOPS-bearing apps are wrapped in Kustomize.
- `Documentation/teyvat-sops.md` (deliverable): keygen, `.sops.yaml`, repo-server wiring, key rotation.

**Steps:** `age-keygen -o keys.txt` → record public recipient in `.sops.yaml` → create `sops-age` Secret **out-of-band** (`kubectl create secret generic sops-age -n argocd --from-file=keys.txt`) → commit `.sops.yaml` + wiring → validate with a throwaway `test.sops.yaml` (`argocd app manifests <test>` shows plaintext, live Secret value is decrypted, ciphertext never live) → remove throwaway.

**Acceptance:** encrypted dummy Secret renders decrypted and applies; `git grep` finds no plaintext `stringData` in `*.sops.yaml`.

**Rollback / blast radius:** **MEDIUM** — a broken repo-server patch stops ALL ArgoCD rendering. Keep the patch small, watch repo-server come back Healthy, be ready to revert the Deployment. **If Phase 0 #1 says the install can't be patched cleanly, take the out-of-band fallback instead and document it.**

---

## PHASE 3 — Gateway API standard CRDs (wave -5)

**Goal:** Install standard-channel Gateway API CRDs, pinned and owned by us (so Envoy Gateway installs without pulling experimental CRDs).

**Version:** Gateway API **v1.5.x standard channel** (VERIFY latest non-rc; NOT v1.6.0-rc).

**File:** `kubernetes/infrastructure/gateway-api-crds.yaml` — ArgoCD Application pointing at a **vendored** copy of `standard-install.yaml` committed into the repo (most reproducible; immune to GitHub asset availability). Annotations `sync-wave: "-5"`. syncOptions: **`ServerSideApply=true`** (CRDs are large — client-side apply hits the annotation-size limit), `SkipDryRunOnMissingResource=true`.

**Steps:** download + verify (HTTP 200) the pinned `standard-install.yaml` → commit under repo → add Application → watch CRDs register.

**Acceptance:** `kubectl get crd gateways/httproutes/gatewayclasses/referencegrants.gateway.networking.k8s.io` all Established; `kubectl explain httproute` works.

**Rollback / blast radius:** LOW (additive; nothing consumes them yet). Do NOT prune CRDs if any CR exists.

---

## PHASE 4 — Envoy Gateway controller + GatewayClass (wave -4 / -3)

**Goal:** Install Envoy Gateway control plane and a GatewayClass. No Gateway/route yet. Ingress NGINX still serves `.50`.

**Versions:** `gateway-helm` **v1.8.x** (VERIFY k8s 1.35 in support matrix). Proxy image pinned via `EnvoyProxy`.

**CRD-skip mechanism (RESOLVED):** Do **NOT** use ArgoCD `Helm.skipCrds: true` — it skips ALL chart CRDs **including Envoy's own** (`EnvoyProxy`/`EnvoyPatchPolicy`), crashlooping the controller. Instead use **value keys**: `crds.gatewayAPI.enabled: false` (skip the Gateway API CRDs we own at v1.5.x) and `crds.envoyGateway.enabled: true` (keep Envoy's own CRDs). **VERIFY exact key names** against `helm show values gateway-helm --version v1.8.x` before committing.

**Files:**
- `kubernetes/infrastructure/envoy-gateway.yaml` — Helm Application, `oci://docker.io/envoyproxy/gateway-helm`, ns `envoy-gateway-system`, `CreateNamespace=true`, wave `"-4"`, `ServerSideApply=true`, the CRD value keys above.
- `kubernetes/apps/gateway/gatewayclass.yaml` — `GatewayClass envoy-gateway` (controllerName `gateway.envoyproxy.io/gatewayclass-controller`), wave `"-3"`.
- `kubernetes/apps/gateway/envoyproxy.yaml` — `EnvoyProxy` pinning the proxy image AND the proxy Service's MetalLB IP. **Phase 4 assigns the TEMP staging IP `.51`** (NOT `.50` — Ingress NGINX still owns it).

**Steps:** commit EG Application → controller Deployment Ready → commit GatewayClass + EnvoyProxy → `kubectl get gatewayclass envoy-gateway` → `Accepted=True`.

**Acceptance:** EG controller Running; GatewayClass `Accepted=True`; no Gateway/route yet; `.50` untouched.

**Rollback / blast radius:** LOW.

---

## PHASE 5 — cert-manager bump (CRD-first) + Gateway API enablement + shared Gateway (temp IP .51)

**Goal:** Bump cert-manager, enable Gateway API integration, stand up the shared Gateway on **temporary** `.51` with cert-manager TLS — testable without touching `.50`.

**Versions:** cert-manager **v1.20.x** (from v1.14.5; VERIFY latest patch). `config.enableGatewayAPI: true`, `crds.enabled: true` (modern key replacing `installCRDs`; VERIFY on 1.20.x). Gateway API is GA in 1.20.x — the old `ExperimentalGatewayAPISupport` feature gate is **REMOVED; do NOT add it**.

**Multi-minor upgrade handling (RESOLVED):** v1.14→v1.20 is a 6-minor jump.
1. **VERIFY the supported upgrade path** in cert-manager docs — if intermediate minors are required, **step through them** (e.g. 1.14→1.16→1.18→1.20), each as its own commit, watching pods Healthy.
2. **CRD-first:** the current cert-manager app lacks `ServerSideApply` and `crds.keep`. Apply the **v1.20 CRDs before the v1.20 controller** (CRD bump as a `"-5"`-wave step / `crds.enabled:true` with `crds.keep:true` so CRDs are never dropped), `ServerSideApply=true`. Confirm no CRD is removed.

**Gateway TLS mechanism (RESOLVED — pick ONE, do not do both):** Use **explicit `Certificate`** (drop the Gateway annotation) to avoid double-management with the gateway-shim. The `teyvat-gateway-tls` Secret **must live in the Gateway's namespace**.

**CA decision:** **reuse existing single-tier `homelab-local-ca`** (already trusted on devices via Pi-hole-distributed root) — avoids re-trusting a new root everywhere.

**Files:**
- `kubernetes/infrastructure/cert-manager.yaml` — bump `targetRevision` (stepwise), add `config.enableGatewayAPI: true`, `crds.enabled: true`, `crds.keep: true`, `ServerSideApply=true`. Keep wave `"0"`.
- `kubernetes/apps/gateway/gateway-certificate.yaml` — `Certificate` covering **both `*.local` and `*.lan`** SANs (matches existing dual-SAN pattern), `secretName: teyvat-gateway-tls` (in Gateway ns), `issuerRef: homelab-local-ca`.
- `kubernetes/apps/gateway/shared-gateway.yaml` — `Gateway teyvat-gateway` (recommend dedicated `gateway` ns, or `envoy-gateway-system`):
  - `gatewayClassName: envoy-gateway`; HTTP :80 listener + HTTPS :443 listeners `mode: Terminate`, `certificateRefs: [teyvat-gateway-tls]`.
  - **Listener hostnames must be non-empty** for cert-manager/TLS to bind — use explicit per-host or wildcard `*.local` / `*.lan` listeners (two). (cert-manager silently skips empty-hostname / non-Terminate / empty-certRef listeners.)
  - `allowedRoutes.namespaces.from: All` (apps live in `default`, `argocd`, `glance`, `ai-stack`, `monitoring`, `observability`).
  - EnvoyProxy/Service pinned to **`.51`** for now.
  - wave `"-1"`.

**Steps:** CRD-first bump (stepwise) → cert-manager pods roll to v1.20.x Healthy, **existing per-app certs still valid (no re-issue storm)** → confirm controller logs show no "gateway api is not enabled" → apply Gateway + Certificate → `teyvat-gateway-tls` populated → confirm Gateway `Programmed=True`/`Accepted=True`, Envoy Service EXTERNAL-IP `.51`.

**Acceptance:** cert-manager v1.20.x Healthy; existing certs intact; Gateway `Programmed=True`; `teyvat-gateway-tls` chains to `homelab-local-ca`; Envoy Service holds `.51`.

**Rollback / blast radius:** cert-manager is the riskiest (controls ALL TLS) → **MEDIUM-HIGH**. CA secrets persist (issuers survive). If the jump misbehaves, the stepwise intermediate minors are the recovery path. Gateway on `.51` is isolated (deleting it doesn't touch `.50`). Do cert-manager bump in its **own commit**, watch closely.

---

## PHASE 6 — Per-app Ingress → HTTPRoute cutover (legacy Ingress stays up)

**Goal:** One HTTPRoute per app on the shared Gateway, each verified via `.51`, while legacy Ingress on `.50` keeps serving. **No Ingress deleted in this phase.**

**Placement:** HTTPRoute **in the app's own namespace**, `parentRefs` → `teyvat-gateway` (cross-namespace parentRef allowed; same-namespace backendRef = no ReferenceGrant). Wave `"1"`.

**Ordering (required):** **Grafana → Jellyfin → ArgoCD UI → rest.** Grafana first (needed for observability verification; it IS a cutover — `grafana.ingress.enabled:true` exists today). Jellyfin second (highest-value + validates the hostless catch-all model early). ArgoCD third (don't lock yourself out — keep `argocd-ingress` until proven; keep `kubectl` access throughout). Then the rest.

**Per-app table (actual hosts/services/ports from repo):**

| Order | App | ns | Hosts | Backend svc:port | Notes |
|---|---|---|---|---|---|
| 1 | Grafana | monitoring | grafana.local (+ .lan) | `kube-prometheus-stack-grafana:80` | **Cutover** — disable `grafana.ingress` only AFTER route verified |
| 1b | Prometheus | monitoring | prometheus.local (+ .lan) | `…-prometheus:9090` | **Was missing from DRAFT.** Route it, OR consciously drop external exposure; disable `prometheus.ingress` in P7 |
| 2 | Jellyfin | default | jellyfin.lan/.local **+ hostless catch-all** | `jellyfin-service:80` | Catch-all HTTPRoute (no hostnames) so `https://192.168.1.50` and Host-less mobile clients hit Jellyfin. Verify it does NOT shadow host-matched routes (Gateway API matches specific hostnames first). VAAPI is pod-internal — unaffected |
| 3 | ArgoCD UI | argocd | argo.local/.lan | `argocd-server:80` | Keep `argocd-ingress` until verified. Old Ingress sets `force-ssl-redirect:"false"`; terminate TLS at Gateway, proxy HTTP→`argocd-server:80` (matches today) |
| 4 | Glance | glance | glance.local/.lan | `glance:80` | — |
| 5 | Komga | default | komga.local/.lan | `komga:80` | Service also has `.54` MetalLB LB IP — independent of routing; leave as-is unless owner wants to retire it |
| 6 | Open-WebUI | ai-stack | ai.local/.lan | `open-webui:80` | — |
| 7 | Prowlarr | default | prowlarr.local/.lan | `prowlarr:9696` | — |
| 8 | qBittorrent | default | qbit.local/.lan | `qbittorrent:8080` | Behind gluetun VPN sidecar (shared netns). WebUI routing is normal HTTP:8080; verify Service selector still resolves to the gluetun-networked pod |
| 9 | Radarr | default | radarr.local/.lan | `radarr:7878` | — |
| 10 | Seerr | default | seerr.local/.lan | `seerr:5055` | Service has `.53` LB IP; `overseerr/` dir empty — ignore |
| 11 | Sonarr | default | sonarr.local/.lan | `sonarr:8989` | — |
| 12 | Suwayomi | default | suwayomi.local/.lan | `suwayomi:4567` | **Stray `metallb.io/loadBalancerIPs: 192.168.1.52` on BOTH Service and Ingress.** Confirm nothing relies on `.52`, drop the stray annotation, route via shared Gateway |
| 13 | Longhorn UI | longhorn-system | longhorn.local | `longhorn-frontend:80` | Ingress is in Longhorn Helm values (`ingressClassName: nginx`). Route first/verify, then set Longhorn `ingress.enabled:false` (P7) |
| 14 | MinIO console | minio | minio.local (+ .lan) | `minio-console:9001` | Created in P8; listed for completeness |

> Not routed (no Ingress, correct): `subgen`, `whisper-jellyfin`, `cbz-maker`, `obsidian-sync`, `flaresolverr`, `ollama` (internal). Their netpol egress IS handled in P15.

**Steps (per app, in order):** add HTTPRoute → `kubectl get httproute <app>` → `Accepted=True`/`ResolvedRefs=True` → verify via `.51` (`curl -k --resolve <host>:443:192.168.1.51 https://<host>/`, or temp hosts entry) → record in migration log → **leave legacy Ingress in place.**

**Acceptance:** every HTTPRoute `Accepted/ResolvedRefs=True`; each app reachable via `.51`; legacy Ingress still reachable via `.50`. Both paths work simultaneously.

**Rollback / blast radius:** LOW per app (delete the HTTPRoute; legacy serves). Watch the Jellyfin catch-all for route shadowing.

---

## PHASE 7 — Flip Gateway to `.50`, retire Ingress NGINX (TWO COMMITS)

**Goal:** Move the Gateway from `.51` to `.50` and remove Ingress NGINX + legacy Ingress objects.

**Pre-reqs:** all P6 routes verified (migration log complete); **independent `kubectl`/console access confirmed** (ArgoCD UI is itself behind the Gateway being moved — do NOT rely on it). Maintenance window.

**selfHeal hazard (explicit):** ArgoCD app-of-apps self-heal reverts manual `kubectl scale`/disable within seconds (user memory). **All disable/scale changes here MUST be committed to Git, never `kubectl`.**

**Commit 1 — release `.50`:** Remove (or disable) the `ingress-nginx.yaml` Application. **Note:** Ingress NGINX pins `.50` via `controller.service.loadBalancerIP` (confirmed), so the Application must be gone for MetalLB to release `.50`.
- **Gate:** `kubectl get svc -A | grep 192.168.1.50` returns empty; no MetalLB pool conflict; `ingress-nginx` namespace/controller gone.

**Commit 2 — claim `.50`:** Change `EnvoyProxy`/Gateway Service IP from `.51` → `.50`.
- **Gate:** Envoy proxy Service EXTERNAL-IP = `.50`; every app reachable via real Pi-hole DNS name on `.50` with TLS chaining to `homelab-local-ca`.

**Commit 3 (cleanup):** Remove per-app legacy Ingress manifests (ArgoCD prunes) and disable chart Ingresses: `grafana.ingress.enabled:false`, `prometheus.ingress.enabled:false` (KPS values), Longhorn `ingress.enabled:false`.

> **Pi-hole note:** reusing `.50` means **no DNS change** (hard constraint satisfied). `.51` was staging only.

**Acceptance:** Envoy Service holds `.50`; `kubectl get ingress -A` empty (or only intentionally kept); every app reachable via real hostname on `.50` with valid TLS; migration log complete.

**Rollback / blast radius:** **HIGHEST in the project.** Keep the deleted `ingress-nginx.yaml` **revert-ready** (re-adding reclaims `.50` if Envoy fails). Each commit independently revertible. The release gate between commits 1 and 2 prevents the duplicate-IP `<pending>` race.

---

## PHASE 8 — MinIO single-node (buckets loki/tempo/velero)

**Goal:** Single-node MinIO on Longhorn PVC with three buckets; S3 API in-cluster only; console via HTTPRoute. **Gate: 3/3 workers Ready** (new PVC, replica=3).

**Versions:** community `minio` **5.4.0** (frozen/EOL — pin hard), image + mc tag **VERIFY** (§4). **VENDOR the chart or use a controlled OCI mirror** — `helm.min.io` now serves paid AIStor; community repo is archived.

**Files:**
- `kubernetes/infrastructure/minio.yaml` — Helm Application, ns `minio`:
  - `mode: standalone`, `replicas: 1` — **VERIFY rendered StatefulSet `replicas:1`** (chart bug #21480 can render 16; if so add an ArgoCD/Kustomize patch forcing `spec.replicas:1`).
  - `image` pinned; `existingSecret: minio-root-creds` (SOPS); `persistence: {enabled:true, storageClass: longhorn, accessMode: RWO, size: 50Gi}`; `resources.requests.memory: 1Gi` (override 16Gi default down — homelab CPU/mem budget per P0 #5).
  - `buckets: [{name: loki},{name: tempo},{name: velero}]` (`policy: none`, `purge: false`).
  - `consoleService.type: ClusterIP`, `consoleIngress.enabled: false`.
- `kubernetes/apps/minio/minio-root-creds.sops.yaml` (SOPS) — `rootUser`, `rootPassword`.
- HTTPRoute `kubernetes/apps/minio/httproute.yaml` → `minio-console:9001`.

**Steps:** create SOPS creds → `helm template` to confirm `replicas:1` + capture exact `mcImage` tag (record in versions.lock.md) → commit Application → StatefulSet (1 replica) Ready + `mc` bucket Job completes → verify buckets → add console HTTPRoute, verify via `.50`.

**Acceptance:** MinIO Running (1 replica); buckets `loki`/`tempo`/`velero` exist; S3 reachable at `http://minio.minio.svc.cluster.local:9000`; console via HTTPRoute+TLS; creds from SOPS (no plaintext).

**Rollback / blast radius:** LOW (nothing consumes it yet). **Gotcha:** confirm Longhorn SC reclaim behavior before relying on PVC persistence later.

---

## PHASE 9 — Loki Monolithic (S3) + Tempo (S3), ALONGSIDE loki-stack

**Goal:** Deploy standalone Loki (Monolithic, S3) and Tempo (single-binary, S3) in a NEW namespace, parallel to existing loki-stack (kept until P11). **Gate: 3/3 workers Ready.**

**Versions (CONFIRMED lineage):** Loki grafana-community **17.4.x** (supports `deploymentMode: Monolithic` — rename landed at community chart 12.0.0; appVersion **VERIFY**). Tempo **1.24.x** (appVersion ~2.9.x; HTTP/query port **3200** — **derive from the pinned chart's `helm show values`, do not hardcode blind**). **Re-validate EVERY values key against `helm show values` for the actually-pinned chart.**

**Naming-collision gotcha (resolved):** loki-stack's release is `loki` (Service `loki` in `monitoring`). Install the new Loki in **ns `observability`** (release `loki`) → Service `loki.observability.svc:3100` (or `loki-gateway` if gateway enabled).

**Files:**
- `kubernetes/infrastructure/loki-s3.yaml` — Helm Application, chart `loki` 17.4.x, ns `observability`:
  - `deploymentMode: Monolithic`; `singleBinary.replicas: 1`; all scalable/microservice components `replicas: 0`.
  - `loki.commonConfig.replication_factor: 1`, `loki.auth_enabled: false`.
  - `loki.schemaConfig.configs: [{from: "2026-06-16", store: tsdb, object_store: s3, schema: v13, index:{prefix: loki_index_, period: 24h}}]` (fresh store; old loki-stack logs NOT migrated — acceptable, ephemeral).
  - `loki.storage`: s3, bucket `loki` (chunks/ruler/admin), `endpoint: http://minio.minio.svc.cluster.local:9000`, **`s3ForcePathStyle: true`**, `insecure: true`, creds from SOPS env.
  - Retention needs **BOTH** `limits_config.retention_period: 720h` AND `compactor.retention_enabled: true` + `delete_request_store: s3` (period alone does nothing). `allow_structured_metadata: true`, `volume_enabled: true`.
  - `minio.enabled: false` (use our MinIO). `gateway.enabled: false` (homelab simplicity; avoids known Monolithic gateway 502 — Grafana points directly at `loki.observability:3100`).
- `kubernetes/infrastructure/tempo.yaml` — Helm Application, chart `tempo` 1.24.x, ns `observability`:
  - image pinned; `tempo.storage.trace`: s3, bucket `tempo`, endpoint `minio.minio.svc:9000`, **`forcepathstyle: true`**, `insecure: true`, creds from SOPS.
  - `tempo.retention: 720h`; `tempo.receivers.otlp.protocols.grpc.endpoint: 0.0.0.0:4317` (+ http :4318).
  - Note query/HTTP port (**3200** for 2.x — confirm from chart) for the Grafana datasource URL.
- `kubernetes/apps/observability/minio-s3-loki.sops.yaml`, `minio-s3-tempo.sops.yaml` (SOPS) — MINIO access/secret keys as env.

**Steps:** create SOPS S3 creds → commit Loki → pod Ready, no S3 errors, objects appear in MinIO `loki` bucket → commit Tempo → pod Ready, OTLP 4317 listening, writes to `tempo` bucket. **Do NOT touch loki-stack.** Watch `kubectl top nodes` (compaction load, P0 #5).

**Acceptance:** new Loki `/ready` 200, objects in `loki` bucket; Tempo Ready, listening 4317/4318 + HTTP 3200, writes to `tempo` bucket; loki-stack untouched.

**Rollback / blast radius:** LOW (parallel install).

---

## PHASE 10 — Grafana Alloy DaemonSet (logs + OTLP traces)

**Goal:** Replace Promtail with Alloy: pod logs → new Loki, OTLP traces → Tempo. **Metrics stay with KPS** (avoid double-scrape). Runs alongside Promtail until verified.

**Versions:** `alloy` chart **1.x** + image **VERIFY** (§4). Promtail EOL Mar 2026.

**Files:**
- `kubernetes/infrastructure/alloy.yaml` — Helm Application, ns `observability`, DaemonSet mode, external ConfigMap (`configMap.create:false`, name `alloy-config`).
- `kubernetes/apps/observability/alloy-config.yaml`:
  - **Logs:** `discovery.kubernetes role=pod` (per-node via `HOSTNAME`) → `discovery.relabel` (namespace/pod/container/app/job, static `cluster="teyvat"`) → `loki.source.kubernetes` → `loki.process` → `loki.write` to `http://loki.observability.svc.cluster.local:3100/loki/api/v1/push`.
  - **Traces:** `otelcol.receiver.otlp` grpc `0.0.0.0:4317` → `otelcol.processor.batch` → `otelcol.exporter.otlp` to `tempo.observability.svc:4317` (`tls.insecure=true`).
  - **Metrics:** scoped to OTLP/app metrics only (KPS retains node-exporter/kubelet/cAdvisor scraping — no remote_write duplication).

**Steps:** commit ConfigMap + Application → Alloy DaemonSet Running on all 3 workers → confirm logs `{cluster="teyvat"}` land in NEW Loki → send a test OTLP trace → appears in Tempo. Promtail still running.

**Acceptance:** Alloy on every worker; new Loki shows Alloy logs; Tempo receives ≥1 trace via 4317; Promtail still up (not yet removed).

**Rollback / blast radius:** LOW (additive; Promtail still ships to old Loki).

---

## PHASE 11 — Bump kube-prometheus-stack, rewire datasources, ship dashboards, retire loki-stack

**Goal:** Bump KPS 61.3.2 → 86.x, repoint Grafana to new Loki/Tempo (+ correlation), add dashboards, then remove loki-stack/Promtail.

**Versions:** KPS **86.x** (operator ~v0.91.x, grafana ~v13, node-exporter/kube-state-metrics bundled — **VERIFY all via `helm show`**). ~25-major jump — **read UPGRADE.md.**

**CRD upgrade mechanism (DECIDED):** the operator CRDs must reach the new version; the chart does NOT auto-upgrade CRDs. **Decision: apply the operator CRD bundle as a separate ArgoCD Application at wave `"-5"`, pinned to the exact operator version (VERIFY), `ServerSideApply=true`** — deterministic with ArgoCD, avoids Helm-hook/wave/SSA interaction surprises from `crds.upgradeJob`. Pin the CRD bundle version explicitly in versions.lock.md.

**Breaking-change checklist (address in values):**
- CRDs → new operator version (separate `"-5"` Application, SSA).
- `*SelectorNilUsesHelmValues` → modern `*Selector.matchLabels: null`. Dashboard sidecar label stays `grafana_dashboard: "1"`.
- Prometheus 3.x (since v67) — config/flag format review.
- PDB (v72) — explicit `enabled:true` if wanted.
- PSP removed (v73) — fine on k8s 1.35.
- **Grafana admin password (v78) no longer hardcoded** — supply `grafana.admin.existingSecret` (SOPS).
- Grafana v13 (v84) — dashboard/plugin compat review.
- distroless images (v85) — mirror distroless variants if mirroring.

**Files:**
- `kubernetes/apps/monitoring/stack.yaml` — bump `targetRevision`; keep `ServerSideApply=true`; `retention:10d`, replicas:1; `grafana.admin.existingSecret` (SOPS):
  - Loki datasource: keep **name `Loki`** + `uid: loki` (dashboards reference it), change **only the URL** → `http://loki.observability.svc:3100`. Add derived fields (logs→traces).
  - Add Tempo datasource: `url: http://tempo.observability.svc:3200` (confirm port from pinned chart), `tracesToLogsV2` (uid loki), `tracesToMetrics`, `serviceMap`, `nodeGraph`.
  - Prometheus: `exemplarTraceIdDestinations` + `enableFeatures: ["exemplar-storage"]` (metrics→traces).
- **Dashboards (the "3" deliverable):**
  - `dashboard-gateway-envoy.yaml` (Envoy request rates / 5xx) — build now.
  - `dashboard-observability-pipeline.yaml` (Loki ingest, Tempo spans, Alloy throughput) — build now.
  - `dashboard-security-posture.yaml` (Kyverno PolicyReports + Trivy findings) — **build/verify AFTER P13/P14 when data exists**; its acceptance screenshot is deferred to post-P14.
  - (Trivy operator dashboard 17813 in P14 is the operator's own, counted separately — not one of the 3.)
- **DELETE** `kubernetes/apps/monitoring/loki.yaml` + `infrastructure/monitoring-loki-stack-LEGACY.yaml` → ArgoCD prunes loki-stack + Promtail (in a SEPARATE commit, only after step 3 below).

**Steps:** (1) apply operator CRD bundle (`"-5"`, SSA). (2) bump KPS; operator + Prometheus + Grafana roll; targets healthy. (3) verify NEW datasources: Loki returns logs, Tempo returns traces, log↔trace↔metric correlation works. (4) **only after step 3 passes**, in a separate commit, delete loki-stack (prune Promtail + old `loki`). (5) add the 2 ready dashboards; security-posture after P14.

**Acceptance / screenshot checklist:**
- [ ] KPS at 86.x, operator at new version, all targets UP.
- [ ] `Loki` datasource → `{cluster="teyvat"}` returns logs from NEW Loki.
- [ ] `Tempo` datasource → a trace renders; service map / node graph populate.
- [ ] Logs→Traces, Traces→Logs, Metrics-exemplar→Tempo all work.
- [ ] loki-stack/Promtail gone (`kubectl get pods -n monitoring | grep promtail` empty).
- [ ] gateway-envoy + observability-pipeline dashboards render (screenshot); security-posture after P14.

**Rollback / blast radius:** **MEDIUM-HIGH; forward-only** — CRD downgrade is unsupported; reverting `targetRevision` to 61.3.2 will NOT downgrade CRDs and may leave the OLD operator unable to reconcile NEW CRDs. **Fix-forward runbook:** if the new operator fails to come up — (a) check operator logs for CRD schema errors, (b) re-apply the pinned CRD bundle via SSA, (c) bump to the next KPS patch rather than rolling back, (d) keep loki-stack alive until step 3 passes so logging never goes dark. KPS bump and loki-stack removal are **separate commits.**

---

## PHASE 12 — PrometheusRules + Alertmanager → ntfy

**Goal:** Alerting rules (incl. CrashLoopBackOff) + Alertmanager ntfy receiver via SOPS token.

**Files:**
- `kubernetes/apps/monitoring/prometheus-rules.yaml` — `PrometheusRule` CRs (none today). At minimum: **KubePodCrashLooping** (resilience proof), node down, PVC near-full (Longhorn), high memory, cert expiry, Loki/Tempo/MinIO down, Velero backup failed. Label so the operator's `ruleSelector` picks them up — **VERIFY the selector after the P11 bump** (`release: kube-prometheus-stack` is the usual value).
- Alertmanager config in `stack.yaml` values: route → `ntfy` receiver; `webhook_configs` URL `https://ntfy.<domain>/teyvat-alerts?template=alertmanager`, `send_resolved: true`.
  - **Auth path (RESOLVED):** mount the SOPS token via `alertmanager.alertmanagerSpec.secrets: [<secretName>]`; the `credentials_file` path MUST be exactly `/etc/alertmanager/secrets/<secretName>/<key>` and `<key>` must match the SOPS secret's key name. **VERIFY** the KPS-86 Alertmanager supports `http_config.authorization.credentials_file` (vs legacy `bearer_token_file`) and that the ntfy version honors `?template=alertmanager`.
- `kubernetes/apps/monitoring/ntfy-token.sops.yaml` (SOPS) — bearer token; pin the **key name** explicitly.
- `Documentation/teyvat-resilience-report.md` — start here (alert proof).

**Decision §12:** hosted ntfy.sh vs self-hosted ntfy.

**Steps:** create ntfy topic + token → SOPS-encrypt, commit → add rules + receiver → **test:** deploy a deliberately-crashing pod (`image: busybox, command: ["false"]`) → alert fires → ntfy notification (firing) → delete pod → "resolved" notification. Screenshot for the report.

**Acceptance:** `ntfy` receiver present; CrashLoopBackOff test produces firing + resolved notifications. Documented.

**Rollback / blast radius:** LOW (alerting only).

---

## PHASE 13 — Kyverno (Audit → soak → per-namespace Enforce)

**Goal:** Install Kyverno; policies **Audit** first; soak; selectively **Enforce** per the actual PolicyReport audit.

**Versions:** `kyverno` **3.8.x** (app ~v1.18.x; VERIFY non-rc + k8s 1.35). **Hand-write the 5 ClusterPolicies** (no chart dep; smaller, fully controlled) using v1.18 syntax (`failureAction` under `validate`, `failureActionOverrides` per-ns; old `validationFailureAction[Overrides]` deprecated).

**Policies:** disallow-latest-tag, require-limits-and-requests, require-pod-probes, disallow-privilege-escalation, require-run-as-nonroot.

**CORRECTED Enforce-risk framing (this is the key fix):**
- `disallow-latest-tag` Enforce blocks only **5 apps' redeploys** (`ollama` ×2, `open-webui:main`, `subgen`, `whisper-jellyfin`; plus the `obsidian-sync` CronJob's `alpine/git:latest`). Pin those to close the gap. **NOT "all of default."**
- The **broad** Enforce blocker is **`require-limits-and-requests` + `require-pod-probes`** — most apps lack container-level limits and probes (probes exist only in open-webui, ollama, flaresolverr). In Enforce these would block the MAJORITY of redeploys. **Re-scope the soak + Enforce-graduation list around limits/probes, driven by the actual per-namespace PolicyReport audit, not assumptions.**

**Files:**
- `kubernetes/infrastructure/kyverno.yaml` — Helm Application, ns `kyverno`, wave `"-4"`; per-controller `serviceMonitor.enabled:true` (label per P12 selector); `grafana.enabled:true` + dashboard label so the sidecar loads the Kyverno dashboard.
- `kubernetes/infrastructure/kyverno-policies.yaml` — the 5 ClusterPolicies, all `failureAction: Audit` initially.

**Steps:** install (Audit) → controllers Healthy, metrics scraped → **soak (days)** → review `kubectl get policyreport -A`/`clusterpolicyreport`; catalog violations (expect: missing limits/probes broadly; `:latest` on the 5) → remediate (pin the 5 images; add limits/probes) and add `failureActionOverrides: Enforce` per-namespace **only for clean namespaces** → flip to Enforce per-ns.

**Acceptance:** Kyverno Healthy; PolicyReports generated; Kyverno dashboard renders; NO running workload disrupted in Audit. Enforce only where verified clean. Evidence into security report.

**Rollback / blast radius:** Audit = NEAR-ZERO. Enforce per-namespace, revert `failureAction` instantly if a deploy is blocked. Do not Enforce `require-limits-and-requests`/`require-pod-probes` in any namespace until that namespace's workloads declare them.

---

## PHASE 14 — Trivy Operator

**Goal:** Continuous vuln/config scanning, metrics → Prometheus, dashboard in Grafana.

**Versions:** `trivy-operator` **0.33.x** (VERIFY), `oci://ghcr.io/aquasecurity/helm-charts/trivy-operator`.

**Files:**
- `kubernetes/infrastructure/trivy-operator.yaml` — Helm Application, ns `trivy-system`, `serviceMonitor.enabled:true` (P12 label). **Resource budget (P0 #5):** scan jobs are CPU/mem-heavy on this CPU-sensitive cluster — set scan concurrency/scheduling limits; watch `kubectl top nodes`.
- Trivy Grafana dashboard: import grafana.com **17813** as a `grafana_dashboard:"1"` ConfigMap (`dashboard-trivy.yaml`) — the operator's own dashboard, **separate from the 3 deliverables**.
- Now build/verify `dashboard-security-posture.yaml` (Kyverno + Trivy data) deferred from P11.

**Steps:** install → generates `VulnerabilityReport`/`ConfigAuditReport` CRs → metrics scraped + dashboard renders.

**Acceptance:** `kubectl get vulnerabilityreports -A` populated; Trivy dashboard renders; ServiceMonitor scraped; security-posture dashboard renders (closes the P11 deferral); no node-pressure outage.

**Rollback / blast radius:** LOW-MEDIUM (scan jobs consume resources).

---

## PHASE 15 — NetworkPolicies (default-deny + DNS/Longhorn/NFS/gateway/scrape allows)

**Goal:** Per-namespace default-deny + explicit allows. **LAST** — a missing allow silently breaks everything. **Prerequisite: P0 #3 (kube-router NP enforcement confirmed).**

**NFS caveat (RESOLVED):** `celestia-nfs` + Prowlarr static NFS PV traffic is **node-kernel mount traffic from the kube-system CSI node-plugin**, NOT from the app pod's netns — pod-level NetworkPolicy may not govern it at all. So:
1. Enumerate all NFS PVs: `kubectl get pv -o wide | grep nfs`. Confirm every server IP is `.210`; **ensure NONE point at decommissioned `192.168.1.103`** (stale `.103` mounts wedge whole nodes — user memory).
2. Determine experimentally whether kube-router NP governs the CSI mount path; target allow rules at the **kube-system CSI node-plugin / node level** accordingly, not blindly at app pods.
3. **Validate by mounting a PVC after applying default-deny** in a test namespace.

**Files (per namespace, `kubernetes/apps/security/networkpolicies/`):**
- `default-deny.yaml` — deny all ingress+egress (per app ns: `default`, `ai-stack`, `glance`, `monitoring`, `observability`; carefully for `argocd`).
- `allow-dns.yaml` — egress to CoreDNS (UDP/TCP 53) — **apply FIRST or every pod loses DNS.**
- `allow-longhorn.yaml` — to/from `longhorn-system` (manager/engine/instance-manager ports) for any ns with Longhorn PVCs.
- `allow-nfs.yaml` — per the CSI-path finding above (Synology `192.168.1.210:2049` nfsvers=4.1; MinIO `minio.minio.svc:9000` for Loki/Tempo/Velero S3 egress).
- `allow-gateway-ingress.yaml` — ingress from `envoy-gateway-system` (Envoy) to app service ports.
- `allow-monitoring-scrape.yaml` — ingress from `monitoring`/`observability` (Prometheus, Alloy) to app `/metrics`; egress from Alloy/Prometheus to targets.
- **qBittorrent/gluetun (CRITICAL — RESOLVED):** the pod is gluetun (v3.41.0) + qbittorrent sharing one netns; default-deny egress kills the WireGuard handshake = the exact "downloading metadata"/dead-tunnel failure in user memory. **ProtonVPN WG endpoint IP rotates**, so a single dst-IP allow won't work. Allow **egress UDP (WG port) to `0.0.0.0/0` + DNS + ingress from Envoy on 8080** for this pod, OR exclude it from default-deny entirely. Apply its policy **LAST in `default`**, then test the tunnel (gluetun control server / public-IP check), keep a one-line revert ready.
- **Internet-egress apps:** Ollama (model pulls), Open-WebUI, Suwayomi/FlareSolverr/Prowlarr (indexers/Cloudflare bypass) — allow egress to internet (or DNS+443). **subgen / whisper-jellyfin** (no Ingress, so no route — but they DO need egress for model/dependency pulls + inter-pod calls to Jellyfin): include their egress (DNS + 443 + intra-`default` to `jellyfin-service`) or default-deny breaks dub-subtitle generation.

**Steps:** (P0 #3 confirmed) → apply ALL allow rules first → apply default-deny **one namespace at a time, lowest-risk first (`glance`)**, verifying app + logs + scrape + PVC mount + DNS after each → save `default` (8 apps + gluetun + NFS + Longhorn) for LAST → qBittorrent policy is the final step in `default`.

**Acceptance:** per namespace — app reachable via Gateway, logs flow to Loki, Prometheus scrapes, Longhorn + NFS PVCs mount, DNS resolves, **gluetun VPN stays up** (qbit not "downloading metadata"), subgen/whisper still function; a deliberate should-be-denied cross-ns probe is denied.

**Rollback / blast radius:** **HIGH** — a bad netpol severs DNS/storage cluster-wide. Per-namespace rollout, allows-first, default-deny-last, one file per namespace for instant revert, `kubectl` access independent of the Gateway. Schedule deliberately.

---

## PHASE 16 — Velero namespace DR (stretch)

**Goal:** Namespace backup+restore to MinIO `velero` bucket with a tested restore drill.

**Versions:** `velero` chart **12.x** (VERIFY); `velero-plugin-for-aws` **VERIFY** — **documented compat ceiling is ~v1.13.x → Velero 1.17.x; resolve plugin/Velero/chart compatibility BEFORE pinning** (likely a real mismatch with Velero 1.18). If unresolved, prefer **Option B (manifest-only)**.

**CSI prerequisite (RESOLVED):** k0s does NOT ship `snapshot.storage.k8s.io` CRDs/controller; Longhorn does not necessarily install them. For **Option A (CSI)** add **`kubernetes/infrastructure/external-snapshotter.yaml`** — a pinned, scoped ArgoCD Application (controller + CRDs, VERIFY version) — and verify Longhorn's `driver.longhorn.io` VolumeSnapshotClass works with the pinned Velero data-mover. **Option B (manifest-only):** lighter; volume restore is a separate Longhorn-S3 step (documented).

**Files:**
- `kubernetes/infrastructure/external-snapshotter.yaml` — only if Option A.
- `kubernetes/infrastructure/velero.yaml` — Helm Application, ns `velero`: BSL provider `aws` → MinIO (`s3Url: http://minio.minio.svc:9000`, `s3ForcePathStyle: "true"`, bucket `velero`); `credentials.existingSecret: velero-s3-creds`; `initContainers` plugin (VERIFY tag); `configuration.features: EnableCSI` only if Option A.
- `kubernetes/apps/velero/velero-s3-creds.sops.yaml` (SOPS) — INI `cloud` key with MinIO access/secret.
- `kubernetes/apps/velero/volumesnapshotclass.yaml` (Option A) — `driver: driver.longhorn.io`, labeled `velero.io/csi-volumesnapshot-class:"true"`.
- `kubernetes/apps/velero/schedule.yaml` — nightly Schedule. **Stagger from Longhorn's `daily-backup` `0 2 * * *` → use `0 3 * * *`** (avoid simultaneous load; user memory + the new `longhorn-recurring-jobs.yaml` in the working tree).

**Steps:** confirm/install CSI snapshot CRDs (Option A) → SOPS creds → commit Velero → `velero backup create test-glance --include-namespaces glance` → Completed, objects in MinIO `velero` bucket → **DR drill (deliverable):** delete `glance` ns → `velero restore create --from-backup test-glance` → app + PVC restored and reachable → document in resilience report.

**Acceptance:** backup Completed to MinIO; restore drill recreates `glance` + workloads + (CSI) volume data; nightly Schedule active (staggered).

**Rollback / blast radius:** LOW for install. **Drill targets a NON-critical namespace (`glance`) only — never `default`/`monitoring`.**

---

## 11. Risks & Gotchas (consolidated)

**Gateway / routing:**
- CRD→controller→Gateway ordering via waves -5/-4/-3/-1; first sync of Gateway/HTTPRoute apps needs `SkipDryRunOnMissingResource=true`.
- Gateway API CRD apply size → `ServerSideApply=true`.
- **Envoy CRD skip via VALUE KEYS, never `Helm.skipCrds:true`** (that drops Envoy's own CRDs → crashloop). VERIFY `crds.gatewayAPI.enabled:false`/`crds.envoyGateway.enabled:true` against `helm show values`.
- cert-manager `config.enableGatewayAPI:true` (GA in 1.20.x; `ExperimentalGatewayAPISupport` REMOVED — do NOT use). CRDs first, CRD-keep on, stepwise from 1.14.
- cert-manager listener requirements: non-empty hostname, `mode: Terminate`, non-empty certRef, Secret kind/core group — else silently skipped. **Use Certificate OR annotation, not both**; Secret in Gateway ns.
- **`.50` flip is TWO commits with a release gate** (ingress-nginx pins `.50` via `controller.service.loadBalancerIP`; MetalLB refuses duplicate → Envoy `<pending>`).
- Jellyfin hostless catch-all must not shadow host-matched routes (specific hostnames match first).
- Suwayomi stray `.52` on Service AND Ingress — confirm unused, drop.
- qBittorrent WebUI routing is normal HTTP:8080 but the Service selects the gluetun-networked pod — verify reachability.
- ArgoCD self-lockout — keep `argocd-ingress` until verified; keep `kubectl` access through P7.
- **Grafana AND Prometheus both have nginx Ingresses today** — both are cutovers; route `prometheus.local` too (or consciously drop it).

**Observability:**
- **Loki 17.4.x IS the correct lineage** (grafana-community; `Monolithic` rename at community chart 12.0.0). appVersion **VERIFY via `helm show`**. Re-validate every values key against the pinned chart.
- Loki schema fresh-install (`v13`/`tsdb`, `from` ≥ today); old loki-stack logs not migrated (ephemeral — acceptable).
- Loki Service-name collision → install in `observability` ns.
- Loki gateway disabled (avoids Monolithic 502); Grafana points at `loki.observability:3100`.
- Datasource: keep name `Loki`+`uid:loki`, change only URL. **Tempo port 3200 — derive from the pinned chart, not asserted.**
- Loki retention needs BOTH `retention_period` AND `compactor.retention_enabled`+`delete_request_store:s3`.
- MinIO chart frozen/EOL/archived + AIStor on helm.min.io → **vendor/mirror**; bug #21480 can render replicas:16 → VERIFY `replicas:1`; capture `mcImage` tag.
- Path-style mandatory everywhere (Loki `s3ForcePathStyle`, Tempo `forcepathstyle`, Velero `s3ForcePathStyle`).
- KPS 61→86 ~25 majors; operator CRDs via separate `"-5"` SSA Application (pinned), Prometheus 3.x, Grafana 13, admin password externalized (SOPS), distroless. **Forward-only** — fix-forward runbook in P11.
- Alloy = logs+traces only; KPS keeps metrics (no double-scrape).

**Security:**
- **Kyverno Enforce blocker = limits/probes (most apps), NOT `:latest` (only 5 apps).** Audit-first mandatory; re-scope graduation around the real PolicyReport.
- NetworkPolicy: allows-first (DNS/Longhorn/NFS/gateway/scrape) before default-deny, per-ns lowest-first. **NFS is CSI-node-plugin/node-level traffic** — target rules accordingly; verify no PV points at decommissioned `.103`. **gluetun needs WG egress to `0.0.0.0/0`** (rotating endpoint); Ollama/Suwayomi/FlareSolverr/subgen/whisper need internet/inter-pod egress.
- **Verify kube-router NP actually drops traffic (P0 #3)** before trusting default-deny.
- SOPS repo-server patch = SPOF for ALL ArgoCD rendering — small, tested, watched; out-of-band fallback documented.
- Longhorn/MetalLB Applications cosmetic OutOfSync (CRD drift) is pre-existing; new CRD-bearing apps may show the same — do not force-prune CRDs.
- Orphaned monitoring apps + `prune:true` → diff before adopting; ensure all 5 dashboards survive.

**Cross-cutting (cluster memory):**
- **ArgoCD self-heal reverts `kubectl scale`/disable in seconds** — every disable/scale change MUST go through Git, never `kubectl` (P7 especially).
- **CPU-sensitive nodes** (sonarr ffprobe loop history) — budget headroom (P0 #5); Trivy scans + Loki/Tempo compaction add load; watch `kubectl top nodes`.
- **Longhorn replica count must equal node count (3)** — new PVCs (MinIO/Loki/Tempo) inherit `defaultClassReplicaCount:3`; gate P8/P9 on 3/3 workers Ready.
- **Backup-window collision** — Longhorn `daily-backup` `0 2 * * *`; stagger Velero `0 3 * * *`.
- **Image pinning** — pin the 5 floating images before Enforcing `disallow-latest-tag`.

---

## 12. Open Decisions for the Owner

1. **Gateway controller:** Envoy Gateway v1.8.x (default; in-matrix for k8s 1.35, CNI-agnostic) vs kgateway. Cilium ruled out (CNI constraint). → Envoy Gateway.
2. **Gateway CRD ownership:** we-own standard CRDs v1.5.x + value-based skip (default) vs chart-managed (experimental channel). → We-own.
3. **cert-manager CA tier:** reuse single-tier `homelab-local-ca` (default — avoids re-trusting a new root) vs root→intermediate chain. → Reuse.
4. **Temp Gateway IP:** `.51` (default; VERIFY free) vs `.55`. Confirm live before P5.
5. **MinIO chart sourcing:** vendor 5.4.0 into repo (default, most reproducible) vs controlled OCI mirror vs trust archived live repo (rejected). → Vendor/mirror. Accept frozen/EOL chart (least-bad free option).
6. **Loki gateway:** `false` (default; homelab simplicity, avoids Monolithic 502) vs `true`. → False.
7. **Observability namespace:** `observability` (default; avoids `loki` Service collision). → observability.
8. **Alloy metrics scope:** logs+traces only, KPS keeps metrics (default; no dup) vs Alloy remote_write. → logs+traces.
9. **Alertmanager target:** **LOCKED → hosted ntfy.sh** (still fires when the cluster is degraded; topic name is the only secret, stored SOPS-encrypted). Self-hosted ntfy rejected for this round.
10. **SOPS integration:** KSOPS (default; fits Kustomize app-of-apps) vs SOPS-CMP sidecar vs ESO (rejected). → KSOPS.
11. **ArgoCD install method** — **PHASE-0 BLOCKER** (promoted from open decision). Determines repo-server KSOPS wiring; out-of-band secret fallback if un-patchable.
12. **Kyverno Enforce scope/timeline:** **LOCKED → Audit → soak → Enforce app namespaces.** Deploy Audit; soak to generate the real PolicyReport; then (a) pin the 5 floating images (`ollama` ×2, `open-webui:main`, `subgen`, `whisper-jellyfin`; + `alpine/git` in the obsidian-sync cron) — prereq for Enforcing `disallow-latest-tag`; (b) add missing CPU/mem limits + liveness/readiness probes to the media-app manifests (the broad blocker); then flip app namespaces to Enforce. System namespaces stay Audit.
13. **kyverno-policies:** hand-write the 5 ClusterPolicies (default; minimal, controlled) vs bundled PSS chart. → Hand-write.
14. **Velero mode:** **LOCKED → Option B (manifest-only).** Velero backs up resource manifests to the MinIO `velero` bucket; volume data stays covered by Longhorn's existing NAS backups (restore is a separate Longhorn-from-S3 step, documented in the resilience report). external-snapshotter / Longhorn VolumeSnapshotClass / CSI data-mover are NOT installed this round — keeps node load and the plugin-compat risk off the table.
15. **Longhorn / csi-driver-nfs bumps:** out of scope (each its own storage risk). Decide separately.

---

## 13. Verify-Before-Apply Gate (every phase)

Before committing any chart/image version, run `helm show chart <repo>/<chart> --version <X>` + `helm show values` and confirm the tag resolves and appVersion/values keys match §4. **The Loki/Tempo schema MUST be validated against the actually-pinned chart** (the DRAFT's Loki 17.4.x is confirmed correct lineage; appVersion + values keys are read from `helm show`, not memory).

**Explicitly NOT confidently pinned — re-verify at execution (do not invent a substitute):**
- Loki 17.4.x **appVersion** (grafana/loki image) and exact values-key schema.
- Tempo chart patch + appVersion + **HTTP/query port** (3100 vs 3200 is chart-version-dependent).
- cert-manager v1.20.x latest patch + **supported upgrade path from 1.14** (may need intermediate minors) + `crds.enabled`/`crds.keep` keys.
- KPS 86.x latest patch + **operator CRD bundle version** + bundled subchart versions.
- Envoy `gateway-helm` v1.8.x CRD-skip value keys + k8s 1.35 support.
- MinIO `RELEASE.*` image tag + `mcImage` tag in 5.4.0 values; rendered `replicas:1`.
- `velero-plugin-for-aws` tag vs Velero/chart (compat ceiling ~v1.13.x→1.17.x — likely needs resolving).
- Kyverno 3.8.x **non-rc** + k8s 1.35; Trivy 0.33.x; Alloy 1.x; Gateway API v1.5.x (NOT v1.6-rc); SOPS/age/KSOPS latest.
- external-snapshotter version (if Option A).

---

All paths under `/Users/ccampbell/dev/homelab-devops/`. No cluster/repo changes have been made — this is the master plan. Owner decisions #9/#12/#14 are LOCKED (see §12 + header). Remaining gates: owner reviews this doc and gives the go; then Phase 0 (read-only) resolves #4 (temp Gateway IP, live) and #11 (ArgoCD install method, live) before any commit in Phase 1.

---

## PNEUMA DELTAS (appended 2026-07-03 — facts changed by the GPU-platform build; see Documentation/pneuma/)

**Phase 0 items pre-answered during the Pneuma build:**
- ArgoCD install method = **raw manifests, out-of-repo** (no helm labels/release). P2 KSOPS repo-server patching must edit the live Deployment or first adopt the ArgoCD install into GitOps; the documented out-of-band-secret fallback stands.
- kube-router **NetworkPolicy enforcement CONFIRMED** live (deny-all smoke test blocked traffic) → P15 is real, proceed.
- Control-plane headroom: master VM 201 is now **5G/4c** after apiserver starvation during the KPS+gpu-operator rollout. Re-check `free -m` on .201 before adding Kyverno (3 controllers)/Trivy/Envoy/Velero — expect to need another bump.
- Cluster shape: workers = aether-worker, nahida-worker, **pneuma** (GPU node: tainted `nvidia.com/gpu=present:NoSchedule`, deliberately NOT a Longhorn node). raiden-worker retired. **Longhorn gates ("all workers Ready") now mean aether+nahida only**; default replica count corrected to 2 in longhorn-app.yaml.

**Phase 1 (adopt orphaned apps): DONE EARLY, differently than planned** — the live KPS/loki-stack turned out to be already deleted (June consolidation casualty; they were never GitOps-wired). `kubernetes/infrastructure/monitoring.yaml` now renders `kubernetes/apps/monitoring/` with a FRESH kube-prometheus-stack **87.5.1** (supersedes the P11 61.3.2→86.x upgrade path — no CRD migration needed; P11 shrinks to datasource rewiring when Loki lands). loki-stack (EOL Promtail) was archived, not adopted — **P9/P10 deploy the new Loki/Alloy greenfield, no parallel-run/retirement step needed**. KPS runs with all `*SelectorNilUsesHelmValues: false` (ServiceMonitors need no release label).

**New SOPS customers for P2:** `litellm-secret` (ai-stack) and `grafana-admin` (monitoring), both currently out-of-band with TODO(SOPS) markers.

**P6 HTTPRoute cutover list +=** `llm.local` (LiteLLM ingress; the gateway also holds LB `.55` directly — only the hostname route migrates).

**P10 Alloy DaemonSet** needs the pneuma toleration `{key: nvidia.com/gpu, operator: Exists, effect: NoSchedule}` or vLLM logs are never shipped.

**P13 Kyverno blocker inventory changed:** ollama (×2 floating tags) deleted; open-webui pinned v0.10.2. All new AI-platform workloads ship pinned images + limits + probes. Remaining floating: subgen, whisper-jellyfin (retiring per furina-cutover-checklist), alpine/git in obsidian-sync (the rag ingest pins alpine/git:v2.47.2 — copy that pin).

**P15 ai-stack NetworkPolicy flows to allow:** open-webui/rag-api/rag-ingest → litellm:4000; litellm → keda interceptor proxy (ns keda, :8080) → vllm-chat/coder:8000 (pneuma); litellm → tei:80 + rag-api:8000; rag-api/ingest → qdrant:6333; monitoring ns → all ai-stack /metrics; vllm/tei/ingest egress to HuggingFace/GitHub/PyPI.

**versions.lock.md seed (verified pins from the Pneuma build):** gpu-operator v26.3.3 · KPS 87.5.1 · keda 2.20.1 · keda-add-ons-http 0.15.0 · qdrant chart 1.18.2 · vllm/vllm-openai v0.24.0 · litellm v1.90.0 · TEI cpu-1.9 · open-webui v0.10.2 · alpine/git v2.47.2.

**New operational invariant:** deleting a child Application file does NOT cascade-delete its resources (no resources-finalizer anywhere, on purpose) — true app retirement needs manual cleanup of leftovers; conversely this is the safety net that limits blast radius. Keep it this way.
