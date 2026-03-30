# Build and Publish

Read this before any build, test, or GHCR publish work.

This file is populated as the build and publish workflow is established.

---

## GHCR Authentication (Local Builds)

To push images to GHCR from your machine:

1. Create a Personal Access Token at GitHub → Settings → Developer settings →
   Personal access tokens → Tokens (classic). Scopes needed: `write:packages`,
   `read:packages`, `delete:packages`.
2. Log in:
   ```bash
   echo <TOKEN> | docker login ghcr.io -u <your-github-username> --password-stdin
   ```

## Building and Publishing Locally

**Fast path** (reuses published av1-stack, only rebuilds Tdarr images, ~5 min):
```bash
./build.sh
docker push ghcr.io/empaa/tdarr:latest
docker push ghcr.io/empaa/tdarr_node:latest
```

**Full rebuild** (recompiles entire AV1 stack from source, ~45 min):
```bash
./build.sh --build-stack
docker push ghcr.io/empaa/av1-stack:latest
docker push ghcr.io/empaa/tdarr:latest
docker push ghcr.io/empaa/tdarr_node:latest
```

## CI Workflows

| Workflow | Trigger | What it builds | Duration |
|---|---|---|---|
| `build-stack.yml` | Push to `Dockerfile.stack` or `patches/**`, or manual dispatch | `ghcr.io/empaa/av1-stack:latest` | ~40 min cold, faster with GHA cache |
| `build-tdarr.yml` | Push to `Dockerfile.tdarr` or `Dockerfile.tdarr_node`, or manual dispatch | `tdarr:latest` and `tdarr_node:latest` | ~5 min |

Both workflows use `cache-from/cache-to: type=gha` so BuildKit stages are cached
between runs. The stack build in particular benefits significantly — individual
component stages are cached independently.
