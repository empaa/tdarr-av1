#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC2034  # used by later tasks
REGISTRY="ghcr.io/empaa"
BUILDER_NAME="multiplatform"
# shellcheck disable=SC2034  # used by later tasks
BINARIES=(av1an ab-av1 ffmpeg)

STACK_ONLY=false
ENCODE=false
PUBLISH=false
CLEAN=false
CLEAN_CACHE=false
ALL_PLATFORMS=false
INTERACTIVE=false
SPECIFIC_ARCH=""
ARCH_COUNT=0

# shellcheck disable=SC2034  # SPECIFIC_ARCH, ARCH_COUNT used by later tasks
for arg in "$@"; do
  case "$arg" in
    --stack-only)    STACK_ONLY=true ;;
    --encode)        ENCODE=true ;;
    --all-platforms) ALL_PLATFORMS=true ;;
    --arm64)         SPECIFIC_ARCH="arm64"; ARCH_COUNT=$((ARCH_COUNT + 1)) ;;
    --amd64)         SPECIFIC_ARCH="amd64"; ARCH_COUNT=$((ARCH_COUNT + 1)) ;;
    --publish)       PUBLISH=true ;;
    --clean)         CLEAN=true ;;
    --clean-cache)   CLEAN_CACHE=true ;;
    --interactive)   INTERACTIVE=true ;;
    *) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

# shellcheck disable=SC2034  # SCRIPT_DIR used by later tasks
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── validation ───────────────────────────────────────────────────────────────

platform_count=0
[[ "$ALL_PLATFORMS" == true ]] && platform_count=$((platform_count + 1))
platform_count=$((platform_count + ARCH_COUNT))
if [[ $platform_count -gt 1 ]]; then
  echo "Error: --all-platforms, --arm64, and --amd64 are mutually exclusive" >&2
  exit 1
fi

if [[ "$STACK_ONLY" == true && "$PUBLISH" == true ]]; then
  echo "Error: --stack-only --publish is invalid — av1-stack is never published" >&2
  exit 1
fi

if [[ "$CLEAN" == true || "$CLEAN_CACHE" == true ]]; then
  for flag in "$STACK_ONLY" "$ENCODE" "$PUBLISH" "$INTERACTIVE"; do
    if [[ "$flag" == true ]]; then
      echo "Error: --clean/--clean-cache cannot be combined with build/test/publish flags" >&2
      exit 1
    fi
  done
fi

if [[ "$INTERACTIVE" == true && "$STACK_ONLY" == true ]]; then
  echo "Error: --interactive requires full tdarr_node image, not --stack-only" >&2
  exit 1
fi

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

# ── build ────────────────────────────────────────────────────────────────────

build_stack() {
  local platform="$1" arch="$2"
  echo "==> Building av1-stack (${platform})..."
  ARCH="${arch}" PLATFORM="${platform}" \
    docker buildx bake \
    --builder "${BUILDER_NAME}" \
    stack-only
}

build_tdarr() {
  local platform="$1" arch="$2"
  echo "==> Building tdarr + tdarr_node (${platform})..."
  ARCH="${arch}" PLATFORM="${platform}" \
    docker buildx bake \
    --builder "${BUILDER_NAME}" \
    default
}

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
    for _ in $(seq 1 30); do
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

