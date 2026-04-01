# Unified Build Script Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `test-stack.sh`, `test-tdarr.sh`, and `publish.sh` with a single `build.sh` that builds, tests, and publishes — guaranteeing what you test is what you ship.

**Architecture:** A single bash script with clearly separated sections: flag parsing/validation, helper functions, result collection, build/test/publish/clean functions, and a main orchestration block. Images are loaded into the local Docker daemon during test, then retagged and pushed for publish (no rebuild).

**Tech Stack:** Bash, Docker CLI, Docker Buildx, Docker Manifest

**Spec:** `docs/superpowers/specs/2026-04-01-unified-build-script-design.md`

---

### Task 1: Create build.sh with flag parsing, validation, and helpers

**Files:**
- Create: `build.sh`

- [ ] **Step 1: Write flag parsing and validation**

Create `build.sh` with the shebang, constants, flag parsing, and validation logic:

```bash
#!/usr/bin/env bash
set -euo pipefail

REGISTRY="ghcr.io/empaa"
BUILDER_NAME="multiplatform"
BINARIES=(av1an ab-av1 ffmpeg)

STACK_ONLY=false
ENCODE=false
PUBLISH=false
CLEAN=false
CLEAN_CACHE=false
ALL_PLATFORMS=false
SPECIFIC_ARCH=""

for arg in "$@"; do
  case "$arg" in
    --stack-only)    STACK_ONLY=true ;;
    --encode)        ENCODE=true ;;
    --all-platforms) ALL_PLATFORMS=true ;;
    --arm64)         SPECIFIC_ARCH="arm64" ;;
    --amd64)         SPECIFIC_ARCH="amd64" ;;
    --publish)       PUBLISH=true ;;
    --clean)         CLEAN=true ;;
    --clean-cache)   CLEAN_CACHE=true ;;
    *) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── validation ───────────────────────────────────────────────────────────────

platform_count=0
[[ "$ALL_PLATFORMS" == true ]] && platform_count=$((platform_count + 1))
[[ -n "$SPECIFIC_ARCH" ]] && platform_count=$((platform_count + 1))
if [[ $platform_count -gt 1 ]]; then
  echo "Error: --all-platforms, --arm64, and --amd64 are mutually exclusive" >&2
  exit 1
fi

if [[ "$STACK_ONLY" == true && "$PUBLISH" == true ]]; then
  echo "Error: --stack-only --publish is invalid — av1-stack is never published" >&2
  exit 1
fi

if [[ "$CLEAN" == true || "$CLEAN_CACHE" == true ]]; then
  for flag in "$STACK_ONLY" "$ENCODE" "$PUBLISH"; do
    if [[ "$flag" == true ]]; then
      echo "Error: --clean/--clean-cache cannot be combined with build/test/publish flags" >&2
      exit 1
    fi
  done
fi
```

- [ ] **Step 2: Add helper functions**

Append to `build.sh` after the validation block:

```bash
# ── helpers ──────────────────────────────────────────────────────────────────

native_arch() {
  case "$(uname -m)" in
    x86_64)        echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
  esac
}

ensure_builder() {
  if ! docker buildx inspect "${BUILDER_NAME}" > /dev/null 2>&1; then
    echo "==> Creating buildx builder '${BUILDER_NAME}'..."
    docker buildx create --name "${BUILDER_NAME}" --driver docker-container
  fi
}

check_ghcr_auth() {
  local auth
  auth=$(python3 -c "
import json, os
try:
    cfg = json.load(open(os.path.expanduser('~/.docker/config.json')))
    a = cfg.get('auths', {}).get('ghcr.io', {})
    print('ok' if a.get('auth') else 'missing')
except Exception:
    print('missing')
" 2>/dev/null)
  if [[ "$auth" != "ok" ]]; then
    echo "Not authenticated to ghcr.io. Run:" >&2
    echo "  gh auth token | docker login ghcr.io -u <github-username> --password-stdin" >&2
    exit 1
  fi
}
```

- [ ] **Step 3: Add result collection and summary display**

Append to `build.sh` after the helpers:

