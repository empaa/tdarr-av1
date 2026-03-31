# Build and Publish

Read this before any build, test, or GHCR publish work.

---

## Local test

**Pre-merge** — builds both platforms, runs binary version checks:
```bash
./test.sh
```

**Pre-release** — binary checks (native platform only) + real encode tests against `test/samples/`:
```bash
./test.sh --release
```

Place sample video files (≥2 min long) in `test/samples/` before running. Outputs land in `test/output/` for inspection.

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

To push manually to GHCR, create a PAT at GitHub → Settings → Developer settings → Personal access tokens (classic) with `write:packages` scope, then:
```bash
echo <TOKEN> | docker login ghcr.io -u <your-github-username> --password-stdin
```

## CI workflows

| Workflow | Trigger | What it does |
|---|---|---|
| `publish.yml` | Push to `main` | Builds and pushes av1-stack, then tdarr + tdarr_node (amd64+arm64) to GHCR |

## Merge workflow

1. Run `./test.sh` locally — must pass
2. Open PR from `dev` to `main`
3. Merge — `publish.yml` fires automatically

## Release workflow

1. Run `./test.sh --release` locally — must pass (requires sample files in `test/samples/`)
2. Merge to `main` — `publish.yml` publishes to GHCR

## Binary list

`test.sh` checks these binaries on both platforms. Current: `av1an`, `ab-av1`, `ffmpeg`. Update when new binaries are confirmed in `Dockerfile.stack`.
