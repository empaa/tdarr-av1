# Build and Publish

Read this before any build, test, or GHCR publish work.

---

## Local test

**Pre-merge** — builds from source, runs binary version checks (native arch):
```bash
./test-stack.sh && ./test-tdarr.sh
```

**Pre-release** — binary checks + real encode tests against `test/samples/`:
```bash
./test-stack.sh --encode && ./test-tdarr.sh --encode
```

Place sample video files (≥2 min long) in `test/samples/` before running.
Outputs land in `test/output/stack/` and `test/output/tdarr/` for inspection.

**Both platforms:**
```bash
./test-stack.sh --all-platforms && ./test-tdarr.sh --all-platforms
```

**Cache management:**
```bash
./test-stack.sh --clean
./test-tdarr.sh --clean
```

## Publish to GHCR

Builds and pushes `tdarr` and `tdarr_node` to GHCR. The `av1-stack` stage is
compiled as part of the build but not published.

**One-time setup per machine:**

1. Create a PAT at GitHub → Settings → Developer settings → Personal access tokens (classic) with `write:packages` scope, then:
```bash
echo <TOKEN> | docker login ghcr.io -u <your-github-username> --password-stdin
```

2. Create the multi-platform buildx builder (persists across sessions):
```bash
docker buildx create --name multiplatform --driver docker-container --use
```

**Publish (native arch only):**
```bash
./publish.sh
```

**Publish (both platforms — run from M1 Mac for best results):**
```bash
./publish.sh --all-platforms
```

On M1 Mac: arm64 compiles natively, amd64 via Rosetta/QEMU (reliable).
On Intel/AMD Linux: arm64 uses QEMU and may segfault on the SVT-AV1 compile.

## Merge workflow

1. Run `./test-stack.sh && ./test-tdarr.sh` locally — must pass
2. Open PR from `dev` to `main`
3. Merge

## Release workflow

1. Run `./test-stack.sh --encode && ./test-tdarr.sh --encode` locally — must pass (requires sample files in `test/samples/`)
2. Merge `dev` → `main`
3. Run `./publish.sh --all-platforms` — builds and pushes to GHCR (~45 min from Mac)

## Binary list

`test-stack.sh` and `test-tdarr.sh` check these binaries: `av1an`, `ab-av1`, `ffmpeg`.
Update when new binaries are added to `Dockerfile`.
