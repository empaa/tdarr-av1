# Testing Suite — Tdarr Image Tests — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the test suite with `test-tdarr.sh` that builds `tdarr-test` and `tdarr_node-test` images on top of the local av1-stack, runs binary checks on both platforms, and (with `--release`) verifies Tdarr starts and AV1 encoding works inside each image.

**Architecture:** Two test Dockerfiles (`Dockerfile.tdarr.test`, `Dockerfile.tdarr_node.test`) use a multi-stage `ARG ARCH` trick to `COPY --from` the locally-built `av1-stack-test:${ARCH}` image. `test-tdarr.sh` mirrors the flag interface of `test.sh` exactly. Encode outputs are segregated into `test/output/stack/`, `test/output/tdarr/`, and `test/output/tdarr_node/`.

**Tech Stack:** Bash, Docker BuildKit, `docker buildx build`, `docker run`, `curl`.

---

## File Map

| Action | File | Purpose |
|---|---|---|
| Modify | `.gitignore` | Switch from flat `test/output/*` to per-subdir rules |
| Create | `test/output/stack/.gitkeep` | Track new stack subdir |
| Create | `test/output/tdarr/.gitkeep` | Track tdarr subdir |
| Create | `test/output/tdarr_node/.gitkeep` | Track tdarr_node subdir |
| Delete | `test/output/.gitkeep` | Old flat dir, replaced by subdirs |
| Modify | `test.sh` | Point OUTPUT_DIR to `test/output/stack/`; update `--clean` |
| Create | `Dockerfile.tdarr.test` | Tdarr test image from local av1-stack |
| Create | `Dockerfile.tdarr_node.test` | Tdarr_node test image from local av1-stack |
| Create | `test-tdarr.sh` | New test script, mirrors test.sh structure |
| Modify | `docs/build-and-publish.md` | Update workflow commands |

---

## Task 1: Restructure test/output/ directories

**Files:**
- Modify: `.gitignore`
- Create: `test/output/stack/.gitkeep`
- Create: `test/output/tdarr/.gitkeep`
- Create: `test/output/tdarr_node/.gitkeep`
- Delete: `test/output/.gitkeep`

- [ ] **Step 1: Update .gitignore**

Replace the two lines:
```
test/output/*
!test/output/.gitkeep
```
With:
```
test/output/*/*
!test/output/*/.gitkeep
```

- [ ] **Step 2: Create subdirectory .gitkeep files**

```bash
mkdir -p test/output/stack test/output/tdarr test/output/tdarr_node
touch test/output/stack/.gitkeep test/output/tdarr/.gitkeep test/output/tdarr_node/.gitkeep
```

- [ ] **Step 3: Remove the old flat .gitkeep**

```bash
git rm test/output/.gitkeep
```

- [ ] **Step 4: Verify git sees the right files**

```bash
git status
```

Expected: `.gitignore` modified; `test/output/.gitkeep` deleted; three new `test/output/*/` .gitkeep files added.

- [ ] **Step 5: Commit**

```bash
git add .gitignore test/output/
git commit -m "chore: restructure test/output into stack/, tdarr/, tdarr_node/ subdirs"
```

---

## Task 2: Update test.sh to write outputs into test/output/stack/

**Files:**
- Modify: `test.sh`

The current script writes encode outputs to `test/output/` (variable `OUTPUT_DIR`) and cleans that directory in `--clean`. Both references need updating.

- [ ] **Step 1: Update OUTPUT_DIR**

Find this line in `test.sh`:
```bash
OUTPUT_DIR="${SCRIPT_DIR}/test/output"
```
Change it to:
```bash
OUTPUT_DIR="${SCRIPT_DIR}/test/output/stack"
```

