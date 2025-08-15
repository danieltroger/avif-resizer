Mostly vibecoded simple tool to resize HDR AVIF images, with and without gain map.

Usage:

```shell
docker build -t avif-gm-resizer .
docker run --rm -v "$PWD:/work" avif-gm-resizer -w 2048 input-gainmap.avif out-gm.avif --verbose
docker run --rm -v "$PWD:/work" avif-gm-resizer -w 2048 input-pq.avif       out-pq.avif --verbose
```
