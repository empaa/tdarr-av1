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

  if [[ "$name" == "tdarr" ]]; then
    local cid="" ok=false
    cid=$(docker run -d \
      -p 8265:8265 \
      -e serverIP=0.0.0.0 \
      -e serverPort=8266 \
      -e webUIPort=8265 \
      -e internalNode=false \
      "${image}") || true

    if [[ -n "$cid" ]]; then
      for i in $(seq 1 30); do
        if curl -sf http://localhost:8265 > /dev/null 2>&1; then
          ok=true
          break
        fi
        sleep 1
      done
    fi

    [[ -n "$cid" ]] && { docker stop "$cid" > /dev/null 2>&1 || true; docker rm "$cid" > /dev/null 2>&1 || true; }

    printf "  %-20s" "startup (HTTP)"
    if [[ "$ok" == true ]]; then
      echo "OK"
      return 0
    else
      echo "FAILED (timeout after 30s)"
      return 1
    fi

  else
    # tdarr_node needs a live server to connect to.
    # Start a tdarr server on a private bridge network, then start the node on the same
    # network. The node stays running if it can connect; check after 10 seconds.
    local net="tdarr-test-net-$$"
    local server_cid="" node_cid="" state="" server_image
    server_image="tdarr-test:${arch}"

    # All resource creation uses || true so set -e cannot skip cleanup.
    docker network create "$net" > /dev/null 2>&1 || true

    if docker network inspect "$net" > /dev/null 2>&1; then
      server_cid=$(docker run -d \
        --network "$net" \
        --name "tdarr-server-$$" \
        -e serverIP=0.0.0.0 \
        -e serverPort=8266 \
        -e webUIPort=8265 \
        -e internalNode=false \
        "${server_image}") || true
    fi

    # Wait up to 20s for the server HTTP port to respond (polled from inside the container).
    local server_ok=false
    if [[ -n "$server_cid" ]]; then
      for i in $(seq 1 20); do
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
        -e serverIP="tdarr-server-$$" \
        -e serverPort=8266 \
        -e nodeName=test-node \
        "${image}") || true

      if [[ -n "$node_cid" ]]; then
        sleep 10
        state=$(docker inspect --format '{{.State.Status}}' "$node_cid" 2>/dev/null || echo "missing")
      fi
    fi

    # Unconditional cleanup — runs regardless of how we got here.
    [[ -n "$node_cid"   ]] && { docker stop "$node_cid"   > /dev/null 2>&1 || true; docker rm "$node_cid"   > /dev/null 2>&1 || true; }
    [[ -n "$server_cid" ]] && { docker stop "$server_cid" > /dev/null 2>&1 || true; docker rm "$server_cid" > /dev/null 2>&1 || true; }
    docker rm -f "tdarr-server-$$" > /dev/null 2>&1 || true
    docker network rm "$net" > /dev/null 2>&1 || true

    printf "  %-20s" "startup (alive)"
    if [[ "$server_ok" != true ]]; then
      echo "FAILED (server did not start)"
      return 1
    elif [[ "${state}" == "running" ]]; then
      echo "OK"
      return 0
    else
      echo "FAILED (state: ${state:-unknown})"
      return 1
    fi
  fi
}

run_encode_test() {
  local name="$1" arch="$2"
  local image="${name}-test:${arch}"
  local samples_dir="${SCRIPT_DIR}/test/samples"
  local output_dir="${SCRIPT_DIR}/test/output/${name}"

  local -a SAMPLE_FILES=()
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
