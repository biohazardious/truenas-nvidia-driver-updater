# TrueNAS NVIDIA Driver Updater

Build and deploy **any** NVIDIA driver as a `systemd-sysext` image (`nvidia.raw`) for **TrueNAS 25/26** — fully automated via Docker.

TrueNAS ships with a specific NVIDIA driver version baked into its immutable root filesystem. This tool lets you compile and package a different driver version (newer or older) without modifying the base OS, using the `systemd-sysext` overlay mechanism that TrueNAS natively supports.

---

## Features

- **Fully automated** — downloads TrueNAS update file, extracts kernel headers, compiles the driver, packages everything
- **TrueNAS 25/26 aware** — supports 25.x codename-based downloads and TrueNAS 26 update URLs
- **Production-kernel aware** — correctly selects the production kernel over debug variants
- **Complete module database** — ships a combined `modules.dep` covering all system + NVIDIA modules (no `depmod -a` needed on read-only target)
- **nvidia-container-toolkit included** — Docker GPU passthrough works out of the box
- **Optional update repack** — can also emit a rebuilt `truenas.update` with the new `nvidia.raw` embedded
- **Before/after filesystem diff** — captures 100% of NVIDIA installer output, no fragile glob patterns
- **Backup & rollback** — deployment script preserves previous images with timestamps
- **Auto sysext diagnostics** — deployment script prints host/image metadata when `systemd-sysext merge` rejects the image

## Quick Start

### 1. Configure

Edit `docker-compose.yaml` with your target versions:

```yaml
environment:
  - NVIDIA_VERSION=590.44.01       # NVIDIA driver version
  - NVIDIA_KERNEL_MODULE_TYPE=open # open or proprietary
  - NVIDIA_BUILD_CC=               # optional: gcc / gcc-14 / other compiler in PATH
  - TRUENAS_VERSION=26.0.0-BETA.1  # TrueNAS version
  - TRUENAS_CODENAME=              # Required for 25.x and earlier only
  - EMBED_NVIDIA_RAW_IN_UPDATE=false  # also emit a rebuilt truenas.update when true
```

### 2. Build

```bash
docker compose build
docker compose run --rm nvidia-builder
```

The build takes ~10-15 minutes (mostly kernel module compilation). By default artifacts are grouped under `./output/<TRUENAS_VERSION>/`.

If `EMBED_NVIDIA_RAW_IN_UPDATE=true`, the build will also unpack the source `truenas.update`, replace the bundled `/usr/share/truenas/sysext-extensions/nvidia.raw`, and write a new `.update` image to `./output/`.

For each generated artifact, the script also writes a sibling `.sha256` file containing the raw SHA256 hash only:

- `./output/<TRUENAS_VERSION>/nvidia.raw.sha256`
- `./output/<TRUENAS_VERSION>/<official update filename>.sha256` (when repack is enabled)

Output naming follows the TrueNAS version:

| TrueNAS version | Output directory | Update filename |
|---|---|---|
| `26.0.0-BETA.1` | `output/26.0.0-BETA.1/` | `TrueNAS-26.0.0-BETA.1.update` |
| `25.10.3` | `output/25.10.3/` | `TrueNAS-SCALE-25.10.3.update` |

`NVIDIA_KERNEL_MODULE_TYPE` is passed through to the NVIDIA installer as `--kernel-module-type=<value>`.

| Value | When to use | Notes |
|-------|-------------|-------|
| `open` | Default choice for most newer GPUs and current TrueNAS releases | Best starting point for Turing / Ampere / Ada / newer platforms |
| `proprietary` | If the open modules fail to build, fail to load, or are known to be unsupported for your hardware/workload | Uses the legacy closed-source kernel modules shipped by NVIDIA |

`NVIDIA_BUILD_CC` lets you override the compiler used for the NVIDIA kernel module build:

- leave it empty to auto-detect a suitable compiler
- set `NVIDIA_BUILD_CC=gcc` to force the default compiler
- set `NVIDIA_BUILD_CC=gcc-14` to force GCC 14 for newer TrueNAS kernels

