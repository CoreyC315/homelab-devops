# Teyvat SOPS — encrypted secrets in Git (Phase 2 deliverable)

**Decided shape (2026-08-14):** SOPS + age, **without** the KSOPS ArgoCD repo-server
patch. Phase 0 confirmed ArgoCD is installed from **raw manifests, out-of-repo** —
patching its repo-server Deployment would be untracked drift on an unmanaged object,
silently wiped by any future ArgoCD manifest re-apply, and a rendering SPOF. The plan's
own documented fallback (out-of-band secret application) is the chosen path, upgraded:
secrets now live **encrypted in Git** and are applied via a documented manual step,
instead of existing nowhere but the cluster.

## The pieces

- **Key**: age keypair, recipient `age1skrf3yy…qsgjqzd743s` (recorded in `.sops.yaml`).
  On the admin Mac it lives in `~/.config/sops/age/keys.txt` (alongside an unrelated
  `age1vth2…` identity). **macOS sops does NOT look there by default** (it uses
  `~/Library/Application Support/sops/age/`) — `export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt`.
  ⚠ Until 2026-11-16 the Mac copy was the wrong key and the ONLY copy of the real one was
  the in-cluster `argocd/sops-age` Secret; it was copied back to the Mac that day.
  **⚠ BACK THE PRIVATE KEY UP** (password manager / offline copy). It is the single
  root of trust; nothing in Git can recover it.
- **Copy for future KSOPS**: `sops-age` Secret in the `argocd` namespace (created
  out-of-band 2026-08-14) already holds the key, so wiring KSOPS later needs no re-key.
- **`.sops.yaml`**: encrypts only `data`/`stringData` of files matching `*.sops.yaml`
  — metadata stays readable for diffs.

## Workflows

**Create a new secret:**
```bash
cd ~/homelab-devops
cat > kubernetes/apps/<app>/<name>.sops.yaml <<EOF
apiVersion: v1
kind: Secret
metadata: {name: <name>, namespace: <ns>}
stringData:
  key: value
EOF
sops -e -i kubernetes/apps/<app>/<name>.sops.yaml   # encrypt in place
git add ... && git commit && git push
sops -d kubernetes/apps/<app>/<name>.sops.yaml | kubectl apply -f -   # apply out-of-band
```

**Edit an existing secret:** `sops kubernetes/apps/<app>/<name>.sops.yaml` (opens
decrypted in $EDITOR, re-encrypts on save) → commit → re-apply as above.

**Why ArgoCD ignores these files safely:** `*.sops.yaml` files are ciphertext
Kubernetes manifests; they are kept OUT of paths ArgoCD Applications render (each
app's Application points at its directory — sops files for out-of-band apply live
there too and WOULD be rendered as garbage... so instead all `*.sops.yaml` live under
`kubernetes/secrets/` which no Application references). Applied secrets carry no
ArgoCD tracking label → prune never touches them (same mechanics as the existing
`protonvpn-secret` / `litellm-secret` / `grafana-admin` out-of-band precedent).

## Current SOPS-managed secrets

| File | Cluster secret | Used by |
|---|---|---|
| `ntfy-url.sops.yaml` | monitoring/ntfy-url | Alertmanager → ntfy |
| `litellm-secret.sops.yaml` | ai-stack/litellm-secret | LiteLLM master key |
| `obsidian-sync-secret.sops.yaml` | ai-stack/obsidian-sync-secret | obsidian vault git sync (GitHub PAT) |
| `openclaw-api-keys.sops.yaml` | ai-stack/openclaw-api-keys | openclaw |
| `cbz-maker-secret.sops.yaml` | default/cbz-maker-secret | cbz-maker → Komga |
| `protonvpn-secret.sops.yaml` | default/protonvpn-secret | qBittorrent gluetun (Proton WireGuard) |
| `whisper-jellyfin-secret.sops.yaml` | default/whisper-jellyfin-secret | whisper-jellyfin |
| `homelable-secret.sops.yaml` | homelable/homelable-secret | homelable auth + MCP keys |
| `grafana-admin.sops.yaml` | monitoring/grafana-admin | Grafana admin login |
| `gha-runner-secret.sops.yaml` | pipeline/gha-runner-secret | ARC runners GitHub token |
| `argocd-secret.sops.yaml` | argocd/argocd-secret | Argo CD admin password + server.secretkey only (TLS self-regenerates) |

(MinIO/Loki/Tempo/Velero S3 creds were removed with MinIO + Velero on 2026-11-16.)

Not stored on purpose (regenerated automatically): webhook/admission certs (cert-manager, ingress-nginx,
kube-prometheus-stack, keda), argocd-redis, argocd-initial-admin-secret, envoy-oidc-hmac,
kyverno-generate-provenance, k0s bootstrap tokens. `argocd/sops-age` is the key itself — never in git.

**Restore all:** `for f in kubernetes/secrets/*.sops.yaml; do sops -d "$f" | kubectl apply -f -; done`
(namespaces must exist first).

## Migration debt (from PNEUMA DELTAS)

Done 2026-11-16: every hand-made secret is now in `kubernetes/secrets/`. When rotating a
secret (e.g. a new Proton WireGuard key), edit the sops file first, then apply it — otherwise git drifts stale.

## Future: full KSOPS wiring (documented, not applied)

If ArgoCD is ever adopted into GitOps (or the drift risk is accepted): initContainer
`viaductoss/ksops:v4.5.1` (`ksops install /custom-tools`), mount `ksops` into
`/usr/local/bin/`, repo-server env `XDG_CONFIG_HOME=/.config` +
`SOPS_AGE_KEY_FILE=/.config/sops/age/keys.txt`, mount the existing `sops-age` Secret
at `/.config/sops/age`, and `argocd-cm` → `kustomize.buildOptions: "--enable-alpha-plugins --enable-exec"`;
SOPS-bearing apps then get a `kustomization.yaml` + KSOPS generator. (Verified against
KSOPS v4.5.1 README + ArgoCD 3.2 docs, 2026-08-14. Note v4.5.1 no longer copies its
own kustomize by default — ArgoCD's built-in is used.)
