# Build and Publish

Read this before any build, test, or GHCR publish work.

---

## Quick reference

| Command | What it does |
|---|---|
| `./build.sh` | Build + test, native arch |
| `./build.sh --all-platforms` | Build + test, amd64 + arm64 |
| `./build.sh --arm64` | Build + test, arm64 only |
| `./build.sh --amd64` | Build + test, amd64 only |
| `./build.sh --encode` | Build + test with encode tests (needs samples) |
| `./build.sh --stack-only` | Build + test av1-stack only (fast feedback) |
| `./build.sh --publish` | Push previously tested images to GHCR |
| `./build.sh --all-platforms --publish` | Build + test + publish (one shot) |
| `./build.sh --clean` | Remove images + test output, stop builder |
| `./build.sh --clean-cache` | Same as --clean + prune buildx cache |

Platform flags (`--all-platforms`, `--arm64`, `--amd64`) are mutually exclusive.
Omitting all three defaults to native architecture.

## How publishing works

Images are built into the local Docker daemon during testing. Publishing retags
and pushes those exact images — no rebuild. This guarantees what you tested is
what you ship.

**Typical two-step workflow:**
```bash
./build.sh --all-platforms          # build + test
./build.sh --publish --all-platforms  # push (no rebuild)
```

**One-shot workflow:**
```bash
./build.sh --all-platforms --publish  # build + test + publish
```

For multi-platform publishes, arch-specific images are pushed first, then a
manifest list is created for the `:latest` tag.

## One-time setup per machine

1. Create a PAT at GitHub → Settings → Developer settings → Personal access tokens (classic) with `write:packages` scope, then:
```bash
echo <TOKEN> | docker login ghcr.io -u <your-github-username> --password-stdin
```

2. The buildx builder is auto-created on first run. To create it manually:
```bash
docker buildx create --name multiplatform --driver docker-container --use
```

## Encode tests

Place sample video files (>= 2 min long) in `test/samples/` before running with
`--encode`. Outputs land in `test/output/stack/` or `test/output/tdarr/` for
inspection.

## Platform notes

On M1 Mac: arm64 compiles natively, amd64 via Rosetta/QEMU (reliable).
On Intel/AMD Linux: arm64 uses QEMU and may segfault on the SVT-AV1 compile.

## Branching strategy

All development uses feature branches merged with `--no-ff` (merge commits):

```
main ──────────────●──────────────●──── (stable, release-ready)
                  ╱              ╱
dev ────●────●───●────●────●───●────── (integration branch)
       ╱    ╱              ╱
      feature/a       feature/b
```

1. Branch `feature/xyz` from `dev` for any new feature or significant change
2. Work and commit on the feature branch
3. Merge to `dev`: `git merge --no-ff feature/xyz`
4. To revert a feature later: `git revert -m 1 <merge-commit>`

Small fixes (typos, single-line changes) can commit directly to `dev`.

## Merge workflow

1. Run `./build.sh` locally — must pass
2. Create PR from `dev` to `main`
3. Merge using **"Create a merge commit"** (not squash, not rebase)

Do not squash merge — it creates divergent histories between dev and main,
causing conflicts on every subsequent PR.

## Release workflow

1. Run `./build.sh --all-platforms --encode` locally — must pass (requires sample files)
2. Merge `dev` → `main` via PR (merge commit, not squash)
3. Run `./build.sh --publish --all-platforms` — pushes tested images to GHCR

## Binary list

`build.sh` checks these binaries: `av1an`, `ab-av1`, `ffmpeg`.
Update the `BINARIES` array in `build.sh` when new binaries are added to `Dockerfile`.
