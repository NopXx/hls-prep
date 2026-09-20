#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Generates rich schemaVersion 2 <slug>.info.json for an HLS bundle.
"""

import os
import sys
import json
import subprocess
import glob
import re
from datetime import datetime, timezone

def get_quality(w, h):
    """Return the release/streaming resolution class.

    Uses both width and height so cropped widescreen movies keep their
    expected class, e.g. 1920x800 -> 1080p, 1280x536 -> 720p,
    854x356 -> 480p, 2560x1080 -> 1440p, 3840x1600 -> 4K.
    """
    w = int(w or 0)
    h = int(h or 0)

    if w >= 3800 or h >= 1600:
        return "4K"
    elif w >= 2500 or h >= 1300:
        return "1440p"
    elif w >= 1900 or h >= 1000:
        return "1080p"
    elif w >= 1260 or h >= 700:
        return "720p"
    elif h >= 500:
        return "576p"
    elif w >= 840 or h >= 400:
        return "480p"
    return "SD"

def parse_fps(val):
    if not val or val == '0/0':
        return None
    if '/' in val:
        try:
            num, den = val.split('/')
            return round(float(num) / float(den), 3) if float(den) != 0 else None
        except:
            return None
    try:
        return round(float(val), 3)
    except:
        return None

def find_tool(name):
    env_path = os.environ.get("PATH", "")
    dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] + env_path.split(":")
    for d in dirs:
        p = os.path.join(d, name)
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return name

def generate_info_json(source_path, outdir, slug=None):
    if not slug:
        slug = os.path.splitext(os.path.basename(source_path))[0]
    
    ffprobe = find_tool("ffprobe")
    cmd = [
        ffprobe, '-v', 'error',
        '-show_format', '-show_streams',
        '-print_format', 'json',
        source_path
    ]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        return None
        
    probe = json.loads(res.stdout)
    fmt = probe.get('format', {})
    streams = probe.get('streams', [])
    
    video_streams = [s for s in streams if s.get('codec_type') == 'video']
    audio_streams = [s for s in streams if s.get('codec_type') == 'audio']
    sub_streams = [s for s in streams if s.get('codec_type') == 'subtitle']
    
    v0 = video_streams[0] if video_streams else {}
    
    v_width = v0.get('width', 0)
    v_height = v0.get('height', 0)
    quality_badge = get_quality(v_width, v_height)
    
    color_transfer = v0.get('color_transfer', '')
    side_data = v0.get('side_data_list', [])
    has_dovi = any('dovi' in str(sd).lower() or 'dolby vision' in str(sd).lower() for sd in side_data)
    
    hdr_badge = None
    if color_transfer == 'smpte2084':
        hdr_badge = "Dolby Vision" if has_dovi else "HDR10"
    elif color_transfer == 'arib-std-b67':
        hdr_badge = "HLG"
    elif has_dovi:
        hdr_badge = "Dolby Vision"
        
    has_atmos = any('atmos' in (s.get('profile', '') + ' ' + s.get('tags', {}).get('title', '')).lower() for s in audio_streams)
    max_channels = max([s.get('channels', 0) for s in audio_streams], default=0)
    
    audio_badge = None
    if has_atmos:
        audio_badge = "Dolby Atmos"
    elif max_channels >= 8:
        audio_badge = "7.1"
    elif max_channels >= 6:
        audio_badge = "5.1"
        
    v_codec = v0.get('codec_name', '').lower()
    codec_badge_map = {
        'hevc': 'HEVC',
        'h264': 'AVC',
        'av1': 'AV1',
        'vp9': 'VP9'
    }
    video_codec_badge = codec_badge_map.get(v_codec, v_codec.upper())
    
    badges = {
        "quality": quality_badge,
        "hdr": hdr_badge,
        "audio": audio_badge,
        "videoCodec": video_codec_badge
    }
    
    source_info = {
        "fileName": os.path.basename(source_path),
        "sizeBytes": int(fmt.get('size', 0)) if fmt.get('size') else os.path.getsize(source_path),
        "container": fmt.get('format_name', ''),
        "durationMs": int(round(float(fmt.get('duration', 0)) * 1000)) if fmt.get('duration') else None,
        "bitrate": int(fmt.get('bit_rate', 0)) if fmt.get('bit_rate') else None
    }
    
    fps = parse_fps(v0.get('r_frame_rate')) or parse_fps(v0.get('avg_frame_rate'))
    pix_fmt = v0.get('pix_fmt', '')
    bit_depth = 10 if '10' in pix_fmt else (12 if '12' in pix_fmt else (int(v0.get('bits_per_raw_sample', 8)) if v0.get('bits_per_raw_sample') else 8))
    
    video_info = {
        "codec": v_codec,
        "outputCodec": v_codec,
        "profile": v0.get('profile', ''),
        "width": v_width,
        "height": v_height,
        "resolution": f"{v_width}x{v_height}",
        "quality": quality_badge,
        "pixelFormat": pix_fmt,
        "bitDepth": bit_depth,
        "frameRate": fps,
        "bitrate": int(v0['bit_rate']) if v0.get('bit_rate') else None,
        "colorRange": v0.get('color_range'),
        "colorSpace": v0.get('color_space'),
        "colorTransfer": color_transfer if color_transfer else None,
        "colorPrimaries": v0.get('color_primaries'),
        "hdr": hdr_badge,
        "dolbyVision": has_dovi,
        "preserveHdr": hdr_badge is not None,
        "targetBitrate": None
    }
    
    audio_tracks = []
    for s in audio_streams:
        prof = s.get('profile', '')
        title = s.get('tags', {}).get('title', '')
        is_atmos = 'atmos' in (prof + ' ' + title).lower()
        disp = s.get('disposition', {})
        audio_tracks.append({
            "index": s.get('index'),
            "codec": s.get('codec_name'),
            "profile": prof,
            "language": s.get('tags', {}).get('language', 'und'),
            "title": title,
            "channels": s.get('channels', 0),
            "layout": s.get('channel_layout', ''),
            "sampleRate": int(s.get('sample_rate', 48000)),
            "bitrate": int(s.get('bit_rate', 0)) if s.get('bit_rate') else None,
            "default": bool(disp.get('default', 0)),
            "forced": bool(disp.get('forced', 0)),
            "atmos": is_atmos,
            "commentary": bool(disp.get('comment', 0))
        })
        
    subtitle_tracks = []
    for s in sub_streams:
        disp = s.get('disposition', {})
        title = s.get('tags', {}).get('title', '')
        c_name = s.get('codec_name', '')
        is_text = c_name in ['subrip', 'mov_text', 'webvtt', 'ass', 'ssa', 'text']
        subtitle_tracks.append({
            "index": s.get('index'),
            "codec": c_name,
            "language": s.get('tags', {}).get('language', 'und'),
            "title": title,
            "kind": "text" if is_text else "image",
            "included": is_text,
            "default": bool(disp.get('default', 0)),
            "forced": bool(disp.get('forced', 0)),
            "closedCaptions": 'cc' in title.lower(),
            "sdh": bool(disp.get('hearing_impaired', 0)) or 'sdh' in title.lower()
        })
        
    # Read master playlist
    master_playlist_path = os.path.join(outdir, f"{slug}.m3u8")
    master_lines = []
    if os.path.exists(master_playlist_path):
        with open(master_playlist_path, 'r', encoding='utf-8', errors='ignore') as f:
            master_lines = f.readlines()
            
    # Parse video stream variants (de-duplicated by playlist filename)
    video_variants = []
    seen_video_pls = set()
    current_inf = None
    for line in master_lines:
        line = line.strip()
        if line.startswith('#EXT-X-STREAM-INF:'):
            current_inf = line
        elif current_inf and not line.startswith('#') and line.endswith('.m3u8'):
            if line not in seen_video_pls:
                seen_video_pls.add(line)
                video_variants.append((current_inf, line))
            current_inf = None
            
    video_renditions = []
    for inf, pl_file in video_variants:
        res_m = re.search(r'RESOLUTION=(\d+)x(\d+)', inf)
        w = int(res_m.group(1)) if res_m else v_width
        h = int(res_m.group(2)) if res_m else v_height
        codec_m = re.search(r'CODECS="([^"]+)"', inf)
        codecs_str = codec_m.group(1) if codec_m else ""
        
        is_hevc = 'hvc1' in codecs_str or 'hev1' in codecs_str or (w == v_width and v_codec == 'hevc')
        r_codec = 'hevc' if is_hevc else 'h264'
        is_raw = (pl_file == f"{slug}.part0.m3u8" and w == v_width and h == v_height)
        # An encoded HEVC HDR rung (prep-hls 'hdr1080' etc.) keeps the source's
        # colour system; the master's VIDEO-RANGE says which. A re-encode drops
        # any Dolby Vision layer, so PQ is plain HDR10.
        range_m = re.search(r'VIDEO-RANGE=(\w+)', inf)
        video_range = range_m.group(1) if range_m else 'SDR'
        if is_raw:
            r_hdr = hdr_badge
        elif video_range == 'PQ':
            r_hdr = 'HDR10'
        elif video_range == 'HLG':
            r_hdr = 'HLG'
        else:
            r_hdr = None
        
        part_stem = pl_file[:-5]
        media_file = f"{part_stem}.m4s"
        q = get_quality(w, h)
        
        video_renditions.append({
            "file": part_stem,
            "playlist": pl_file,
            "mediaFile": media_file,
            "kind": "video",
            "raw": is_raw,
            "source": "copied untouched" if is_raw else "re-encoded",
            "codec": r_codec,
            "sourceCodec": v_codec,
            "width": w,
            "height": h,
            "resolution": f"{w}x{h}",
            "quality": q,
            "hdr": r_hdr,
            "dolbyVision": has_dovi if is_raw else False,
            "bitDepth": bit_depth if is_raw else (10 if r_hdr else 8),
            "targetBitrate": None if is_raw else f"{int(round(h * 3.25))}k"
        })
        
    # Audio renditions (de-duplicated by playlist URI)
    audio_media_lines = [l.strip() for l in master_lines if l.startswith('#EXT-X-MEDIA:TYPE=AUDIO')]
    audio_renditions = []
    seen_audio_uris = set()
    for line in audio_media_lines:
        uri_m = re.search(r'URI="([^"]+)"', line)
        if not uri_m:
            continue
        pl_file = uri_m.group(1)
        if pl_file in seen_audio_uris:
            continue
        seen_audio_uris.add(pl_file)
        
        part_stem = pl_file[:-5] if pl_file.endswith('.m3u8') else pl_file
        media_file = f"{part_stem}.m4s"
        
        grp_m = re.search(r'GROUP-ID="([^"]+)"', line)
        grp = grp_m.group(1) if grp_m else "a"
        
        lang_m = re.search(r'LANGUAGE="([^"]+)"', line)
        lang = lang_m.group(1) if lang_m else "und"
        
        ch_m = re.search(r'CHANNELS="(\d+)"', line)
        ch = int(ch_m.group(1)) if ch_m else 2
        
        def_m = re.search(r'DEFAULT=(YES|NO)', line)
        is_def = (def_m.group(1) == 'YES') if def_m else False
        
        is_raw = ('raw' in grp.lower() or 'original' in pl_file.lower() or ch > 2)
        
        src_track = next((t for t in audio_tracks if t['language'] == lang), audio_tracks[0] if audio_tracks else None)
        title = src_track['title'] if src_track else ""
        src_codec = src_track['codec'] if src_track else "unknown"
        
        out_codec = src_codec if is_raw else "aac"
        codec_string = "ec-3" if out_codec in ['eac3', 'ac3'] else ("mp4a.40.2" if out_codec == 'aac' else out_codec)
        
        audio_renditions.append({
            "file": part_stem,
            "playlist": pl_file,
            "mediaFile": media_file,
            "kind": "audio",
            "group": grp,
            "raw": is_raw,
            "padded": False,
            "source": "copied untouched" if is_raw else "re-encoded",
            "codec": out_codec,
            "codecString": codec_string,
            "sourceCodec": src_codec,
            "language": lang,
            "title": title,
            "channels": ch,
            "channelLayout": "stereo" if ch == 2 else f"{ch}.1(side)",
            "bitrateKbps": int((src_track['bitrate'] or 640000) / 1000) if is_raw else 192,
            "atmos": src_track['atmos'] if src_track else False,
            "default": is_def
        })
        
    # Subtitle renditions
    sub_renditions = []
    vtt_files = sorted(glob.glob(os.path.join(outdir, f"{slug}.sub-*.vtt")))
    for vf in vtt_files:
        v_name = os.path.basename(vf)
        m = re.search(r'\.sub-([a-z0-9]+)-(\d+)\.vtt$', v_name)
        lang = m.group(1) if m else "und"
        idx = int(m.group(2)) if m else 0
        src_sub = next((s for s in subtitle_tracks if s['language'] == lang or s['index'] == idx), None)
        sub_renditions.append({
            "file": v_name,
            "kind": "subtitle",
            "format": "webvtt",
            "sourceCodec": src_sub['codec'] if src_sub else "subrip",
            "language": lang,
            "title": src_sub['title'] if src_sub else "",
            "forced": src_sub['forced'] if src_sub else False,
            "default": src_sub['default'] if src_sub else False
        })
        
    # Files listing
    all_out_files = sorted(os.listdir(outdir))
    files_list = []
    for fn in all_out_files:
        fp = os.path.join(outdir, fn)
        if not os.path.isfile(fp):
            continue
        sz = os.path.getsize(fp)
        
        if fn == f"{slug}.m3u8":
            files_list.append({
                "name": fn,
                "sizeBytes": sz,
                "role": "master playlist"
            })
        elif fn.endswith(".m3u8") and '.part' in fn and not re.search(r'\.part\d+\.m3u8$', fn):
            # Audio media playlist
            stem = fn[:-5]
            rend = next((r for r in audio_renditions if r['file'] == stem), None)
            item = {
                "name": fn,
                "sizeBytes": sz,
                "role": "media playlist",
                "rendition": stem,
                "streamKind": "audio",
                "codec": rend['codec'] if rend else "aac",
                "raw": rend['raw'] if rend else False,
                "language": rend['language'] if rend else "und",
                "channels": rend['channels'] if rend else 2
            }
            files_list.append(item)
        elif fn.endswith(".m4s") and '.part' in fn and not re.search(r'\.part\d+\.m4s$', fn):
            # Audio media segment
            stem = fn[:-4]
            rend = next((r for r in audio_renditions if r['file'] == stem), None)
            item = {
                "name": fn,
                "sizeBytes": sz,
                "role": "media segments (fmp4, single file)",
                "rendition": stem,
                "streamKind": "audio",
                "codec": rend['codec'] if rend else "aac",
                "raw": rend['raw'] if rend else False,
                "language": rend['language'] if rend else "und",
                "channels": rend['channels'] if rend else 2
            }
            files_list.append(item)
        elif fn.endswith(".m3u8") and (re.search(r'\.part\d+\.m3u8$', fn)):
            # Video media playlist
            stem = fn[:-5]
            rend = next((r for r in video_renditions if r['file'] == stem), None)
            item = {
                "name": fn,
                "sizeBytes": sz,
                "role": "media playlist",
                "rendition": stem,
                "streamKind": "video",
                "codec": rend['codec'] if rend else "h264",
                "raw": rend['raw'] if rend else False,
                "resolution": rend['resolution'] if rend else ""
            }
            if rend and rend.get('hdr'):
                item['hdr'] = rend['hdr']
            files_list.append(item)
        elif fn.endswith(".m4s") and (re.search(r'\.part\d+\.m4s$', fn)):
            # Video media segment
            stem = fn[:-4]
            rend = next((r for r in video_renditions if r['file'] == stem), None)
            item = {
                "name": fn,
                "sizeBytes": sz,
                "role": "media segments (fmp4, single file)",
                "rendition": stem,
                "streamKind": "video",
                "codec": rend['codec'] if rend else "h264",
                "raw": rend['raw'] if rend else False,
                "resolution": rend['resolution'] if rend else ""
            }
            if rend and rend.get('hdr'):
                item['hdr'] = rend['hdr']
            files_list.append(item)
        elif fn.endswith(".poster.jpg") or fn.endswith(".jpg"):
            files_list.append({
                "name": fn,
                "sizeBytes": sz,
                "role": "poster image"
            })
        elif fn.endswith(".vtt"):
            m = re.search(r'\.sub-([a-z0-9]+)-\d+\.vtt$', fn)
            lang = m.group(1) if m else "und"
            files_list.append({
                "name": fn,
                "sizeBytes": sz,
                "role": "subtitle",
                "format": "webvtt",
                "language": lang
            })
        elif fn.endswith(".info.json"):
            files_list.append({
                "name": fn,
                "role": "manifest (this file)"
            })
            
    iso_now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%fZ')
    
    output = {
        "schemaVersion": 2,
        "hdr": hdr_badge,
        "audio": audio_badge,
        "badges": badges,
        "source": source_info,
        "video": video_info,
        "audioTracks": audio_tracks,
        "subtitleTracks": subtitle_tracks,
        "renditions": {
            "video": video_renditions,
            "audio": audio_renditions,
            "subtitles": sub_renditions
        },
        "files": files_list,
        "generatedAt": iso_now
    }
    
    target_json = os.path.join(outdir, f"{slug}.info.json")
    with open(target_json, 'w', encoding='utf-8') as f:
        json.dump(output, f, indent=2, ensure_ascii=False)
        f.write('\n')
        
    return target_json

if __name__ == '__main__':
    if len(sys.argv) < 3:
        print("Usage: generate-info-json.py <source_path> <outdir> [slug]", file=sys.stderr)
        sys.exit(1)
    src = sys.argv[1]
    out = sys.argv[2]
    s = sys.argv[3] if len(sys.argv) > 3 else None
    result = generate_info_json(src, out, s)
    if result:
        print(f"Generated {result}")
    else:
        sys.exit(1)