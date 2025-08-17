Mostly vibecoded simple tool to resize HDR AVIF images, with and without gain map.

Usage:

Once to build:
```shell
docker build -t avif-gm-resizer .
```


To run:
```shell
# Extract SDR from gain-map for non-HDR displays
docker run --rm -v "$PWD:/work" avif-gm-resizer --sdr-only -w 2048 input-gainmap.avif out-sdr.avif --verbose

# Extract HDR from gain-map for HDR displays
docker run --rm -v "$PWD:/work" avif-gm-resizer --hdr-only -w 2048 input-gainmap.avif out-hdr.avif --verbose

# Resize pure PQ file
docker run --rm -v "$PWD:/work" avif-gm-resizer -w 2560 input-pq.avif out-pq.avif --verbose
```