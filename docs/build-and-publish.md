# Build and Publish

Read this before any build, test, or GHCR publish work.

---

## Local test (run before merging)

```bash
./test.sh
```

Builds `Dockerfile.stack` for linux/amd64 and linux/arm64, runs binary version checks (`av1an`, `ab-av1`, `ffmpeg`) on both platforms. Must pass before opening a PR to `main`.

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

## Binary list

`test.sh` checks these binaries on both platforms. Current: `av1an`, `ab-av1`, `ffmpeg`. Update when new binaries are confirmed in `Dockerfile.stack`.