- [ ] **Step 2: Update --clean to wipe test/output/stack/**

Find this block in `test.sh`:
```bash
  echo "==> Cleaning test/output/..."
  find "${SCRIPT_DIR}/test/output" -mindepth 1 ! -name '.gitkeep' -delete
```
Change it to:
```bash
  echo "==> Cleaning test/output/stack/..."
  find "${SCRIPT_DIR}/test/output/stack" -mindepth 1 ! -name '.gitkeep' -delete
```

- [ ] **Step 3: Run a quick dry-run to verify the script parses correctly**

```bash
bash -n test.sh
```

Expected: no output (no syntax errors).

- [ ] **Step 4: Commit**

```bash
git add test.sh
git commit -m "fix: redirect test.sh encode outputs to test/output/stack/"
```

---

## Task 3: Create Dockerfile.tdarr.test and Dockerfile.tdarr_node.test

**Files:**
- Create: `Dockerfile.tdarr.test`
- Create: `Dockerfile.tdarr_node.test`

These use a multi-stage trick: `ARG ARCH` before `FROM` lets us parameterise the local av1-stack image name; then a named stage `AS stack` is used as the `COPY --from` source, avoiding the need to modify the production Dockerfiles.

- [ ] **Step 1: Create Dockerfile.tdarr.test**

```dockerfile
ARG ARCH=amd64
FROM av1-stack-test:${ARCH} AS stack

FROM ghcr.io/haveagitgat/tdarr:latest
COPY --from=stack /usr/local /usr/local
COPY --from=stack /etc/vapoursynth /etc/vapoursynth
RUN ldconfig && \
    apt-get update && \
    apt-get install -y mkvtoolnix && \
    rm -rf /var/lib/apt/lists/*
```

- [ ] **Step 2: Create Dockerfile.tdarr_node.test**

```dockerfile
ARG ARCH=amd64
FROM av1-stack-test:${ARCH} AS stack

FROM ghcr.io/haveagitgat/tdarr_node:latest
COPY --from=stack /usr/local /usr/local
COPY --from=stack /etc/vapoursynth /etc/vapoursynth
RUN ldconfig && \
    apt-get update && \
    apt-get install -y mkvtoolnix && \
    rm -rf /var/lib/apt/lists/*
```

- [ ] **Step 3: Verify the files look right**

```bash
cat Dockerfile.tdarr.test
cat Dockerfile.tdarr_node.test
```

Expected: each file has exactly 2 `FROM` lines, `COPY --from=stack`, and the `RUN` block.

- [ ] **Step 4: Commit**

```bash
git add Dockerfile.tdarr.test Dockerfile.tdarr_node.test
git commit -m "feat: add test Dockerfiles for tdarr and tdarr_node"
```

---

## Task 4: Create test-tdarr.sh

**Files:**
- Create: `test-tdarr.sh`

Mirrors `test.sh` structure exactly. Phase 1: binary checks on both platforms. Phase 2 (`--release`): startup check + encode test on native arch, for both `tdarr` and `tdarr_node`.

- [ ] **Step 1: Create test-tdarr.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

BINARIES=(av1an ab-av1 ffmpeg)
IMAGES=(tdarr tdarr_node)
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
  local name="$1" platform="$2" arch="$3"
  local image="${name}-test:${arch}"

  if [[ "$RELEASE" == true ]] && docker image inspect "$image" > /dev/null 2>&1; then
    echo "==> Using cached image ${image}"
    return 0
  fi

  echo "==> Building Dockerfile.${name}.test (${platform})..."
  docker buildx build \
    --platform "${platform}" \
    --build-arg ARCH="${arch}" \
    --output "type=docker,name=${image}" \
    -f "Dockerfile.${name}.test" \
    .
}

run_binary_checks() {
  local name="$1" platform="$2" arch="$3"
  local image="${name}-test:${arch}"
  local failed=0

  echo ""
  echo "Running binary checks for ${name} (${platform})..."
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
    echo "FAILED: $failed binary check(s) failed for ${name} (${platform})"
    return 1
  fi
  echo "All binary checks passed for ${name} (${platform})"
}

run_startup_check() {
  local name="$1" arch="$2"
  local image="${name}-test:${arch}"

  echo ""
  echo "Running startup check for ${name}..."

  local cid

  if [[ "$name" == "tdarr" ]]; then
    cid=$(docker run -d \
      -p 8265:8265 \
      -e serverIP=0.0.0.0 \
      -e serverPort=8266 \
      -e webUIPort=8265 \
      -e internalNode=false \
      "${image}")

    local ok=false
    for i in $(seq 1 30); do
      if curl -sf http://localhost:8265 > /dev/null 2>&1; then
        ok=true
        break
      fi
      sleep 1
    done

    docker stop "$cid" > /dev/null
    docker rm   "$cid" > /dev/null

    printf "  %-20s" "startup (HTTP)"
    if [[ "$ok" == true ]]; then
      echo "OK"
      return 0
    else
      echo "FAILED (timeout after 30s)"
      return 1
    fi

  else
    # tdarr_node has no HTTP server; start it with a dummy server address
    # and verify it stays alive for 10 seconds (not a missing-binary crash).
    cid=$(docker run -d \
      -e serverIP=127.0.0.1 \
      -e serverPort=8266 \
      -e nodeName=test-node \
      "${image}")

    sleep 10
    local state
    state=$(docker inspect --format '{{.State.Status}}' "$cid" 2>/dev/null || echo "missing")

    docker stop "$cid" > /dev/null 2>&1 || true
    docker rm   "$cid" > /dev/null 2>&1 || true

    printf "  %-20s" "startup (alive)"
    if [[ "$state" == "running" ]]; then
      echo "OK"
      return 0
    else
      echo "FAILED (state: ${state})"
      return 1
    fi
  fi
}

run_encode_test() {
  local name="$1" arch="$2"
  local image="${name}-test:${arch}"
  local samples_dir="${SCRIPT_DIR}/test/samples"
  local output_dir="${SCRIPT_DIR}/test/output/${name}"

  SAMPLE_FILES=()
  while IFS= read -r -d '' f; do
    SAMPLE_FILES+=("$f")
  done < <(find "$samples_dir" -maxdepth 1 -type f ! -name '.gitkeep' ! -name '.*' -print0)

  if [[ ${#SAMPLE_FILES[@]} -eq 0 ]]; then
    echo "WARNING: No sample files found in test/samples/ — skipping encode tests for ${name}"
    return 0
  fi

  echo "==> Running encode tests for ${name} (${#SAMPLE_FILES[@]} sample(s))..."

  local encode_failed=0
  local failures=()

  for sample in "${SAMPLE_FILES[@]}"; do
    local filename stem
    filename="$(basename "$sample")"
    stem="${filename%.*}"

    echo ""
    echo "  Sample: ${filename}"

    local container_exit=0
    docker run --rm \
      -v "${samples_dir}:/samples:ro" \
      -v "${output_dir}:/output" \
      "${image}" bash -c '
        set -e
        ffmpeg -y -ss 00:01:00 -t 60 -i "/samples/$1" -c copy "/output/$2_clip.mkv" 2>/dev/null
        av1an -i "/output/$2_clip.mkv" --encoder aom --target-quality 90 --verbose -o "/output/$2_av1an_aom.mkv"
        av1an -i "/output/$2_clip.mkv" --encoder svt-av1 --target-quality 90 --verbose -o "/output/$2_av1an_svtav1.mkv"
        ab-av1 auto-encode -i "/output/$2_clip.mkv" --min-vmaf 90 -o "/output/$2_ab-av1.mkv"
      ' -- "$filename" "$stem" \
      || container_exit=$?

    for suffix in _av1an_aom.mkv _av1an_svtav1.mkv _ab-av1.mkv; do
      local outfile="${output_dir}/${stem}${suffix}"
      local label="${stem}${suffix}"
      printf "    %-44s" "$label"
      if [[ $container_exit -ne 0 ]]; then
        echo "FAILED (container exited ${container_exit})"
        failures+=("${label}: container exited ${container_exit}")
        encode_failed=$((encode_failed + 1))
      elif [[ -f "$outfile" ]] && [[ -s "$outfile" ]]; then
        echo "OK"
      else
        echo "FAILED (missing or empty)"
        failures+=("${label}: output missing or empty")
        encode_failed=$((encode_failed + 1))
      fi
    done
  done

  if [[ $encode_failed -gt 0 ]]; then
    echo "FAILED: ${encode_failed} encode check(s) failed for ${name}:"
    for f in "${failures[@]}"; do
      echo "  - $f"
    done
    return 1
  fi

  echo "All encode tests passed for ${name}"
}

# ── clean ─────────────────────────────────────────────────────────────────────

if [[ "$CLEAN" == true ]]; then
  echo "==> Cleaning cached images..."
  for name in "${IMAGES[@]}"; do
    docker rmi "${name}-test:amd64" 2>/dev/null || true
    docker rmi "${name}-test:arm64" 2>/dev/null || true
  done
  echo "==> Cleaning test/output/tdarr/ and test/output/tdarr_node/..."
  find "${SCRIPT_DIR}/test/output/tdarr"      -mindepth 1 ! -name '.gitkeep' -delete
  find "${SCRIPT_DIR}/test/output/tdarr_node" -mindepth 1 ! -name '.gitkeep' -delete
  echo "Clean complete."
  [[ "$RELEASE" == false ]] && exit 0
fi

# ── Phase 1: binary checks ────────────────────────────────────────────────────

OVERALL_FAILED=0

if [[ "$RELEASE" == true ]]; then
  ARCH=$(native_arch)
  PLATFORM="linux/${ARCH}"
  for name in "${IMAGES[@]}"; do
    build_image "$name" "$PLATFORM" "$ARCH"
    run_binary_checks "$name" "$PLATFORM" "$ARCH" || OVERALL_FAILED=$((OVERALL_FAILED + 1))
  done
else
  for platform in linux/amd64 linux/arm64; do
    arch="${platform#linux/}"
    for name in "${IMAGES[@]}"; do
      build_image "$name" "$platform" "$arch"
      run_binary_checks "$name" "$platform" "$arch" || OVERALL_FAILED=$((OVERALL_FAILED + 1))
    done
  done
  echo ""
  if [[ $OVERALL_FAILED -gt 0 ]]; then
    echo "FAILED: ${OVERALL_FAILED} image(s) had binary check failures"
    exit 1
  fi
  echo "All checks passed (linux/amd64, linux/arm64) — safe to merge"
  exit 0
fi

# ── Phase 2: startup + encode tests (--release only) ─────────────────────────

for name in "${IMAGES[@]}"; do
  if run_startup_check "$name" "$ARCH"; then
    run_encode_test "$name" "$ARCH" || OVERALL_FAILED=$((OVERALL_FAILED + 1))
  else
    OVERALL_FAILED=$((OVERALL_FAILED + 1))
    echo "Skipping encode test for ${name} (startup failed)"
  fi
done

echo ""
if [[ $OVERALL_FAILED -gt 0 ]]; then
  echo "FAILED: ${OVERALL_FAILED} check(s) failed"
  exit 1
fi

echo "All checks passed — safe to release"
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x test-tdarr.sh
```

- [ ] **Step 3: Check syntax**

```bash
bash -n test-tdarr.sh
```

Expected: no output.

- [ ] **Step 4: Commit**

```bash
git add test-tdarr.sh
git commit -m "feat: add test-tdarr.sh for tdarr/tdarr_node image tests"
```

---

## Task 5: Smoke-test — binary checks (no --release)

Before running this task, `test.sh` must have been run at least once to produce `av1-stack-test:amd64` and `av1-stack-test:arm64`.

- [ ] **Step 1: Run binary checks only**

```bash
./test-tdarr.sh
```

Expected output (approx):
```
==> Building Dockerfile.tdarr.test (linux/amd64)...
Running binary checks for tdarr (linux/amd64)...
  av1an       OK
  ab-av1      OK
  ffmpeg      OK
All binary checks passed for tdarr (linux/amd64)

==> Building Dockerfile.tdarr.test (linux/arm64)...
...
==> Building Dockerfile.tdarr_node.test (linux/amd64)...
...
All checks passed (linux/amd64, linux/arm64) — safe to merge
```

- [ ] **Step 2: If any binary check fails, diagnose**

Re-run with output visible to see the exact error:
```bash
docker run --rm tdarr-test:amd64 av1an --version
docker run --rm tdarr-test:amd64 ab-av1 --version
docker run --rm tdarr-test:amd64 ffmpeg -version
```

A `cannot execute binary file` error means architecture mismatch. A `not found` error means the `COPY --from=stack` didn't land the binary correctly — check `Dockerfile.tdarr.test` ARG and FROM ordering.

---

## Task 6: Smoke-test — release mode (startup + encode)

Requires at least one sample file in `test/samples/` and `av1-stack-test:amd64` (or arm64 on Apple Silicon) already built.

- [ ] **Step 1: Run release mode**

```bash
./test-tdarr.sh --release
```

Expected output (approx):
```
==> Using cached image tdarr-test:amd64

Running binary checks for tdarr (linux/amd64)...
  av1an       OK
  ab-av1      OK
  ffmpeg      OK
All binary checks passed for tdarr (linux/amd64)

Running startup check for tdarr...
  startup (HTTP)      OK

==> Running encode tests for tdarr (1 sample(s))...

  Sample: <filename>.mkv
    <stem>_av1an_aom.mkv                        OK
    <stem>_av1an_svtav1.mkv                     OK
    <stem>_ab-av1.mkv                           OK

Running binary checks for tdarr_node (linux/amd64)...
...
Running startup check for tdarr_node...
  startup (alive)     OK
...
All checks passed — safe to release
```

- [ ] **Step 2: If tdarr startup fails (HTTP timeout)**

Check what env vars the Tdarr image actually needs:
```bash
docker run --rm ghcr.io/haveagitgat/tdarr:latest env | sort
```

Adjust the `-e` flags in the `run_startup_check` function in `test-tdarr.sh` to match. Common corrections: `webUIPort` may need to be `TDARR_WEB_UI_PORT`, or the port may differ. Check which port is actually published:
```bash
docker run -d --name tdarr-debug ghcr.io/haveagitgat/tdarr:latest
sleep 5
docker logs tdarr-debug | head -40
docker stop tdarr-debug && docker rm tdarr-debug
```

- [ ] **Step 3: If tdarr_node startup fails (state not 'running')**

Check the container logs:
```bash
docker run -d --name node-debug \
  -e serverIP=127.0.0.1 -e serverPort=8266 -e nodeName=test-node \
  tdarr_node-test:amd64
sleep 10
docker logs node-debug
docker stop node-debug && docker rm node-debug
```

If the node exits because it can't connect to the server (expected), that's an acceptable failure mode for the test — you'll need to start a `tdarr-test` container first and point the node at it, then adjust `run_startup_check` accordingly.

---

## Task 7: Update docs/build-and-publish.md

**Files:**
- Modify: `docs/build-and-publish.md`

- [ ] **Step 1: Update the Pre-merge section**

Find:
```markdown
1. Run `./test.sh` locally — must pass
```
Replace with:
```markdown
1. Run `./test.sh && ./test-tdarr.sh` locally — must pass
```

- [ ] **Step 2: Update the Release workflow section**

Find:
```markdown
1. Run `./test.sh --release` locally — must pass (requires sample files in `test/samples/`)
```
Replace with:
```markdown
1. Run `./test.sh --release && ./test-tdarr.sh --release` locally — must pass (requires sample files in `test/samples/`)
```

- [ ] **Step 3: Verify the doc reads correctly**

```bash
grep -A3 "Pre-merge\|Release workflow\|Run \`./test" docs/build-and-publish.md
```

- [ ] **Step 4: Commit**

```bash
git add docs/build-and-publish.md
git commit -m "docs: update workflow commands for test-tdarr.sh"
```