```bash
# ── result collection ────────────────────────────────────────────────────────

declare -a RESULTS=()

add_result() {
  local platform="$1" label="$2" status="$3"
  RESULTS+=("${platform}|${label}|${status}")
}

print_summary() {
  if [[ ${#RESULTS[@]} -eq 0 ]]; then
    return 0
  fi

  echo ""
  echo "════════════════════════════════════════"
  echo "  Test Summary"
  echo "════════════════════════════════════════"

  local current_platform=""
  for entry in "${RESULTS[@]}"; do
    IFS='|' read -r platform label status <<< "$entry"
    if [[ "$platform" != "$current_platform" ]]; then
      [[ -n "$current_platform" ]] && echo ""
      echo "  ${platform}"
      current_platform="$platform"
    fi
    printf "    %-28s %s\n" "$label" "$status"
  done

  local failed=0
  for entry in "${RESULTS[@]}"; do
    [[ "$entry" == *"|FAILED" ]] && failed=$((failed + 1))
  done

  echo "════════════════════════════════════════"
  if [[ $failed -gt 0 ]]; then
    echo "  FAILED: ${failed} check(s) failed"
  else
    echo "  All checks passed"
  fi
  echo "════════════════════════════════════════"

  return "$failed"
}
```

- [ ] **Step 4: Run shellcheck**

Run: `shellcheck build.sh`
Expected: No errors (warnings about `read` splitting are acceptable).

- [ ] **Step 5: Commit**

```bash
git add build.sh
git commit -m "feat: add build.sh skeleton with flag parsing, helpers, result collection"
```

---

### Task 2: Add build and test functions

**Files:**
- Modify: `build.sh`

- [ ] **Step 1: Add build functions**

Append to `build.sh` after the result collection section:

```bash
# ── build ────────────────────────────────────────────────────────────────────

build_stack() {
  local platform="$1" arch="$2"
  echo "==> Building av1-stack (${platform})..."
  docker buildx build \
    --builder "${BUILDER_NAME}" \
    --platform "${platform}" \
    --target av1-stack \
    --output "type=docker,name=av1-stack:${arch}" \
    .
}

build_tdarr() {
  local platform="$1" arch="$2"
  echo "==> Building tdarr (${platform})..."
  docker buildx build \
    --builder "${BUILDER_NAME}" \
    --platform "${platform}" \
    --target tdarr \
    --output "type=docker,name=tdarr:${arch}" \
    .
  echo "==> Building tdarr_node (${platform})..."
  docker buildx build \
    --builder "${BUILDER_NAME}" \
    --platform "${platform}" \
    --target tdarr_node \
    --output "type=docker,name=tdarr_node:${arch}" \
    .
}
```

- [ ] **Step 2: Add binary check function**

Append after the build functions:

```bash
# ── tests ────────────────────────────────────────────────────────────────────

run_binary_checks() {
  local image="$1" label="$2" platform="$3"

  echo -n "Binary checks ${label} (${platform})... "
  for bin in "${BINARIES[@]}"; do
    local version_flag="--version"
    [[ "$bin" == "ffmpeg" ]] && version_flag="-version"
    if docker run --rm --entrypoint "" --platform "${platform}" "${image}" \
        "$bin" $version_flag > /dev/null 2>&1; then
      add_result "$platform" "${bin} (${label})" "OK"
    else
      add_result "$platform" "${bin} (${label})" "FAILED"
    fi
  done
  echo "done"
}
```

- [ ] **Step 3: Add startup check function**

Append after binary checks:

