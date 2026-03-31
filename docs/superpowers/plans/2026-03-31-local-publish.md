# Local Publish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the broken GitHub Actions publish workflow with a local `publish.sh` script that builds multi-platform images and pushes them to GHCR.

**Architecture:** Delete `.github/workflows/publish.yml`, add `publish.sh` (wraps `docker buildx build --push` for all three images in order), update `docs/build-and-publish.md` to reflect the new manual release flow.

**Tech Stack:** Bash, Docker Buildx, GHCR

---

## File Map

| Action | File | Responsibility |
|--------|------|----------------|
| Delete | `.github/workflows/publish.yml` | CI publish — being removed |
| Create | `publish.sh` | Multi-platform build + push to GHCR |
| Modify | `docs/build-and-publish.md` | Reflect new release workflow |

---

### Task 1: Close the pending PR

**Files:** none (GitHub operation)

- [ ] **Step 1: Close PR #2**

```bash
gh pr close 2 --comment "Closing — replacing CI publish workflow with local publish.sh. Will open a new PR after that change."
```

Expected output: `✓ Closed pull request #2 ...`

- [ ] **Step 2: Verify dev is clean and up to date**

```bash
git status
git log --oneline -5
```

Expected: clean working tree, on branch `dev`.

---

### Task 2: Delete the CI publish workflow

**Files:**
- Delete: `.github/workflows/publish.yml`

- [ ] **Step 1: Delete the file**

```bash
rm .github/workflows/publish.yml
```

- [ ] **Step 2: Verify it's gone**

```bash
ls .github/workflows/
```

Expected: empty directory or no `publish.yml` listed.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/publish.yml
git commit -m "chore: remove CI publish workflow (switching to local publish.sh)"
```

---

### Task 3: Add publish.sh

**Files:**
- Create: `publish.sh`

- [ ] **Step 1: Create the script**

```bash
cat > publish.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

REGISTRY="ghcr.io/empaa"

# Verify GHCR login before starting a ~45-min build
if ! grep -q "ghcr.io" "${HOME}/.docker/config.json" 2>/dev/null; then
    echo "Error: not logged in to GHCR. Run:"
    echo "  echo <TOKEN> | docker login ghcr.io -u <YOUR_USERNAME> --password-stdin"
    echo "See docs/build-and-publish.md for instructions."
    exit 1
fi

echo "==> Building and pushing av1-stack (linux/amd64 + linux/arm64, ~45 min)..."
docker buildx build \
    --platform linux/amd64,linux/arm64 \
    --target final \
    -f Dockerfile.stack \
    -t "${REGISTRY}/av1-stack:latest" \
    --push \
    .

echo "==> Building and pushing tdarr images (linux/amd64 + linux/arm64)..."
docker buildx build \
    --platform linux/amd64,linux/arm64 \
    -f Dockerfile.tdarr \
    -t "${REGISTRY}/tdarr:latest" \
    --push \
    .

docker buildx build \
    --platform linux/amd64,linux/arm64 \
    -f Dockerfile.tdarr_node \
    -t "${REGISTRY}/tdarr_node:latest" \
    --push \
    .

echo ""
echo "Done. Published:"
echo "  ${REGISTRY}/av1-stack:latest"
echo "  ${REGISTRY}/tdarr:latest"
echo "  ${REGISTRY}/tdarr_node:latest"
EOF
chmod +x publish.sh
```

- [ ] **Step 2: Verify the script looks right**

```bash
cat publish.sh
```

Expected: script with GHCR login check, three `docker buildx build --push` calls in order (av1-stack, tdarr, tdarr_node).

- [ ] **Step 3: Commit**

```bash
git add publish.sh
git commit -m "feat: add publish.sh for local multi-platform build and push to GHCR"
```

---

### Task 4: Update docs/build-and-publish.md

**Files:**
- Modify: `docs/build-and-publish.md`

- [ ] **Step 1: Replace the file contents**

Replace the entire file with:

```markdown
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

## Publish to GHCR

Builds multi-platform images (linux/amd64 + linux/arm64) and pushes them to GHCR.
Run this from the M1 Mac — arm64 compiles natively, amd64 via Rosetta/QEMU (reliable).
On Intel/AMD Linux, arm64 still uses QEMU and may segfault on the SVT-AV1 compile.

**One-time setup** — create a PAT at GitHub → Settings → Developer settings → Personal access tokens (classic) with `write:packages` scope, then:
```bash
echo <TOKEN> | docker login ghcr.io -u <your-github-username> --password-stdin
```

**Publish:**
```bash
./publish.sh
```

## Merge workflow

1. Run `./test.sh` locally — must pass
2. Open PR from `dev` to `main`
3. Merge

## Release workflow

1. Run `./test.sh --release` locally — must pass (requires sample files in `test/samples/`)
2. Merge `dev` → `main`
3. Run `./publish.sh` — builds and pushes to GHCR (~45 min from Mac)

## Binary list

`test.sh` checks these binaries on both platforms. Current: `av1an`, `ab-av1`, `ffmpeg`. Update when new binaries are confirmed in `Dockerfile.stack`.
```

- [ ] **Step 2: Commit**

```bash
git add docs/build-and-publish.md
git commit -m "docs: update build-and-publish for local publish workflow"
```

---

### Task 5: Run tests, open PR, merge

- [ ] **Step 1: Run pre-merge tests**

```bash
./test.sh
```

Expected: both platforms pass binary checks. Fix any failures before continuing.

- [ ] **Step 2: Open PR**

```bash
gh pr create --title "feat: replace CI publish with local publish.sh" --body "$(cat <<'EOF'
## Summary
- Removes `.github/workflows/publish.yml` — GitHub Actions no longer builds on merge to main
- Adds `publish.sh` — local multi-platform build and push to GHCR (recommended from M1 Mac)
- Updates `docs/build-and-publish.md` to reflect the new release workflow

## Why
The CI workflow was segfaulting after ~2 hours during SVT-AV1 compilation under QEMU arm64 emulation (exit code 139). Building locally on the M1 Mac compiles arm64 natively and avoids the issue entirely.

## Test plan
- [ ] `./test.sh` passes on dev machine before merge
- [ ] After merge, verify no publish workflow fires in GitHub Actions
- [ ] Run `./publish.sh` to publish the release
EOF
)"
```

- [ ] **Step 3: Merge the PR**

```bash
gh pr merge --squash --delete-branch
```

Expected: PR merged, `dev` branch deleted, `main` updated.

---

### Task 6: Publish the release

- [ ] **Step 1: Verify GHCR login**

```bash
grep -q "ghcr.io" "${HOME}/.docker/config.json" && echo "Logged in" || echo "Not logged in — run docker login first"
```

If not logged in:
```bash
echo <YOUR_PAT> | docker login ghcr.io -u <YOUR_GITHUB_USERNAME> --password-stdin
```

- [ ] **Step 2: Run publish**

```bash
./publish.sh
```

Expected: ~45 min build on M1 Mac. Final output:
```
Done. Published:
  ghcr.io/empaa/av1-stack:latest
  ghcr.io/empaa/tdarr:latest
  ghcr.io/empaa/tdarr_node:latest
```

- [ ] **Step 3: Verify images on GHCR**

```bash
docker buildx imagetools inspect ghcr.io/empaa/tdarr:latest
```

Expected: manifest list showing both `linux/amd64` and `linux/arm64` digests.
