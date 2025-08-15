# syntax=docker/dockerfile:1
FROM alpine:3.22

# Prebuilt tools: avifenc/avifdec/avifgainmaputil, ImageMagick, ffmpeg, bash
RUN apk add --no-cache libavif-apps imagemagick ffmpeg bash coreutils gawk

# Copy the script in verbatim (avoids quoting issues during build)
COPY avif-gainmap-resize /usr/local/bin/avif-gainmap-resize
RUN chmod +x /usr/local/bin/avif-gainmap-resize

WORKDIR /work
ENTRYPOINT ["avif-gainmap-resize"]
