#!/usr/bin/env bash
set -euo pipefail

BINARIES=(av1an ab-av1 ffmpeg)
ENCODE=false
ALL_PLATFORMS=false
CLEAN=false

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

build_image() {
  local platform="$1" arch="$2"
  echo "==> Building av1-stack (${platform})..."
  docker buildx build \
    --platform "${platform}" \
    --target av1-stack \
    --output "type=docker,name=av1-stack:${arch}" \
    .
}

run_binary_checks() {
  local platform="$1" arch="$2"
  local image="av1-stack:${arch}"
  local failed=0

  echo ""
  echo "Binary checks (${platform})..."
  for bin in "${BINARIES[@]}"; do
    printf "  %-12s" "$bin"
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

  if [[ $failed -gt 0 ]]; then
    echo "FAILED: $failed binary check(s) for ${platform}"
    return 1
  fi
  echo "All binary checks passed (${platform})"
}

run_encode_test() {
  local platform="$1" arch="$2"
  local image="av1-stack:${arch}"
  local samples_dir="${SCRIPT_DIR}/test/samples"
  local output_dir="${SCRIPT_DIR}/test/output/stack"

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
  docker rmi av1-stack:amd64 2>/dev/null || true
  docker rmi av1-stack:arm64 2>/dev/null || true
  find "${SCRIPT_DIR}/test/output/stack" -mindepth 1 ! -name '.gitkeep' -delete
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

for platform in "${PLATFORMS[@]}"; do
  arch="${platform#linux/}"
  build_image "$platform" "$arch"
  run_binary_checks "$platform" "$arch" || OVERALL_FAILED=$((OVERALL_FAILED + 1))
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
