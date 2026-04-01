# Build and Publish

Read this before any build, test, or GHCR publish work.

---

## Local test

**Pre-merge** — builds both platforms, runs binary version checks:
```bash
./test.sh && ./test-tdarr.sh
```

**Pre-release** — binary checks (native platform only) + real encode tests against `test/samples/`:
```bash
./test.sh --release && ./test-tdarr.sh --release
```

Place sample video files (≥2 min long) in `test/samples/` before running. Outputs land in `test/output/stack/` (av1-stack), `test/output/tdarr/`, and `test/output/tdarr_node/` for inspection.

**Cache management:**
```bash
./test.sh --clean                 # remove cached images + wipe test/output/
./test.sh --release --clean       # clean then do a full release test run
```

## Local builds (manual)

**Fast path** — reuses published av1-stack, only rebuilds Tdarr images (~5 min):
```bash
./build.sh
```

**Full rebuild** — recompiles entire AV1 stack from source (~45 min):
```bash
./build.sh --build-stack
```

## Publish to GHCR

Builds multi-platform images (linux/amd64 + linux/arm64) and pushes them to GHCR.
Run this from the M1 Mac — arm64 compiles natively, amd64 via Rosetta/QEMU (reliable).
On Intel/AMD Linux, arm64 still uses QEMU and may segfault on the SVT-AV1 compile.

**One-time setup per machine:**

1. Create a PAT at GitHub → Settings → Developer settings → Personal access tokens (classic) with `write:packages` scope, then:
```bash
echo <TOKEN> | docker login ghcr.io -u <your-github-username> --password-stdin
```

2. Create the multi-platform buildx builder (persists across sessions):
```bash
docker buildx create --name multiplatform --driver docker-container --use
```

**Publish:**
```bash
./publish.sh
```

## Merge workflow

1. Run `./test.sh && ./test-tdarr.sh` locally — must pass
2. Open PR from `dev` to `main`
3. Merge

## Release workflow

1. Run `./test.sh --release && ./test-tdarr.sh --release` locally — must pass (requires sample files in `test/samples/`)
2. Merge `dev` → `main`
3. Run `./publish.sh` — builds and pushes to GHCR (~45 min from Mac)

## Binary list

`test.sh` checks these binaries on both platforms. Current: `av1an`, `ab-av1`, `ffmpeg`. Update when new binaries are confirmed in `Dockerfile.stack`.
