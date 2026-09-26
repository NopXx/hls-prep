#!/usr/bin/env bash
#
# Turns an MKV with several audio tracks and subtitles into something a browser
# can actually play, and can switch tracks in: an HLS master playlist, one
# media file per rendition, and a WebVTT file per text subtitle.
#
#   bash prep-hls.sh film.mkv [outdir]
#
# It lives in public/ so the library can hand it to whoever is uploading —
# the machine with the files on it is usually not the machine with the repo.
#
# bash (4+) and ffmpeg, nothing else — so it runs the same in Git Bash or WSL
# on Windows as it does on the Mac. macOS still ships bash 3.2, which this needs
# more than; `brew install bash` and run it with that. Run it wherever the file
# is, before uploading.
# Nothing here happens at playback time — the VPS has two cores and no business
# transcoding anything.
#
# Video is copied, not re-encoded, whenever it is already H.264 unless
# PREP_FORCE_VIDEO_ENCODE=1 is set. Audio is re-encoded only when it is
# something a browser cannot decode (AC3, DTS,
# TrueHD, FLAC). Image subtitles (PGS, VOBSUB) cannot be shown by a browser at
# all and are reported rather than silently dropped.
#
# Knobs, all environment variables (the PowerShell twin takes them as switches):
#   PREP_COPY_VIDEO=1      keep the video stream, do not re-encode
#   PREP_FORCE_VIDEO_ENCODE=1  force video re-encode even when source is H.264;
#                              wins over PREP_COPY_VIDEO when both are set
#   PREP_LADDER=1          make a ladder (heights above the source dropped), so
#                          the player can switch resolution; unset = a single
#                          rendition at the source height
#   PREP_LADDER_HEIGHTS    quality tiers, comma-separated, tallest first; default
#                          '2160,1440,1080'. Cinema crops are classified by their
#                          16:9 tier (e.g. 1920x800 = 1080p, 3840x1600 = 2160p).
#                          'raw' is a rung that copies the
#                          source stream untouched (its codec and HDR kept), so
#                          '1080,raw' ships a re-encoded 1080 beside the original
#                          'hdr' adds a source-resolution HEVC Main 10 HDR rung;
#                          'hdr1080', 'hdr720' (any 'hdr<height>') add smaller
#                          HEVC Main 10 HDR rungs. hls.js only adapts within one
#                          codec and video range, so an HDR tier needs its own
#                          lower rungs — 'raw,hdr1080,hdr720,1080,720' gives an
#                          HDR ladder beside the H.264 SDR one. Uses
#                          hevc_videotoolbox on Mac, hevc_nvenc on NVIDIA,
#                          then libx265 as a CPU fallback when available
#   PREP_LADDER_BITRATES   optional per-rung targets, e.g. '1080:10M,720:5M';
#                          an HDR rung is keyed 'hdr1080:6M'.
#                          These never affect the untouched 'raw' rung
#   PREP_HDR_BITRATE       bitrate for the source-resolution HEVC HDR rung; default 12M
#   PREP_NVENC_PRESET      NVENC preset for a single encode; default p4
#   PREP_NVENC_LADDER_PRESET NVENC preset for ladder rungs; default p3
#   PREP_NVENC_TUNE        NVENC tune; default hq
#   PREP_GPU_TONEMAP=0/1   use hardware HDR->SDR tonemapping when available.
#                          Apple VideoToolbox defaults to on; NVIDIA defaults off
#   PREP_COPY_AUDIO=1      also carry the original audio untouched (Apple only)
#   PREP_AUDIO_POLICY     'transcode' (default) keeps the existing stereo/5.1
#                          AAC behavior. 'browser-copy' does no audio encoding:
#                          AAC/FLAC/AC-3/E-AC-3 are stream-copied; DTS/TrueHD
#                          and unknown codecs are skipped. This minimizes CPU use.
#   PREP_AUDIO_CHANNELS   In transcode mode: '2' (default), '2,6' for stereo+5.1,
#                          add 'raw' to copy; 'stereo+raw' skips encoding for
#                          stereo-only sources. Ignored in browser-copy mode.
#   PREP_VIDEO_BITRATE     re-encode target, default 8M
#   PREP_AUDIO_BITRATE     re-encode target, default 192k (per-layout otherwise)
#   PREP_SEGMENT_SECONDS   default 6
#   PREP_POSTER_SECONDS    default 5
#   PREP_PROGRESS_WIDTH    width of the terminal progress bar; default 32
#
# The output is flat and prefixed, because the library treats a Drive
# sub-folder as a series. `<slug>.m3u8` is the video; everything else is named
# `<slug>.part*` or `<slug>.sub-*`, which is how sync tells a playlist to list
# from the pieces it points at.
# macOS's stock bash is 3.2 (frozen at the last GPL2 release) and mishandles
# empty/unset arrays under `set -u`, which this script leans on throughout.
# Everywhere else — Git Bash, WSL, Linux, a brewed bash — is 4+. Ask for it
# rather than sprinkle 3.2 workarounds no other platform needs. Checked before
# `set -o pipefail`, which a non-bash shell would choke on first.
if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "prep-hls.sh needs bash 4 or newer; this is ${BASH_VERSION:-not bash}." >&2
  echo "On a Mac:  brew install bash   then run:  \$(brew --prefix)/bin/bash prep-hls.sh ..." >&2
  exit 1
fi

set -euo pipefail

input=${1:?usage: prep-hls.sh input.mkv [outdir]}

# One folder per film, named after the file, so several of them can be prepared
# side by side without their parts landing in the same place. A trailing dot or
# space is trimmed because Windows rejects it in a directory name.
dir_name=$(basename "${input%.*}" | sed 's/[ .]*$//')
[ -n "$dir_name" ] || dir_name=hls
outdir=${2:-$(dirname "$input")/$dir_name}

