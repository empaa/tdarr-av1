# Release Test Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `test.sh` with `--release` mode that runs real av1an and ab-av1 encode tests against local sample files, with image caching and `--clean` support.

**Architecture:** Three changes — update `.gitignore` and create `test/` directory structure, rewrite `test.sh` to support flags/caching/encode tests, update docs. No new files beyond the directory scaffolding.

**Tech Stack:** Bash, Docker (buildx), av1an, ab-av1, ffmpeg — all already present in Dockerfile.stack.

---

### Task 1: Set up test/ directory structure

**Files:**
- Modify: `.gitignore`
- Create: `test/samples/.gitkeep`
- Create: `test/output/.gitkeep`

- [ ] **Step 1: Update .gitignore**

Replace the existing `SAMPLES` line and add the new test directory rules. Open `.gitignore` — current contents:
```
old_resources
.worktrees
SAMPLES
```

Replace with:
```
old_resources
.worktrees
test/samples/*
!test/samples/.gitkeep
test/output/*
!test/output/.gitkeep
```

- [ ] **Step 2: Create the tracked empty directories**

```bash
mkdir -p test/samples test/output
touch test/samples/.gitkeep test/output/.gitkeep
```

- [ ] **Step 3: Verify git tracks the directories but not future contents**

```bash
git status
```

Expected: `.gitignore`, `test/samples/.gitkeep`, and `test/output/.gitkeep` shown as new/modified. No other files under `test/`.

- [ ] **Step 4: Commit**

```bash
git add .gitignore test/samples/.gitkeep test/output/.gitkeep
git commit -m "chore: add test/samples and test/output directories"
```

---

### Task 2: Rewrite test.sh

**Files:**
- Modify: `test.sh`

This is a full replacement of `test.sh`. The new script supports `--release`, `--clean`, image caching, native-platform detection, and encode tests.

- [ ] **Step 1: Verify current test.sh passes before touching it**

```bash
./test.sh
```

Expected: `All checks passed (linux/amd64, linux/arm64) — safe to merge`

- [ ] **Step 2: Replace test.sh with the new implementation**

```bash
#!/usr/bin/env bash
set -euo pipefail

BINARIES=(av1an ab-av1 ffmpeg)
RELEASE=false
CLEAN=false

for arg in "$@"; do
  case "$arg" in
    --release) RELEASE=true ;;
    --clean)   CLEAN=true ;;
    *) echo "Unknown flag: $arg"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── helpers ───────────────────────────────────────────────────────────────────

native_arch() {
  case "$(uname -m)" in
    x86_64)        echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
  esac
}

build_image() {
  local platform="$1" arch="$2"
  local image="av1-stack-test:${arch}"

  if [[ "$RELEASE" == true ]] && docker image inspect "$image" > /dev/null 2>&1; then
    echo "==> Using cached image ${image}"
    return 0
  fi

  echo "==> Building Dockerfile.stack (${platform})..."
  docker buildx build \
    --platform "${platform}" \
    --output "type=docker,name=${image}" \
    --target final \
    -f Dockerfile.stack \
    .
}

run_binary_checks() {
  local platform="$1" arch="$2"
  local image="av1-stack-test:${arch}"
  local failed=0

  echo ""
  echo "Running binary checks (${platform})..."
  for bin in "${BINARIES[@]}"; do
    printf "  %-12s" "$bin"
    local version_flag="--version"
    [[ "$bin" == "ffmpeg" ]] && version_flag="-version"
    if docker run --rm --platform "${platform}" "${image}" "$bin" $version_flag > /dev/null 2>&1; then
      echo "OK"
    else
      echo "FAILED"
      failed=$((failed + 1))
    fi
  done

  echo ""
  if [[ $failed -gt 0 ]]; then
    echo "FAILED: $failed binary check(s) failed for ${platform}"
    exit 1
  fi
  echo "All checks passed for ${platform}"
}

# ── clean ─────────────────────────────────────────────────────────────────────

if [[ "$CLEAN" == true ]]; then
  echo "==> Cleaning cached images..."
  docker rmi av1-stack-test:amd64 2>/dev/null || true
  docker rmi av1-stack-test:arm64 2>/dev/null || true
  echo "==> Cleaning test/output/..."
  find "${SCRIPT_DIR}/test/output" -mindepth 1 ! -name '.gitkeep' -delete
  echo "Clean complete."
  [[ "$RELEASE" == false ]] && exit 0
fi

# ── Phase 1: binary checks ────────────────────────────────────────────────────

if [[ "$RELEASE" == true ]]; then
  ARCH=$(native_arch)
  PLATFORM="linux/${ARCH}"
  build_image "$PLATFORM" "$ARCH"
  run_binary_checks "$PLATFORM" "$ARCH"
  echo ""
else
  for platform in linux/amd64 linux/arm64; do
    arch="${platform#linux/}"
    build_image "$platform" "$arch"
    run_binary_checks "$platform" "$arch"
    echo ""
  done
  echo "All checks passed (linux/amd64, linux/arm64) — safe to merge"
  exit 0
fi

# ── Phase 2: encode tests (--release only) ────────────────────────────────────

SAMPLES_DIR="${SCRIPT_DIR}/test/samples"
OUTPUT_DIR="${SCRIPT_DIR}/test/output"
IMAGE="av1-stack-test:${ARCH}"

SAMPLE_FILES=()
while IFS= read -r -d '' f; do
  SAMPLE_FILES+=("$f")
done < <(find "$SAMPLES_DIR" -maxdepth 1 -type f ! -name '.gitkeep' -print0)

if [[ ${#SAMPLE_FILES[@]} -eq 0 ]]; then
  echo "WARNING: No sample files found in test/samples/ — skipping encode tests"
  exit 0
fi

echo "==> Running encode tests (${#SAMPLE_FILES[@]} sample(s))..."

ENCODE_FAILED=0
FAILURES=()

for sample in "${SAMPLE_FILES[@]}"; do
  filename="$(basename "$sample")"
  stem="${filename%.*}"

  echo ""
  echo "  Sample: ${filename}"

  container_exit=0
  docker run --rm \
    -v "${SAMPLES_DIR}:/samples:ro" \
    -v "${OUTPUT_DIR}:/output" \
    "${IMAGE}" bash -c "
      set -e
      ffmpeg -y -ss 00:01:00 -t 60 -i /samples/${filename} -c copy /output/${stem}_clip.mkv 2>/dev/null
      av1an -i /output/${stem}_clip.mkv --encoder aom --target-quality 90 -o /output/${stem}_av1an_aom.mkv
      av1an -i /output/${stem}_clip.mkv --encoder svt-av1 --target-quality 90 -o /output/${stem}_av1an_svtav1.mkv
      ab-av1 encode -i /output/${stem}_clip.mkv --min-vmaf 90 -o /output/${stem}_ab-av1.mkv
    " || container_exit=$?

  for suffix in _av1an_aom.mkv _av1an_svtav1.mkv _ab-av1.mkv; do
    outfile="${OUTPUT_DIR}/${stem}${suffix}"
    label="${stem}${suffix}"
    printf "    %-44s" "$label"
    if [[ $container_exit -ne 0 ]]; then
      echo "FAILED (container exited ${container_exit})"
      FAILURES+=("${label}: container exited ${container_exit}")
      ENCODE_FAILED=$((ENCODE_FAILED + 1))
    elif [[ -f "$outfile" ]] && [[ -s "$outfile" ]]; then
      echo "OK"
    else
      echo "FAILED (missing or empty)"
      FAILURES+=("${label}: output missing or empty")
      ENCODE_FAILED=$((ENCODE_FAILED + 1))
    fi
  done
done

echo ""
if [[ $ENCODE_FAILED -gt 0 ]]; then
  echo "FAILED: ${ENCODE_FAILED} encode check(s) failed:"
  for f in "${FAILURES[@]}"; do
    echo "  - $f"
  done
  exit 1
fi

echo "All encode tests passed — safe to release"
```

