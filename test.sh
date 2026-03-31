#!/usr/bin/env bash
set -euo pipefail

IMAGE="av1-stack-test:local"

# Update this list as custom binaries are confirmed in Dockerfile.stack
BINARIES=(av1an ab-av1 ffmpeg)

echo "Building Dockerfile.stack (linux/amd64)..."
docker buildx build \
  --platform linux/amd64 \
  --output "type=docker,name=${IMAGE}" \
  --target final \
  -f Dockerfile.stack \
  .

echo ""
echo "Running binary checks..."
FAILED=0
for bin in "${BINARIES[@]}"; do
  printf "  %-12s" "$bin"
  if docker run --rm "${IMAGE}" "$bin" --version > /dev/null 2>&1; then
    echo "OK"
  else
    echo "FAILED"
    FAILED=$((FAILED + 1))
  fi
done

echo ""
if [[ $FAILED -gt 0 ]]; then
  echo "FAILED: $FAILED binary check(s) failed"
  exit 1
fi
echo "All checks passed — safe to merge"
