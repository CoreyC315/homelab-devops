# Teyvat SOPS — encrypted secrets in Git (Phase 2 deliverable)

**Decided shape (2026-08-14):** SOPS + age, **without** the KSOPS ArgoCD repo-server
patch. Phase 0 confirmed ArgoCD is installed from **raw manifests, out-of-repo** —
patching its repo-server Deployment would be untracked drift on an unmanaged object,
silently wiped by any future ArgoCD manifest re-apply, and a rendering SPOF. The plan's
own documented fallback (out-of-band secret application) is the chosen path, upgraded:
secrets now live **encrypted in Git** and are applied via a documented manual step,
instead of existing nowhere but the cluster.

## The pieces

- **Key**: age keypair at `~/.config/sops/age/keys.txt` on the admin workstation
  (sops' default lookup path). Public recipient recorded in `.sops.yaml` at repo root.
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
| (created in later phases: minio root creds, loki/tempo S3 creds, ntfy topic URL, velero S3 creds) | | |

## Migration debt (from PNEUMA DELTAS)

`litellm-secret` (ai-stack) and `grafana-admin` (monitoring) predate this setup and
exist only in-cluster. When convenient: export → re-author as `kubernetes/secrets/*.sops.yaml` → commit.

## Future: full KSOPS wiring (documented, not applied)

If ArgoCD is ever adopted into GitOps (or the drift risk is accepted): initContainer
`viaductoss/ksops:v4.5.1` (`ksops install /custom-tools`), mount `ksops` into
`/usr/local/bin/`, repo-server env `XDG_CONFIG_HOME=/.config` +
`SOPS_AGE_KEY_FILE=/.config/sops/age/keys.txt`, mount the existing `sops-age` Secret
at `/.config/sops/age`, and `argocd-cm` → `kustomize.buildOptions: "--enable-alpha-plugins --enable-exec"`;
SOPS-bearing apps then get a `kustomization.yaml` + KSOPS generator. (Verified against
KSOPS v4.5.1 README + ArgoCD 3.2 docs, 2026-08-14. Note v4.5.1 no longer copies its
own kustomize by default — ArgoCD's built-in is used.)
