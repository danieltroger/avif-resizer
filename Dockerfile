# syntax=docker/dockerfile:1
FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG LIBAVIF_VERSION=v1.3.0

# Build tools + runtime tools (ImageMagick used only for resizing)
RUN apt-get update && apt-get install -y \
    build-essential cmake ninja-build git pkg-config ca-certificates \
    imagemagick \
    # system libs for libavif apps:
    libpng-dev zlib1g-dev libjpeg-turbo8-dev libwebp-dev \
    libaom-dev libdav1d-dev libyuv-dev libsharpyuv-dev \
 && rm -rf /var/lib/apt/lists/*

# Build libavif (apps: avifenc/avifdec/avifgainmaputil)
RUN git clone --depth=1 --branch ${LIBAVIF_VERSION} https://github.com/AOMediaCodec/libavif.git /opt/libavif && \
    cmake -S /opt/libavif -B /opt/libavif/build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DAVIF_BUILD_APPS=ON \
      -DAVIF_CODEC_AOM=SYSTEM \
      -DAVIF_CODEC_DAV1D=SYSTEM \
      -DAVIF_LIBYUV=ON \
      -DAVIF_LIBSHARPYUV=ON \
      -DAVIF_JPEG=ON \
      -DAVIF_ZLIBPNG=ON && \
    cmake --build /opt/libavif/build --parallel && \
    cmake --install /opt/libavif/build

# Little wrapper that resizes AVIF->AVIF while preserving gain-map/HDR
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
'Quality/speed knobs (defaults):' \
'  -q, --qcolor <0-100>       Base image quality (default: 55)' \
'      --qgain  <0-100>       Gain-map quality (default: 60)' \
'  -s, --speed  <0-10>        Encoder speed (default: 6)' \
'      --downscaling <1|2|4>  Store gain-map at 1/x res (default: 2)' \
'      --headroom <float>     HDR headroom in stops (default: 4)' \
'      --depth-gain-map <8|10|12>  Gain-map bit depth (default: 10)' \
'  -y, --yuv {444,422,420,400}   YUV format for output base (optional)' \
'      --cicp-base P/T/M      Override base CICP (e.g. 1/13/6 for BT.709/sRGB/BT.601)' \
'      --cicp-alt  P/T/M      Override alternate (HDR) CICP (e.g. 9/16/9 for BT.2020/PQ/BT.2020nc)' \
'' \
'Notes:' \
'  * If the input has NO gain-map, this resizes as plain AVIF (SDR).' \
'' \
'EOF' \
'}' \
'' \
'WIDTH=""; QCOLOR="${QCOLOR:-55}"; QGAIN="${QGAIN:-60}"; SPEED="${SPEED:-6}";' \
'DOWNSCALING="${DOWNSCALING:-2}"; HEADROOM="${HEADROOM:-4}"; DEPTH_GAINMAP="${DEPTH_GAINMAP:-10}";' \
'YUV="${YUV:-}"; CICP_BASE=""; CICP_ALT="";' \
'' \
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
'    --cicp-base) CICP_BASE="$2"; shift 2;;' \
'    --cicp-alt|--cicp-alternate) CICP_ALT="$2"; shift 2;;' \
'    -h|--help) usage; exit 0;;' \
'    *) break;;' \
'  esac' \
'done' \
'' \
'if [[ -z "${WIDTH}" || $# -lt 2 ]]; then usage; exit 1; fi' \
'IN="$1"; OUT="$2"' \
'tmp="$(mktemp -d)"; trap '"'"'rm -rf "$tmp"'"'"' EXIT' \
'' \
'# Check for gain-map' \
'if avifgainmaputil printmetadata "$IN" >/dev/null 2>&1; then' \
'  echo "[GM] Input has a gain-map — preserving it...";' \
'  # Base (SDR) & Alternate (HDR) renderings' \
'  avifdec "$IN" "$tmp/base.png"' \
'  avifgainmaputil tonemap "$IN" "$tmp/alt.png" --headroom "$HEADROOM"' \
'' \
'  # Resize both identically' \
'  magick "$tmp/base.png" -filter Lanczos -resize "${WIDTH}x" "$tmp/base_r.png"' \
'  magick "$tmp/alt.png"  -filter Lanczos -resize "${WIDTH}x" "$tmp/alt_r.png"' \
'' \
'  # Build CLI bits for optional CICP overrides' \
'  cicp_base_args=(); [[ -n "$CICP_BASE" ]] && cicp_base_args+=(--cicp-base "$CICP_BASE")' \
'  cicp_alt_args=();  [[ -n "$CICP_ALT"  ]] && cicp_alt_args+=(--cicp-alternate "$CICP_ALT")' \
'' \
'  # Recombine into AVIF+gain-map at the new size' \
'  avifgainmaputil combine "${tmp}/base_r.png" "${tmp}/alt_r.png" "$OUT" \' \
'    --downscaling "$DOWNSCALING" --qgain-map "$QGAIN" --depth-gain-map "$DEPTH_GAINMAP" \' \
'    ${YUV:+-y "$YUV"} -q "$QCOLOR" -s "$SPEED" "${cicp_base_args[@]}" "${cicp_alt_args[@]}"' \
'else' \
'  echo "[GM] No gain-map found — resizing as plain AVIF (SDR)."' \
'  avifdec "$IN" "$tmp/base.png"' \
'  magick "$tmp/base.png" -filter Lanczos -resize "${WIDTH}x" "$tmp/base_r.png"' \
'  avifenc -q "$QCOLOR" -s "$SPEED" ${YUV:+-y "$YUV"} "$tmp/base_r.png" "$OUT"' \
'fi' \
'' \
'echo "✔ Wrote: $OUT"' \
> /usr/local/bin/avif-gainmap-resize && chmod +x /usr/local/bin/avif-gainmap-resize

WORKDIR /work
ENTRYPOINT ["avif-gainmap-resize"]
