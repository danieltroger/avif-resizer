# syntax=docker/dockerfile:1
FROM alpine:3.22

# Prebuilt apps: avifenc, avifdec, avifgainmaputil
RUN apk add --no-cache libavif-apps imagemagick bash

# Wrapper: resize AVIF->AVIF to a target WIDTH, preserving AR and gain-map
RUN cat >/usr/local/bin/avif-gainmap-resize <<'SH'
#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: avif-gainmap-resize -w <width> [options] <input.avif> <output.avif>

Required:
  -w, --width <px>          Target width in pixels (height auto; AR preserved)

Quality/speed (defaults):
  -q, --qcolor <0-100>      Base image quality (default: 55)
      --qgain  <0-100>      Gain-map quality (default: 60)
  -s, --speed  <0-10>       Encoder speed (default: 6)
      --downscaling <1|2|4> Store gain-map at 1/x resolution (default: 2)
      --headroom <float>    HDR headroom in stops when rendering alternate (default: 4)

Notes:
  * If the input has NO gain-map, this just resizes to plain AVIF (SDR).
EOF
}

WIDTH=""
QCOLOR="${QCOLOR:-55}"
QGAIN="${QGAIN:-60}"
SPEED="${SPEED:-6}"
DOWNSCALING="${DOWNSCALING:-2}"
HEADROOM="${HEADROOM:-4}"

# Parse args
while [ $# -gt 0 ]; do
  case "$1" in
    -w|--width) WIDTH="$2"; shift 2;;
    -q|--qcolor) QCOLOR="$2"; shift 2;;
    --qgain) QGAIN="$2"; shift 2;;
    -s|--speed) SPEED="$2"; shift 2;;
    --downscaling) DOWNSCALING="$2"; shift 2;;
    --headroom) HEADROOM="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) break;;
  esac
done

if [ -z "${WIDTH}" ] || [ $# -lt 2 ]; then usage; exit 1; fi
IN="$1"; OUT="$2"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# If the file has a gain-map, preserve it by recombining a resized base+alternate
if avifgainmaputil printmetadata "$IN" >/dev/null 2>&1; then
  echo "[GM] Input has a gain-map — preserving it..."
  # Extract base (SDR) and render alternate (HDR) from the gain-map image
  avifdec "$IN" "$tmp/base.png"
  avifgainmaputil tonemap "$IN" "$tmp/alt.png" --headroom "$HEADROOM"

  # Resize both with identical kernel/geometry
  magick "$tmp/base.png" -filter Lanczos -resize "${WIDTH}x" "$tmp/base_r.png"
  magick "$tmp/alt.png"  -filter Lanczos -resize "${WIDTH}x" "$tmp/alt_r.png"

  # Recombine into AVIF+gain-map at the new size
  avifgainmaputil combine "$tmp/base_r.png" "$tmp/alt_r.png" "$OUT" \
    --downscaling "$DOWNSCALING" --qgain-map "$QGAIN" -q "$QCOLOR" -s "$SPEED"
else
  echo "[GM] No gain-map found — resizing as plain AVIF (SDR)."
  avifdec "$IN" "$tmp/base.png"
  magick "$tmp/base.png" -filter Lanczos -resize "${WIDTH}x" "$tmp/base_r.png"
  avifenc -q "$QCOLOR" -s "$SPEED" "$tmp/base_r.png" "$OUT"
fi

echo "✔ Wrote: $OUT"
SH

RUN chmod +x /usr/local/bin/avif-gainmap-resize

WORKDIR /work
ENTRYPOINT ["avif-gainmap-resize"]
