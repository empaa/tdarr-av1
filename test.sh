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
