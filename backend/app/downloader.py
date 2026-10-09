import asyncio
import os
import re
import shutil
import tempfile
from typing import Any, Dict

import yt_dlp


# ── Global State for Cancellation and Pause ───────────────────────────────────
# Key: client_id, Value: bool (True if cancelled/paused)
cancellation_map: Dict[str, bool] = {}
pause_map: Dict[str, bool] = {}

def cancel_download(client_id: str):
    """Mark a download as cancelled."""
    cancellation_map[client_id] = True

def pause_download(client_id: str):
    """Mark a download as paused."""
    pause_map[client_id] = True


# ── Helpers ──────────────────────────────────────────────────────────────────

def sanitize_filename(name: str) -> str:
    """Remove characters that are illegal in Windows/Linux file names."""
    name = re.sub(r'[\\/*?:"<>|]', '', name)
    name = name.strip().strip('.')
    return name or 'download'


def check_ffmpeg() -> bool:
    """Return True if FFmpeg is available on PATH."""
    return shutil.which('ffmpeg') is not None


def check_disk_space(path: str, required_bytes: int = 500 * 1024 * 1024) -> bool:
    """Return True if the target path has at least required_bytes free."""
    try:
        stat = shutil.disk_usage(path)
        return stat.free >= required_bytes
    except Exception:
        return True


# ── Metadata ──────────────────────────────────────────────────────────────────

def get_video_info(url: str) -> Dict[str, Any]:
    ydl_opts = {
        'quiet': True,
        'no_warnings': True,
        'extract_flat': False,
        'extractor_args': {
            'youtube': [
                'player_client=ios,mweb,web',
            ]
        },
        'remote_components': ['ejs:github'],
    }
    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        info = ydl.extract_info(url, download=False)

        formats = []
        seen_resolutions: set = set()
        for f in info.get('formats', []):
            if f.get('vcodec') == 'none':
                continue
            width = f.get('width')
            height = f.get('height')
            if not width or not height:
                continue
            resolution = f'{width}x{height}'
            if resolution in seen_resolutions:
                continue
            seen_resolutions.add(resolution)
            formats.append({
                'format_id': f.get('format_id'),
                'resolution': resolution,
                'height': height,
                'ext': f.get('ext'),
                'filesize': f.get('filesize') or f.get('filesize_approx'),
                'note': f.get('format_note', ''),
                'vcodec': f.get('vcodec'),
                'acodec': f.get('acodec'),
            })

        formats.sort(key=lambda x: x.get('height', 0), reverse=True)

        return {
            'title': info.get('title'),
            'thumbnail': info.get('thumbnail'),
            'duration': info.get('duration'),
            'uploader': info.get('uploader'),
            'formats': formats,
            'original_url': url,
        }


# ── Downloader ────────────────────────────────────────────────────────────────

class DownloadCancelledException(Exception):
    """Custom exception to stop yt-dlp on cancel."""
    pass

class DownloadPausedException(Exception):
    """Custom exception to stop yt-dlp on pause."""
    pass


