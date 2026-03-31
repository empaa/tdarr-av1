# Dev Workflow Setup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Set up two GitHub Actions workflows (`test.yml` and `publish.yml`) and branch protection so that `main` can only be merged to after a clean build and binary version checks pass on both images and both platforms.

**Architecture:** Two separate workflows — `test.yml` runs on PR to main and manual dispatch, building both images for both platforms and verifying all custom binaries; `publish.yml` runs on push to main, building multi-platform and pushing to GHCR. A summary job in `test.yml` provides a single status check name for branch protection. Branch protection is configured via `gh` CLI.

**Tech Stack:** GitHub Actions, Docker Buildx, QEMU (for cross-platform), `docker/build-push-action@v6`, `actionlint` (YAML validation via Docker)

---

### Task 1: Create `test.yml`

**Files:**
- Create: `.github/workflows/test.yml`

> Note: This workflow references `Dockerfile.tdarr` and `Dockerfile.tdarr_node` — these do not exist yet. The workflow is correct and ready; update the `dockerfile` values in the matrix when Dockerfiles are created. The `BINARIES` array must also be updated as custom binaries are added to the Dockerfiles.

- [ ] **Step 1: Create the workflows directory**

```bash
mkdir -p .github/workflows
```

- [ ] **Step 2: Write `.github/workflows/test.yml`**

```yaml
name: Test

on:
  pull_request:
    branches: [main]
  workflow_dispatch:

jobs:
  build-and-test:
    name: Build and test ${{ matrix.image }} (${{ matrix.platform }})
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        image: [tdarr, tdarr_node]
        platform: [linux/amd64, linux/arm64]
        include:
          - image: tdarr
            dockerfile: Dockerfile.tdarr
          - image: tdarr_node
            dockerfile: Dockerfile.tdarr_node
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up QEMU
        uses: docker/setup-qemu-action@v3

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Build ${{ matrix.image }} for ${{ matrix.platform }}
        uses: docker/build-push-action@v6
        with:
          context: .
          file: ${{ matrix.dockerfile }}
          platforms: ${{ matrix.platform }}
          load: true
          tags: test-${{ matrix.image }}:local

      - name: Test binaries in ${{ matrix.image }} (${{ matrix.platform }})
        run: |
          # Update this list as custom binaries are added to the Dockerfiles
          BINARIES=(av1an ab-av1)
          for bin in "${BINARIES[@]}"; do
            echo "=== Testing $bin ==="
            docker run --rm --platform ${{ matrix.platform }} test-${{ matrix.image }}:local "$bin" --version
          done

  summary:
    name: Tests passed
    runs-on: ubuntu-latest
    needs: [build-and-test]
    if: always()
    steps:
      - name: Check all jobs passed
        run: |
          if [[ "${{ needs.build-and-test.result }}" != "success" ]]; then
            echo "One or more test jobs failed or were cancelled"
            exit 1
          fi
          echo "All test jobs passed"
```

- [ ] **Step 3: Validate with actionlint**

```bash
docker run --rm -v "$(pwd):/repo" --workdir /repo rhysd/actionlint:latest
```

Expected: no errors printed, exit 0. If errors appear, fix them before continuing.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/test.yml
git commit -m "ci: add test workflow (build + binary checks on PR to main and dispatch)

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>"
```

---

### Task 2: Create `publish.yml`

**Files:**
- Create: `.github/workflows/publish.yml`

> Note: Like `test.yml`, this references `Dockerfile.tdarr` and `Dockerfile.tdarr_node`. Update `dockerfile` values in the matrix when Dockerfiles are created.

- [ ] **Step 1: Write `.github/workflows/publish.yml`**

```yaml
name: Publish

on:
  push:
    branches: [main]

jobs:
  publish:
    name: Publish ${{ matrix.image }}
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    strategy:
      matrix:
        include:
          - image: tdarr
            dockerfile: Dockerfile.tdarr
            tag: ghcr.io/empaa/tdarr:latest
          - image: tdarr_node
            dockerfile: Dockerfile.tdarr_node
            tag: ghcr.io/empaa/tdarr_node:latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up QEMU
        uses: docker/setup-qemu-action@v3

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push ${{ matrix.image }}
        uses: docker/build-push-action@v6
        with:
          context: .
          file: ${{ matrix.dockerfile }}
          platforms: linux/amd64,linux/arm64
          push: true
          tags: ${{ matrix.tag }}
```

- [ ] **Step 2: Validate with actionlint**

```bash
docker run --rm -v "$(pwd):/repo" --workdir /repo rhysd/actionlint:latest
```

Expected: no errors, exit 0.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/publish.yml
git commit -m "ci: add publish workflow (multi-platform GHCR push on merge to main)

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>"
```

---

### Task 3: Push to dev and configure branch protection

**Files:** none — GitHub settings via `gh` CLI

> Branch protection must be configured after at least one successful run of `test.yml` so that the `Tests passed` status check name is registered in GitHub. However, we can pre-configure it with the known name. If the protection rule cannot reference an unregistered check, set it up after the first successful run (see Step 4 note).

- [ ] **Step 1: Push the workflows to dev**

```bash
git push origin dev
```

- [ ] **Step 2: Verify both workflow files appear on GitHub**

```bash
gh browse --repo empaa/tdarr-av1
```

Navigate to Actions tab and confirm `Test` and `Publish` workflows are listed.

- [ ] **Step 3: Run the test workflow manually on dev to register the status check name**

```bash
gh workflow run test.yml --repo empaa/tdarr-av1 --ref dev
```

Wait for it to complete (it will fail — Dockerfiles don't exist yet — but the job names will be registered):

```bash
gh run list --repo empaa/tdarr-av1 --workflow test.yml --limit 1
```

Watch until status shows `completed`. The `Tests passed` check name is now known to GitHub.

- [ ] **Step 4: Configure branch protection on main**

```bash
gh api \
  --method PUT \
  -H "Accept: application/vnd.github+json" \
  /repos/empaa/tdarr-av1/branches/main/protection \
  --input - <<'EOF'
{
  "required_status_checks": {
    "strict": false,
    "contexts": ["Tests passed"]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null
}
EOF
```

Expected: JSON response showing `required_status_checks.contexts` contains `"Tests passed"`.

- [ ] **Step 5: Verify protection is active**

```bash
gh api /repos/empaa/tdarr-av1/branches/main/protection \
  --jq '.required_status_checks.contexts'
```

Expected output:
```json
["Tests passed"]
```

---

## What comes next

These workflows are ready but will not pass until Dockerfiles are added. When writing Dockerfiles:

1. Update the `dockerfile` matrix values in both workflows if the actual filenames differ from `Dockerfile.tdarr` / `Dockerfile.tdarr_node`
2. Update the `BINARIES` array in `test.yml` to include all custom-built binaries
3. Open a PR from `dev` to `main` — the test workflow runs automatically and must pass before merge