### 3. Deploy to TrueNAS

Copy the generated `output/<TRUENAS_VERSION>/nvidia.raw` and `deploy-nvidia.sh` to your TrueNAS system, then:

```bash
chmod +x deploy-nvidia.sh
./deploy-nvidia.sh nvidia.raw
```

The deploy script handles everything:
- Unmerges active sysext extensions
- Unlocks the read-only `/usr` ZFS dataset
- Backs up the existing `nvidia.raw` (timestamped)
- Installs the new image
- Re-locks the dataset and merges extensions
- If the merge fails, prints `systemd-sysext` compatibility diagnostics automatically

### 4. Verify

```bash
nvidia-smi
```

---

## TrueNAS Version Reference

| TrueNAS Version | Codename     |
|------------------------|--------------|
| 26.x                   | not used     |
| 25.10.x                | Goldeye      |
| 25.04.x                | Fangtooth    |
| 24.10.x                | Electric Eel |
| 24.04.x                | Dragonfish   |
| 23.10.x                | Cobia        |

> `TRUENAS_CODENAME` is only needed for 25.x and earlier download URLs. For TrueNAS 26+, leave it empty.

---

## How It Works

```
┌─────────────────────────────────────────────────────────┐
│                   Docker Build Container                │
│                                                         │
│  1. Load local truenas.update or download one           │
│  2. Extract nested rootfs → kernel headers + modules    │
│  3. Detect the production kernel and matching headers   │
│  4. Download the NVIDIA .run installer                  │
│  5. Take a BEFORE snapshot of /usr and /etc             │
│  6. Install toolkit deps + compile NVIDIA modules       │
│  7. Take an AFTER snapshot and diff new files           │
│  8. Stage runtime files into the sysext tree            │
│  9. Build combined modules.dep (system + nvidia)        │
│ 10. Write extension-release metadata                    │
│ 11. Package nvidia.raw and write nvidia.raw.sha256      │
│ 12. Optional: replace bundled nvidia.raw in             │
│      truenas.update, rebuild MANIFEST, and emit         │
│      a new .update plus .update.sha256                  │
└─────────────────────────────────────────────────────────┘
```

### Why systemd-sysext?

TrueNAS 25/26 uses an immutable root filesystem. `systemd-sysext` provides a supported overlay mechanism that merges the contents of `/usr` from extension images on top of the base OS — without modifying it. This means:

- **Survives reboots** — extensions are re-merged on boot
- **Survives updates** — rebuild `nvidia.raw` with new kernel headers after a TrueNAS update
- **Clean rollback** — `systemd-sysext unmerge` restores the original state

### Key Technical Decisions

| Decision | Rationale |
|----------|-----------|
| `--kernel-module-type=open` | Uses the open GPU kernel modules; this is the recommended default here and avoids `MITIGATION_RETHUNK` / naked-return hard errors on hardened TrueNAS kernels for many modern GPUs |
| Auto-detect `gcc` / `gcc-14` with optional `NVIDIA_BUILD_CC` override | Newer TrueNAS kernels may require GCC 14-only module build flags, while older driver/kernel combinations may still benefit from forcing a specific compiler |
| `--no-drm` | TrueNAS kernel lacks `drm_fbdev_ttm_driver_fbdev_probe`, causing `nvidia-drm.ko` to fail with "Unknown symbol". DRM/KMS is for display output — irrelevant on a headless NAS |
| Production kernel preference | TrueNAS ships both debug and production kernels; the production kernel is what actually boots. Alphabetical sorting would pick the wrong one |
| Combined `modules.dep` | The sysext's `modules.dep` overlays the system's via overlayfs. Shipping an nvidia-only `modules.dep` would make all other kernel modules (nf_tables, bridge, etc.) invisible, breaking Docker and networking |
| `extension-release.nvidia` → `ID=_any` | Matches TrueNAS's own sysext packaging behavior and avoids host-version compatibility rejection during `systemd-sysext merge` |
| Write sibling `.sha256` files for generated artifacts | Keeps `nvidia.raw` and optional `.update` outputs easy to verify in simple release directories and mirrors the user's existing artifact layout |
| Rebuild `MANIFEST` checksums when repacking `truenas.update` | Replacing the bundled `nvidia.raw` changes `rootfs.squashfs`; the update manifest must be rewritten or TrueNAS rejects the repacked `.update` |
| gzip compression | Matches TrueNAS's own squashfs convention for consistent image sizes |