# HLS cuts at keyframes, not at arbitrary timestamps. Keep one validated value
# for both the muxer and the forced-keyframe expression used by encoded rungs.
# Stream-copied rungs necessarily retain the source file's existing GOPs.
segment_seconds=${PREP_SEGMENT_SECONDS:-6}
if ! [[ "$segment_seconds" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
  ! awk -v seconds="$segment_seconds" 'BEGIN { exit !(seconds > 0) }'; then
  echo "PREP_SEGMENT_SECONDS must be a positive number, got '$segment_seconds'" >&2
  exit 1
fi

# Everything after the last dot, lowercased and stripped of characters that
# would need escaping in a playlist URI.
slug=$(basename "${input%.*}" | tr ' ' '-' | tr -cd '[:alnum:]._-')
[ -n "$slug" ] || slug=video

mkdir -p "$outdir"

# ffprobe's key=value output, parsed in bash: a JSON parser would mean python,
# and python is one more thing to have installed on a Windows box.
list_streams() {
  ffprobe -v error -select_streams "$1" \
    -show_entries stream=index,codec_name,channels,bit_rate:stream_tags=language,title \
    -of default=nw=1 "$input" |
    awk -F= '
      BEGIN { sep = sprintf("%c", 28) }
      /^index=/ { if (n++) print line; line = "" ; codec = ""; channels = "2"; bitrate = ""; lang = "und"; title = "" }
      /^codec_name=/ { codec = $2 }
      /^channels=/ { channels = $2 }
      /^bit_rate=/ { bitrate = $2 }
      /^TAG:language=/ { lang = $2 }
      /^TAG:title=/ { title = substr($0, index($0, "=") + 1) }
      # A tab is shell whitespace, so `read` collapses an empty title and shifts
      # bit_rate into its field. A non-whitespace separator preserves empties.
      { line = codec sep channels sep lang sep title sep bitrate }
      END { if (n) print line }
    '
}

# The video's codec, profile, level, pixel format and transfer — enough to
# decide whether it needs tonemapping and what to write in the master's CODECS.
# Parsed key=value, because a profile like "Main 10" carries a space that a
# positional read would split.
probe_video() { ffprobe -v error -select_streams v:0 -show_entries "stream=$1" -of default=nw=1:nk=1 "$input" | head -1; }
video_codec=$(probe_video codec_name)
video_profile=$(probe_video profile)
video_level=$(probe_video level)
video_pixfmt=$(probe_video pix_fmt)
video_transfer=$(probe_video color_transfer)
video_primaries=$(probe_video color_primaries)
video_space=$(probe_video color_space)
# ffprobe reports a rational ("24000/1001"); a playlist wants a decimal, and
# three places is what Apple's own examples carry.
video_fps=$(probe_video r_frame_rate | awk -F/ 'NF==2 && $2 > 0 { printf "%.3f", $1 / $2; exit } NF==1 && $1 > 0 { printf "%.3f", $1; exit }')
video_width=$(probe_video width)
video_height=$(probe_video height)
video_bitrate=$(probe_video bit_rate)

# Treat ladder numbers as quality tiers, not literal stored-frame heights.
# Movie releases commonly crop the black bars, so a 1080p source may actually
# be 1920x800/804/816 and a 2160p source may be 3840x1600. For landscape video,
# derive the nominal tier from whichever is larger: the real height or the
# height implied by a 16:9 frame of the same width. Portrait video mirrors that
# rule so 1080x1920 remains a 1080p-class source.
video_orientation=landscape
video_reference_height=${video_height:-0}
if [[ "${video_width:-}" =~ ^[0-9]+$ ]] && [[ "${video_height:-}" =~ ^[0-9]+$ ]] &&
  [ "$video_width" -gt 0 ] && [ "$video_height" -gt 0 ]; then
  if [ "$video_width" -ge "$video_height" ]; then
    ref_from_long=$(( (video_width * 9 + 15) / 16 ))
    [ "$ref_from_long" -gt "$video_reference_height" ] && video_reference_height=$ref_from_long
  else
    video_orientation=portrait
    video_reference_height=$video_width
    ref_from_long=$(( (video_height * 9 + 15) / 16 ))
    [ "$ref_from_long" -gt "$video_reference_height" ] && video_reference_height=$ref_from_long
  fi
fi

# Build the 16:9 bounding box for a quality tier. Cropped sources are fitted
# inside this box without adding black bars or upscaling the source-size rung.
# Globals set: rung_box_w, rung_box_h.
set_rung_box() {
  local q=$1 long
  long=$(( (q * 16 + 8) / 9 ))
  [ $((long % 2)) -ne 0 ] && long=$((long + 1))
  if [ "$video_orientation" = "portrait" ]; then
    rung_box_w=$q; rung_box_h=$long
  else
    rung_box_w=$long; rung_box_h=$q
  fi
}

# Allow a tiny tolerance for odd encodes such as 1918px-wide "1080p" files.
rung_available() {
  local q=$1
  [ "$q" -le $((video_reference_height + 2)) ]
}

# A tier is source-sized when the original already fits inside its 16:9 box.
# Example: 1920x800 fits 1920x1080, so the 1080p rung is copied/no-resize.
rung_is_source_size() {
  local q=$1
  set_rung_box "$q"
  [ "$video_width" -le "$rung_box_w" ] && [ "$video_height" -le "$rung_box_h" ] && rung_available "$q"
}

# Decide how to fit the original aspect ratio inside a tier box. Globals set:
# rung_scale_mode = none|width|height, rung_scale_w, rung_scale_h.
set_rung_scale() {
  local q=$1
  set_rung_box "$q"
  if [ "$video_width" -le "$rung_box_w" ] && [ "$video_height" -le "$rung_box_h" ]; then
    rung_scale_mode=none
    rung_scale_w=$video_width
    rung_scale_h=$video_height
  elif [ $((video_width * rung_box_h)) -ge $((video_height * rung_box_w)) ]; then
    rung_scale_mode=width
    rung_scale_w=$rung_box_w
    rung_scale_h=-2
  else
    rung_scale_mode=height
    rung_scale_w=-2
    rung_scale_h=$rung_box_h
  fi
}

# Many MKV/WEB-DL files carry no per-stream bit_rate — it lives on the container,
# not the video stream, so the probe above comes back 'N/A'. Left unfilled,
# rung_bitrate falls to its hard cap (8M at 1080p) and a rung balloons far past
# the size the GUI estimated. Derive the video bitrate the way the GUI does
# (prep-hls-gui-mac.swift): the file's overall rate minus the audio tracks.
if ! [[ "${video_bitrate:-}" =~ ^[0-9]+$ ]]; then
  src_size=$(ffprobe -v error -show_entries format=size -of default=nw=1:nk=1 "$input")
  src_dur=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$input")
  audio_bps=$(ffprobe -v error -select_streams a -show_entries stream=bit_rate \
    -of default=nw=1:nk=1 "$input" | awk '/^[0-9]+$/ { s += $1 } END { print s + 0 }')
  video_bitrate=$(awk -v sz="${src_size:-0}" -v du="${src_dur:-0}" -v ab="$audio_bps" \
    'BEGIN { if (du > 0) { v = sz * 8 / du - ab; if (v > 0) { printf "%.0f", v; exit } } print "" }')
fi

# One line per stream: codec, channels, language, title, bit_rate.
audio=$(list_streams a)
subs=$(list_streams s)

if [ -z "$audio" ]; then
  echo "No audio streams in $input" >&2
  exit 1
fi

echo "video: ${video_codec:-none} (${video_width:-?}x${video_height:-?}, ${video_reference_height:-?}p-class)"

# H.264 plays everywhere. By default an H.264 source is copied at source
# resolution to avoid a needless quality loss. PREP_FORCE_VIDEO_ENCODE=1 turns
# that automatic copy off (useful when the 4K master itself should be compressed
# by NVENC). PREP_COPY_VIDEO=1 can still force-copy any codec, unless FORCE wins.
copy_video=0
if [ "${PREP_FORCE_VIDEO_ENCODE:-0}" != "1" ] && {
  [ "$video_codec" = "h264" ] || [ "${PREP_COPY_VIDEO:-0}" = "1" ]
}; then
  copy_video=1
fi
if [ "${PREP_FORCE_VIDEO_ENCODE:-0}" = "1" ] && [ "${PREP_COPY_VIDEO:-0}" = "1" ]; then
  echo "  PREP_FORCE_VIDEO_ENCODE=1 overrides PREP_COPY_VIDEO=1" >&2
fi
out_codec=h264
[ "$copy_video" = "1" ] && out_codec=$video_codec

# Empty by default so the ffmpeg line can expand it even when nothing needs a
# hardware decoder (an unset array trips set -u on older bash).
input_args=()
video_args=()
video_maps=()
nvid=0

# A browser cannot decode 10-bit, so a deep-colour source comes down to
# yuv420p. HDR needs more than a bit-depth cut: without tonemapping, BT.2020/PQ
# read as BT.709 arrives grey and washed out.
is_hdr=0
case "$video_transfer" in smpte2084 | arib-std-b67) is_hdr=1 ;; esac

# A 'HYBRID' HDR source carries a Dolby Vision layer inside the HEVC bitstream. A
# copied rung keeps the layer, but fmp4 only writes the dvcC/dvvC signalling box
# under -strict unofficial; without it Apple sees the HDR10 base and misses the
# DV. A re-encoded (tonemapped) rung drops DV either way, so it only matters when
# the source stream is copied.
# Older ffmpeg has no `stream_side_data` show_entries section and errors out on it.
# Swallow that (2>/dev/null, || true): a build that cannot report the DV side data
# also cannot preserve DV, so treating it as "no DV" is correct — has_dovi stays 0.
dovi_probe=$({ ffprobe -v error -select_streams v:0 \
  -show_entries stream_side_data=side_data_type,dv_profile,dv_level,dv_bl_signal_compatibility_id -of default=nw=1 "$input" 2>/dev/null || true; } |
  awk -F= '
    /^side_data_type=/ { active = (tolower($2) ~ /dovi|dolby vision/); if (active) found=1; profile=""; level=""; compat="" }
    active && /^dv_profile=/ { profile=$2 }
    active && /^dv_level=/ { level=$2 }
    active && /^dv_bl_signal_compatibility_id=/ { compat=$2 }
    END { if (found) print profile "\t" level "\t" compat }
  ')
has_dovi=0; dv_profile=''; dv_level=''; dv_compat=''
if [ -n "$dovi_probe" ]; then
  has_dovi=1
  IFS=$'\t' read -r dv_profile dv_level dv_compat <<< "$dovi_probe"
fi

is_deep=0
case "$video_pixfmt" in *10le | *10be | *12le | *12be | *16le | *16be | p010* | p012* | p016*) is_deep=1 ;; esac

# Seeing an encoder in `ffmpeg -encoders` only means the binary was compiled
# with it; the matching GPU/driver can still be absent. Prove each hardware
# candidate with a small real encode before committing a long conversion to it.
# 320x180 is intentionally used here: very small frames such as 128x72 can be
# rejected by NVENC on some NVIDIA GPUs/drivers even though the encoder itself
# is fully functional.
test_h264_encoder() {
  ffmpeg -nostdin -hide_banner -v error \
    -f lavfi -i 'testsrc2=size=320x180:rate=24' -t 0.25 \
    -pix_fmt yuv420p -c:v "$1" -f null - </dev/null >/dev/null 2>&1
}

# HDR rungs are 10-bit HEVC. Just like H.264, test a real frame: Colab's FFmpeg
# may list an NVENC encoder even on a GPU generation that cannot execute it.
test_hevc10_encoder() {
  local enc=$1
  local args=(-c:v "$enc" -profile:v main10)
  [ "$enc" = "hevc_nvenc" ] && args+=(-preset "${PREP_NVENC_PRESET:-p4}" -tune "${PREP_NVENC_TUNE:-hq}")
  [ "$enc" = "libx265" ] && args+=(-preset ultrafast)
  ffmpeg -nostdin -hide_banner -v error \
    -f lavfi -i 'testsrc2=size=320x180:rate=24' -t 0.25 \
    -vf format=p010le "${args[@]}" -f null - </dev/null >/dev/null 2>&1
}

ff_encoders=$(ffmpeg -hide_banner -encoders 2>&1)
venc=libx264
for candidate in h264_videotoolbox h264_nvenc; do
  if grep -q "$candidate" <<< "$ff_encoders"; then
    if test_h264_encoder "$candidate"; then
      venc=$candidate
      break
    fi
    echo "  $candidate is listed but failed its encode preflight — using the next encoder" >&2
  fi
done

# Preferred 10-bit HEVC encoder for compressed HDR rungs. Keep VideoToolbox
# first on Mac, then NVENC (Tesla T4 / RTX / L4 etc.), then CPU x265.
hdr_venc=''
if [ "$is_hdr" = "1" ]; then
  for candidate in hevc_videotoolbox hevc_nvenc libx265; do
    if grep -q "$candidate" <<< "$ff_encoders"; then
      if test_hevc10_encoder "$candidate"; then
        hdr_venc=$candidate
        break
      fi
      echo "  $candidate is listed but failed its Main 10 preflight — trying the next encoder" >&2
    fi
  done
fi

# ffmpeg's filter list, read once — the GPU paths below probe it.
ff_filters=$(ffmpeg -hide_banner -filters 2>&1)

# scale_cuda gained its `format` option (resize + pixel-format in one GPU pass)
# only in newer ffmpeg; older builds (e.g. Kaggle's stock ffmpeg) reject it with
# "Option 'format' not found". Detect it so the CUDA ladder can omit the option
# on an 8-bit source (where it is a no-op anyway) and fall back to the CPU for a
# 10-bit source it can no longer down-convert on the GPU.
scale_cuda_format=0
if ffmpeg -hide_banner -h filter=scale_cuda 2>/dev/null | grep -qw format; then
  scale_cuda_format=1
fi
# The ":format=..." suffix to append to a scale_cuda, empty when unsupported.
sc_yuv=$([ "$scale_cuda_format" = "1" ] && echo ":format=yuv420p" || echo "")

# Apple Silicon can keep HEVC decode, HDR->SDR colour conversion/scaling, and
# H.264 encode in VideoToolbox surfaces. `scale_vt` uses
# VTPixelTransferSession; unlike h264_videotoolbox alone this also moves the
# expensive PQ/HLG -> BT.709 step off the CPU. Homebrew FFmpeg calls the hw-frame
# format `videotoolbox_vld`. Allow an explicit 0 for colour-comparison/debugging,
# but make the fast path the Mac default.
apple_vt_hdr=0
if [ "$is_hdr" = "1" ] && [ "$venc" = "h264_videotoolbox" ] &&
  [ "${PREP_GPU_TONEMAP:-1}" != "0" ] && echo "$ff_filters" | grep -q ' scale_vt '; then
  apple_vt_hdr=1
fi

# Some remuxed/malformed HEVC files cannot create an IOSurface even though the
# decoder advertises VideoToolbox support. Probe a single tiny frame before a
# long job; if hardware setup fails, retain the proven CPU tone-map path rather
# than aborting the whole queue after output files have been opened.
if [ "$apple_vt_hdr" = "1" ] && ! ffmpeg -nostdin -v error \
  -hwaccel videotoolbox -hwaccel_output_format videotoolbox_vld -i "$input" \
  -frames:v 1 -an \
  -vf 'scale_vt=w=-2:h=64:color_matrix=bt709:color_primaries=bt709:color_transfer=bt709,hwdownload,format=p010le,format=nv12' \
  -f null -; then
  apple_vt_hdr=0
  echo "  VideoToolbox HDR preflight failed — falling back to CPU tonemapping" >&2
fi

# A ladder re-encodes two or three rungs at once, which otherwise pins the CPU
# on decoding the 4K source and rescaling it once per rung. On NVENC we keep an
# SDR/deep ladder wholly on the GPU: NVDEC decodes, scale_cuda resizes (and
# drops 10-bit to the 8-bit a browser needs) in one pass, NVENC encodes — the
# CPU never touches a frame. A build without scale_cuda falls back to the CPU.
gpu_ladder=0
if [ -n "${PREP_LADDER:-}" ] && [ "$venc" = "h264_nvenc" ] && [ "$is_hdr" = "0" ] &&
  echo "$ff_filters" | grep -q scale_cuda &&
  { [ "$scale_cuda_format" = "1" ] || [ "$is_deep" = "0" ]; }; then
  gpu_ladder=1
fi

# An HDR ladder is the slow one: tonemapping is the cost, and the CPU chain runs
# it on the full frame once per rung. With libplacebo we tonemap once on the GPU
# and split that single SDR result to the rungs (the filter_complex is built in
# the ladder section) — roughly 3x faster. A copy-top-rung ladder keeps the
# per-rung path, so this wants every rung encoded.
gpu_hdr_ladder=0
if [ -n "${PREP_LADDER:-}" ] && [ "$is_hdr" = "1" ] && [ "${PREP_GPU_TONEMAP:-0}" = "1" ] &&
  [ "$venc" = "h264_nvenc" ] && [ "$copy_video" != "1" ] && echo "$ff_filters" | grep -q libplacebo &&
  [ "$scale_cuda_format" = "1" ]; then
  gpu_hdr_ladder=1
fi

# Rough per-height target bitrates for the ladder, in the range a streaming
# service uses for H.264 — an explicit PREP_VIDEO_BITRATE only overrides the
# single-rendition (no-ladder) encode, not the ladder rungs.
rung_bitrate() {
  local entry key value cap
  if [ "$1" -ge 2160 ]; then cap=16000
  elif [ "$1" -ge 1440 ]; then cap=10000
  elif [ "$1" -ge 1080 ]; then cap=8000
  elif [ "$1" -ge 720 ]; then cap=4000
  elif [ "$1" -ge 480 ]; then cap=2000
  else cap=1000
  fi
  local custom=()
  IFS=',' read -r -a custom <<< "${PREP_LADDER_BITRATES:-}"
  for entry in "${custom[@]}"; do
    key=${entry%%:*}
    value=${entry#*:}
    if [ "$entry" != "$value" ] && [ "$key" = "$1" ] && [ -n "$value" ]; then
      [ "${value,,}" = "auto" ] && break
      case "$value" in *[!0-9kKmM.]*) echo "Invalid bitrate '$value' for ${key}p" >&2; return 1 ;; esac
      echo "$value"
      return 0
    fi
  done
  # Cap the normal H.264 target at the source bitrate, scaled by the nominal
  # quality tier rather than the cropped stored height (1920x800 is 1080p).
  if [[ "${video_bitrate:-}" =~ ^[0-9]+$ ]] && [ "$video_bitrate" -gt 0 ] &&
    [ -n "${video_reference_height:-}" ] && [ "$video_reference_height" -gt 0 ]; then
    awk -v src="$video_bitrate" -v h="$1" -v sh="$video_reference_height" -v cap="$cap" \
      'BEGIN { v = src / 1000 * h / sh; if (v < 500) v = 500; if (v > cap) v = cap; printf "%.0fk\n", v }'
  else
    echo "${cap}k"
  fi
}

# True when the user gave an explicit (non-auto) PREP_LADDER_BITRATES target for
# height $1. Such a rung is meant to be re-encoded to that bitrate — so the top
# rung is not stream-copied out from under an intended shrink.
rung_explicit() {
  local entry key value custom=()
  IFS=',' read -r -a custom <<< "${PREP_LADDER_BITRATES:-}"
  for entry in "${custom[@]}"; do
    key=${entry%%:*}; value=${entry#*:}
    if [ "$entry" != "$value" ] && [ "$key" = "$1" ] && [ -n "$value" ] && [ "${value,,}" != "auto" ]; then
      return 0
    fi
  done
  return 1
}

# Adds one encoded video output at index $1, scaled to height $2 (empty keeps
# the source height). Used for every ladder rung and the single re-encode.
add_encoded_video() {
  local i=$1 h=$2 br=$3 vf th
  local scale_mode=none scale_w=$video_width scale_h=$video_height
  if [ -n "$h" ]; then
    set_rung_scale "$h"
    scale_mode=$rung_scale_mode; scale_w=$rung_scale_w; scale_h=$rung_scale_h
  fi
  video_maps+=(-map 0:v:0)
  if [ "$apple_vt_hdr" = "1" ]; then
    # Keep VideoToolbox frames on the hardware path. scale_vt performs both the
    # resize and HDR colour conversion. FFmpeg's HLS negotiation cannot pass a
    # VideoToolbox surface directly to this encoder even though the null muxer
    # can, so download its native P010 surface and convert that SDR result to
    # NV12. Tone mapping and scaling remain on the GPU; only the final handoff
    # crosses system memory. Even a source-height encode must pass through it.
    th=${h:-$video_reference_height}
    # scale_vt (the VideoToolbox scaler) intermittently writes a few pixels of
    # rainbow garbage along the right edge (and occasionally the others). Scale a
    # touch tall and crop a border back off, which lands on the same output size
    # (h exactly, w within 2px) while discarding the band the garbage lives in.
    if [ "$scale_mode" = "width" ]; then
      # Add a small horizontal guard band, then crop it after VideoToolbox.
      video_args+=(-filter:v:"$i" "scale_vt=w=$((scale_w + 16)):h=-2:color_matrix=bt709:color_primaries=bt709:color_transfer=bt709,hwdownload,format=p010le,format=nv12,crop=iw-16:ih")
    elif [ "$scale_mode" = "height" ]; then
      video_args+=(-filter:v:"$i" "scale_vt=w=-2:h=$((scale_h + 8)):color_matrix=bt709:color_primaries=bt709:color_transfer=bt709,hwdownload,format=p010le,format=nv12,crop=iw-16:ih-8")
    else
      video_args+=(-filter:v:"$i" "scale_vt=w=$((video_width + 16)):h=-2:color_matrix=bt709:color_primaries=bt709:color_transfer=bt709,hwdownload,format=p010le,format=nv12,crop=iw-16:ih")
    fi
  elif [ "$gpu_ladder" = "1" ]; then
    # scale_cuda resizes and lands on 8-bit yuv420p in a single GPU pass; -2
    # keeps the aspect and an even width. A source-height top rung still runs
    # through it — a cheap no-op resize that also does any 10-bit->8-bit drop.
    if [ "$scale_mode" = "none" ]; then
      video_args+=(-filter:v:"$i" "scale_cuda=${video_width}:${video_height}${sc_yuv}")
    else
      video_args+=(-filter:v:"$i" "scale_cuda=${scale_w}:${scale_h}${sc_yuv}")
    fi
  else
    vf="$base_vf"
    if [ -n "$h" ] && [ "$scale_mode" != "none" ]; then
      vf="${vf:+$vf,}scale=${scale_w}:${scale_h}"
    fi
    [ -n "$vf" ] && video_args+=(-filter:v:"$i" "$vf")
  fi
  video_args+=(-c:v:"$i" "$venc" -b:v:"$i" "$br" \
    -flags:v:"$i" +cgop \
    -force_key_frames:v:"$i" "expr:gte(t,n_forced*$segment_seconds)")
  case "$venc" in
    h264_videotoolbox)
      video_args+=(-tag:v:"$i" avc1)
      ;;
    h264_nvenc)
      # p4 is a good T4/RTX quality-speed balance for one encode. A ladder uses
      # p3 by default so several simultaneous NVENC sessions keep good throughput.
      if [ -n "${PREP_LADDER:-}" ]; then np=${PREP_NVENC_LADDER_PRESET:-p3}; else np=${PREP_NVENC_PRESET:-p4}; fi
      video_args+=(-preset:v:"$i" "$np" -tune:v:"$i" "${PREP_NVENC_TUNE:-hq}" -rc:v:"$i" vbr)
      ;;
    libx264)
      video_args+=(-preset:v:"$i" medium)
      ;;
  esac
  [ "$is_hdr" = "1" ] && video_args+=(-color_primaries:v:"$i" bt709 -color_trc:v:"$i" bt709 -colorspace:v:"$i" bt709)
  # A trailing false test above must not be the function's exit status: set -e
  # would take it down with the caller.
  return 0
}

