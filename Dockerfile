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

# Add libavif tools to PATH and set library path
ENV PATH="/usr/local/bin:${PATH}"
ENV LD_LIBRARY_PATH="/usr/local/lib:${LD_LIBRARY_PATH}"

# Create the wrapper script
RUN echo '#!/usr/bin/env bash' > /usr/local/bin/avif-gainmap-resize && \
    echo 'set -euo pipefail' >> /usr/local/bin/avif-gainmap-resize && \
    echo '' >> /usr/local/bin/avif-gainmap-resize && \
    echo 'usage(){' >> /usr/local/bin/avif-gainmap-resize && \
    echo '  cat <<EOF' >> /usr/local/bin/avif-gainmap-resize && \
    echo 'Usage: avif-gainmap-resize -w <width> [options] <input.avif> <output.avif>' >> /usr/local/bin/avif-gainmap-resize && \
    echo '' >> /usr/local/bin/avif-gainmap-resize && \
    echo 'Required:' >> /usr/local/bin/avif-gainmap-resize && \
    echo '  -w, --width <px>           Target width in pixels (height auto; AR preserved)' >> /usr/local/bin/avif-gainmap-resize && \
    echo '' >> /usr/local/bin/avif-gainmap-resize && \
    echo 'Common options (sane defaults):' >> /usr/local/bin/avif-gainmap-resize && \
    echo '  -q, --qcolor <0-100>       Base image quality (default: 55)' >> /usr/local/bin/avif-gainmap-resize && \
    echo '      --qgain  <0-100>       Gain-map quality (default: 60; 100=lossless)' >> /usr/local/bin/avif-gainmap-resize && \
    echo '  -s, --speed  <0-10>        Encoder speed (0=slow/best, default: 6)' >> /usr/local/bin/avif-gainmap-resize && \
    echo '      --downscaling <1|2|4>  Store gain-map at 1/x resolution (default: 2)' >> /usr/local/bin/avif-gainmap-resize && \
    echo '      --headroom <float>     HDR headroom in stops for alternate (default: 4)' >> /usr/local/bin/avif-gainmap-resize && \
    echo '      --depth-gain-map <8|10|12> Depth of gain-map image (default: 10)' >> /usr/local/bin/avif-gainmap-resize && \
    echo '  -y, --yuv {444,422,420,400} YUV format for output base (optional)' >> /usr/local/bin/avif-gainmap-resize && \
    echo '' >> /usr/local/bin/avif-gainmap-resize && \
    echo 'Notes:' >> /usr/local/bin/avif-gainmap-resize && \
    echo '  * If input has NO gain-map, we just resize & re-encode as plain AVIF (SDR).' >> /usr/local/bin/avif-gainmap-resize && \
    echo '    (If you need to preserve pure-HDR AVIFs too, ask and we can adapt.)' >> /usr/local/bin/avif-gainmap-resize && \
    echo '' >> /usr/local/bin/avif-gainmap-resize && \
    echo 'Examples:' >> /usr/local/bin/avif-gainmap-resize && \
    echo '  avif-gainmap-resize -w 2048 in.avif out.avif' >> /usr/local/bin/avif-gainmap-resize && \
    echo '  avif-gainmap-resize -w 2560 --qcolor 60 --qgain 60 --downscaling 2 in.avif out.avif' >> /usr/local/bin/avif-gainmap-resize && \
    echo 'EOF' >> /usr/local/bin/avif-gainmap-resize && \
    echo '}' >> /usr/local/bin/avif-gainmap-resize && \
    echo '' >> /usr/local/bin/avif-gainmap-resize && \
    echo 'WIDTH=""' >> /usr/local/bin/avif-gainmap-resize && \
    echo 'QCOLOR="${QCOLOR:-55}"' >> /usr/local/bin/avif-gainmap-resize && \
    echo 'QGAIN="${QGAIN:-60}"' >> /usr/local/bin/avif-gainmap-resize && \
    echo 'SPEED="${SPEED:-6}"' >> /usr/local/bin/avif-gainmap-resize && \
    echo 'DOWNSCALING="${DOWNSCALING:-2}"' >> /usr/local/bin/avif-gainmap-resize && \
    echo 'HEADROOM="${HEADROOM:-4}"' >> /usr/local/bin/avif-gainmap-resize && \
    echo 'DEPTH_GAINMAP="${DEPTH_GAINMAP:-10}"' >> /usr/local/bin/avif-gainmap-resize && \
    echo 'YUV="${YUV:-}"' >> /usr/local/bin/avif-gainmap-resize && \
    echo '' >> /usr/local/bin/avif-gainmap-resize && \
    echo '# Arg parsing' >> /usr/local/bin/avif-gainmap-resize && \
    echo 'while [[ $# -gt 0 ]]; do' >> /usr/local/bin/avif-gainmap-resize && \
    echo '  case "$1" in' >> /usr/local/bin/avif-gainmap-resize && \
    echo '    -w|--width) WIDTH="$2"; shift 2;;' >> /usr/local/bin/avif-gainmap-resize && \
    echo '    -q|--qcolor) QCOLOR="$2"; shift 2;;' >> /usr/local/bin/avif-gainmap-resize && \
    echo '    --qgain) QGAIN="$2"; shift 2;;' >> /usr/local/bin/avif-gainmap-resize && \
    echo '    -s|--speed) SPEED="$2"; shift 2;;' >> /usr/local/bin/avif-gainmap-resize && \
    echo '    --downscaling) DOWNSCALING="$2"; shift 2;;' >> /usr/local/bin/avif-gainmap-resize && \
    echo '    --headroom) HEADROOM="$2"; shift 2;;' >> /usr/local/bin/avif-gainmap-resize && \
    echo '    --depth-gain-map) DEPTH_GAINMAP="$2"; shift 2;;' >> /usr/local/bin/avif-gainmap-resize && \
    echo '    -y|--yuv) YUV="$2"; shift 2;;' >> /usr/local/bin/avif-gainmap-resize && \
    echo '    -h|--help) usage; exit 0;;' >> /usr/local/bin/avif-gainmap-resize && \
    echo '    --) shift; break;;' >> /usr/local/bin/avif-gainmap-resize && \
    echo '    *) break;;' >> /usr/local/bin/avif-gainmap-resize && \
    echo '  esac' >> /usr/local/bin/avif-gainmap-resize && \
    echo 'done' >> /usr/local/bin/avif-gainmap-resize && \
    echo '' >> /usr/local/bin/avif-gainmap-resize && \
    echo 'if [[ -z "${WIDTH}" || $# -lt 2 ]]; then usage; exit 1; fi' >> /usr/local/bin/avif-gainmap-resize && \
    echo 'IN="$1"; OUT="$2"' >> /usr/local/bin/avif-gainmap-resize && \
    echo '' >> /usr/local/bin/avif-gainmap-resize && \
    echo 'tmp="$(mktemp -d)"; trap '"'"'rm -rf "$tmp"'"'"' EXIT' >> /usr/local/bin/avif-gainmap-resize && \
    echo '' >> /usr/local/bin/avif-gainmap-resize && \
    echo '# Does the input contain a gain-map?' >> /usr/local/bin/avif-gainmap-resize && \
    echo 'if avifgainmaputil printmetadata "$IN" >/dev/null 2>&1; then' >> /usr/local/bin/avif-gainmap-resize && \
    echo '  echo "[GM] Input has a gain-map — preserving it...";' >> /usr/local/bin/avif-gainmap-resize && \
    echo '  # Base (SDR) image from the AVIF' >> /usr/local/bin/avif-gainmap-resize && \
    echo '  avifdec "$IN" "$tmp/base.png"' >> /usr/local/bin/avif-gainmap-resize && \
    echo '  # Alternate (HDR) rendering; headroom>0 yields PQ by default' >> /usr/local/bin/avif-gainmap-resize && \
    echo '  avifgainmaputil tonemap "$IN" "$tmp/alt.png" --headroom "$HEADROOM" -d 10' >> /usr/local/bin/avif-gainmap-resize && \
    echo '  # Resize both with the same filter and geometry' >> /usr/local/bin/avif-gainmap-resize && \
    echo '  convert "$tmp/base.png" -filter Lanczos -resize "${WIDTH}x" "$tmp/base_r.png"' >> /usr/local/bin/avif-gainmap-resize && \
    echo '  convert "$tmp/alt.png"  -filter Lanczos -resize "${WIDTH}x" "$tmp/alt_r.png"' >> /usr/local/bin/avif-gainmap-resize && \
    echo '  # Recombine to AVIF+gain-map at the new size' >> /usr/local/bin/avif-gainmap-resize && \
    echo '  avifgainmaputil combine "$tmp/base_r.png" "$tmp/alt_r.png" "$OUT" \\' >> /usr/local/bin/avif-gainmap-resize && \
    echo '    --downscaling "$DOWNSCALING" --qgain-map "$QGAIN" --depth-gain-map "$DEPTH_GAINMAP" \\' >> /usr/local/bin/avif-gainmap-resize && \
    echo '    ${YUV:+-y "$YUV"} -q "$QCOLOR" -s "$SPEED"' >> /usr/local/bin/avif-gainmap-resize && \
    echo 'else' >> /usr/local/bin/avif-gainmap-resize && \
    echo '  echo "[GM] No gain-map found — resizing as plain AVIF (SDR)."' >> /usr/local/bin/avif-gainmap-resize && \
    echo '  avifdec "$IN" "$tmp/base.png"' >> /usr/local/bin/avif-gainmap-resize && \
    echo '  convert "$tmp/base.png" -filter Lanczos -resize "${WIDTH}x" "$tmp/base_r.png"' >> /usr/local/bin/avif-gainmap-resize && \
    echo '  avifenc -q "$QCOLOR" -s "$SPEED" ${YUV:+-y "$YUV"} "$tmp/base_r.png" "$OUT"' >> /usr/local/bin/avif-gainmap-resize && \
    echo 'fi' >> /usr/local/bin/avif-gainmap-resize && \
    echo '' >> /usr/local/bin/avif-gainmap-resize && \
    echo 'echo "✔ Wrote: $OUT"' >> /usr/local/bin/avif-gainmap-resize && \
    chmod +x /usr/local/bin/avif-gainmap-resize

WORKDIR /work
ENTRYPOINT ["avif-gainmap-resize"]
