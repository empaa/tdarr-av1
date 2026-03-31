#!/usr/bin/env bash
set -euo pipefail

REGISTRY="ghcr.io/empaa"

# Quick pre-check: fails if ghcr.io has never been configured locally.
# Does NOT verify token validity — if the push fails mid-build, re-run docker login.
if ! grep -q "ghcr.io" "${HOME}/.docker/config.json" 2>/dev/null; then
    echo "Error: ghcr.io not found in ~/.docker/config.json."
    echo "Run: echo <TOKEN> | docker login ghcr.io -u <YOUR_USERNAME> --password-stdin"
    echo "See docs/build-and-publish.md for instructions."
    exit 1
fi

echo "==> Building and pushing av1-stack (linux/amd64 + linux/arm64, ~45 min)..."
docker buildx build \
    --platform linux/amd64,linux/arm64 \
    --target final \
    -f Dockerfile.stack \
    -t "${REGISTRY}/av1-stack:latest" \
    --push \
    .

echo "==> Building and pushing tdarr images (linux/amd64 + linux/arm64)..."
docker buildx build \
    --platform linux/amd64,linux/arm64 \
    -f Dockerfile.tdarr \
    -t "${REGISTRY}/tdarr:latest" \
    --push \
    .

docker buildx build \
    --platform linux/amd64,linux/arm64 \
    -f Dockerfile.tdarr_node \
    -t "${REGISTRY}/tdarr_node:latest" \
    --push \
    .

echo ""
echo "Done. Published:"
echo "  ${REGISTRY}/av1-stack:latest"
echo "  ${REGISTRY}/tdarr:latest"
echo "  ${REGISTRY}/tdarr_node:latest"
