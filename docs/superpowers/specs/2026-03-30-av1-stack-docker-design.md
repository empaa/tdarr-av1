# AV1 Stack Docker Image Design

**Date:** 2026-03-30
**Status:** Approved

## Goal

Produce two Docker images that extend the official Tdarr images with a native AV1 encoding stack (av1an + ab-av1 + all dependencies), publishable to GHCR and usable directly via `docker pull` / `docker run`.

The previous approach used a separately-built binary bundle injected into the official containers at runtime via shell wrappers and `LD_LIBRARY_PATH`. This project replaces that with stack components properly installed inside the images.

---

## Images

| Image | Base | Role |
|---|---|---|
| `ghcr.io/empaa/av1-stack:latest` | Ubuntu (matched to Tdarr's OS — see Risk below) | Compiled AV1 stack installed at `/usr/local`. Not a runnable container; used as a `COPY --from` source. |
| `ghcr.io/empaa/tdarr:latest` | `ghcr.io/haveagitgat/tdarr:latest` | Tdarr server with AV1 stack layered in. |
| `ghcr.io/empaa/tdarr_node:latest` | `ghcr.io/haveagitgat/tdarr_node:latest` | Tdarr node with AV1 stack layered in. |

The Tdarr images always use `latest` as their base, picking up Tdarr upstream releases automatically via the weekly CI build.

---

## AV1 Stack Components

All components are built from source. Versions are pinned and documented in `docs/constraints.md` as decisions are made.

| Component | Version | Notes |
|---|---|---|
| SVT-AV1 | 3.1.2 | v3.0+ broke API; FFmpeg 8.0.1 required for compatibility |
| libaom | 3.12.1 | |
| libvmaf | 3.0.0 | Built with `built_in_models=true`; models also copied to `/usr/local/share/vmaf` |
| zimg | 3.0.5 | VapourSynth dependency |
| VapourSynth | R72 | **Must be exactly R72.** R73 removed VSScript API v3 which av1an requires. |
| L-SMASH-Works | master | VapourSynth plugin; enables fast lsmash chunk method in av1an |
| FFmpeg | 8.0.1 | Built with `--enable-libsvtav1 --enable-libaom --enable-libvmaf` |
| av1an | 0.5.2 | Requires `patches/av1an-vmaf.py` patch (fixes inverted VMAF model path logic) |
| ab-av1 | 0.10.3 | |
| mkvmerge | system apt | From mkvtoolnix package |

**Installation layout:** All components install to `/usr/local` (bins → `/usr/local/bin`, libs → `/usr/local/lib`, models → `/usr/local/share/vmaf`). `ldconfig` is run after installation. VapourSynth's system plugin directory is set to `/usr/local/lib/vapoursynth` by writing `/etc/vapoursynth/vapoursynth.conf` with `SystemPluginDir=/usr/local/lib/vapoursynth` in the `final` stage.

**ffmpeg shadowing:** Our ffmpeg at `/usr/local/bin/ffmpeg` takes precedence over Tdarr's system ffmpeg at `/usr/bin/ffmpeg` via standard `$PATH` ordering. No wrappers or `LD_LIBRARY_PATH` manipulation needed.

---

## Repository Structure

```
Dockerfile.stack              # Multi-stage: compiles entire AV1 stack
Dockerfile.tdarr              # FROM tdarr:latest + COPY from av1-stack + ldconfig
Dockerfile.tdarr_node         # FROM tdarr_node:latest + COPY from av1-stack + ldconfig
patches/
  av1an-vmaf.py               # Fixes inverted VMAF model path logic in av1an vmaf.rs
build.sh                      # Local build script (fast and full modes)
.github/workflows/
  build-stack.yml             # Publish av1-stack to GHCR
  build-tdarr.yml             # Publish tdarr and tdarr_node to GHCR
docs/
  constraints.md              # Version constraints with rationale
  architecture.md             # Architecture decisions as the project is built
  build-and-publish.md        # Build commands, GHCR auth, tagging strategy
```

---

## Dockerfile.stack — Build Stage Graph

```
base (Ubuntu + build tools + Rust toolchain)
 ├── build-svtav1       (independent)
 ├── build-libaom       (independent)
 ├── build-libvmaf      (independent)
 ├── build-vapoursynth  (includes zimg; independent)
 │        │
 ├── build-ffmpeg  ←── svtav1, libaom, libvmaf
 │        │
 ├── build-lsmash  ←── vapoursynth, ffmpeg
 ├── build-av1an   ←── vapoursynth, ffmpeg  (applies av1an-vmaf.py patch)
 └── build-ab-av1       (Rust only; independent)
          │
          ▼
       final  ←── all build-* stages
  (copies to /usr/local, ldconfig, vapoursynth conf, vmaf models)
```

BuildKit runs independent stages in parallel automatically.

---

## Tdarr Dockerfiles

Both Tdarr Dockerfiles follow the same minimal pattern:

```dockerfile
FROM ghcr.io/haveagitgat/tdarr:latest          # or tdarr_node
COPY --from=ghcr.io/empaa/av1-stack:latest /usr/local /usr/local
RUN ldconfig
```

---

## CI/CD

### `build-stack.yml`

- **Triggers:** `workflow_dispatch`, or push to `Dockerfile.stack` or `patches/`
- **What it does:** Builds and pushes `ghcr.io/empaa/av1-stack:latest`
- **Duration:** ~40 min cold; faster on cache hits
- **Caching:** `cache-from/cache-to: type=gha` to cache individual build stages
- **Auth:** `GITHUB_TOKEN` with `packages: write` (automatic)

### `build-tdarr.yml`

- **Triggers:** `workflow_dispatch`, push to `Dockerfile.tdarr` or `Dockerfile.tdarr_node`
- **What it does:** Pulls `av1-stack:latest` from GHCR; builds and pushes `tdarr:latest` and `tdarr_node:latest`
- **Duration:** ~5 min (no recompilation)
- **Auth:** `GITHUB_TOKEN` with `packages: write`

---

## Local Build Script

```
./build.sh                  # Pull av1-stack from GHCR, build tdarr images locally (~5 min)
./build.sh --build-stack    # Compile av1-stack from scratch, then build tdarr images (~45 min)
```

The fast path is the default — used for iterating on Tdarr Dockerfile changes. `--build-stack` is used when updating component versions or the stack build itself.

Local GHCR auth requires a Personal Access Token with `write:packages`. Documented in `docs/build-and-publish.md`.

---

## Key Implementation Risk

**Base OS glibc compatibility.** The compiled `.so` files reference glibc symbols from the OS they are built on. If the av1-stack build base is newer than Tdarr's base OS, the libraries will fail at runtime with symbol-not-found errors.

**First implementation step:** Run `docker run --rm ghcr.io/haveagitgat/tdarr cat /etc/os-release` to determine Tdarr's base OS. Set the av1-stack build base to match exactly. Record the result in `docs/constraints.md`.
