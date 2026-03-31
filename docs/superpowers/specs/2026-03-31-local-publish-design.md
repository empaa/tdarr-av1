# Local Publish Design

**Date:** 2026-03-31
**Status:** Approved

## Problem

The GitHub Actions `publish.yml` workflow builds multi-platform Docker images (amd64 + arm64) using QEMU emulation on free GitHub runners. After ~2 hours, the SVT-AV1 compile crashes with exit code 139 (segfault) — a known QEMU reliability issue with heavy C++ compilation on arm64.

## Decision

Replace CI-triggered builds with a local `publish.sh` script. Releases are published manually from the developer's machine (M1 MacBook preferred — arm64 native, amd64 via Rosetta/QEMU which is significantly more reliable than the reverse).

## What Changes

### Delete
- `.github/workflows/publish.yml` — CI no longer builds or publishes on merge to `main`

### Add
- `publish.sh` — local multi-platform build + push to GHCR

### Update
- `docs/build-and-publish.md` — replace CI merge workflow with local publish command

## `publish.sh` Behaviour

- Uses `docker buildx` with `--platform linux/amd64,linux/arm64 --push`
- Always builds the full stack from source (no fast-path pull — this is a real release)
- Build order: `av1-stack` → `tdarr` + `tdarr_node`
- Fails early with a helpful message if not logged in to GHCR
- Tags all images `:latest`

## Release Workflow (After This Change)

1. Run `./test.sh --release` locally — must pass
2. Merge `dev` → `main` (no CI build fires)
3. Run `./publish.sh` — builds multi-platform, pushes to GHCR (~45 min from Mac)

## Secrets / Public Repo

No secrets in `publish.sh`. Registry name (`ghcr.io/empaa`) is already public in `build.sh`. GHCR authentication is done separately via `docker login ghcr.io` using a PAT — never stored in the script.

## Fallback

If building from the Linux machine, arm64 still goes through QEMU and may hit the same segfault. Preferred solution: build from the M1 Mac. If that's not possible, build amd64 only on Linux and arm64 on the Mac, then merge manifests manually (out of scope for this change).
