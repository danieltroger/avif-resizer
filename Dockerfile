# syntax=docker/dockerfile:1
FROM alpine:3.22

# Prebuilt tools: avifenc/avifdec/avifgainmaputil, ImageMagick, ffmpeg, bash
RUN apk add --no-cache libavif-apps imagemagick ffmpeg bash coreutils

# Copy the script in as-is; no funny quoting during build
COPY avif-gainmap-resize /usr/local/bin/avif-gainmap-resize
RUN chmod +x /usr/local/bin/avif-gainmap-resize

WORKDIR /work
ENTRYPOINT ["avif-gainmap-resize"]