# Pre-scan the requested ladder before choosing the HDR processing path.
# If every requested encoded rung is HDR (hdr / hdr<height>), there is no
# reason to build an HDR->SDR tone-map chain at all. On NVIDIA we can keep
# 10-bit PQ/HLG frames on the GPU from NVDEC -> scale_cuda -> HEVC NVENC.
requested_sdr_rungs=0
requested_hdr_rungs=0
if [ -n "${PREP_LADDER:-}" ]; then
  IFS=',' read -r -a _pre_ladder_tokens <<< "$(echo "${PREP_LADDER_HEIGHTS:-2160,1440,1080}" | tr 'A-Z ' 'a-z')"
  for _t in "${_pre_ladder_tokens[@]}"; do
    case "$_t" in
      hdr|hdr[0-9]*) requested_hdr_rungs=1 ;;
      raw|'') ;;
      [0-9]*) requested_sdr_rungs=1 ;;
    esac
  done
fi

gpu_hdr_passthrough=0
if [ "$is_hdr" = "1" ] && [ "$requested_hdr_rungs" = "1" ] && [ "$requested_sdr_rungs" = "0" ] && \
  [ "$hdr_venc" = "hevc_nvenc" ] && echo "$ff_filters" | grep -q scale_cuda && \
  [ "$scale_cuda_format" = "1" ]; then
  gpu_hdr_passthrough=1
fi

# The filter chain every encoded SDR rung shares (the scale is appended per rung).
base_vf=""
if [ "$gpu_hdr_passthrough" = "1" ]; then
  input_args=(-hwaccel cuda -hwaccel_output_format cuda)
  echo "  ladder: HDR kept on GPU with NVDEC + scale_cuda + HEVC NVENC (no tonemapping)"
elif [ "$apple_vt_hdr" = "1" ]; then
  input_args=(-hwaccel videotoolbox -hwaccel_output_format videotoolbox_vld)
  echo "  tonemapping HDR ($video_transfer, $video_pixfmt) to SDR BT.709 with Apple VideoToolbox GPU"
elif [ "$is_hdr" = "1" ] && [ "${PREP_GPU_TONEMAP:-0}" = "1" ] && [ "$gpu_hdr_ladder" = "0" ] &&
  echo "$ff_filters" | grep -q libplacebo; then
  # Single-stream GPU tonemap (and the lower rungs of a copy-top-rung ladder).
  # NVDEC hands off CUDA frames; libplacebo wants Vulkan, and there is no direct
  # interop, so the one hwdownload in the middle is the price.
  input_args=(-init_hw_device vulkan=vk -filter_hw_device vk -hwaccel cuda -hwaccel_output_format cuda)
  base_vf='hwdownload,format=p010le,libplacebo=tonemapping=bt.2390:colorspace=bt709:color_primaries=bt709:color_trc=bt709:format=yuv420p,hwdownload,format=yuv420p'
  echo "  tonemapping HDR ($video_transfer, $video_pixfmt) on the GPU with libplacebo (bt.2390)"
elif [ "$gpu_hdr_ladder" = "1" ]; then
  # The tonemap+split lives in the filter_complex below; here we just name the
  # Vulkan/CUDA devices it needs.
  input_args=(-init_hw_device vulkan=vk -filter_hw_device vk -hwaccel cuda -hwaccel_output_format cuda)
  echo "  ladder: tonemapping HDR ($video_transfer, $video_pixfmt) once on the GPU, then splitting to the rungs"
elif [ "$is_hdr" = "1" ]; then
  if [ "${PREP_GPU_TONEMAP:-0}" = "1" ] && ! echo "$ff_filters" | grep -q libplacebo; then
    echo "  PREP_GPU_TONEMAP asked for, but this ffmpeg has no libplacebo — using the CPU" >&2
  fi
  # Linearise PQ, tonemap in float, land back on BT.709.
  base_vf='zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p'
  echo "  tonemapping HDR ($video_transfer, $video_pixfmt) to SDR BT.709 — CPU work, slow"
elif [ "$is_deep" = "1" ] && [ "$gpu_ladder" = "0" ]; then
  base_vf='format=yuv420p'
  echo "  converting $video_pixfmt to 8-bit yuv420p"
fi

if [ "$gpu_ladder" = "1" ]; then
  input_args=(-hwaccel cuda -hwaccel_output_format cuda)
  echo "  ladder: NVDEC decode + scale_cuda on the GPU (the CPU stays free)"
fi

# The ladder request splits into an optional 'raw' rung — the source stream
# copied untouched, its own codec and HDR kept — and numeric quality tiers to
# encode, tallest first. Tiers above the source class are dropped; cropped cinema
# frames use their 16:9 class (1920x800 => 1080p, 1280x536 => 720p). A raw rung lets Apple
# devices take the HDR/HEVC original while the encoded rungs cover every other
# browser. With neither left, fall back to a single source-height encoded rung.
want_raw=0
want_hdr=0
heights=()
hdr_heights=()
IFS=',' read -r -a ladder_tokens <<< "$(echo "${PREP_LADDER_HEIGHTS:-2160,1440,1080}" | tr 'A-Z ' 'a-z')"
for h in "${ladder_tokens[@]}"; do
  [ -n "$h" ] || continue
  if [ "$h" = "raw" ]; then want_raw=1; continue; fi
  if [ "$h" = "hdr" ]; then want_hdr=1; continue; fi
  if [[ "$h" =~ ^hdr([0-9]+)$ ]]; then
    hh=${BASH_REMATCH[1]}
    if rung_is_source_size "$hh"; then
      # A cropped cinema source can be source-sized at a taller nominal tier
      # (e.g. 3840x1600 is the source-resolution 2160p HDR rung).
      want_hdr=1
    elif rung_available "$hh"; then
      case " ${hdr_heights[*]:-} " in *" $hh "*) ;; *) hdr_heights+=("$hh") ;; esac
    fi
    continue
  fi
  case "$h" in ''|*[!0-9]*) echo "PREP_LADDER_HEIGHTS takes heights, 'hdr', 'hdr<height>', or 'raw'; got '$h'" >&2; exit 1 ;; esac
  if ! rung_available "$h"; then continue; fi
  case " ${heights[*]:-} " in *" $h "*) continue ;; esac
  heights+=("$h")
done
if [ "${#heights[@]}" -gt 0 ]; then
  # Descending, so index 0 is the top rung.
  IFS=$'\n' heights=($(printf '%s\n' "${heights[@]}" | sort -rn)); unset IFS
elif [ "$want_raw" = "0" ] && [ "$want_hdr" = "0" ] && [ "${#hdr_heights[@]}" -eq 0 ]; then
  heights=("${video_reference_height:-0}")
fi
if [ "${#hdr_heights[@]}" -gt 0 ]; then
  IFS=$'\n' hdr_heights=($(printf '%s\n' "${hdr_heights[@]}" | sort -rn)); unset IFS
fi

