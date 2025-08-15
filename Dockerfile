# syntax=docker/dockerfile:1
FROM alpine:3.22

# Prebuilt binaries: avifenc/avifdec/avifgainmaputil, ImageMagick, ffmpeg
RUN apk add --no-cache libavif-apps imagemagick bash ffmpeg coreutils

# Wrapper: resize AVIF->AVIF preserving aspect ratio and HDR / gain-map
RUN cat >/usr/local/bin/avif-gainmap-resize <<'SH'
#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: avif-gainmap-resize -w <width> [options] <input.avif> <output.avif>

Required:
  -w, --width <px>           Target width in pixels (height auto; AR preserved)

Quality/speed (defaults):
  -q, --qcolor <0-100>       Base/Color quality (default: 55)
      --qgain  <0-100>       Gain-map quality (default: 60)
  -s, --speed  <0-10>        Encoder speed (default: 6)
      --downscaling <1|2|4>  Store gain-map at 1/x resolution (default: 2)
      --headroom <float>     HDR headroom (stops) for gain-map alt render (default: 4)
      --verbose              Print detected CICP/bit-depth/YUV

Notes:
  • Gain-map inputs: we render an HDR "alternate" view, resize base+alt identically,
    then recombine with explicit CICP so viewers recognize HDR.
  • Pure-HDR (no gain-map) inputs: we avoid PNG (no tone-map); decode to Y4M,
    resize in YUV via ffmpeg, then re-encode with original CICP/bit-depth/YUV.
EOF
}

# Defaults
WIDTH=""; QCOLOR="${QCOLOR:-55}"; QGAIN="${QGAIN:-60}"; SPEED="${SPEED:-6}";
DOWNSCALING="${DOWNSCALING:-2}"; HEADROOM="${HEADROOM:-4}"; VERBOSE=0

# Parse args
while [ $# -gt 0 ]; do
  case "$1" in
    -w|--width) WIDTH="$2"; shift 2;;
    -q|--qcolor) QCOLOR="$2"; shift 2;;
    --qgain) QGAIN="$2"; shift 2;;
    -s|--speed) SPEED="$2"; shift 2;;
    --downscaling) DOWNSCALING="$2"; shift 2;;
    --headroom) HEADROOM="$2"; shift 2;;
    --verbose) VERBOSE=1; shift;;
    -h|--help) usage; exit 0;;
    *) break;;
  esac
