# Local Dual-Platform Testing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the GitHub Actions test gate with a local `test.sh` that builds and verifies binaries on both linux/amd64 and linux/arm64 before merging.

**Architecture:** Update `test.sh` to loop over both platforms sequentially — build, load, test binaries — then delete `test.yml` and update the docs to reflect the new workflow.

**Tech Stack:** Bash, Docker Buildx (multi-platform via QEMU)

---

## Files

| Action | Path |
|--------|------|
| Modify | `test.sh` |
| Delete | `.github/workflows/test.yml` |
| Modify | `docs/build-and-publish.md` |

---

### Task 1: Update `test.sh` for dual-platform testing

**Files:**
- Modify: `test.sh`

- [ ] **Step 1: Replace `test.sh` with the dual-platform version**

Full file content (replaces existing):

```bash
#!/usr/bin/env bash
set -euo pipefail

# Update this list as custom binaries are confirmed in Dockerfile.stack
BINARIES=(av1an ab-av1 ffmpeg)
PLATFORMS=(linux/amd64 linux/arm64)

for platform in "${PLATFORMS[@]}"; do
  arch="${platform#linux/}"
  IMAGE="av1-stack-test:${arch}"

  echo "==> Building Dockerfile.stack (${platform})..."
  docker buildx build \
    --platform "${platform}" \
    --output "type=docker,name=${IMAGE}" \
    --target final \
    -f Dockerfile.stack \
    .

  echo ""
  echo "Running binary checks (${platform})..."
  FAILED=0
  for bin in "${BINARIES[@]}"; do
    printf "  %-12s" "$bin"
    if docker run --rm --platform "${platform}" "${IMAGE}" "$bin" --version > /dev/null 2>&1; then
      echo "OK"
    else
      echo "FAILED"
      FAILED=$((FAILED + 1))
    fi
  done

  echo ""
  if [[ $FAILED -gt 0 ]]; then
    echo "FAILED: $FAILED binary check(s) failed for ${platform}"
    exit 1
  fi
  echo "All checks passed for ${platform}"
  echo ""
done

echo "All checks passed (linux/amd64, linux/arm64) — safe to merge"
```

- [ ] **Step 2: Verify syntax**

```bash
bash -n test.sh
```

Expected: no output (clean parse, exit 0)

- [ ] **Step 3: Commit**

```bash
git add test.sh
git commit -m "test: extend test.sh to build and verify binaries on both amd64 and arm64"
```

---

### Task 2: Delete the GitHub Actions test workflow

**Files:**
- Delete: `.github/workflows/test.yml`

- [ ] **Step 1: Delete the file**

```bash
git rm .github/workflows/test.yml
```

- [ ] **Step 2: Commit**

```bash
git commit -m "ci: remove test.yml — local test.sh now covers both platforms"
```

---

### Task 3: Update `docs/build-and-publish.md`

**Files:**
- Modify: `docs/build-and-publish.md`

Make three targeted edits to `docs/build-and-publish.md`:

- [ ] **Step 1: Update the local test description (line 13)**

Change:
```
Builds `Dockerfile.stack` for linux/amd64, runs binary version checks (`av1an`, `ab-av1`, `ffmpeg`). Must pass before opening a PR to `main`.
```
To:
```
Builds `Dockerfile.stack` for linux/amd64 and linux/arm64, runs binary version checks (`av1an`, `ab-av1`, `ffmpeg`) on both platforms. Must pass before opening a PR to `main`.
```

- [ ] **Step 2: Remove the `test.yml` row from the CI workflows table (lines 34–37)**

Change the CI workflows table from:
```
| Workflow | Trigger | What it does |
|---|---|---|
| `test.yml` | PR to `main`, manual dispatch | Builds `Dockerfile.stack` (amd64), runs binary checks. Gates merge via "Tests passed" |
| `publish.yml` | Push to `main` | Builds and pushes av1-stack, then tdarr + tdarr_node (amd64+arm64) to GHCR |
```
To:
```
| Workflow | Trigger | What it does |
|---|---|---|
| `publish.yml` | Push to `main` | Builds and pushes av1-stack, then tdarr + tdarr_node (amd64+arm64) to GHCR |
```

- [ ] **Step 3: Simplify the merge workflow and binary list note (lines 39–48)**

Change the merge workflow section from:
```
1. Run `./test.sh` locally — must pass
2. Open PR from `dev` to `main`
3. Wait for `test.yml` to pass on GitHub (failsafe)
4. Merge — `publish.yml` fires automatically
```
To:
```
1. Run `./test.sh` locally — must pass
2. Open PR from `dev` to `main`
3. Merge — `publish.yml` fires automatically
```

Change the binary list note from:
```
`test.sh` and `test.yml` keep the same binary list in sync manually. Current: `av1an`, `ab-av1`, `ffmpeg`. Update both when new binaries are confirmed in `Dockerfile.stack`.
```
To:
```
`test.sh` checks these binaries on both platforms. Current: `av1an`, `ab-av1`, `ffmpeg`. Update when new binaries are confirmed in `Dockerfile.stack`.
```

- [ ] **Step 2: Verify the file looks correct**

```bash
cat docs/build-and-publish.md
```

Expected: file renders cleanly, no `test.yml` references remain.

- [ ] **Step 3: Commit**

```bash
git add docs/build-and-publish.md
git commit -m "docs: update build-and-publish to reflect dual-platform local testing"
```