# Target bitrate for an HDR rung of height $1: 'hdr<h>:<rate>' from
# PREP_LADDER_BITRATES, else the source bitrate scaled to the height, capped at
# roughly what a streaming service spends on HEVC HDR at that size.
hdr_rung_bitrate() {
  local entry value cap
  if [ "$1" -ge 1440 ]; then cap=8000
  elif [ "$1" -ge 1080 ]; then cap=6000
  elif [ "$1" -ge 720 ]; then cap=3500
  else cap=2000
  fi
  local custom=()
  IFS=',' read -r -a custom <<< "${PREP_LADDER_BITRATES:-}"
  for entry in "${custom[@]}"; do
    value=${entry#*:}
    if [ "${entry%%:*}" = "hdr$1" ] && [ "$entry" != "$value" ] && [ -n "$value" ] && [ "${value,,}" != "auto" ]; then
      case "$value" in *[!0-9kKmM.]*) echo "Invalid bitrate '$value' for hdr$1" >&2; return 1 ;; esac
      echo "$value"
      return 0
    fi
  done
  if [[ "${video_bitrate:-}" =~ ^[0-9]+$ ]] && [ "$video_bitrate" -gt 0 ] &&
    [ -n "${video_reference_height:-}" ] && [ "$video_reference_height" -gt 0 ]; then
    awk -v src="$video_bitrate" -v h="$1" -v sh="$video_reference_height" -v cap="$cap" \
      'BEGIN { v = src / 1000 * h / sh; if (v < 800) v = 800; if (v > cap) v = cap; printf "%.0fk\n", v }'
  else
    echo "${cap}k"
  fi
}

# Adds one HEVC Main 10 output at index $1 that keeps the source's HDR colour
# system, scaled to height $2 (empty keeps the source size), at bitrate $3.
# On NVIDIA this uses hevc_nvenc; on Mac it keeps the VideoToolbox path.
add_hdr_video() {
  local i=$1 h=$2 br=$3 np
  local scale_mode=none scale_w=$video_width scale_h=$video_height
  if [ -n "$h" ]; then
    set_rung_scale "$h"
    scale_mode=$rung_scale_mode; scale_w=$rung_scale_w; scale_h=$rung_scale_h
  fi
  video_maps+=(-map 0:v:0)
  if [ "$gpu_hdr_passthrough" = "1" ]; then
    # NVDEC provides CUDA/P010 surfaces. Keep them on the GPU and resize in
    # 10-bit without changing the HDR transfer/primaries. A source-size rung
    # needs no filter at all and goes straight into hevc_nvenc.
    if [ -n "$h" ] && [ "$scale_mode" != "none" ]; then
      video_args+=(-filter:v:"$i" "scale_cuda=${scale_w}:${scale_h}:format=p010le")
    fi
  elif [ "$hdr_venc" = "hevc_videotoolbox" ] && [ "$apple_vt_hdr" = "1" ] && [ -n "$h" ]; then
    # scale_vt with no colour arguments resizes without converting, so PQ/HLG
    # stays PQ/HLG. Fit inside the tier box so cinema crops keep their aspect.
    if [ "$scale_mode" = "width" ]; then
      video_args+=(-filter:v:"$i" "scale_vt=w=$((scale_w + 16)):h=-2,hwdownload,format=p010le,crop=iw-16:ih")
    elif [ "$scale_mode" = "height" ]; then
      video_args+=(-filter:v:"$i" "scale_vt=w=-2:h=$((scale_h + 8)),hwdownload,format=p010le,crop=iw-16:ih-8")
    else
      video_args+=(-filter:v:"$i" 'hwdownload,format=p010le')
    fi
  elif [ "$hdr_venc" = "hevc_videotoolbox" ] && [ "$apple_vt_hdr" = "1" ]; then
    video_args+=(-filter:v:"$i" 'hwdownload,format=p010le')
  elif [ -n "$h" ] && [ "$scale_mode" != "none" ]; then
    # CPU scale + 10-bit handoff is intentionally the compatibility path here:
    # it works for NVENC and x265 and avoids conflicting hw-frame devices when
    # an HDR->SDR ladder is being produced in the same ffmpeg invocation.
    video_args+=(-filter:v:"$i" "scale=${scale_w}:${scale_h},format=p010le")
  else
    video_args+=(-filter:v:"$i" 'format=p010le')
  fi
  video_args+=(-c:v:"$i" "$hdr_venc" -profile:v:"$i" main10 \
    -b:v:"$i" "$br" -tag:v:"$i" hvc1 \
    -flags:v:"$i" +cgop \
    -force_key_frames:v:"$i" "expr:gte(t,n_forced*$segment_seconds)" \
    -color_primaries:v:"$i" "${video_primaries:-bt2020}" \
    -color_trc:v:"$i" "$video_transfer" -colorspace:v:"$i" "${video_space:-bt2020nc}")
  if [ "$hdr_venc" = "hevc_nvenc" ]; then
    if [ -n "${PREP_LADDER:-}" ]; then np=${PREP_NVENC_LADDER_PRESET:-p3}; else np=${PREP_NVENC_PRESET:-p4}; fi
    video_args+=(-preset:v:"$i" "$np" -tune:v:"$i" "${PREP_NVENC_TUNE:-hq}" -rc:v:"$i" vbr)
  elif [ "$hdr_venc" = "libx265" ]; then
    video_args+=(-preset:v:"$i" medium)
  fi
  hevc_sequences+="$((i + 1)),"
  hdr_sequences+="$((i + 1)),"
  return 0
}

filter_complex=""
copied_hevc=0
hevc_sequences=','
hdr_sequences=','
dv_sequences=','

if [ -n "${PREP_LADDER:-}" ]; then
  # The raw rung goes first (it is the tallest, at source height). fmp4 defaults
  # HEVC to the hev1 tag, which Safari refuses; hvc1 keeps the parameter sets
  # where it looks for them.
  if [ "$want_raw" = "1" ]; then
    video_maps+=(-map 0:v:0)
    video_args+=(-c:v:"$nvid" copy)
    if [ "$video_codec" = "hevc" ]; then
      video_args+=(-tag:v:"$nvid" hvc1); copied_hevc=1
      hevc_sequences+="$((nvid + 1)),"
      [ "$is_hdr" = "1" ] && hdr_sequences+="$((nvid + 1)),"
      [ "$has_dovi" = "1" ] && dv_sequences+="$((nvid + 1)),"
    fi
    raw_note="${video_reference_height}p-class ${video_width}x${video_height} $video_codec"
    [ "$is_hdr" = "1" ] && raw_note="$raw_note HDR"
    echo "  rung raw: copying the source stream untouched ($raw_note)"
    nvid=$((nvid + 1))
  fi

  # A smaller 4K file cannot be a stream copy. This rendition re-encodes at the
  # source dimensions as HEVC Main 10 while retaining the HDR colour system.
  # It is intentionally separate from `raw`: Dolby Vision enhancement data is
  # not preserved by an encode, while an HDR10/PQ base remains HDR10/PQ.
  if [ "$want_hdr" = "1" ] || [ "${#hdr_heights[@]}" -gt 0 ]; then
    if [ "$is_hdr" != "1" ]; then
      echo "  compressed HDR rung requested, but the source is not HDR — skipping" >&2
    elif [ -z "$hdr_venc" ]; then
      echo "Compressed HDR needs a working 10-bit HEVC encoder (hevc_videotoolbox, hevc_nvenc, or libx265)" >&2
      exit 1
    else
      if [ "$want_hdr" = "1" ]; then
        hdr_br=${PREP_HDR_BITRATE:-12M}
        add_hdr_video "$nvid" '' "$hdr_br"
        echo "  rung 4K HDR compressed: HEVC Main 10 with $hdr_venc ($hdr_br, source resolution)"
        nvid=$((nvid + 1))
      fi
      for h in "${hdr_heights[@]}"; do
        br=$(hdr_rung_bitrate "$h")
        add_hdr_video "$nvid" "$h" "$br"
        echo "  rung ${h}p HDR: HEVC Main 10 with $hdr_venc ($br), HDR kept"
        nvid=$((nvid + 1))
      done
    fi
  fi

  if [ "$gpu_hdr_ladder" = "1" ] && [ "${#heights[@]}" -gt 0 ]; then
    # Tonemap once, then split that one SDR frame to every encoded rung —
    # rather than tonemapping per rung. Tonemapping is the cost and it scales
    # with pixel count, so scale down to the tallest rung on the GPU *first*
    # (cheap) and tonemap at that size, not at the source 4K: a 1080-max
    # ladder is ~2x faster this way, and a source-height top rung makes the
    # pre-scale a no-op (scale_cuda passes through), so nothing is lost.
    # Output stream indices carry on from $nvid so a raw rung keeps index 0.
    max_h=${heights[0]}
    set_rung_scale "$max_h"
    max_scale_w=$rung_scale_w; max_scale_h=$rung_scale_h
    labels=""
    for ((k = 0; k < ${#heights[@]}; k++)); do labels+="[s$k]"; done
    tonemap="[0:v]scale_cuda=${max_scale_w}:${max_scale_h}:format=p010le,hwdownload,format=p010le,libplacebo=tonemapping=bt.2390:colorspace=bt709:color_primaries=bt709:color_trc=bt709:format=yuv420p,hwdownload,format=yuv420p"
    scale_parts=()
    for k in "${!heights[@]}"; do
      h=${heights[$k]}
      # Fit each nominal tier inside its 16:9 box, preserving cinema crops.
      set_rung_scale "$h"
      if [ "$rung_scale_mode" = "none" ]; then
        scale_parts+=("[s$k]null[v$k]")
      else
        scale_parts+=("[s$k]scale=${rung_scale_w}:${rung_scale_h}[v$k]")
      fi
      video_maps+=(-map "[v$k]")
      br=$(rung_bitrate "$h")
      video_args+=(-c:v:"$nvid" "$venc" -b:v:"$nvid" "$br" -preset:v:"$nvid" p3 \
        -flags:v:"$nvid" +cgop \
        -force_key_frames:v:"$nvid" "expr:gte(t,n_forced*$segment_seconds)" \
        -color_primaries:v:"$nvid" bt709 -color_trc:v:"$nvid" bt709 -colorspace:v:"$nvid" bt709)
      echo "  rung ${h}p: encoding to H.264 with $venc ($br), GPU-tonemapped"
      nvid=$((nvid + 1))
    done
    scale_join=""
    for sp in "${scale_parts[@]}"; do scale_join+="$sp;"; done
    scale_join=${scale_join%;}
    filter_complex="$tonemap,split=${#heights[@]}$labels;$scale_join"
  elif [ "${#heights[@]}" -gt 0 ]; then
    # The encoded rungs. Without a raw rung the top one still copies when the
    # source is already deliverable (H.264 unless forced to encode, or
    # PREP_COPY_VIDEO=1 on an HEVC the viewers can take); a raw rung is the copy
    # instead, so the rest all re-encode. An explicit PREP_LADDER_BITRATES target
    # for that height overrides the copy — the user asked to re-encode (to shrink)
    # to that bitrate.
    for h in "${heights[@]}"; do
      # A cropped source can be source-sized at a nominally taller tier:
      # 1920x800 -> 1080p, 1280x536 -> 720p, 3840x1600 -> 2160p.
      hh=$h
      if rung_is_source_size "$h"; then hh=''; fi
      if [ "$want_raw" = "0" ] && [ "$nvid" = "0" ] && [ "$copy_video" = "1" ] && [ -z "$hh" ] && ! rung_explicit "$h"; then
        video_maps+=(-map 0:v:0)
        video_args+=(-c:v:"$nvid" copy)
        if [ "$video_codec" = "hevc" ]; then
          video_args+=(-tag:v:"$nvid" hvc1); copied_hevc=1
          hevc_sequences+="$((nvid + 1)),"
          [ "$is_hdr" = "1" ] && hdr_sequences+="$((nvid + 1)),"
          [ "$has_dovi" = "1" ] && dv_sequences+="$((nvid + 1)),"
        fi
        echo "  rung ${h}p: copying the source stream"
      else
        add_encoded_video "$nvid" "$hh" "$(rung_bitrate "$h")"
        echo "  rung ${h}p: encoding to H.264 with $venc ($(rung_bitrate "$h"))"
      fi
      nvid=$((nvid + 1))
    done
  fi
elif [ "$copy_video" = "1" ]; then
  # fmp4 defaults HEVC to the hev1 tag, which Safari refuses outright; hvc1
  # keeps the parameter sets in the sample description where it looks for them.
  video_maps=(-map 0:v:0)
  video_args=(-c:v:0 copy)
  if [ "$video_codec" = "hevc" ]; then
    video_args+=(-tag:v:0 hvc1); copied_hevc=1
    hevc_sequences+='1,'
    [ "$is_hdr" = "1" ] && hdr_sequences+='1,'
    [ "$has_dovi" = "1" ] && dv_sequences+='1,'
  fi
  nvid=1
  echo "  copying the video stream"
else
  add_encoded_video 0 '' "${PREP_VIDEO_BITRATE:-8M}"
  nvid=1
  echo "  re-encoding to H.264 with $venc (${PREP_VIDEO_BITRATE:-8M})"
fi

# A raw-only ladder copies and never decodes, so any GPU decode/tonemap device
# picked earlier would just sit unused (and the CUDA init can complain). Drop it.
if [ -n "${PREP_LADDER:-}" ] && [ "$want_raw" = "1" ] && [ "$want_hdr" = "0" ] && [ "${#hdr_heights[@]}" -eq 0 ] && [ "${#heights[@]}" -eq 0 ]; then
  input_args=()
fi

# Pull the audio streams into arrays: each layout below walks them again.
a_codec=(); a_channels=(); a_lang=(); a_title=(); a_bitrate=()
while IFS=$'\034' read -r codec channels language title bitrate; do
  [ -n "$codec" ] || continue
  a_codec+=("$codec"); a_channels+=("$channels"); a_lang+=("$language")
  a_title+=("${title:-$language}"); a_bitrate+=("$bitrate")
done <<< "$audio"

# A file-name-safe label per audio stream. Two tracks in the same language (an
# eng TrueHD beside an eng AC3, say) would otherwise both be named 'eng' and
# collide on one file — the later clobbering the earlier and leaving the master
# pointing several renditions at the same bytes. A repeated language gets a
# 1-based suffix ('eng1', 'eng2'); a lone one stays bare. O(n²) over a handful of
# streams, and no associative array, which macOS bash 3.2 does not have.
a_langname=()
for i in "${!a_lang[@]}"; do
  lang=${a_lang[$i]}; total=0; before=0
  for j in "${!a_lang[@]}"; do
    if [ "${a_lang[$j]}" = "$lang" ]; then
      total=$((total + 1))
      [ "$j" -lt "$i" ] && before=$((before + 1))
    fi
  done
  if [ "$total" -gt 1 ]; then a_langname+=("${lang}$((before + 1))"); else a_langname+=("$lang"); fi
done

# What a rendition's codec is called in a CODECS attribute.
codec_string() {
  case "$1" in
    aac) echo 'mp4a.40.2' ;;
    eac3) echo 'ec-3' ;;
    ac3) echo 'ac-3' ;;
    flac) echo 'fLaC' ;;
    truehd) echo 'mlpa' ;;
    # The DTS core, which every DTS variant carries. Naming the extension
    # (dtsh/dtsl) would take the stream profile, and a player that cannot do
    # the core cannot do those either. Returning nothing, as this did, leaves
    # the group with no codec at all, and a cloned variant then keeps the
    # CODECS of the one above it — advertising a codec it does not serve.
    dts) echo 'dtsc' ;;
    *) echo '' ;;
  esac
}