```bash
run_startup_check() {
  local platform="$1" arch="$2"
  local net="tdarr-test-net-$$"
  local server_cid="" node_cid="" state="" server_ok=false

  echo -n "Startup check (${platform})... "

  docker network create "$net" > /dev/null 2>&1 || true

  if docker network inspect "$net" > /dev/null 2>&1; then
    server_cid=$(docker run -d \
      --network "$net" \
      --name "tdarr-server-$$" \
      --platform "${platform}" \
      -e serverIP=0.0.0.0 \
      -e serverPort=8266 \
      -e webUIPort=8265 \
      -e internalNode=false \
      "tdarr:${arch}") || true
  fi

  if [[ -n "$server_cid" ]]; then
    for i in $(seq 1 30); do
      if docker exec "$server_cid" curl -sf http://localhost:8265 > /dev/null 2>&1; then
        server_ok=true
        break
      fi
      sleep 1
    done
  fi

  if [[ "$server_ok" == true ]]; then
    node_cid=$(docker run -d \
      --network "$net" \
      --platform "${platform}" \
      -e serverIP="tdarr-server-$$" \
      -e serverPort=8266 \
      -e nodeName=test-node \
      "tdarr_node:${arch}") || true

    if [[ -n "$node_cid" ]]; then
      sleep 10
      state=$(docker inspect --format '{{.State.Status}}' "$node_cid" 2>/dev/null || echo "missing")
    fi
  fi

  # Cleanup
  [[ -n "$node_cid"   ]] && { docker stop "$node_cid"   > /dev/null 2>&1 || true; docker rm "$node_cid"   > /dev/null 2>&1 || true; }
  [[ -n "$server_cid" ]] && { docker stop "$server_cid" > /dev/null 2>&1 || true; docker rm "$server_cid" > /dev/null 2>&1 || true; }
  docker rm -f "tdarr-server-$$" > /dev/null 2>&1 || true
  docker network rm "$net" > /dev/null 2>&1 || true

  if [[ "$server_ok" == true ]]; then
    add_result "$platform" "tdarr server" "OK"
  else
    add_result "$platform" "tdarr server" "FAILED"
  fi

  if [[ "${state}" == "running" ]]; then
    add_result "$platform" "tdarr_node alive" "OK"
  else
    add_result "$platform" "tdarr_node alive" "FAILED"
  fi

  echo "done"
}
```

- [ ] **Step 4: Add encode test function**

Append after startup check:

```bash
run_encode_test() {
  local image="$1" output_dir="$2" platform="$3"
  local samples_dir="${SCRIPT_DIR}/test/samples"

  local -a SAMPLE_FILES=()
  while IFS= read -r -d '' f; do
    SAMPLE_FILES+=("$f")
  done < <(find "$samples_dir" -maxdepth 1 -type f ! -name '.gitkeep' ! -name '.*' -print0)

  if [[ ${#SAMPLE_FILES[@]} -eq 0 ]]; then
    echo "WARNING: No sample files in test/samples/ — skipping encode tests"
    return 0
  fi

  echo -n "Encode tests (${platform}, ${#SAMPLE_FILES[@]} sample(s))... "

  for sample in "${SAMPLE_FILES[@]}"; do
    local filename stem
    filename="$(basename "$sample")"
    stem="${filename%.*}"

    local container_exit=0
    docker run --rm --entrypoint "" \
      --platform "${platform}" \
      -v "${samples_dir}:/samples:ro" \
      -v "${output_dir}:/output" \
      "${image}" bash -c '
        set -e
        ffmpeg -y -ss 00:01:00 -t 60 -i "/samples/$1" -c copy "/output/$2_clip.mkv" 2>/dev/null
        av1an -i "/output/$2_clip.mkv" --encoder aom --target-quality 90 --verbose \
          -o "/output/$2_av1an_aom.mkv"
        av1an -i "/output/$2_clip.mkv" --encoder svt-av1 --target-quality 90 --verbose \
          -o "/output/$2_av1an_svtav1.mkv"
        ab-av1 auto-encode -i "/output/$2_clip.mkv" --min-vmaf 90 \
          -o "/output/$2_ab-av1.mkv"
      ' -- "$filename" "$stem" \
      || container_exit=$?

    for suffix in _av1an_aom.mkv _av1an_svtav1.mkv _ab-av1.mkv; do
      local outfile="${output_dir}/${stem}${suffix}"
      local label="encode ${stem}${suffix}"
      if [[ $container_exit -ne 0 ]]; then
        add_result "$platform" "$label" "FAILED"
      elif [[ -f "$outfile" ]] && [[ -s "$outfile" ]]; then
        add_result "$platform" "$label" "OK"
      else
        add_result "$platform" "$label" "FAILED"
      fi
    done
  done

  echo "done"
}
```

- [ ] **Step 5: Run shellcheck**

Run: `shellcheck build.sh`
Expected: No errors.

- [ ] **Step 6: Commit**

```bash
git add build.sh
git commit -m "feat(build.sh): add build and test functions"
```

---

### Task 3: Add publish, clean, and main orchestration

**Files:**
- Modify: `build.sh`

- [ ] **Step 1: Add publish functions**

Append to `build.sh` after the test functions:

```bash
# ── publish ──────────────────────────────────────────────────────────────────

check_local_images() {
  local -a required=("$@")
  local -a missing=()

  for img in "${required[@]}"; do
    if ! docker image inspect "$img" > /dev/null 2>&1; then
      missing+=("$img")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Missing test images: ${missing[*]}" >&2
    echo "Run ./build.sh first to build and test them." >&2
    return 1
  fi
}

publish_images() {
  local -a arches=("$@")

  for target in tdarr tdarr_node; do
    if [[ ${#arches[@]} -gt 1 ]]; then
      for arch in "${arches[@]}"; do
        echo "==> Pushing ${REGISTRY}/${target}:${arch}..."
        docker tag "${target}:${arch}" "${REGISTRY}/${target}:${arch}"
        docker push "${REGISTRY}/${target}:${arch}"
      done
      echo "==> Creating manifest ${REGISTRY}/${target}:latest..."
      docker manifest create --amend "${REGISTRY}/${target}:latest" \
        "${REGISTRY}/${target}:amd64" \
        "${REGISTRY}/${target}:arm64"
      docker manifest push "${REGISTRY}/${target}:latest"
    else
      local arch="${arches[0]}"
      echo "==> Pushing ${REGISTRY}/${target}:latest..."
      docker tag "${target}:${arch}" "${REGISTRY}/${target}:latest"
      docker push "${REGISTRY}/${target}:latest"
    fi
  done
}
```

- [ ] **Step 2: Add clean functions**

Append after publish functions:

```bash
# ── clean ────────────────────────────────────────────────────────────────────

do_clean() {
  echo "==> Cleaning..."
  for target in tdarr tdarr_node av1-stack; do
    for arch in amd64 arm64; do
      docker rmi "${target}:${arch}" 2>/dev/null || true
    done
  done
  find "${SCRIPT_DIR}/test/output/stack" -mindepth 1 ! -name '.gitkeep' -delete 2>/dev/null || true
  find "${SCRIPT_DIR}/test/output/tdarr" -mindepth 1 ! -name '.gitkeep' -delete 2>/dev/null || true
  docker buildx stop "${BUILDER_NAME}" 2>/dev/null || true

  if [[ "$CLEAN_CACHE" == true ]]; then
    echo "==> Pruning buildx cache..."
    docker buildx prune --builder "${BUILDER_NAME}" --force 2>/dev/null || true
  fi

  echo "Done."
}
```

- [ ] **Step 3: Add main orchestration**

Append at the end of `build.sh`:

```bash
# ── main ─────────────────────────────────────────────────────────────────────

# Handle clean modes (standalone, exits early)
if [[ "$CLEAN" == true || "$CLEAN_CACHE" == true ]]; then
  do_clean
  exit 0
fi

# Resolve target platforms
if [[ "$ALL_PLATFORMS" == true ]]; then
  ARCHES=(amd64 arm64)
elif [[ -n "$SPECIFIC_ARCH" ]]; then
  ARCHES=("$SPECIFIC_ARCH")
else
  ARCHES=("$(native_arch)")
fi

# Early GHCR auth check if publishing
if [[ "$PUBLISH" == true ]]; then
  check_ghcr_auth
fi

ensure_builder

# Determine if this is a publish-only run (--publish with no test-triggering flags)
PUBLISH_ONLY=false
if [[ "$PUBLISH" == true && "$ENCODE" == false && "$STACK_ONLY" == false ]]; then
  # Check if all required images already exist locally
  local_images_exist=true
  for arch in "${ARCHES[@]}"; do
    for target in tdarr tdarr_node; do
      if ! docker image inspect "${target}:${arch}" > /dev/null 2>&1; then
        local_images_exist=false
        break 2
      fi
    done
  done
  if [[ "$local_images_exist" == true ]]; then
    PUBLISH_ONLY=true
  fi
fi

if [[ "$PUBLISH_ONLY" == false ]]; then
  # Build and test
  for arch in "${ARCHES[@]}"; do
    platform="linux/${arch}"

    if [[ "$STACK_ONLY" == true ]]; then
      build_stack "$platform" "$arch"
      run_binary_checks "av1-stack:${arch}" "av1-stack" "$platform"
      if [[ "$ENCODE" == true ]]; then
        run_encode_test "av1-stack:${arch}" "${SCRIPT_DIR}/test/output/stack" "$platform"
      fi
    else
      build_tdarr "$platform" "$arch"
      run_binary_checks "tdarr:${arch}" "tdarr" "$platform"
      run_binary_checks "tdarr_node:${arch}" "tdarr_node" "$platform"
      run_startup_check "$platform" "$arch"
      if [[ "$ENCODE" == true ]]; then
        run_encode_test "tdarr:${arch}" "${SCRIPT_DIR}/test/output/tdarr" "$platform"
      fi
    fi
  done

  # Print summary and capture exit status
  print_summary || {
    exit 1
  }
fi

# Publish if requested
if [[ "$PUBLISH" == true ]]; then
  declare -a required=()
  for arch in "${ARCHES[@]}"; do
    required+=("tdarr:${arch}" "tdarr_node:${arch}")
  done
  check_local_images "${required[@]}"

  publish_images "${ARCHES[@]}"

  echo ""
  echo "Done. Images published:"
  echo "  ${REGISTRY}/tdarr:latest"
  echo "  ${REGISTRY}/tdarr_node:latest"
fi
```