- [ ] **Step 3: Make test.sh executable**

```bash
chmod +x test.sh
```

- [ ] **Step 4: Verify ./test.sh (no flags) still works**

```bash
./test.sh
```

Expected: builds both platforms (or uses cache), runs binary checks, ends with `All checks passed (linux/amd64, linux/arm64) — safe to merge`

- [ ] **Step 5: Verify --clean works**

```bash
./test.sh --clean
```

Expected output:
```
==> Cleaning cached images...
==> Cleaning test/output/...
Clean complete.
```

After running, verify images are gone:
```bash
docker image inspect av1-stack-test:amd64 2>&1 | head -1
docker image inspect av1-stack-test:arm64 2>&1 | head -1
```

Expected: `Error response from daemon: No such image: av1-stack-test:amd64` (and arm64)

- [ ] **Step 6: Verify --release with empty samples/ skips encode tests gracefully**

```bash
./test.sh --release
```

Expected: builds native platform, runs binary checks, then:
```
WARNING: No sample files found in test/samples/ — skipping encode tests
```
Script exits 0.

- [ ] **Step 7: Commit**

```bash
git add test.sh
git commit -m "feat: add --release, --clean flags and encode tests to test.sh"
```

---

### Task 3: Update docs/build-and-publish.md

**Files:**
- Modify: `docs/build-and-publish.md`

- [ ] **Step 1: Update the local test section**

Replace the current "Local test" section with:

```markdown
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
```

- [ ] **Step 2: Update the merge workflow section**

Replace the current merge workflow with:

```markdown
## Merge workflow

1. Run `./test.sh` locally — must pass
2. Open PR from `dev` to `main`
3. Merge — `publish.yml` fires automatically

## Release workflow

1. Run `./test.sh --release` locally — must pass (requires sample files in `test/samples/`)
2. Merge to `main` — `publish.yml` publishes to GHCR
```

- [ ] **Step 3: Verify the docs look correct**

```bash
cat docs/build-and-publish.md
```

Expected: both sections updated, no leftover references to old single-line test description.

- [ ] **Step 4: Commit**

```bash
git add docs/build-and-publish.md
git commit -m "docs: update build-and-publish for --release test workflow"
```
