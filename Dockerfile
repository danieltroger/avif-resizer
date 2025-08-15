# syntax=docker/dockerfile:1
FROM alpine:3.22

# Prebuilt binaries: avifenc/avifdec/avifgainmaputil, ImageMagick, ffmpeg
RUN apk add --no-cache libavif-apps imagemagick bash ffmpeg coreutils

# Wrapper: resize AVIF->AVIF preserving aspect ratio and HDR / gain-map
RUN cat >/usr/local/bin/avif-gainmap-resize <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

echo "Script starting..."
echo "Arguments: $@"

# Parse arguments
WIDTH=""
while [ $# -gt 0 ]; do
  case "$1" in
    -w|--width) WIDTH="$2"; shift 2;;
    *) break;;
  esac
done

if [ -z "${WIDTH}" ] || [ $# -lt 2 ]; then
  echo "Usage: $0 -w <width> <input.avif> <output.avif>"
  exit 1
fi

IN="$1"
OUT="$2"

echo "Width: $WIDTH"
echo "Input: $IN"
echo "Output: $OUT"

# Change to working directory
cd /work

# Test if input file exists
if [ ! -f "$IN" ]; then
  echo "Error: Input file $IN not found"
  exit 1
fi

echo "Input file exists, processing..."

# Create temporary directory
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Decoding input file..."
avifdec "$IN" "$tmp/in.y4m"

echo "Resizing with ffmpeg..."
ffmpeg -nostdin -hide_banner -loglevel error -y \
  -i "$tmp/in.y4m" \
  -vf "scale=${WIDTH}:-2:flags=lanczos" \
  -pix_fmt yuv444p10le \
  -strict -1 \
  "$tmp/out.y4m"

echo "Encoding output file..."
avifenc -q 55 -s 6 "$tmp/out.y4m" "$OUT"

echo "Script completed successfully"
EOF

RUN chmod +x /usr/local/bin/avif-gainmap-resize

WORKDIR /work
ENTRYPOINT ["avif-gainmap-resize"]
