Mostly vibecoded simple tool to resize HDR AVIF images, with and without gain map.

## Usage:

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
docker run --rm -v "$PWD:/work" avif-gm-resizer -w 2048 input-pq.avif out-pq.avif --verbose
```

## Limitations

For HDR AVIF's with gain-map, the gainmap can't be resized without the colours yellowing (check out https://github.com/danieltroger/avif-resizer/commit/5b332af32cd1f50f7bff2740376b98868e18eb67 if you're fine with that). As a workaround, this tool can extract a resized base-SDR version to show on SDR displays and can create a resized PQ version for HDR displays.