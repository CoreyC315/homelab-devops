# Runbook: Enable VAAPI Hardware Transcoding for Jellyfin

**Status:** Planned (not yet executed)
**Goal:** Move Jellyfin transcoding off the CPU (~6 cores → <1 core) onto the aether Vega iGPU via VAAPI.

## Background

Jellyfin (`jellyfin:10.11.8`, namespace `default`) is pinned to **aether-worker** (VM 112,
`192.168.1.212`) and currently does **pure software transcoding** — caught pulling ~6 of 8 cores.

- Config confirms `HardwareAccelerationType = none`, `EncodingThreadCount = -1` (uncapped).
- The aether *host* has an **AMD Vega / Cezanne iGPU** (`04:00.0`, device id `1002:1638`,
  `/dev/dri/renderD128` present on host), IOMMU/AMD-Vi enabled — but **not passed through** to VM 112.
- The GPU function `04:00.0` is **alone in IOMMU group 12** (isolated from the USB/audio functions),
  so we can pass through only the GPU — no ACS-override hacks.
- ⚠️ aether also hosts the **k0s control-plane master (VM 201)** since raiden died, so a host
  reboot briefly takes down the control plane (running workloads stay up).

**Disruption:** one reboot of the aether host. Run when people are off Jellyfin and a brief
control-plane blip is acceptable.

**Limitation:** Cezanne does H.264/HEVC encode/decode but **no AV1 encode** — fine for anime/dub streams.

---

## Phase 0 — Pre-flight (non-disruptive)

1. Confirm no active streams (Jellyfin Dashboard → Activity).
2. Record rollback state:
   ```bash
   ssh root@aether 'qm config 112 > /root/vm112-pre-gpu.conf; lspci -nnk -s 04:00.0'
   ```

## Phase 1 — Bind the iGPU to vfio on the host (disruptive: host reboot)

1. Enable vfio modules — append to `/etc/modules`:
   ```
   vfio
   vfio_iommu_type1
   vfio_pci
   ```
   *Why:* kernel modules that let a physical PCI device be handed to a guest VM.

2. Claim the GPU for vfio and keep `amdgpu` off it — create `/etc/modprobe.d/vfio.conf`:
   ```
   options vfio-pci ids=1002:1638
   softdep amdgpu pre: vfio-pci
   ```
   *Why:* binds the Vega GPU (`1002:1638`) to `vfio-pci` before `amdgpu` grabs it. aether is
   headless so the host doesn't need the GPU. The audio function is id `1637` (untouched).

3. `update-initramfs -u -k all`

4. **Reboot aether.** ⚠️ VM 112 (worker) and VM 201 (master) both go down briefly.

5. Verify: `lspci -nnk -s 04:00.0` → `Kernel driver in use: vfio-pci`.

**Rollback:** remove `/etc/modprobe.d/vfio.conf` + the `/etc/modules` lines, `update-initramfs -u`, reboot.

## Phase 2 — Attach the GPU to the worker VM

1. Switch VM 112 to q35 (needed for PCIe passthrough):
   ```bash
   qm set 112 -machine q35
   ```
   *Why:* i440fx can't do clean PCIe passthrough. Safe for this virtio Linux guest (virtio-scsi
   disks, virtio NIC with static cloud-init IP). Rollback: `qm set 112 -machine i440fx`.

2. Attach only the GPU function:
   ```bash
   qm set 112 -hostpci0 0000:04:00.0,pcie=1
   ```

3. Protect from Terraform drift — add `hostpci` and `machine` to `lifecycle.ignore_changes` on
   `proxmox_vm_qemu.k0s_worker_aether` in `terraform/virtual-machines.tf`.
   *Why:* the Telmate provider is destructive/buggy with these fields (see
   terraform-proxmox-provider-gotchas); manage out-of-band and ignore drift to avoid a
   destroy+recreate of the worker.

4. Start VM 112 and verify in-guest:
   ```bash
   ls -l /dev/dri          # expect card0 + renderD128
   getent group render video   # note the render gid for Phase 3
   ```

## Phase 3 — Expose /dev/dri to the Jellyfin pod (GitOps)

Edit `kubernetes/apps/jellyfin/deployment.yaml`:

- Add a `hostPath` volume for `/dev/dri` + a `volumeMount` at `/dev/dri`.
- Add `securityContext.supplementalGroups: [<render-gid>, <video-gid>]` (gids from Phase 2 step 4).

*Why:* the container needs the device node and group membership to open `renderD128`. Jellyfin is
already pinned to aether-worker, so a plain hostPath is the simplest correct approach (no device
plugin). Commit → ArgoCD auto-syncs → pod restarts with the GPU.

## Phase 4 — Enable VAAPI in Jellyfin and verify

1. Dashboard → Playback → **Hardware acceleration = VAAPI** (device `/dev/dri/renderD128` already
   pre-filled). Enable H.264/HEVC decode + encode.
2. Force a transcode and confirm:
   - Playback dashboard shows **"Transcoding (hardware)"**.
   - `kubectl top pod -n default | grep jellyfin` drops from ~6000m to a few hundred m.

---

## Optional cheap wins (no infra change)

- Cap `EncodingThreadCount` (e.g. 4) so one transcode can't peg the node / starve the master VM.
- Favor direct play: text subs (SRT/ASS from subgen) direct-play; image/PGS subs force burn-in re-encode.
- Lower per-user max streaming bitrate so remote clients request lighter transcodes.
