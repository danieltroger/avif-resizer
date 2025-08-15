# syntax=docker/dockerfile:1
FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG LIBAVIF_VERSION=v1.3.0

# Build deps + ImageMagick for high-quality resizing
RUN apt-get update && apt-get install -y \
    build-essential cmake ninja-build git pkg-config ca-certificates \
    python3 meson nasm \
    imagemagick libxml2-dev && \
    rm -rf /var/lib/apt/lists/*

# Build libavif with apps (avifenc/avifdec/avifgainmaputil).
# We build codecs locally for a self-contained image.
RUN git clone --depth=1 --branch ${LIBAVIF_VERSION} https://github.com/AOMediaCodec/libavif.git /opt/libavif && \
    cmake -S /opt/libavif -B /opt/libavif/build -G Ninja \
      -DAVIF_BUILD_APPS=ON \
      # If using libavif >= 1.2.0, drop the old experimental flag:
      # (gain-map API is enabled by default)
      # -DAVIF_ENABLE_EXPERIMENTAL_GAIN_MAP=ON \
      -DAVIF_CODEC_AOM=LOCAL \
      -DAVIF_CODEC_DAV1D=LOCAL \
      -DAVIF_LIBYUV=LOCAL \
      -DAVIF_LIBSHARPYUV=LOCAL \
      -DAVIF_JPEG=LOCAL \
      -DAVIF_ZLIBPNG=LOCAL && \
    cmake --build /opt/libavif/build --parallel && \
    cmake --install /opt/libavif/build

# Simple wrapper that:
# 1) Extracts the SDR base image
# 2) Renders the HDR "alternate" image via gain-map
# 3) Resizes both to the requested width with identical kernel
# 4) Re-combines them into a new AVIF with a (possibly downscaled) gain-map
RUN printf '%s\n' \
'#!/usr/bin/env bash' \
'set -euo pipefail' \
'' \
'usage(){' \
'  cat <<EOF' \
'Usage: avif-gainmap-resize -w <width> [options] <input.avif> <output.avif>' \
'' \
'Required:' \
'  -w, --width <px>           Target width in pixels (height auto; AR preserved)' \
'' \
'Common options (sane defaults):' \
'  -q, --qcolor <0-100>       Base image quality (default: 55)' \
'      --qgain  <0-100>       Gain-map quality (default: 60; 100=lossless)' \
'  -s, --speed  <0-10>        Encoder speed (0=slow/best, default: 6)' \
'      --downscaling <1|2|4>  Store gain-map at 1/x resolution (default: 2)' \
'      --headroom <float>     HDR headroom in stops for alternate (default: 4)' \
'      --depth-gain-map <8|10|12> Depth of gain-map image (default: 10)' \
'  -y, --yuv {444,422,420,400} YUV format for output base (optional)' \
'' \
'Notes:' \
'  * If input has NO gain-map, we just resize & re-encode as plain AVIF (SDR).' \
'    (If you need to preserve pure-HDR AVIFs too, ask and we can adapt.)' \
'' \
'Examples:' \
'  avif-gainmap-resize -w 2048 in.avif out.avif' \
'  avif-gainmap-resize -w 2560 --qcolor 60 --qgain 60 --downscaling 2 in.avif out.avif' \
'EOF' \
'}' \
'' \
'WIDTH=""' \
'QCOLOR="${QCOLOR:-55}"' \
'QGAIN="${QGAIN:-60}"' \
'SPEED="${SPEED:-6}"' \
'DOWNSCALING="${DOWNSCALING:-2}"' \
'HEADROOM="${HEADROOM:-4}"' \
'DEPTH_GAINMAP="${DEPTH_GAINMAP:-10}"' \
'YUV="${YUV:-}"' \
'' \
'# Arg parsing' \
'while [[ $# -gt 0 ]]; do' \
'  case "$1" in' \
'    -w|--width) WIDTH="$2"; shift 2;;' \
'    -q|--qcolor) QCOLOR="$2"; shift 2;;' \
'    --qgain) QGAIN="$2"; shift 2;;' \
'    -s|--speed) SPEED="$2"; shift 2;;' \
'    --downscaling) DOWNSCALING="$2"; shift 2;;' \
'    --headroom) HEADROOM="$2"; shift 2;;' \
'    --depth-gain-map) DEPTH_GAINMAP="$2"; shift 2;;' \
'    -y|--yuv) YUV="$2"; shift 2;;' \
'    -h|--help) usage; exit 0;;' \
'    --) shift; break;;' \
'    *) break;;' \
'  esac' \
'done' \
'' \
'if [[ -z "${WIDTH}" || $# -lt 2 ]]; then usage; exit 1; fi' \
'IN="$1"; OUT="$2"' \
'' \
'tmp="$(mktemp -d)"; trap '"'"'rm -rf "$tmp"'"'"' EXIT' \
'' \
'# Does the input contain a gain-map?' \
'if avifgainmaputil printmetadata "$IN" >/dev/null 2>&1; then' \
'  echo "[GM] Input has a gain-map — preserving it...";' \
'  # Base (SDR) image from the AVIF' \
'  avifdec "$IN" "$tmp/base.png"' \
'  # Alternate (HDR) rendering; headroom>0 yields PQ by default' \
'  avifgainmaputil tonemap "$IN" "$tmp/alt.png" --headroom "$HEADROOM" -d 16' \
'  # Resize both with the same filter and geometry' \
'  magick "$tmp/base.png" -filter Lanczos -resize "${WIDTH}x" "$tmp/base_r.png"' \
'  magick "$tmp/alt.png"  -filter Lanczos -resize "${WIDTH}x" "$tmp/alt_r.png"' \
'  # Recombine to AVIF+gain-map at the new size' \
'  avifgainmaputil combine "$tmp/base_r.png" "$tmp/alt_r.png" "$OUT" \' \
'    --downscaling "$DOWNSCALING" --qgain-map "$QGAIN" --depth-gain-map "$DEPTH_GAINMAP" \' \
'    ${YUV:+-y "$YUV"} -q "$QCOLOR" -s "$SPEED"' \
'else' \
'  echo "[GM] No gain-map found — resizing as plain AVIF (SDR)."'; \
'  avifdec "$IN" "$tmp/base.png"' \
'  magick "$tmp/base.png" -filter Lanczos -resize "${WIDTH}x" "$tmp/base_r.png"' \
'  avifenc -q "$QCOLOR" -s "$SPEED" ${YUV:+-y "$YUV"} "$tmp/base_r.png" "$OUT"' \
'fi' \
'' \
'echo "✔ Wrote: $OUT"' \
> /usr/local/bin/avif-gainmap-resize && \
chmod +x /usr/local/bin/avif-gainmap-resize

WORKDIR /work
ENTRYPOINT ["avif-gainmap-resize"]
