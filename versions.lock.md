# versions.lock.md — Teyvat pinned versions

> Hardening-plan §4 deliverable (P1). Every pin below was **re-verified against live
> sources on 2026-08-14** (helm v4.2.4 `show chart/values`, repo index.yaml files,
> GitHub releases API, upstream docs — 12-way parallel verification pass; full agent
> evidence in the hardening execution log). Update this file in the same commit as
> any version change. Deltas vs. the plan's 2026-06-16 guesses are called out.

## Existing (already GitOps-managed — recorded, not changed here)

| Component | Chart / source | Pinned | Notes |
|---|---|---|---|
| kube-prometheus-stack | prometheus-community | **87.5.1** | operator v0.92.1, Alertmanager **v0.33.0**, fresh install 2026-07-02 (supersedes plan's 61.3.2→86.x path) |
| gpu-operator | helm.ngc.nvidia.com | v26.3.3 | |
| KEDA / keda-http-add-on | kedacore | 2.20.1 / 0.15.0 | |
| Longhorn | charts.longhorn.io | ~1.7.2 | out of scope (owner call) — `defaultClassReplicaCount: 2` |
| MetalLB | metallb/metallb config/native | v0.14.8 | DO NOT TOUCH (hard constraint), pool `.50-.55` |
| Ingress NGINX | kubernetes.github.io | 4.10.1 | **retire target** (P7) |
| cert-manager | charts.jetstack.io | v1.14.5 | **bump target** (P5, stepwise — see below) |
| ArgoCD | raw manifests, out-of-repo | v3.2.4 | install method confirmed P0 |
| qdrant / litellm / vllm / open-webui / TEI | various | 1.18.2 / v1.90.0 / v0.8.4 / v0.10.2 / cpu-1.9 | ousia-platform pins (vllm v0.8.4 pinned for CUDA 12.4 — see ousia phase-1 notes; supersedes the delta note's v0.24.0) |

## New — Gateway track (P3–P7)

| Component | Source | Pinned | Verified facts |
|---|---|---|---|
| Gateway API CRDs | github.com/kubernetes-sigs/gateway-api, **vendored** `standard-install.yaml` | **v1.5.1** (standard channel, 8 CRDs) | v1.6.1 is latest stable, but Envoy Gateway v1.8's compat matrix pairs with **v1.5.1** — stay matrix-matched. Asset URL returns 200, vendored into repo. |
| Envoy Gateway | `oci://docker.io/envoyproxy/gateway-helm` | **v1.8.3** | k8s 1.32–1.35 in matrix ✓; data plane envoy distroless-v1.38.0. **`crds.enabled: false`** (single bool — the plan's per-group keys don't exist in this chart). |
| Envoy Gateway CRDs | `oci://docker.io/envoyproxy/gateway-crds-helm` | **v1.8.3** | The plan's `crds.envoyGateway.enabled` / `crds.gatewayAPI.enabled` keys live HERE (both default false). Set envoyGateway=true, gatewayAPI=false → renders exactly the 8 `gateway.envoyproxy.io` CRDs. |
| MetalLB IP pin mechanism | — | EnvoyProxy `spec.provider.kubernetes.envoyService.annotations: metallb.io/loadBalancerIPs` | **Gateway `.spec.addresses` is a trap** (renders to Service `externalIPs`, MetalLB ignores it). Temp IP **`.53`** (only free pool IP — plan's `.51` is now suwayomi's). |

## Bump — cert-manager (P5, one minor at a time per upstream policy)

Stepwise path (latest patch of each minor, from live charts.jetstack.io index):
**v1.14.5 → v1.15.5 → v1.16.5 → v1.17.4 → v1.18.6 → v1.19.6 → v1.20.3 → v1.21.1 (final)**

Final-state values (v1.21.1): `crds.enabled: true` + `crds.keep: true` (replaces deprecated `installCRDs`), `config.gatewayAPI.enabled: true` (canonical since 1.21; `config.enableGatewayAPI` deprecated). Gateway API support = BETA, default-gate on since 1.15 (plan's "GA" claim corrected). Images `quay.io/jetstack/cert-manager-*:v1.21.1`.

## New — Observability track (P8–P12)

| Component | Source | Chart | App/image | Key verified facts |
|---|---|---|---|---|
| MinIO | **`https://charts.min.io`** (live; helm.min.io now AIStor-only — plan's vendoring need moot) | **5.4.0** (frozen/EOL, latest of lineage) | `quay.io/minio/minio:RELEASE.2024-12-18T13-15-44Z`, mc `RELEASE.2024-11-21T17-21-54Z` | `mode: standalone` + `replicas: 1` renders Deployment replicas:1 (bug #21480 not reproduced on helm4 — belt-and-suspenders keep both set). Default 16Gi mem request / 500Gi PVC MUST be overridden. `existingSecret` keys: `rootUser`/`rootPassword`. |
| Loki | **grafana-community.github.io/helm-charts** (grafana.github.io's `loki` is now Enterprise Logs 7.x — wrong lineage) | **17.4.11** | `grafana/loki:3.7.2` | `deploymentMode: Monolithic` is default. REQUIRED: `singleBinary.replicas: 1` **AND** `write/read/backend.replicas: 0` (validate.yaml enforces), `loki.storage.bucketNames.{chunks,ruler}`. Retention: `loki.compactor.retention_enabled` + `delete_request_store` (NOT top-level `compactor:` — that's the pod spec). Creds: `${VAR}` + `singleBinary.extraEnvFrom` (expand-env hardcoded on). Disable: chunksCache/resultsCache (8G+1G memcached!), lokiCanary, gateway, minio. |
| Tempo | grafana.github.io/helm-charts | **1.24.4** | `grafana/tempo:2.9.0` | HTTP/query port **3200** confirmed. S3 keys Tempo-native: **`forcepathstyle`** (not Loki's `s3ForcePathStyle`). Creds: `tempo.extraArgs: {"config.expand-env": "true"}` (map, no leading dash) + `extraEnvFrom`. `reportingEnabled: false`. Retention `tempo.retention`. |
| Grafana Alloy | grafana.github.io/helm-charts | **1.11.1** | `grafana/alloy:v1.18.1` | `alloy.configMap.create: false` + name/key (key = mounted filename). `controller.type: daemonset` (default). GPU-node toleration via `controller.tolerations`. OTLP via `alloy.extraPorts` (renders container + Service ports). `crds.create: false` (skip PodLogs CRD). Components (loki.source.kubernetes etc.) all current in v1.18. |
| ntfy (hosted) | ntfy.sh | — | — | `https://ntfy.sh/<topic>?template=alertmanager` **verified live** (named templates since ntfy 2.14.0; hosted runs it). AM v0.33.0 supports `url_file` (since 0.26.0) + `alertmanagerSpec.secrets` mounts at `/etc/alertmanager/secrets/<name>/` → topic URL stays out of git. |

## New — Security track (P13–P15)

| Component | Source | Chart | App | Key facts |
|---|---|---|---|---|
| Kyverno | kyverno.github.io/kyverno | **3.8.2** (3.9 is rc-only) | v1.18.2 | k8s support window v1.33–v1.35 ✓. Policy syntax: `validate.failureAction` + `failureActionOverrides` (old `validationFailureAction` deprecated). ServiceMonitor per controller ×4 + `grafana.enabled`. |
| Trivy Operator | **`https://aquasecurity.github.io/helm-charts`** (plan's OCI ghcr path is STALE — abandoned at 0.32.1) | **0.35.0** | 0.33.0 | `serviceMonitor.enabled`, `operator.scanJobsConcurrentLimit` (default 10 — lower for this CPU-sensitive cluster), `excludeNamespaces` glob. |
| SOPS / age | getsops / FiloSottile releases | binaries | **v3.13.3 / v1.3.1** | installed on the admin box 2026-08-14. |
| KSOPS | viaduct-ai/kustomize-sops | image | v4.5.1 | **documentation-only** — repo-server patch NOT applied (out-of-band decision, see P2 log + teyvat-sops.md). |

## New — DR track (P16)

| Component | Source | Chart | App | Key facts |
|---|---|---|---|---|
| Velero | vmware-tanzu.github.io/helm-charts | **12.1.0** | velero 1.18.1 | Plugin **`velero/velero-plugin-for-aws:v1.14.2`** (compat table: v1.14.x ↔ Velero 1.18.x — chart's own example shows v1.13.1 which is WRONG for 1.18, do not copy). Manifest-only: `snapshotsEnabled: false`, `deployNodeAgent: false`, no `EnableCSI`. BSL is a LIST (`configuration.backupStorageLocation[0]`), `config.s3ForcePathStyle: "true"` + `s3Url`, region still required. external-snapshotter NOT installed (Option B locked). |