run_encode_test() {
  local image="$1" output_dir="$2" platform="$3"
  local samples_dir="${SCRIPT_DIR}/test/samples"

  local -a SAMPLE_FILES=()
  while IFS= read -r -d '' f; do
    SAMPLE_FILES+=("$f")
  done < <(find "$samples_dir" -maxdepth 1 -type f ! -name '.gitkeep' ! -name '.*' -print0)

  if [[ ${#SAMPLE_FILES[@]} -eq 0 ]]; then
    echo "==> No sample files found, generating synthetic clip..."
    bash "${SCRIPT_DIR}/test/genSample.sh"
    # Re-scan after generation
    while IFS= read -r -d '' f; do
      SAMPLE_FILES+=("$f")
    done < <(find "$samples_dir" -maxdepth 1 -type f ! -name '.gitkeep' ! -name '.*' -print0)
    if [[ ${#SAMPLE_FILES[@]} -eq 0 ]]; then
      echo "ERROR: Sample generation failed — skipping encode tests" >&2
      return 1
    fi
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
        # Get duration; skip clip extraction for short files (< 120s)
        duration=$(ffprobe -v error -show_entries format=duration \
          -of csv=p=0 "/samples/$1" 2>/dev/null | cut -d. -f1)
        if [[ "${duration:-0}" -ge 120 ]]; then
          ffmpeg -y -ss 00:01:00 -t 60 -i "/samples/$1" -c copy "/output/$2_clip.mkv" 2>/dev/null
        else
          cp "/samples/$1" "/output/$2_clip.mkv"
        fi
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

# ── interactive ──────────────────────────────────────────────────────────────

run_interactive() {
  local arch="$1" platform="linux/${arch}"
  local samples_dir="${SCRIPT_DIR}/test/samples"
  local output_dir="${SCRIPT_DIR}/test/output/interactive"
  local config_dir="${SCRIPT_DIR}/test/tdarr_config"
  local net="tdarr-interactive-net"
  local server_name="tdarr-interactive-server"
  local node_name="tdarr-interactive-node"

  mkdir -p "$output_dir" \
    "${config_dir}/server" "${config_dir}/configs" \
    "${config_dir}/logs" "${config_dir}/temp"

  # Clean up any leftover containers from a previous run
  docker rm -f "$server_name" "$node_name" > /dev/null 2>&1 || true
  docker network rm "$net" > /dev/null 2>&1 || true

  docker network create "$net" > /dev/null 2>&1

  echo ""
  echo "════════════════════════════════════════"
  echo "  Starting Tdarr (${platform})"
  echo "════════════════════════════════════════"
  echo ""

  # Start server with dashboard exposed and media mounted
  echo "==> Starting tdarr server..."
  docker run -d \
    --network "$net" \
    --name "$server_name" \
    --platform "${platform}" \
    -p 8265:8265 \
    -e serverIP=0.0.0.0 \
    -e serverPort=8266 \
    -e webUIPort=8265 \
    -e internalNode=false \
    -v "${samples_dir}:/media/samples" \
    -v "${output_dir}:/media/output" \
    -v "${config_dir}/server:/app/server" \
    -v "${config_dir}/configs:/app/configs" \
    -v "${config_dir}/logs:/app/logs" \
    -v "${config_dir}/temp:/temp" \
    "tdarr:${arch}" > /dev/null

  # Wait for server to be ready
  echo -n "==> Waiting for server..."
  local server_ok=false
  for _ in $(seq 1 60); do
    if docker exec "$server_name" curl -sf http://localhost:8265 > /dev/null 2>&1; then
      server_ok=true
      break
    fi
    echo -n "."
    sleep 1
  done
  echo ""

  if [[ "$server_ok" != true ]]; then
    echo "ERROR: Server failed to start. Logs:" >&2
    docker logs "$server_name" 2>&1 | tail -20
    docker rm -f "$server_name" > /dev/null 2>&1 || true
    docker network rm "$net" > /dev/null 2>&1 || true
    return 1
  fi

  # Start node connected to server, with same media mounts
  echo "==> Starting tdarr_node..."
  docker run -d \
    --network "$net" \
    --name "$node_name" \
    --platform "${platform}" \
    -e serverIP="$server_name" \
    -e serverPort=8266 \
    -e nodeName=test-node \
    -v "${samples_dir}:/media/samples" \
    -v "${output_dir}:/media/output" \
    -v "${config_dir}/configs:/app/configs" \
    -v "${config_dir}/logs:/app/logs" \
    -v "${config_dir}/temp:/temp" \
    "tdarr_node:${arch}" > /dev/null

  echo ""
  echo "════════════════════════════════════════"
  echo "  Tdarr is running"
  echo "════════════════════════════════════════"
  echo ""
  echo "  Dashboard:  http://localhost:8265"
  echo ""
  echo "  Media paths inside containers:"
  echo "    /media/samples  <- test/samples/"
  echo "    /media/output   <- test/output/interactive/"
  echo ""
  echo "  Config persisted at: test/tdarr_config/"
  echo ""
  echo "  Press Enter to stop and clean up..."
  echo "════════════════════════════════════════"

  read -r

  echo "==> Stopping containers..."
  docker rm -f "$node_name" "$server_name" > /dev/null 2>&1 || true
  docker network rm "$net" > /dev/null 2>&1 || true
  echo "Done."
}

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
      docker manifest rm "${REGISTRY}/${target}:latest" 2>/dev/null || true
      docker manifest create "${REGISTRY}/${target}:latest" \
        "${REGISTRY}/${target}:amd64" \
        "${REGISTRY}/${target}:arm64"
      docker manifest push --purge "${REGISTRY}/${target}:latest"
    else
      local arch="${arches[0]}"
      echo "==> Pushing ${REGISTRY}/${target}:latest..."
      docker tag "${target}:${arch}" "${REGISTRY}/${target}:latest"
      docker push "${REGISTRY}/${target}:latest"
    fi
  done
}

# ── clean ────────────────────────────────────────────────────────────────────

do_clean() {
  echo "==> Cleaning local images and test output..."
  for target in tdarr tdarr_node av1-stack; do
    for arch in amd64 arm64; do
      docker rmi "${target}:${arch}" 2>/dev/null || true
    done
  done
  find "${SCRIPT_DIR}/test/output/stack" -mindepth 1 ! -name '.gitkeep' -delete 2>/dev/null || true
  find "${SCRIPT_DIR}/test/output/tdarr" -mindepth 1 ! -name '.gitkeep' -delete 2>/dev/null || true

  if [[ "$CLEAN_CACHE" == true ]]; then
    echo "==> Removing local build cache..."
    rm -rf "${SCRIPT_DIR}/.buildcache"
    echo "==> Stopping builder and pruning buildx cache..."
    docker buildx stop "${BUILDER_NAME}" 2>/dev/null || true
    docker buildx prune --builder "${BUILDER_NAME}" --force 2>/dev/null || true
  fi

  echo "Done."
}

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

# Determine if this is a publish-only run (--publish with no build-triggering flags)
PUBLISH_ONLY=false
if [[ "$PUBLISH" == true && "$ENCODE" == false && "$STACK_ONLY" == false \
      && "$ALL_PLATFORMS" == false && -z "$SPECIFIC_ARCH" ]]; then
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
  ensure_builder
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

# Interactive Tdarr stack if requested
if [[ "$INTERACTIVE" == true ]]; then
  run_interactive "${ARCHES[0]}"
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
