#!/usr/bin/env bash
set -euo pipefail

BINARIES=(av1an ab-av1 ffmpeg)
ENCODE=false
ALL_PLATFORMS=false
CLEAN=false
BUILDER_NAME="multiplatform"

for arg in "$@"; do
  case "$arg" in
    --encode)        ENCODE=true ;;
    --all-platforms) ALL_PLATFORMS=true ;;
    --clean)         CLEAN=true ;;
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

build_images() {
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

ensure_builder() {
  if ! docker buildx inspect "${BUILDER_NAME}" > /dev/null 2>&1; then
    echo "==> Creating buildx builder '${BUILDER_NAME}'..."
    docker buildx create --name "${BUILDER_NAME}" --driver docker-container
  fi
}

run_binary_checks() {
  local platform="$1" arch="$2"
  local failed=0

  echo ""
  echo "Binary checks (${platform})..."
  for name in tdarr tdarr_node; do
    local image="${name}:${arch}"
    echo "  [${name}]"
    for bin in "${BINARIES[@]}"; do
      printf "    %-12s" "$bin"
      local version_flag="--version"
      [[ "$bin" == "ffmpeg" ]] && version_flag="-version"
      if docker run --rm --entrypoint "" --platform "${platform}" "${image}" \
          "$bin" $version_flag > /dev/null 2>&1; then
        echo "OK"
      else
        echo "FAILED"
        failed=$((failed + 1))
      fi
    done
  done

  if [[ $failed -gt 0 ]]; then
    echo "FAILED: $failed binary check(s) for ${platform}"
    return 1
  fi
  echo "All binary checks passed (${platform})"
}

run_startup_check() {
  local platform="$1" arch="$2"
  local net="tdarr-test-net-$$"
  local server_cid="" node_cid="" state="" server_ok=false

  echo ""
  echo "Startup check (${platform})..."

  # All resource creation uses || true so set -e cannot skip cleanup.
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

  # Wait up to 30s for the server HTTP port to respond (polled from inside the container).
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

  # Unconditional cleanup — runs regardless of how we got here.
  [[ -n "$node_cid"   ]] && { docker stop "$node_cid"   > /dev/null 2>&1 || true; docker rm "$node_cid"   > /dev/null 2>&1 || true; }
  [[ -n "$server_cid" ]] && { docker stop "$server_cid" > /dev/null 2>&1 || true; docker rm "$server_cid" > /dev/null 2>&1 || true; }
  docker rm -f "tdarr-server-$$" > /dev/null 2>&1 || true
  docker network rm "$net" > /dev/null 2>&1 || true

  printf "  %-20s" "tdarr server"
  if [[ "$server_ok" == true ]]; then
    echo "OK"
  else
    echo "FAILED (timeout after 30s)"
    return 1
  fi

  printf "  %-20s" "tdarr_node alive"
  if [[ "${state}" == "running" ]]; then
    echo "OK"
    return 0
  else
    echo "FAILED (state: ${state:-unknown})"
    return 1
  fi
}

run_encode_test() {
  local platform="$1" arch="$2"
  local image="tdarr:${arch}"
  local samples_dir="${SCRIPT_DIR}/test/samples"
  local output_dir="${SCRIPT_DIR}/test/output/tdarr"

  local -a SAMPLE_FILES=()
  while IFS= read -r -d '' f; do
    SAMPLE_FILES+=("$f")
  done < <(find "$samples_dir" -maxdepth 1 -type f ! -name '.gitkeep' ! -name '.*' -print0)

  if [[ ${#SAMPLE_FILES[@]} -eq 0 ]]; then
    echo "WARNING: No sample files in test/samples/ — skipping encode tests"
    return 0
  fi

  echo ""
  echo "Encode tests (${platform}, ${#SAMPLE_FILES[@]} sample(s))..."
  local failed=0
  local -a failures=()

  for sample in "${SAMPLE_FILES[@]}"; do
    local filename stem
    filename="$(basename "$sample")"
    stem="${filename%.*}"
    echo "  Sample: ${filename}"

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
      local label="${stem}${suffix}"
      printf "    %-44s" "$label"
      if [[ $container_exit -ne 0 ]]; then
        echo "FAILED (container exited ${container_exit})"
        failures+=("${label}: container exited ${container_exit}")
        failed=$((failed + 1))
      elif [[ -f "$outfile" ]] && [[ -s "$outfile" ]]; then
        echo "OK"
      else
        echo "FAILED (missing or empty)"
        failures+=("${label}: output missing or empty")
        failed=$((failed + 1))
      fi
    done
  done

  if [[ $failed -gt 0 ]]; then
    echo "FAILED: ${failed} encode check(s):"
    for f in "${failures[@]}"; do echo "  - $f"; done
    return 1
  fi
  echo "All encode tests passed (${platform})"
}

# ── clean ─────────────────────────────────────────────────────────────────────

if [[ "$CLEAN" == true ]]; then
  echo "==> Cleaning..."
  docker rmi tdarr:amd64 2>/dev/null || true
  docker rmi tdarr:arm64 2>/dev/null || true
  docker rmi tdarr_node:amd64 2>/dev/null || true
  docker rmi tdarr_node:arm64 2>/dev/null || true
  find "${SCRIPT_DIR}/test/output/tdarr"      -mindepth 1 ! -name '.gitkeep' -delete
  find "${SCRIPT_DIR}/test/output/tdarr_node" -mindepth 1 ! -name '.gitkeep' -delete
  docker buildx stop "${BUILDER_NAME}" 2>/dev/null || true
  echo "Done."
  exit 0
fi

# ── run ───────────────────────────────────────────────────────────────────────

OVERALL_FAILED=0

if [[ "$ALL_PLATFORMS" == true ]]; then
  PLATFORMS=(linux/amd64 linux/arm64)
else
  ARCH=$(native_arch)
  PLATFORMS=("linux/${ARCH}")
fi

ensure_builder

for platform in "${PLATFORMS[@]}"; do
  arch="${platform#linux/}"
  build_images "$platform" "$arch"
  run_binary_checks "$platform" "$arch" || OVERALL_FAILED=$((OVERALL_FAILED + 1))
  run_startup_check "$platform" "$arch" || OVERALL_FAILED=$((OVERALL_FAILED + 1))
  if [[ "$ENCODE" == true ]]; then
    run_encode_test "$platform" "$arch" || OVERALL_FAILED=$((OVERALL_FAILED + 1))
  fi
done

echo ""
if [[ $OVERALL_FAILED -gt 0 ]]; then
  echo "FAILED: ${OVERALL_FAILED} check(s) failed"
  exit 1
fi

if [[ "$ALL_PLATFORMS" == true ]]; then
  echo "All checks passed (linux/amd64, linux/arm64)"
else
  echo "All checks passed"
fi