---

## Advanced Usage

### Common Build Variants

**Use a pre-downloaded update file** to avoid re-downloading the ~1.8 GB TrueNAS update on every build:

```bash
# Download once
wget -O truenas.update "https://update-public.sys.truenas.net/TrueNAS-26-BETA/TrueNAS-26.0.0-BETA.1.update"

# Build — the script detects the local file and skips download
docker compose run --rm nvidia-builder
```

**Also generate an updated `truenas.update`** with the new `nvidia.raw` embedded:

```bash
docker compose run --rm \
  -e EMBED_NVIDIA_RAW_IN_UPDATE=true \
  nvidia-builder
```

This still generates the standalone `nvidia.raw`, and additionally writes:

- `output/<TRUENAS_VERSION>/<official update filename>`
- `output/<TRUENAS_VERSION>/<official update filename>.sha256`

### When `systemd-sysext` Rejects the Image

If deployment fails with an error such as:

```text
No suitable extensions found (1 ignored due to incompatible image(s)).
```

re-run the normal deploy command:

```bash
./deploy-nvidia.sh output/<TRUENAS_VERSION>/nvidia.raw
```

The script now prints:

- host `/usr/lib/os-release`
- embedded `usr/lib/extension-release.d/extension-release.nvidia`
- `systemd-sysext status`
- `SYSTEMD_LOG_LEVEL=debug systemd-sysext refresh`

### After a TrueNAS Update

When TrueNAS updates its kernel, you need to rebuild:

1. Update `TRUENAS_VERSION` in `docker-compose.yaml`
2. Remove any cached `truenas.update` file
3. Run `docker compose build && docker compose run --rm nvidia-builder`
4. Deploy the new `nvidia.raw`

### Rollback to Previous Driver

The deploy script saves backups in a `backups/` directory alongside itself (keeps the 5 most recent):

```bash
# List available backups
ls -la backups/

# Rollback
./deploy-nvidia.sh backups/nvidia.raw.backup_20260422_160428
```

---

## File Structure

```
.
├── Dockerfile              # Debian 12 build container
├── docker-compose.yaml     # Build configuration (versions here)
├── entrypoint.sh           # Main build script
├── deploy-nvidia.sh        # TrueNAS deployment script
├── output/                 # Build outputs organized by TrueNAS version
├── backups/                # Previous nvidia.raw backups (auto-managed)
├── LICENSE
└── README.md
```

## Requirements

- **Build machine**: Docker with `docker compose`
- **TrueNAS**: 24.04+ / 25.x / 26.x (systemd-sysext support)
- **GPU**: Any NVIDIA GPU supported by the target driver version

## Troubleshooting

### `nvidia-smi` fails with "couldn't communicate with the NVIDIA driver"

The kernel modules were compiled for the wrong kernel version. Verify with:
```bash
uname -r                    # running kernel
modinfo nvidia | grep vermagic  # module's target kernel
```
These must match. Rebuild with the correct `TRUENAS_VERSION`.

### Docker fails with "iptables: Failed to initialize nft"

The sysext's `modules.dep` is overriding the system's module database. This was a bug in early versions — ensure you're using the latest build script which ships a combined `modules.dep`.

### Docker warns "nvidia-container-runtime: no such file or directory"

The `nvidia-container-toolkit` package is missing from the sysext. Ensure you're using the latest build script which installs it via apt.

---

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgments

- Inspired by the official [TrueNAS SCALE extension build system](https://github.com/truenas/scale-build)
- NVIDIA driver installer from [NVIDIA's official download site](https://www.nvidia.com/Download/index.aspx)
- nvidia-container-toolkit from [NVIDIA's container toolkit repo](https://github.com/NVIDIA/nvidia-container-toolkit)
