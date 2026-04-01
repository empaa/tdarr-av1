# Test Suite Redesign

**Date:** 2026-04-01
**Status:** Approved

## Problem

The existing test suite has three structural problems:

1. **Dockerfile divergence.** Separate `Dockerfile.*.test` files existed alongside production `Dockerfile.tdarr` and `Dockerfile.tdarr_node`. Fixes had to be applied twice — once to the test files and once to production. This caused the Ubuntu 24.04 Python 3.10 compat bug to be discovered only during testing, not caught in the production Dockerfiles.

2. **Pre-built GHCR stack dependency.** Production `Dockerfile.tdarr` and `Dockerfile.tdarr_node` pulled the AV1 stack from `ghcr.io/empaa/av1-stack:latest`. This introduced a stale-image risk: tdarr could update its base OS (as it did, 22.04 → 24.04) while the published stack image lagged behind. The stack image is also no longer consumed by anyone other than these two Dockerfiles.

3. **Disconnected test scripts.** `test.sh` tested the stack image; `test-tdarr.sh` tested the tdarr images. They shared no Dockerfile and no stage, making it easy for them to drift apart.

## Design

### Single Dockerfile, Multiple Targets

One `Dockerfile` at the root replaces all five existing Dockerfiles:

```
base  (Ubuntu 24.04 + build tools + Rust)
 ├── build-svtav1       (independent)
 ├── build-libaom       (independent)
 ├── build-libvmaf      (independent)
 ├── build-vapoursynth  (zimg built inside; independent)
 ├── build-ffmpeg  ←── svtav1, libaom, libvmaf
 ├── build-lsmash  ←── vapoursynth, ffmpeg
 ├── build-av1an   ←── vapoursynth, ffmpeg
 └── build-ab-av1       (Rust only; independent)
          │
          ▼
      av1-stack   ← named target; all build-* stages merged into /usr/local
          │
          ├── tdarr       ← av1-stack layered onto ghcr.io/haveagitgat/tdarr
          └── tdarr_node  ← av1-stack layered onto ghcr.io/haveagitgat/tdarr_node
```

The `tdarr` and `tdarr_node` targets copy from `av1-stack`:
- `/usr/local` — all compiled binaries and libraries
- `/etc/vapoursynth` — VapourSynth plugin config
- `/usr/lib/python3.10` — Python 3.10 stdlib (absent on Ubuntu 24.04)

They also set `ENV PYTHONPATH=/usr/local/lib/python3.10/site-packages` and install `mkvtoolnix`.

**Deleted files:**
- `Dockerfile.stack`
- `Dockerfile.tdarr`
- `Dockerfile.tdarr_node`
- `Dockerfile.tdarr.test`
- `Dockerfile.tdarr_node.test`
- `test.sh`
- `build.sh`

### test-stack.sh

Builds the `av1-stack` target and validates it.

**Flags:**
- `--encode` — run actual encode tests against `test/samples/`
- `--all-platforms` — build and test both `linux/amd64` and `linux/arm64`
- `--clean` — remove cached `av1-stack:local` image(s) and wipe `test/output/stack/`

**Steps (default):**
1. `docker buildx build --target av1-stack --output type=docker,name=av1-stack:local`
2. Binary checks inside the container (`--entrypoint ""`): `av1an --version`, `ab-av1 --version`, `ffmpeg -version`

**With `--encode`:**
3. For each file in `test/samples/`, run a 60s clip encode with `av1an` (aom + svt-av1) and `ab-av1` inside the container
4. Verify output files exist and are non-empty; report failures

**With `--all-platforms`:**
- Steps 1–2 (and 3–4 if `--encode`) run for both `linux/amd64` and `linux/arm64`
- Images tagged `av1-stack:amd64` and `av1-stack:arm64`

Outputs land in `test/output/stack/`.

### test-tdarr.sh

Builds both `tdarr` and `tdarr_node` targets and validates them. Docker cache reuses `av1-stack` stages if already built by `test-stack.sh`.

**Flags:**
- `--encode` — run actual encode tests against `test/samples/`
- `--all-platforms` — build and test both `linux/amd64` and `linux/arm64`
- `--clean` — remove cached images and wipe `test/output/tdarr/` + `test/output/tdarr_node/`

**Steps (default):**
1. `docker buildx build --target tdarr --output type=docker,name=tdarr:local`
2. `docker buildx build --target tdarr_node --output type=docker,name=tdarr_node:local`
3. Binary checks on both images (`--entrypoint ""`): `av1an`, `ab-av1`, `ffmpeg`
4. Startup test:
   - Create a private bridge network
   - Start `tdarr:local` on the network; wait up to 30s for HTTP on port 8265
   - Start `tdarr_node:local` on the same network pointing at the server
   - Wait 10s; verify node container is still in `running` state
   - Unconditional cleanup of containers and network

**With `--encode`:**
5. Encode suite (same as `test-stack.sh`) run inside `tdarr:local` only — `tdarr_node:local` is not encode-tested separately since it shares the identical stack
6. Verify outputs in `test/output/tdarr/`

Outputs land in `test/output/tdarr/` and `test/output/tdarr_node/`.

### publish.sh

Builds and pushes `tdarr` and `tdarr_node` to GHCR. The `av1-stack` target is not published — it exists solely as a build stage and test target.

**Flags:**
- `--all-platforms` — build for both `linux/amd64` + `linux/arm64` (default: native arch only)

**Steps:**
1. `docker buildx build --target tdarr --push -t ghcr.io/empaa/tdarr:latest`
2. `docker buildx build --target tdarr_node --push -t ghcr.io/empaa/tdarr_node:latest`

With `--all-platforms`, adds `--platform linux/amd64,linux/arm64` to each build.

### Workflow

```bash
# Pre-merge (fast, native arch, no samples needed)
./test-stack.sh && ./test-tdarr.sh

# Pre-release (encode tests, requires sample files in test/samples/)
./test-stack.sh --encode && ./test-tdarr.sh --encode

# Release (publish to GHCR, both platforms)
./publish.sh --all-platforms
```

## Docs to Update

- `docs/constraints.md` — update Tdarr base OS from Ubuntu 22.04 → 24.04
- `docs/architecture.md` — update build stage graph, remove av1-stack GHCR distribution section
- `docs/build-and-publish.md` — replace all references to old scripts and workflow
