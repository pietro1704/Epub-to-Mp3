# Legacy cover reference fixtures

The `reference-cover.{bmp,gif,tiff}` images and `legacy-{bmp,gif,tiff}.mp3`
files were generated once with FFmpeg 9.0.2. Tests do not invoke FFmpeg.
They preserve the accepted cover MIME types and exact attached image bytes of
the retired external cover path. The new path also preserves the input MPEG
frames, sample rate and duration rather than re-encoding them while tagging.

For each extension, the image command was:

```sh
ffmpeg -nostdin -v error -f lavfi \
  -i 'color=c=0x285a96:s=16x16:d=0.04' -frames:v 1 -threads 1 \
  reference-cover.EXT
```

The legacy attachment command used `frame-stream-stereo.fixture` as input:

```sh
ffmpeg -nostdin -v error -i frame-stream-stereo.fixture \
  -i reference-cover.EXT -map 0:a:0 -map 1:v:0 \
  -c:a libmp3lame -b:a 48k -ac 1 -ar 24000 -c:v copy \
  -id3v2_version 3 -metadata:s:v:0 title=Cover legacy-EXT.mp3
```

The separate `desktop-adpcm.fixture` is IMA ADPCM WAV, 8000 Hz, with a
container duration estimate of 0.256 seconds. FFmpeg decodes 4082 bytes of mono
signed 16-bit PCM, or 2041 samples (0.255125 seconds); the in-process duration
uses those actual samples rather than the rounded block estimate.
Its in-process regression runs with both
external audio command overrides pointing to an executable that exits 97.

`reference-stream.flac` covers content sniffing outside WAV/MPEG. It contains
800 mono samples at 8000 Hz (0.1 seconds), generated once with:

```sh
ffmpeg -nostdin -v error -f lavfi \
  -i sine=frequency=730:sample_rate=8000:duration=0.1 \
  -c:a flac reference-stream.flac
```
