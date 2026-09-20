# HLS Studio

Tools for preparing a video file as a browser-playable HLS bundle with selectable audio tracks and text subtitles.

## Requirements

- Bash 4 or newer
- FFmpeg and FFprobe on `PATH`
- Python 3 for the detailed `.info.json` manifest (the preparation script writes a smaller fallback manifest without it)

On macOS, the system Bash is too old; install a newer Bash and use it to run the script. On Windows, use Git Bash or WSL.

Check the tools in the shell where you plan to run the script:

```bash
bash --version
ffmpeg -version
ffprobe -version
```

## GPU support

When the script needs to encode video, it tests available encoders and uses the first one that actually works:

| Hardware | H.264 output | 10-bit HEVC HDR rungs |
| --- | --- | --- |
| Apple (macOS) | VideoToolbox | VideoToolbox |
| NVIDIA | NVENC | NVENC |
| AMD or Intel GPU | CPU fallback (`libx264`) | CPU fallback (`libx265`, if available) |

AMD AMF, Intel Quick Sync, and VA-API hardware encoding are not implemented in this script. You can still run it on those machines, but video encoding uses the CPU. An H.264 source is copied without re-encoding by default, so that path does not need a GPU. GPU acceleration also depends on the installed FFmpeg build and working drivers; the script checks hardware encoders with a short test encode and falls back when a test fails. Some HDR conversion and scaling paths likewise require specific FFmpeg filters and may run on the CPU.

## Prepare a video

```bash
bash prep-hls.sh /path/to/film.mkv [output-directory]
```

The square brackets indicate an optional argument; do not type them. Run the command from the directory containing `prep-hls.sh`, or use its full path. Quote paths that contain spaces.

### Step-by-step example

```bash
# Create an output folder named Film next to Film.mkv.
bash prep-hls.sh "/path/to/Film.mkv"

# Or choose the output folder yourself.
bash prep-hls.sh "/path/to/Film.mkv" "/path/to/Film-hls"
```

Wait for the `done` message. The script lists every generated file at the end. For `Film.mkv`, the default output folder contains files such as:

```text
Film/
  Film.m3u8          # master playlist: start playback here
  Film.part0.m3u8    # a rendition playlist
  Film.part0.m4s     # media data
  Film.poster.jpg    # poster image
  Film.info.json     # source and rendition metadata
```

Additional audio renditions, subtitle files, and ladder rungs create more files. Upload or serve the whole folder; the master playlist refers to the other files by name. To confirm the output was created, open the master playlist in a text editor and check that the referenced files exist beside it.

H.264 video is copied by default; other video may be re-encoded for browser playback. Audio tracks are copied or converted according to their codecs and the selected audio policy. Image subtitles such as PGS and VobSub cannot be converted to browser text subtitles and are reported by the script.

### Common options

Set these environment variables before running `prep-hls.sh`:

| Variable | Purpose |
| --- | --- |
| `PREP_LADDER=1` | Generate multiple resolution renditions. |
| `PREP_LADDER_HEIGHTS=1080,720` | Choose ladder tiers; `raw` keeps an untouched source rendition. |
| `PREP_FORCE_VIDEO_ENCODE=1` | Re-encode even when the source video is H.264. |
| `PREP_COPY_VIDEO=1` | Keep the source video stream untouched, unless force encode is enabled. |
| `PREP_AUDIO_POLICY=browser-copy` | Copy supported audio codecs without encoding; unsupported tracks are skipped. |
| `PREP_AUDIO_CHANNELS=2,6` | Produce stereo and 5.1 audio in the default transcode policy. |
| `PREP_SEGMENT_SECONDS=6` | Set the target HLS segment duration. |

For example:

```bash
PREP_LADDER=1 PREP_LADDER_HEIGHTS=1080,720 bash prep-hls.sh film.mkv
```

More examples:

```bash
# Keep a source-quality copy alongside 1080p and 720p renditions.
PREP_LADDER=1 PREP_LADDER_HEIGHTS=raw,1080,720 bash prep-hls.sh film.mkv

# Generate stereo and 5.1 audio in the default transcode policy.
PREP_AUDIO_CHANNELS=2,6 bash prep-hls.sh film.mkv

# Re-encode an H.264 source with a chosen video bitrate.
PREP_FORCE_VIDEO_ENCODE=1 PREP_VIDEO_BITRATE=6M bash prep-hls.sh film.mkv
```

Ladder tiers above the source resolution are omitted. A copied source rendition retains its original codec and HDR format, so browser support depends on the playback device. `PREP_AUDIO_POLICY=browser-copy` can skip audio codecs it cannot copy for browser playback; check the script output before uploading.

See the comments at the top of [`prep-hls.sh`](prep-hls.sh) for the full set of encoding, HDR, bitrate, and audio options.

## Regenerate metadata

The preparation script creates `.info.json` itself. To generate the detailed manifest again for an existing bundle, run:

```bash
python3 generate-info-json.py /path/to/film.mkv /path/to/output-directory [slug]
```

The optional `slug` must match the prefix used by the bundle's master playlist.