async def download_video(
    url: str,
    format_id: str,
    output_path: str,
    progress_hook,
    loop: asyncio.AbstractEventLoop,
    client_id: str
) -> str:
    """
    Downloads a video using yt-dlp.
    Supports cancellation via client_id check in progress hook.
    """
    # Reset flags for this client
    cancellation_map[client_id] = False
    pause_map[client_id] = False

    if not check_ffmpeg():
        raise RuntimeError("FFmpeg not found on PATH.")

    os.makedirs(output_path, exist_ok=True)

    if not check_disk_space(output_path):
        raise RuntimeError("Less than 500 MB free on target drive.")

    is_audio = format_id == 'audio'

    if is_audio:
        fmt = 'bestaudio/best'
        postprocessors = [{
            'key': 'FFmpegExtractAudio',
            'preferredcodec': 'mp3',
            'preferredquality': '192',
        }]
        merge_format = None
    else:
        fmt = f'{format_id}+bestaudio/bestvideo+bestaudio/best'
        postprocessors = []
        merge_format = 'mp4'

    tmp_dir = os.path.join(tempfile.gettempdir(), f'samdl_{client_id}')
    os.makedirs(tmp_dir, exist_ok=True)

    def make_hook(loop_ref, async_cb, cid):
        def hook(d):
            # 🛑 CHECK FOR CANCELLATION OR PAUSE
            if cancellation_map.get(cid, False):
                raise DownloadCancelledException("Download cancelled by user.")
            if pause_map.get(cid, False):
                raise DownloadPausedException("Download paused by user.")

            if d['status'] == 'downloading':
                data = {
                    'status': 'downloading',
                    'downloaded_bytes': d.get('downloaded_bytes'),
                    'total_bytes': d.get('total_bytes') or d.get('total_bytes_estimate'),
                    'speed': d.get('speed'),
                    'eta': d.get('eta'),
                    'percent': (d.get('_percent_str') or '0%').strip(),
                    'filename': os.path.basename(d.get('filename', '')),
                }
                asyncio.run_coroutine_threadsafe(async_cb(data), loop_ref)
            elif d['status'] == 'finished':
                data = {
                    'status': 'finished',
                    'filename': os.path.basename(d.get('filename', '')),
                }
                asyncio.run_coroutine_threadsafe(async_cb(data), loop_ref)
        return hook

    ydl_opts = {
        'format': fmt,
        'outtmpl': os.path.join(tmp_dir, '%(title)s.%(ext)s'),
        'restrictfilenames': True,
        'progress_hooks': [make_hook(loop, progress_hook, client_id)],
        'merge_output_format': merge_format,
        'postprocessors': postprocessors,
        'noplaylist': True,
        'quiet': False,
        'no_warnings': False,
        'extractor_args': {
            'youtube': [
                'player_client=ios,mweb,web',
            ]
        },
        'remote_components': ['ejs:github'],
        'http_headers': {
            'User-Agent': (
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
                'AppleWebKit/537.36 (KHTML, like Gecko) '
                'Chrome/124.0.0.0 Safari/537.36'
            )
        },
    }

    final_file: str = ''

    def run_ydl():
        nonlocal final_file
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            try:
                info = ydl.extract_info(url, download=True)
                prepared = ydl.prepare_filename(info)
                if merge_format:
                    base = os.path.splitext(prepared)[0]
                    candidate = f'{base}.{merge_format}'
                else:
                    candidate = prepared
                
                if not os.path.exists(candidate):
                    files = sorted(
                        [os.path.join(tmp_dir, f) for f in os.listdir(tmp_dir)],
                        key=os.path.getmtime,
                        reverse=True,
                    )
                    candidate = files[0] if files else candidate
                final_file = candidate
            except DownloadCancelledException:
                raise
            except DownloadPausedException:
                raise
            except yt_dlp.utils.DownloadError as e:
                error_msg = str(e)
                if "403" in error_msg or "Forbidden" in error_msg:
                    raise RuntimeError("YouTube blocked the download (HTTP 403). Ensure yt-dlp is updated or browser cookies are accessible.") from e
                raise e
            except Exception as e:
                if cancellation_map.get(client_id, False):
                    raise DownloadCancelledException("Download cancelled by user.")
                if pause_map.get(client_id, False):
                    raise DownloadPausedException("Download paused by user.")
                raise e

    try:
        await asyncio.to_thread(run_ydl)

        if final_file and os.path.exists(final_file):
            raw_name = os.path.basename(final_file)
            safe_name = sanitize_filename(os.path.splitext(raw_name)[0]) + os.path.splitext(raw_name)[1]
            dest = os.path.join(output_path, safe_name)
            shutil.move(final_file, dest)
            return dest
        else:
            raise RuntimeError("Download failed: Final file not found.")
    except DownloadCancelledException:
        # Re-raise so main.py knows it was a manual cancel
        raise
    except DownloadPausedException:
        # Re-raise so main.py knows it was a manual pause
        raise
    finally:
        # If cancelled or finished successfully, clean up temp dir. 
        # If paused, KEEP the temp dir so it can resume later.
        if not pause_map.get(client_id, False):
            shutil.rmtree(tmp_dir, ignore_errors=True)
        # Cleanup maps
        cancellation_map.pop(client_id, None)
        pause_map.pop(client_id, None)