done
if [ -z "${WIDTH}" ] || [ $# -lt 2 ]; then usage; exit 1; fi

IN="$1"; OUT="$2"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# --- Helpers ---------------------------------------------------------------

# Extract base CICP/bit-depth/YUV/range/CLLI from avifdec --info
read_source_info() {
  local f="$1" info
  info="$(avifdec --info "$f" 2>/dev/null || true)"
  SRC_P="$(printf '%s\n' "$info" | sed -n 's/.*Color Primaries:[[:space:]]*\([0-9]\+\).*/\1/p' | head -n1)"
  SRC_T="$(printf '%s\n' "$info" | sed -n 's/.*Transfer Char\.[[:space:]]*:[[:space:]]*\([0-9]\+\).*/\1/p' | head -n1)"
  SRC_M="$(printf '%s\n' "$info" | sed -n 's/.*Matrix Coeffs\.[[:space:]]*:[[:space:]]*\([0-9]\+\).*/\1/p' | head -n1)"
  SRC_DEPTH="$(printf '%s\n' "$info" | sed -n 's/.*Bit Depth[[:space:]]*:[[:space:]]*\([0-9]\+\).*/\1/p' | head -n1)"
  SRC_YUV="$(printf '%s\n' "$info" | sed -n 's/.*Format[[:space:]]*:[[:space:]]*YUV\([0-9]\+\).*/\1/p' | head -n1)"
  SRC_RANGE="$(printf '%s\n' "$info" | sed -n 's/.*Range[[:space:]]*:[[:space:]]*\(Full\|Limited\).*/\1/p' | head -n1)"
  SRC_CLLI="$(printf '%s\n' "$info" | sed -n 's/.*CLLI[[:space:]]*:[[:space:]]*\([0-9]\+,[[:space:]]*[0-9]\+\).*/\1/p' | head -n1 | tr -d ' ')"

  # Sensible fallbacks
  [ -z "${SRC_P}" ] && SRC_P=1
  [ -z "${SRC_T}" ] && SRC_T=13
  [ -z "${SRC_M}" ] && SRC_M=6
  [ -z "${SRC_DEPTH}" ] && SRC_DEPTH=10
  [ -z "${SRC_YUV}" ] && SRC_YUV=444
  [ -z "${SRC_RANGE}" ] && SRC_RANGE="Full"
}

log_src() {
  [ "$VERBOSE" -eq 1 ] || return 0
  echo "Source CICP P/T/M: ${SRC_P}/${SRC_T}/${SRC_M}, depth: ${SRC_DEPTH}, YUV: ${SRC_YUV}, range: ${SRC_RANGE}${SRC_CLLI:+, CLLI: ${SRC_CLLI}}"
}

# Build avifenc flags matching the source’s characteristics
build_encode_flags() {
  ENC_FLAGS=( -q "$QCOLOR" -s "$SPEED" --cicp "${SRC_P}/${SRC_T}/${SRC_M}" --depth "${SRC_DEPTH}" --yuv "${SRC_YUV}" )
  if [ "${SRC_RANGE}" = "Full" ]; then ENC_FLAGS+=( --range full ); else ENC_FLAGS+=( --range limited ); fi
  if [ -n "${SRC_CLLI:-}" ]; then ENC_FLAGS+=( --clli "${SRC_CLLI}" ); fi
}

# --- Workflow --------------------------------------------------------------

read_source_info "$IN"; log_src

# Does the input have a gain-map?
if avifgainmaputil printmetadata "$IN" >/dev/null 2>&1; then
  echo "[GM] Input has a gain-map — preserving it…"

  # Extract base (SDR) and render HDR alternate (keep high precision)
  avifdec "$IN" "$tmp/base.png"
  avifgainmaputil tonemap "$IN" "$tmp/alt.png" --headroom "$HEADROOM" -d 16

  # Resize both identically (Lanczos), keeping AR via widthx
  magick "$tmp/base.png" -filter Lanczos -resize "${WIDTH}x" "$tmp/base_r.png"
  magick "$tmp/alt.png"  -filter Lanczos -resize "${WIDTH}x" "$tmp/alt_r.png"

  # Choose CICP:
  #  • Base: exactly the source's base CICP (what avifdec --info reports)
  #  • Alternate: same primaries/matrix as base, **PQ transfer (16)** so HDR is recognized
  ALT_P="${SRC_P}"
  ALT_T=16
  ALT_M="${SRC_M}"

  [ "$VERBOSE" -eq 1 ] && echo "Combine CICP — base: ${SRC_P}/${SRC_T}/${SRC_M}, alt: ${ALT_P}/${ALT_T}/${ALT_M}"

  # Recombine into AVIF+gain-map at the new size, with explicit CICP
  avifgainmaputil combine "$tmp/base_r.png" "$tmp/alt_r.png" "$OUT" \
    --downscaling "$DOWNSCALING" --qgain-map "$QGAIN" -q "$QCOLOR" -s "$SPEED" \
    --cicp-base "${SRC_P}/${SRC_T}/${SRC_M}" \
    --cicp-alternate "${ALT_P}/${ALT_T}/${ALT_M}"

  echo "✔ Wrote (gain-map): $OUT"

else
  echo "[GM] No gain-map — preserving pure-HDR if present."

  # Pure-HDR path: keep PQ/HLG samples; avoid PNG to prevent tone-mapping.
  # Decode to Y4M, resize in YUV with ffmpeg, then re-encode with original CICP.
  avifdec "$IN" "$tmp/in.y4m"

  # Build ffmpeg pixel format to match desired depth/YUV (e.g., yuv444p10le)
  case "${SRC_YUV}" in
    444|422|420|400) ;;
    *) SRC_YUV=444 ;;
  esac
  case "${SRC_DEPTH}" in
    8|10|12) ;;
    *) SRC_DEPTH=10 ;;
  esac
  FMT="yuv${SRC_YUV}p${SRC_DEPTH}le"

  ffmpeg -nostdin -hide_banner -loglevel error -y \
    -i "$tmp/in.y4m" \
    -vf "scale=${WIDTH}:-2:flags=lanczos" \
    -pix_fmt "$FMT" \
    "$tmp/out.y4m"

  build_encode_flags
  avifenc "${ENC_FLAGS[@]}" "$tmp/out.y4m" "$OUT"

  echo "✔ Wrote (pure-HDR): $OUT"
fi
SH

RUN chmod +x /usr/local/bin/avif-gainmap-resize

WORKDIR /work
ENTRYPOINT ["avif-gainmap-resize"]