channel_label() {
  case "$1" in
    raw) echo original ;;
    1) echo mono ;;
    2) echo stereo ;;
    6) echo 5.1 ;;
    8) echo 7.1 ;;
    *) echo "${1}ch" ;;
  esac
}

# 192k is a stereo figure and starves 5.1, but scaling it straight up
# overshoots: surround channels are coded jointly and the LFE costs almost
# nothing. 64k per channel lands on 384k for 5.1, which is what Apple's HLS
# spec asks for. An explicit PREP_AUDIO_BITRATE still wins.
bitrate_set=0; [ -n "${PREP_AUDIO_BITRATE+x}" ] && bitrate_set=1
channel_bitrate() {
  if [ "$bitrate_set" = "1" ] || [ "$1" -le 2 ]; then echo "${PREP_AUDIO_BITRATE:-192k}"; else echo "$((64 * $1))k"; fi
}

# Audio policy. The original transcode path can make stereo/5.1 AAC layouts.
# browser-copy is the low-CPU path for web playback: codecs the target player can
# consume are copied bit-for-bit and unsupported home-theater codecs are omitted.
audio_mode=$(echo "${PREP_AUDIO_POLICY:-transcode}" | tr 'A-Z ' 'a-z')
case "$audio_mode" in
  transcode|browser-copy) ;;
  *) echo "PREP_AUDIO_POLICY must be 'transcode' or 'browser-copy', got '$audio_mode'" >&2; exit 1 ;;
esac

channels_set=0; [ -n "${PREP_AUDIO_CHANNELS+x}" ] && channels_set=1
if [ "$audio_mode" = "browser-copy" ]; then
  channel_list=(browser)
  echo "audio policy: browser-copy (AAC/FLAC/AC-3/E-AC-3 copy; DTS/TrueHD skipped)"
else
  # One entry per audio rendition: '2' for stereo only, '2,6' for stereo and 5.1
  # side by side, '2,6,raw' to carry the untouched original alongside them.
  audio_policy=$(echo "${PREP_AUDIO_CHANNELS:-2}" | tr 'A-Z ' 'a-z')
  if [ "$audio_policy" = "stereo+raw" ]; then
    # A surround source gets an AAC stereo fallback plus the untouched stream.
    # If every input track is already stereo/mono, copy it once as raw.
    all_stereo=1
    for channels in "${a_channels[@]}"; do
      if [ "$channels" -gt 2 ]; then all_stereo=0; break; fi
    done
    if [ "$all_stereo" = "1" ]; then
      channel_list=(raw)
      echo "audio policy: source is stereo-only — copying without re-encoding"
    else
      channel_list=(2 raw)
      echo "audio policy: creating stereo compatibility + keeping original raw audio"
    fi
  else
    IFS=',' read -r -a channel_list <<< "$audio_policy"
  fi
  for spec in "${channel_list[@]}"; do
    [ "$spec" = "raw" ] && continue
    case "$spec" in
      ''|*[!0-9]*) echo "PREP_AUDIO_CHANNELS takes 1..8 or 'raw', got '$spec'" >&2; exit 1 ;;
    esac
    { [ "$spec" -lt 1 ] || [ "$spec" -gt 8 ]; } && { echo "PREP_AUDIO_CHANNELS takes 1..8 or 'raw', got '$spec'" >&2; exit 1; }
  done
  # PREP_COPY_AUDIO adds the original rather than replacing the list.
  if [ "${PREP_COPY_AUDIO:-0}" = "1" ] && [[ " ${channel_list[*]} " != *" raw "* ]]; then
    if [ "$channels_set" = "1" ]; then channel_list+=(raw); else channel_list=(raw); fi
  fi
  [ "${#channel_list[@]}" -gt 4 ] && { echo "PREP_AUDIO_CHANNELS takes at most 4 renditions" >&2; exit 1; }
fi

multi=0; [ "${#channel_list[@]}" -gt 1 ] && multi=1

maps=("${video_maps[@]}")
codec_args=()
map_parts=()
groups=(); gbitrate=(); gcodec=(); gdefault=()
out_index=0
needs_experimental=0

# The group index for a name, appending a fresh group the first time it is
# seen, and setting $gi. Not `echo`+`$(...)`: a command substitution runs in a
# subshell, and the array appends below would vanish with it on return.
group_idx() {
  local g=$1 i
  for i in "${!groups[@]}"; do
    if [ "${groups[$i]}" = "$g" ]; then gi=$i; return; fi
  done
  groups+=("$g"); gbitrate+=(0); gcodec+=(''); gdefault+=(0)
  gi=$((${#groups[@]} - 1))
}

# CODECS on an HLS variant must describe every codec that can appear in the
# associated audio group. browser-copy may keep, for example, E-AC-3 English and
# AC-3 Thai in the same group, so accumulate unique codec strings rather than
# letting the last track overwrite the earlier one.
add_group_codec() {
  local idx=$1 c=$2 existing
  [ -n "$c" ] || return 0
  existing=${gcodec[$idx]}
  case ",$existing," in
    *",$c,"*) ;;
    *) gcodec[$idx]="${existing:+$existing,}$c" ;;
  esac
}

for spec in "${channel_list[@]}"; do
  # A rendition group per layout. browser-copy keeps all compatible source
  # tracks together so language switching stays in one audio group.
  if [ "$audio_mode" = "browser-copy" ]; then
    group=aud
  elif [ "$multi" = "0" ]; then
    group=aud
  elif [ "$spec" = "raw" ]; then
    group=araw
  else
    group="a$spec"
  fi

  for i in "${!a_codec[@]}"; do
    codec=${a_codec[$i]}; channels=${a_channels[$i]}; language=${a_lang[$i]}; title=${a_title[$i]}

    # A rendition group is a set of interchangeable alternatives, and a
    # variant's CODECS is the union across it. Carry DTS or TrueHD beside AC-3
    # and that union promises a codec only some members need: a client that
    # trusts it either refuses the whole variant or opens the one track it
    # cannot decode — AVPlayer answers "Cannot Open" and says no more. They get
    # a group of their own instead, so a player that wants them can still find
    # them and one that cannot simply never sees them.
    track_group=$group
    if [ "$spec" = "raw" ]; then
      case "$codec" in dts|truehd) track_group="araw${codec}" ;; esac
    fi
    # Per track rather than per rendition: the raw group must not be created
    # when every raw track turns out to be one of the split-off codecs, or a
    # variant would point at a group with nothing in it.
    group_idx "$track_group"

    if [ "$audio_mode" = "browser-copy" ]; then
      case "$codec" in
        aac|flac|ac3|eac3)
          maps+=(-map "0:a:$i")
          codec_args+=(-c:a:"$out_index" copy)
          [ "$codec" = "flac" ] && needs_experimental=1
          add_group_codec "$gi" "$(codec_string "$codec")"
          kbps=640; [ -n "${a_bitrate[$i]}" ] && [ "${a_bitrate[$i]}" != "N/A" ] && kbps=$((a_bitrate[i] / 1000))
          [ "$kbps" -gt "${gbitrate[$gi]}" ] && gbitrate[$gi]=$kbps
          name=$(echo "$title" | tr ' ' '-' | tr -cd '[:alnum:]._-')
          [ -n "$name" ] || name=$language
          default=''
          [ "${gdefault[$gi]}" = "0" ] && { default=,default:yes; gdefault[$gi]=1; }
          map_parts+=("a:$out_index,agroup:$track_group,language:$language,name:$name$default")
          echo "audio $i: $codec ${channels}ch $language — copying for browser playback"
          out_index=$((out_index + 1))
          ;;
        dts|truehd)
          echo "audio $i: $codec ${channels}ch $language — skipped (browser-copy policy)" >&2
          ;;
        *)
          echo "audio $i: $codec ${channels}ch $language — skipped (not in browser-copy allowlist)" >&2
          ;;
      esac
      continue
    fi

    if [ "$spec" = "raw" ]; then
      # Stream copy keeps source timestamps and metadata such as Atmos.
      maps+=(-map "0:a:$i")
      codec_args+=(-c:a:"$out_index" copy)
      case "$codec" in flac|truehd) needs_experimental=1 ;; esac
      add_group_codec "$gi" "$(codec_string "$codec")"
      kbps=640; [ -n "${a_bitrate[$i]}" ] && [ "${a_bitrate[$i]}" != "N/A" ] && kbps=$((a_bitrate[i] / 1000))
      [ "$kbps" -gt "${gbitrate[$gi]}" ] && gbitrate[$gi]=$kbps
      echo "audio $i: $codec ${channels}ch $language — copying untouched"
    else
      maps+=(-map "0:a:$i")
      chan=$spec
      bitrate=$(channel_bitrate "$chan")
      kbps=${bitrate//[!0-9]/}
      [ "$kbps" -gt "${gbitrate[$gi]}" ] && gbitrate[$gi]=$kbps
      add_group_codec "$gi" 'mp4a.40.2'
      if [ "$codec" = "aac" ] && [ "$channels" -le "$chan" ]; then
        codec_args+=(-c:a:"$out_index" copy)
        echo "audio $i: $codec ${channels}ch $language — copying"
      else
        codec_args+=(-c:a:"$out_index" aac -ac:a:"$out_index" "$chan" -b:a:"$out_index" "$bitrate" \
          -filter:a:"$out_index" 'aresample=async=1000')
        echo "audio $i: $codec ${channels}ch $language — re-encoding to $(channel_label "$spec") AAC ($bitrate, timestamp sync)"
      fi
    fi

    if [ "$multi" = "1" ]; then
      name="${a_langname[$i]}-$(channel_label "$spec")"
    else
      name=$(echo "$title" | tr ' ' '-' | tr -cd '[:alnum:]._-')
      [ -n "$name" ] || name=$language
    fi
    # Per group, not per file: ffmpeg marks nothing DEFAULT on its own, so a
    # single global flag left every group after the first without one, and a
    # player then picks by its own rules rather than the one meant to lead.
    default=''
    [ "${gdefault[$gi]}" = "0" ] && { default=,default:yes; gdefault[$gi]=1; }
    map_parts+=("a:$out_index,agroup:$track_group,language:$language,name:$name$default")
    out_index=$((out_index + 1))
  done
done

# If browser-copy skipped every source track (for example a DTS-only file), keep
# the job valid by producing video-only HLS instead of trying to reference an
# empty audio group.
if [ "$out_index" -eq 0 ]; then
  groups=(); gbitrate=(); gcodec=(); gdefault=()
  echo "audio: no browser-copy compatible tracks kept; output will be video-only" >&2
fi

# Every video rendition joins the first audio group; a player picks the rung by
# bandwidth and the audio group by codec support.
video_sm=""
if [ "${#groups[@]}" -gt 0 ]; then
  for ((vi = 0; vi < nvid; vi++)); do video_sm+="v:$vi,agroup:${groups[0]} "; done
else
  for ((vi = 0; vi < nvid; vi++)); do video_sm+="v:$vi "; done
fi
stream_map="${video_sm}${map_parts[*]}"

# Subtitles ride alongside as plain WebVTT files rather than as HLS renditions:
# a <track> element switches them in every browser, and it keeps the master
# playlist to the one thing HLS is needed for, which is the audio.
sub_index=0
while IFS=$'\034' read -r codec channels language title bitrate; do
  [ -n "$codec" ] || continue
  i=$sub_index
  sub_index=$((sub_index + 1))
  case "$codec" in
    subrip | ass | ssa | mov_text | webvtt | text)
      out="$outdir/${slug}.sub-${language}-${i}.vtt"
      ffmpeg -nostdin -v error -y -i "$input" -map "0:s:$i" -c:s webvtt "$out"
      echo "subtitle $i: $codec $language -> $(basename "$out")"
      ;;
    *)
      echo "subtitle $i: $codec $language — image subtitles, skipped (a browser cannot draw them)" >&2
      ;;
  esac
