#!/usr/bin/env bash
set -euo pipefail

# Generate a synthetic test clip if test/samples/ has no video files.
# Output: test/samples/synthetic.mkv (5s, 720p, h264+aac, SMPTE bars + tone)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SAMPLES_DIR="${SCRIPT_DIR}/samples"

mkdir -p "$SAMPLES_DIR"

# Check for existing video files (anything that isn't .gitkeep or dotfiles)
video_count=$(find "$SAMPLES_DIR" -maxdepth 1 -type f ! -name '.gitkeep' ! -name '.*' | wc -l | tr -d ' ')

if [[ "$video_count" -gt 0 ]]; then
  echo "test/samples/ already has ${video_count} file(s), skipping generation."
  exit 0
fi

echo "==> Generating synthetic test clip..."

ffmpeg -f lavfi -i "smptebars=size=1280x720:rate=24:duration=5" \
       -f lavfi -i "sine=frequency=1000:sample_rate=48000:duration=5" \
       -c:v libx264 -preset ultrafast -crf 18 \
       -c:a aac -b:a 128k \
       -y "${SAMPLES_DIR}/synthetic.mkv"

echo "==> Created test/samples/synthetic.mkv"
