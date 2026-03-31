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