done <<< "$subs"

echo "writing HLS to $outdir/${slug}.m3u8"

# FFmpeg's normal -stats output is a carriage-return status line and notebook
# frontends do not always render it reliably. Use -progress and turn the machine-
# readable fields into a download-style percentage bar instead. The duration is
# read independently from the container, so this also works when stream bit_rate
# is N/A (common with MKV/WEB-DL files).
progress_duration=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$input" 2>/dev/null | head -1)
progress_duration_us=0
if [[ "${progress_duration:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  progress_duration_us=$(awk -v d="$progress_duration" 'BEGIN { printf "%.0f", d * 1000000 }')
fi

show_ffmpeg_progress() {
  local total_us=${1:-0}
  local width=${PREP_PROGRESS_WIDTH:-32}
  local key value out_us=0 frame=0 fps='0.00' speed='0x'
  local pct100 pct_whole pct_frac filled i done_bar todo_bar
  local cur_sec total_sec cur_h cur_m cur_s total_h total_m total_s

  # Keep the bar readable even when an accidental environment value is supplied.
  case "$width" in ''|*[!0-9]*) width=32 ;; esac
  [ "$width" -lt 10 ] && width=10
  [ "$width" -gt 60 ] && width=60

  while IFS='=' read -r key value; do
    value=${value%$'\r'}
    case "$key" in
      frame) frame=$value ;;
      fps) fps=$value ;;
      out_time_us)
        [[ "$value" =~ ^[0-9]+$ ]] && out_us=$value
        ;;
      speed) speed=$value ;;
      progress)
        if [ "$total_us" -gt 0 ]; then
          if [ "$value" = "end" ]; then
            out_us=$total_us
            pct100=10000
          else
            pct100=$(( out_us * 10000 / total_us ))
            [ "$pct100" -gt 10000 ] && pct100=10000
          fi

          pct_whole=$((pct100 / 100))
          pct_frac=$((pct100 % 100))
          filled=$((pct100 * width / 10000))
          [ "$filled" -gt "$width" ] && filled=$width

          done_bar=''; todo_bar=''
          for ((i=0; i<filled; i++)); do done_bar+='█'; done
          for ((i=filled; i<width; i++)); do todo_bar+='░'; done

          cur_sec=$((out_us / 1000000))
          total_sec=$((total_us / 1000000))
          cur_h=$((cur_sec / 3600)); cur_m=$(((cur_sec % 3600) / 60)); cur_s=$((cur_sec % 60))
          total_h=$((total_sec / 3600)); total_m=$(((total_sec % 3600) / 60)); total_s=$((total_sec % 60))

          printf '\r  [%s%s] %3d.%02d%%  %02d:%02d:%02d / %02d:%02d:%02d  %s fps  %s' \
            "$done_bar" "$todo_bar" "$pct_whole" "$pct_frac" \
            "$cur_h" "$cur_m" "$cur_s" "$total_h" "$total_m" "$total_s" "$fps" "$speed"
        else
          # Duration probing should normally succeed, but keep useful progress if
          # an unusual input container has no duration metadata.
          printf '\r  processed %s us  frame=%s  %s fps  %s' "$out_us" "$frame" "$fps" "$speed"
        fi
        [ "$value" = "end" ] && printf '\n'
        ;;
    esac
  done
}

# single_file + fmp4: one media file per rendition, indexed by byte ranges in
# the playlist. Thousands of segment files would be unusable in Drive, and the
# proxy already serves ranges.
# An HDR ladder tonemaps once and splits, so it maps filtergraph labels ([v0]…)
# rather than the input stream; everything else filters per output stream.
fc_args=(); [ -n "$filter_complex" ] && fc_args=(-filter_complex "$filter_complex")
# Keep Dolby Vision on a copied HEVC rung: fmp4 needs -strict unofficial to
# write the dvcC/dvvC box, or the DV layer is silently dropped to its HDR10 base.
dv_args=()
if [ "$needs_experimental" = "1" ]; then
  dv_args=(-strict experimental)
elif [ "$copied_hevc" = "1" ] && [ "$has_dovi" = "1" ]; then
  dv_args=(-strict unofficial)
fi
if [ "$copied_hevc" = "1" ] && [ "$has_dovi" = "1" ]; then
  echo "  raw rung: keeping Dolby Vision (writing dvcC via -strict unofficial)"
fi
[ "$needs_experimental" = "1" ] && echo "  original FLAC/TrueHD audio: enabling experimental MP4 support"
# -nostdin, on every ffmpeg call here: ffmpeg otherwise polls the terminal for
# its interactive keys (q to quit), and a process in a background process group
# that reads its controlling terminal is stopped by SIGTTIN. That is a job
# frozen at "T" the moment encoding starts, which resumes on SIGCONT and then
# freezes again at the next poll — with no error to explain any of it. Nothing
# here wants keystrokes, so reading stdin is pure downside.
# -progress pipe:1 emits stable key=value records. Parse those records into one
# compact line rather than dumping frame/fps/out_time fields into Colab output.
# Keep stderr untouched so real FFmpeg warnings/errors are still visible.
set +e
ffmpeg -nostdin -v warning -nostats -stats_period 1 -progress pipe:1 -y "${input_args[@]}" -i "$input" \
  "${fc_args[@]}" \
  "${maps[@]}" \
  "${video_args[@]}" \
  "${codec_args[@]}" \
  "${dv_args[@]}" \
  -f hls \
  -hls_time "$segment_seconds" \
  -hls_playlist_type vod \
  -hls_segment_type fmp4 \
  -hls_flags single_file+independent_segments \
  -hls_fmp4_init_filename "${slug}.part%v-init.mp4" \
  -hls_segment_filename "$outdir/${slug}.part%v.m4s" \
  -master_pl_name "${slug}.m3u8" \
  -var_stream_map "$stream_map" \
  "$outdir/${slug}.part%v.m3u8" | show_ffmpeg_progress "$progress_duration_us"
ffmpeg_status=${PIPESTATUS[0]}
set -e
if [ "$ffmpeg_status" -ne 0 ]; then
  echo "FFmpeg failed with exit code $ffmpeg_status" >&2
  exit "$ffmpeg_status"
fi

# ffmpeg writes no CODECS attribute for HEVC, and never writes VIDEO-RANGE at
# all. Apple's HLS authoring spec requires both, and Safari will refuse a
# variant it cannot identify, so they get filled in here. It also points its
# one variant at the first audio group and leaves the others unreachable — each
# extra group needs a variant of its own aimed at the same video playlist.
master="$outdir/${slug}.m3u8"
if [ -f "$master" ]; then
  # hvc1.<profile_space><profile_idc>.<compat>.<tier><level>.<constraints>
  hvc=''
  hvc_spec=','
  if [ "$hevc_sequences" != ',' ]; then
    prof=1; case "$video_profile" in *10*) prof=2 ;; esac
    hvc="hvc1.$prof.4.L$video_level.B0"
    # An encoded rung has its own level — a 1080p HDR rung is not the source's
    # 5.1 — so read each HEVC output back rather than repeat the source's.
    IFS=',' read -r -a hevc_seq_list <<< "${hevc_sequences#,}"
    for seq in "${hevc_seq_list[@]}"; do
      [ -n "$seq" ] || continue
      part_media="$outdir/${slug}.part$((seq - 1)).m4s"
      out_level=$(ffprobe -v error -select_streams v:0 -show_entries stream=level -of default=nw=1:nk=1 "$part_media" 2>/dev/null | head -1)
      out_profile=$(ffprobe -v error -select_streams v:0 -show_entries stream=profile -of default=nw=1:nk=1 "$part_media" 2>/dev/null | head -1)
      [[ "$out_level" =~ ^[0-9]+$ ]] || continue
      out_prof=1; case "$out_profile" in *10*) out_prof=2 ;; esac
      hvc_spec+="$seq=hvc1.$out_prof.4.L$out_level.B0,"
    done
  fi
  case "$video_transfer" in
    smpte2084) range=PQ ;;
    arib-std-b67) range=HLG ;;
    *) range=SDR ;;
  esac
  first_audio=''; base_kbps=0
  if [ "${#groups[@]}" -gt 0 ]; then
    first_audio=${gcodec[0]}
    base_kbps=${gbitrate[0]}
  fi

  # Cross-compatible Dolby Vision (profile 8.x) rides on the HDR10/HLG base that
  # CODECS already names; a SUPPLEMENTAL-CODECS tag is what makes an Apple device
  # pick up the DV layer rather than just the base. dvh1.<profile>.<level>, both
  # zero-padded. Non-DV players ignore the attribute and take the base.
  dv_supp=''
  if [ "$copied_hevc" = "1" ] && [ "$has_dovi" = "1" ] && [ -n "$dv_profile" ] && [ -n "$dv_level" ]; then
    brand=''
    if [ "$dv_profile" = "8" ]; then
      case "$dv_compat:$video_transfer" in
        1:smpte2084) brand=db1p ;;
        2:*) [ "$range" = "SDR" ] && brand=db2g ;;
        4:bt2020-10) range=HLG; brand=db4g ;;
        4:arib-std-b67) brand=db4h ;;
      esac
    fi
    if [ -n "$brand" ]; then
      dv_supp=$(printf ',SUPPLEMENTAL-CODECS="dvh1.%02d.%02d/%s"' "$dv_profile" "$dv_level" "$brand")
    fi
  fi

  # Extra groups, encoded as "group|codec|deltaBps" for the awk pass below.
  extra_spec=''
  if [ "${#groups[@]}" -gt 1 ]; then
    for gi in "${!groups[@]}"; do
      [ "$gi" = "0" ] && continue
      delta=$(( (gbitrate[gi] - base_kbps) * 1000 ))
      extra_spec+="${groups[$gi]}|${gcodec[$gi]}|$delta;"
    done
  fi

  # One awk pass: add CODECS/VIDEO-RANGE to the HEVC variants, then clone every
  # EXT-X-STREAM-INF line once per extra audio group. Splitting on commas would
  # break the quoted CODECS, so the edits are done with match/substr.
  awk -v hvc="$hvc" -v range="$range" -v firstaudio="$first_audio" -v extra="$extra_spec" \
      -v dvsupp="$dv_supp" -v hevcs="$hevc_sequences" -v hdrs="$hdr_sequences" -v dvs="$dv_sequences" \
      -v hvcspec="$hvc_spec" -v fps="$video_fps" '
    function set_attr(line, key, val,   pre, rest, p) {
      # Replace key="..." if present, else append it.
      p = index(line, key "=\"")
      if (p > 0) {
        pre = substr(line, 1, p - 1)
        rest = substr(line, p + length(key) + 2)
        rest = substr(rest, index(rest, "\"") + 1)
        return pre key "=\"" val "\"" rest
      }
      return line ","key"=\"" val "\""
    }
    function video_of(line,   p, s) {
      # First token inside CODECS="...".
      p = index(line, "CODECS=\"")
      if (p == 0) return ""
      s = substr(line, p + 8)
      s = substr(s, 1, index(s, "\"") - 1)
      if (index(s, ",")) s = substr(s, 1, index(s, ",") - 1)
      return s
    }
    function bump_bandwidth(line, d,   out, s, m, n) {
      out = ""; s = line
      while (match(s, /BANDWIDTH=[0-9]+/)) {
        m = substr(s, RSTART, RLENGTH)
        n = substr(m, index(m, "=") + 1) + d
        out = out substr(s, 1, RSTART - 1) "BANDWIDTH=" n
        s = substr(s, RSTART + RLENGTH)
      }
      return out s
    }
    { lines[NR] = $0 }
    /^#EXT-X-STREAM-INF/ {
      seq++
      ishevc = index(hevcs, "," seq ",") > 0
      ishdr = index(hdrs, "," seq ",") > 0
      isdv = index(dvs, "," seq ",") > 0
      if (ishevc && index($0, "CODECS=") == 0) {
        own = hvc
        p = index(hvcspec, "," seq "=")
        if (p > 0) { own = substr(hvcspec, p + length(seq) + 2); own = substr(own, 1, index(own, ",") - 1) }
        codecs = firstaudio != "" ? own "," firstaudio : own
        lines[NR] = set_attr($0, "CODECS", codecs)
      }
      # VIDEO-RANGE is an enumerated token, not a quoted string. FFmpeg omits
      # it even when it already managed to write the HEVC CODECS attribute.
      if (ishdr && index(lines[NR], "VIDEO-RANGE=") == 0)
        lines[NR] = lines[NR] ",VIDEO-RANGE=" range (isdv ? dvsupp : "")
      # AVFoundation discards an HDR variant that declares no FRAME-RATE: it
      # never reaches the variant list, so nothing downstream can select it or
      # say why. SDR is exempt, which is what makes it hard to see — the h264
      # rungs keep working and only the HDR one goes missing, until a ladder
      # pruned to that rung leaves a player with nothing at all. The Apple
      # authoring rules ask for it on every video variant regardless.
      if (fps != "" && index(lines[NR], "FRAME-RATE=") == 0)
        lines[NR] = lines[NR] ",FRAME-RATE=" fps
      sinf[++ns] = NR
    }
    END {
      for (i = 1; i <= NR; i++) print lines[i]
      if (extra == "" || ns == 0) exit
      # One clone of every video variant per extra audio group: a ladder has
      # several variants, and each has to be reachable from each group.
      m = split(extra, rows, ";")
      for (r = 1; r <= m; r++) {
        if (rows[r] == "") continue
        split(rows[r], f, "|")
        for (k = 1; k <= ns; k++) {
          base = lines[sinf[k]]
          clone = set_attr(base, "AUDIO", "group_" f[1])
          vpart = video_of(base)
          if (vpart != "" && f[2] != "") clone = set_attr(clone, "CODECS", vpart "," f[2])
          clone = bump_bandwidth(clone, f[3] + 0)
          print clone
          print lines[sinf[k] + 1]
        }
      }
    }
  ' "$master" > "$master.tmp" && mv "$master.tmp" "$master"

  if [ "$hevc_sequences" != ',' ]; then
    dv_note=''; [ -n "$dv_supp" ] && dv_note=' + Dolby Vision'
    echo "  master playlist: added CODECS and VIDEO-RANGE=$range$dv_note for Apple"
  fi
  [ "${#groups[@]}" -gt 1 ] && echo "  master playlist: added $(( ${#groups[@]} - 1 )) more variant(s) so every audio group is reachable"
