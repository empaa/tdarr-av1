# Local Dual-Platform Testing Design

**Date:** 2026-03-31
**Status:** Approved

## Problem

The current setup gates merges to `main` via a GitHub Actions `test.yml` workflow that builds `Dockerfile.stack` for linux/amd64 and runs binary version checks. This is a redundant step — the developer already runs `test.sh` locally before opening a PR. The GHA test adds wait time and complexity without adding coverage, since it only tests amd64 while `publish.yml` builds both amd64 and arm64.

## Goal

Replace the GHA test gate with a local `test.sh` that covers both platforms (linux/amd64 and linux/arm64), giving confidence that the publish workflow will succeed on both architectures before merging.

## Design

### `test.sh` — loop over both platforms

Add `PLATFORMS=(linux/amd64 linux/arm64)` and iterate. For each platform:

1. Build `Dockerfile.stack` (target: `final`) for that platform via `docker buildx build`
2. Load the image into Docker with a platform-specific tag (e.g. `av1-stack-test:amd64`, `av1-stack-test:arm64`)
3. Run each binary in `BINARIES` with `docker run --rm --platform <plat> <image> <bin> --version`
4. Fail fast on first build failure; collect binary check failures within a platform and report at the end of that platform's run

Final success message: `All checks passed (linux/amd64, linux/arm64) — safe to merge`

### `.github/workflows/test.yml` — deleted

Remove entirely. No branch protection rule or status check depends on it.

### `docs/build-and-publish.md` — updated

- Remove `test.yml` row from the CI workflows table
- Update local test description: "Builds `Dockerfile.stack` for linux/amd64 and linux/arm64, runs binary version checks"
- Remove the "keep binary lists in sync" note (only one list exists now)
- Simplify merge workflow: run `./test.sh` locally → open PR → merge (no GHA wait step)

## Trade-offs

- Build time roughly doubles (two sequential platform builds instead of one), but this was already the developer's responsibility locally. The GHA test was not saving time, just duplicating it.
- arm64 build on Apple Silicon is native (fast); amd64 build runs via QEMU (slower but acceptable since only `--version` checks are needed, not encode runs).

## Out of scope

- `publish.yml` is unchanged — it continues to build and push both platforms on merge to `main`
- No changes to `build.sh`
- No changes to `Dockerfile.stack` or any Dockerfile