Note: The `PUBLISH_ONLY` logic works as follows — when `--publish` is the only action flag (no `--encode`, no `--stack-only`) AND all required images already exist locally, the build+test phase is skipped entirely. If images are missing, it falls through to build+test first. This means:
- `./build.sh --all-platforms` then `./build.sh --publish --all-platforms` → second run skips build, just pushes
- `./build.sh --all-platforms --publish` on a fresh machine → builds+tests+publishes
- `./build.sh --all-platforms --encode --publish` → always builds+tests(with encode)+publishes

- [ ] **Step 4: Make executable and run shellcheck**

Run: `chmod +x build.sh && shellcheck build.sh`
Expected: No errors.

- [ ] **Step 5: Commit**

```bash
git add build.sh
git commit -m "feat(build.sh): add publish, clean, and main orchestration"
```

---

### Task 4: Delete old scripts and update docs

**Files:**
- Delete: `test-stack.sh`
- Delete: `test-tdarr.sh`
- Delete: `publish.sh`
- Modify: `docs/build-and-publish.md`

- [ ] **Step 1: Delete old scripts**

```bash
git rm test-stack.sh test-tdarr.sh publish.sh
```

- [ ] **Step 2: Rewrite docs/build-and-publish.md**

Replace the entire contents of `docs/build-and-publish.md` with:

```markdown
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

## Merge workflow

1. Run `./build.sh` locally — must pass
2. Open PR from `dev` to `main`
3. Merge

## Release workflow

1. Run `./build.sh --all-platforms --encode` locally — must pass (requires sample files)
2. Merge `dev` → `main`
3. Run `./build.sh --publish --all-platforms` — pushes tested images to GHCR

## Binary list

`build.sh` checks these binaries: `av1an`, `ab-av1`, `ffmpeg`.
Update the `BINARIES` array in `build.sh` when new binaries are added to `Dockerfile`.
```

- [ ] **Step 3: Commit**

```bash
git add -A docs/build-and-publish.md
git commit -m "refactor: replace test-stack/test-tdarr/publish with unified build.sh

Delete test-stack.sh, test-tdarr.sh, and publish.sh.
Rewrite docs/build-and-publish.md for the new single-script workflow."
```

---

### Task 5: Smoke test

**Files:** None (manual verification)

- [ ] **Step 1: Verify flag parsing works**

Run: `./build.sh --help-test 2>&1 || true`
Expected: "Unknown flag: --help-test" error message.

Run: `./build.sh --all-platforms --arm64 2>&1 || true`
Expected: "mutually exclusive" error message.

Run: `./build.sh --stack-only --publish 2>&1 || true`
Expected: "av1-stack is never published" error message.

Run: `./build.sh --clean --publish 2>&1 || true`
Expected: "cannot be combined" error message.

- [ ] **Step 2: Run a native build + test**

Run: `./build.sh`
Expected: Builds tdarr + tdarr_node for native arch. Binary checks and startup check run. Summary table prints at the end with all results.

- [ ] **Step 3: Verify publish-only mode detects existing images**

Run: `./build.sh --publish 2>&1` (without GHCR auth — expect auth error, confirming it reached the publish path without rebuilding).

- [ ] **Step 4: Verify clean works**

Run: `./build.sh --clean`
Expected: Removes images, cleans test output, stops builder. Prints "Done."