fi

# A .m3u8 has no thumbnail of its own — Drive generates one for a video file,
# not for a text playlist — so the library gets a still to put on the card.
ffmpeg -nostdin -v error -y -ss "${PREP_POSTER_SECONDS:-5}" -i "$input" -frames:v 1 -vf scale=640:-2 \
  "$outdir/${slug}.poster.jpg" 2>/dev/null ||
  ffmpeg -nostdin -v error -y -i "$input" -frames:v 1 -vf scale=640:-2 "$outdir/${slug}.poster.jpg"

# A tiny sidecar the library reads for the quality badges. The manifest carries
# neither HDR nor an AAC track's channel count (5.1 AAC looks like stereo in its
# CODECS), and the VPS cannot probe a file that only lives in Drive — so what is
# known here, at ingest, is written down beside the bundle. The labels match
# the ones viewers know from streaming services. They describe the best stream
# in the bundle: a raw rung keeps Dolby Vision/HDR and raw E-AC-3 may keep Atmos,
# even when the compatibility rungs beside them are H.264 SDR and stereo AAC.
hdr=null
source_video_kept=0
if [ "$copy_video" = "1" ] || { [ -n "${PREP_LADDER:-}" ] && { [ "$want_raw" = "1" ] || [ "$want_hdr" = "1" ]; }; }; then
  source_video_kept=1
fi
if [ "$source_video_kept" = "1" ]; then
  case "$video_transfer" in
    smpte2084)
      if [ "$copied_hevc" = "1" ] && [ "$has_dovi" = "1" ]; then hdr='"Dolby Vision"'
      else hdr='"HDR10"'
      fi
      ;;
    arib-std-b67) hdr='"HLG"' ;;
  esac
fi
maxch=0
keeps_raw_audio=0
if [ "$audio_mode" = "browser-copy" ]; then
  # Badge only the tracks that browser-copy actually retained.
  for i in "${!a_codec[@]}"; do
    case "${a_codec[$i]}" in
      aac|flac|ac3|eac3)
        c=${a_channels[$i]}
        case "$c" in '' | *[!0-9]*) c=0 ;; esac
        if [ "$c" -gt "$maxch" ]; then maxch=$c; fi
        keeps_raw_audio=1
        ;;
    esac
  done
else
  for spec in "${channel_list[@]}"; do
    if [ "$spec" = "raw" ]; then
      keeps_raw_audio=1
      for c in "${a_channels[@]}"; do
        case "$c" in '' | *[!0-9]*) c=0 ;; esac
        if [ "$c" -gt "$maxch" ]; then maxch=$c; fi
      done
    elif [ "$spec" -gt "$maxch" ]; then
      maxch=$spec
    fi
  done
fi
audio_badge=null
audio_has_atmos=$(ffprobe -v error -select_streams a -show_entries stream=profile -of default=nw=1:nk=1 "$input" |
  awk 'tolower($0) ~ /atmos/ { print 1; exit }')
if [ "$keeps_raw_audio" = "1" ] && [ "${audio_has_atmos:-0}" = "1" ]; then audio_badge='"Dolby Atmos"'
elif [ "$maxch" -ge 8 ]; then audio_badge='"7.1"'
elif [ "$maxch" -ge 6 ]; then audio_badge='"5.1"'
fi
# Write the same rich schema-v2 sidecar as the PowerShell version.  The Bash
# script used to depend on an optional generate-info-json.py helper and otherwise
# fell back to only {hdr,audio}; that made Linux/Colab bundles lose resolution,
# source, rendition and per-file metadata.  Keep it self-contained instead: when
# python3 is present (Colab/Linux normally has it), probe the source and the HLS
# outputs that were just written and build the detailed manifest here.
if command -v python3 >/dev/null 2>&1; then
  python3 - "$input" "$outdir" "$slug" "$hdr" "$audio_badge" \
    "$copy_video" "$want_raw" "$want_hdr" "$source_video_kept" <<'PYINFO'
import datetime as dt
import json
import os
import re
import subprocess
import sys
from pathlib import Path

src = Path(sys.argv[1])
outdir = Path(sys.argv[2])
slug = sys.argv[3]


def json_arg(value):
    try:
        return json.loads(value)
    except Exception:
        return None


legacy_hdr = json_arg(sys.argv[4])
legacy_audio = json_arg(sys.argv[5])
copy_video = sys.argv[6] == "1"
want_raw = sys.argv[7] == "1"
want_hdr = sys.argv[8] == "1"
source_video_kept = sys.argv[9] == "1"


def probe(path):
    try:
        p = subprocess.run(
            ["ffprobe", "-v", "error", "-show_format", "-show_streams", "-of", "json", str(path)],
            check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True
        )
        return json.loads(p.stdout or "{}")
    except Exception:
        return {}


def as_int(v):
    try:
        return int(v)
    except Exception:
        return None


def as_float(v):
    try:
        return float(v)
    except Exception:
        return None


def fps_value(rate):
    if not rate:
        return None
    try:
        a, b = str(rate).split("/", 1)
        b = float(b)
        return round(float(a) / b, 3) if b else None
    except Exception:
        return None


def quality_label(w, h):
    w, h = w or 0, h or 0
    # Match the PowerShell sidecar: cropped cinema frames are classified by the
    # resolution class of their long edge (1920x800 => 1080p, 3840x1600 => 4K).
    if w >= 3800 or h >= 2160:
        return "4K"
    if w >= 2500 or h >= 1440:
        return "1440p"
    if w >= 1800 or h >= 1080:
        return "1080p"
    if w >= 1200 or h >= 720:
        return "720p"
    if w >= 700 or h >= 480:
        return "480p"
    return f"{h}p" if h else "unknown"


def bit_depth(pix_fmt):
    m = re.search(r"(\d+)(?:le|be)$", pix_fmt or "")
    return int(m.group(1)) if m else 8


def has_dolby_vision(stream):
    blob = json.dumps(stream, ensure_ascii=False).lower()
    return "dolby vision" in blob or "dovi" in blob or "dv_profile" in blob


def hdr_label(stream, allow_dv=True):
    tr = stream.get("color_transfer")
    if tr == "smpte2084":
        return "Dolby Vision" if allow_dv and has_dolby_vision(stream) else "HDR10"
    if tr == "arib-std-b67":
        return "HLG"
    return None


def codec_string(codec, profile=""):
    c = (codec or "").lower()
    if c == "aac": return "mp4a.40.2"
    if c == "eac3": return "ec-3"
    if c == "ac3": return "ac-3"
    if c == "flac": return "fLaC"
    if c == "truehd": return "mlpa"
    if c == "opus": return "opus"
    if c == "alac": return "alac"
    if c == "mp3": return "mp4a.40.34"
    if c == "dts":
        pl = (profile or "").lower()
        if "master" in pl: return "dtsl"
        if "high resolution" in pl: return "dtsh"
        return "dtsc"
    return ""


def disposition(stream, key):
    return bool((stream.get("disposition") or {}).get(key, 0))


def stream_title(stream):
    return str((stream.get("tags") or {}).get("title") or "")


def stream_lang(stream):
    return str((stream.get("tags") or {}).get("language") or "und")


def sanitise_name(text):
    return re.sub(r"[^A-Za-z0-9._-]", "", (text or "").replace(" ", "-"))


source_probe = probe(src)
streams = source_probe.get("streams") or []
fmt = source_probe.get("format") or {}
video_src = next((s for s in streams if s.get("codec_type") == "video"), {})
audio_src = [s for s in streams if s.get("codec_type") == "audio"]
sub_src = [s for s in streams if s.get("codec_type") == "subtitle"]

sw = as_int(video_src.get("width")) or 0
sh = as_int(video_src.get("height")) or 0
src_quality = quality_label(sw, sh)
src_codec = str(video_src.get("codec_name") or "")
src_pix = str(video_src.get("pix_fmt") or "")
src_depth = bit_depth(src_pix)
src_dv = has_dolby_vision(video_src)

# EXT-X-MEDIA carries the language/title/group information for separate audio
# renditions.  ffprobe on the .m4s gives codec/channels/resolution, so combining
# both sources reproduces the useful PowerShell rendition manifest.
def parse_attrs(line):
    attrs = {}
    payload = line.split(":", 1)[1] if ":" in line else ""
    for m in re.finditer(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)', payload):
        v = m.group(2)
        if len(v) >= 2 and v[0] == '"' and v[-1] == '"':
            v = v[1:-1]
        attrs[m.group(1)] = v
    return attrs


audio_meta = {}
master = outdir / f"{slug}.m3u8"
if master.exists():
    try:
        for line in master.read_text(encoding="utf-8", errors="replace").splitlines():
            if line.startswith("#EXT-X-MEDIA:"):
                a = parse_attrs(line)
                if a.get("TYPE") == "AUDIO" and a.get("URI"):
                    base = Path(a["URI"]).name
                    if base.endswith(".m3u8"):
                        base = base[:-5]
                    audio_meta[base] = a
    except Exception:
        pass


def match_source_audio(meta, out_stream):
    lang = (meta or {}).get("LANGUAGE")
    name = (meta or {}).get("NAME") or ""
    # Prefer an exact/sanitised title match, then language, then channel/codec.
    for s in audio_src:
        title = stream_title(s)
        if name and (name == title or sanitise_name(title) == name):
            return s
    if lang:
        same = [s for s in audio_src if stream_lang(s) == lang]
        if len(same) == 1:
            return same[0]
        if same:
            oc = as_int(out_stream.get("channels"))
            for s in same:
                if as_int(s.get("channels")) == oc:
                    return s
            return same[0]
    return audio_src[0] if len(audio_src) == 1 else {}


video_renditions = []
audio_renditions = []
rendition_by_base = {}

media_files = sorted(outdir.glob(f"{slug}.part*.m4s"), key=lambda p: p.name)
for media in media_files:
    pr = probe(media)
    out_streams = pr.get("streams") or []
    st = next((x for x in out_streams if x.get("codec_type") in ("video", "audio")), None)
    if not st:
        continue
    base = media.name[:-4]
    playlist = f"{base}.m3u8"
    codec = str(st.get("codec_name") or "")

    if st.get("codec_type") == "video":
        w = as_int(st.get("width")) or 0
        h = as_int(st.get("height")) or 0
        m = re.search(r"\.part(\d+)$", base)
        idx = int(m.group(1)) if m else len(video_renditions)
        # In this script a copied source rung is the first video rendition when
        # copy_video is active (including the explicit raw rung).
        copied = bool(idx == 0 and copy_video and w == sw and h == sh and codec == src_codec)
        if want_raw and idx == 0 and w == sw and h == sh and codec == src_codec:
            copied = True
        out_hdr = hdr_label(st, allow_dv=copied and src_dv)
        br = as_int(st.get("bit_rate"))
        r = {
            "file": base,
            "playlist": playlist,
            "mediaFile": media.name,
            "kind": "video",
            "raw": copied,
            "source": "copied untouched" if copied else "re-encoded",
            "codec": codec,
            "sourceCodec": src_codec,
            "width": w,
            "height": h,
            "resolution": f"{w}x{h}" if w and h else None,
            "quality": quality_label(w, h),
            "hdr": out_hdr,
            "dolbyVision": bool(copied and src_dv),
            "bitDepth": bit_depth(st.get("pix_fmt") or ""),
            "targetBitrate": None if copied else br,
        }
        video_renditions.append(r)
        rendition_by_base[base] = r
    else:
        meta = audio_meta.get(base, {})
        src_a = match_source_audio(meta, st)
        channels = as_int(st.get("channels")) or 0
        source_channels = as_int(src_a.get("channels")) or 0
        source_codec_a = str(src_a.get("codec_name") or "")
        raw = bool(source_codec_a and codec == source_codec_a and channels == source_channels)
        meta_name = meta.get("NAME") or ""
        source_title = stream_title(src_a)
        # FFmpeg may invent NAME=audio_N when the source has no HLS display name;
        # prefer the source title/language in the sidecar in that case.
        title = (source_title or stream_lang(src_a)) if re.fullmatch(r"audio_\d+", meta_name) else (meta_name or source_title or stream_title(st))
        language = meta.get("LANGUAGE") or stream_lang(src_a) or stream_lang(st)
        profile = str(src_a.get("profile") or st.get("profile") or "")
        atmos = bool(raw and ("atmos" in title.lower() or "atmos" in profile.lower()))
        br = as_int(st.get("bit_rate"))
        if br is None:
            br = as_int(src_a.get("bit_rate")) if raw else None
        r = {
            "file": base,
            "playlist": playlist,
            "mediaFile": media.name,
            "kind": "audio",
            "group": meta.get("GROUP-ID") or "aud",
            "raw": raw,
            "padded": False,
            "source": "copied untouched" if raw else "re-encoded",
            "codec": codec,
            "codecString": codec_string(codec, profile),
            "sourceCodec": source_codec_a or None,
            "language": language,
            "title": title,
            "channels": channels,
            "channelLayout": st.get("channel_layout") or None,
            "bitrateKbps": round(br / 1000) if br else None,
            "atmos": atmos,
            "default": str(meta.get("DEFAULT", "NO")).upper() == "YES",
        }
        audio_renditions.append(r)
        rendition_by_base[base] = r

# Sort numeric video part indexes naturally; audio stays in playlist/name order.
def video_order(r):
    m = re.search(r"\.part(\d+)$", r["file"])
    return int(m.group(1)) if m else 999999
video_renditions.sort(key=video_order)

text_sub_codecs = {"subrip", "ass", "ssa", "mov_text", "webvtt", "text"}
subtitle_renditions = []
for i, s in enumerate(sub_src):
    lang = stream_lang(s)
    name = f"{slug}.sub-{lang}-{i}.vtt"
    path = outdir / name
    if path.exists():
        subtitle_renditions.append({
            "file": name,
            "kind": "subtitle",
            "format": "webvtt",
            "sourceCodec": str(s.get("codec_name") or ""),
            "language": lang,
            "title": stream_title(s),
            "forced": disposition(s, "forced"),
            "default": disposition(s, "default"),
        })

# Source track inventories, matching the PowerShell sidecar fields.
audio_tracks = []
for s in audio_src:
    title = stream_title(s)
    profile = str(s.get("profile") or "")
    audio_tracks.append({
        "index": as_int(s.get("index")),
        "codec": str(s.get("codec_name") or ""),
        "profile": profile,
        "language": stream_lang(s),
        "title": title,
        "channels": as_int(s.get("channels")),
        "layout": s.get("channel_layout") or None,
        "sampleRate": as_int(s.get("sample_rate")),
        "bitrate": as_int(s.get("bit_rate")),
        "default": disposition(s, "default"),
        "forced": disposition(s, "forced"),
        "atmos": bool("atmos" in title.lower() or "atmos" in profile.lower()),
        "commentary": bool("commentary" in title.lower() or disposition(s, "comment")),
    })

subtitle_tracks = []
for i, s in enumerate(sub_src):
    title = stream_title(s)
    codec = str(s.get("codec_name") or "")
    lang = stream_lang(s)
    included = (outdir / f"{slug}.sub-{lang}-{i}.vtt").exists()
    subtitle_tracks.append({
        "index": as_int(s.get("index")),
        "codec": codec,
        "language": lang,
        "title": title,
        "kind": "text" if codec in text_sub_codecs else "image",
        "included": included,
        "default": disposition(s, "default"),
        "forced": disposition(s, "forced"),
        "closedCaptions": bool(re.search(r"\bCC\b|closed captions", title, re.I)),
        "sdh": bool(re.search(r"\bSDH\b|hearing impaired", title, re.I) or disposition(s, "hearing_impaired")),
    })

# Flat file-by-file manifest.  Link part*.m3u8/m4s entries to the rendition that
# owns them so the library can read resolution/channels without probing Drive.
files = []
esc = re.escape(slug)
for f in sorted((x for x in outdir.iterdir() if x.is_file()), key=lambda x: x.name):
    if f.name == f"{slug}.info.json":
        continue
    e = {"name": f.name, "sizeBytes": f.stat().st_size}
    if f.name == f"{slug}.m3u8":
        e["role"] = "master playlist"
    elif f.name == f"{slug}.poster.jpg":
        e["role"] = "poster image"
    elif re.match(rf"^{esc}\.sub-[^.]+-\d+\.vtt$", f.name):
        e["role"] = "subtitle"
        e["format"] = "webvtt"
        m = re.match(rf"^{esc}\.sub-([^.]+)-\d+\.vtt$", f.name)
        if m: e["language"] = m.group(1)
    else:
        m = re.match(rf"^(?P<base>{esc}\.part.+?)(?P<init>-init)?\.(?P<ext>m3u8|m4s|mp4)$", f.name)
        if m:
            base = m.group("base")
            ext = m.group("ext")
            e["role"] = "media playlist" if ext == "m3u8" else ("fmp4 init segment" if m.group("init") else "media segments (fmp4, single file)")
            e["rendition"] = base
            r = rendition_by_base.get(base)
            if r:
                e["streamKind"] = r["kind"]
                e["codec"] = r.get("codec")
                e["raw"] = r.get("raw", False)
                if r["kind"] == "video":
                    e["resolution"] = r.get("resolution")
                    if r.get("hdr"): e["hdr"] = r["hdr"]
                else:
                    e["language"] = r.get("language")
                    e["channels"] = r.get("channels")
        else:
            e["role"] = "other"
    files.append(e)
files.append({"name": f"{slug}.info.json", "role": "manifest (this file)"})

# Prefer actual top rendition codec when available; otherwise mirror PS1's
# source/copy decision.
top_video = video_renditions[0] if video_renditions else None
output_codec = (top_video or {}).get("codec") or (src_codec if copy_video else "h264")

info = {
    "schemaVersion": 2,
    "hdr": legacy_hdr,
    "audio": legacy_audio,
    "badges": {
        "quality": src_quality,
        "hdr": legacy_hdr,
        "audio": legacy_audio,
        "videoCodec": output_codec.upper() if output_codec else None,
    },
    "source": {
        "fileName": src.name,
        "sizeBytes": src.stat().st_size if src.exists() else None,
        "container": fmt.get("format_name"),
        "durationMs": round(float(fmt["duration"]) * 1000) if fmt.get("duration") else None,
        "bitrate": as_int(fmt.get("bit_rate")),
    },
    "video": {
        "codec": src_codec,
        "outputCodec": output_codec,
        "profile": video_src.get("profile"),
        "width": sw,
        "height": sh,
        "resolution": f"{sw}x{sh}" if sw and sh else None,
        "quality": src_quality,
        "pixelFormat": src_pix,
        "bitDepth": src_depth,
        "frameRate": fps_value(video_src.get("avg_frame_rate")),
        "bitrate": as_int(video_src.get("bit_rate")),
        "colorRange": video_src.get("color_range"),
        "colorSpace": video_src.get("color_space"),
        "colorTransfer": video_src.get("color_transfer"),
        "colorPrimaries": video_src.get("color_primaries"),
        "hdr": legacy_hdr,
        "dolbyVision": bool(source_video_kept and src_dv),
        "preserveHdr": bool(source_video_kept and legacy_hdr),
        "targetBitrate": (top_video or {}).get("targetBitrate") if top_video and not top_video.get("raw") else None,
    },
    "audioTracks": audio_tracks,
    "subtitleTracks": subtitle_tracks,
    "renditions": {
        "video": video_renditions,
        "audio": audio_renditions,
        "subtitles": subtitle_renditions,
    },
    "files": files,
    "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
}

(outdir / f"{slug}.info.json").write_text(
    json.dumps(info, ensure_ascii=False, separators=(",", ":")), encoding="utf-8"
)
PYINFO
else
  # No Python: still write useful resolution/quality metadata instead of the old
  # two-field fallback.  Detailed track/rendition arrays require python3.
  if [ "${video_width:-0}" -ge 3800 ] || [ "${video_height:-0}" -ge 2160 ]; then quality='4K'
  elif [ "${video_width:-0}" -ge 2500 ] || [ "${video_height:-0}" -ge 1440 ]; then quality='1440p'
  elif [ "${video_width:-0}" -ge 1800 ] || [ "${video_height:-0}" -ge 1080 ]; then quality='1080p'
  elif [ "${video_width:-0}" -ge 1200 ] || [ "${video_height:-0}" -ge 720 ]; then quality='720p'
  elif [ "${video_width:-0}" -ge 700 ] || [ "${video_height:-0}" -ge 480 ]; then quality='480p'
  else quality="${video_height:-0}p"
  fi
  printf '{"schemaVersion":2,"hdr":%s,"audio":%s,"badges":{"quality":"%s","hdr":%s,"audio":%s,"videoCodec":"%s"},"video":{"codec":"%s","width":%s,"height":%s,"resolution":"%sx%s","quality":"%s"}}\n' \
    "$hdr" "$audio_badge" "$quality" "$hdr" "$audio_badge" "${out_codec^^}" \
    "$video_codec" "${video_width:-0}" "${video_height:-0}" "${video_width:-0}" "${video_height:-0}" "$quality" \
    > "$outdir/${slug}.info.json"
fi

echo
echo "done. Open Upload in the library and select every file in $outdir —"
echo "they are one video, and the queue takes them together:"
ls -1 "$outdir" | sed 's/^/  /'
