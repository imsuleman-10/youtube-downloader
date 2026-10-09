import asyncio
import os
import urllib.parse
from typing import Dict

from fastapi import BackgroundTasks, FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from pydantic import BaseModel

from .downloader import (
    check_ffmpeg, 
    download_video, 
    get_video_info, 
    cancel_download, 
    pause_download,
    DownloadCancelledException,
    DownloadPausedException
)

app = FastAPI(title="SamTube API", version="1.2.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Base directory for downloads
DOWNLOADS_DIR = os.path.join(os.getcwd(), "downloads")
os.makedirs(DOWNLOADS_DIR, exist_ok=True)


# ── WebSocket Connection Manager ─────────────────────────────────────────────
class ConnectionManager:
    def __init__(self):
        self.active: Dict[str, WebSocket] = {}

    async def connect(self, client_id: str, ws: WebSocket):
        await ws.accept()
        self.active[client_id] = ws

    def disconnect(self, client_id: str):
        self.active.pop(client_id, None)

    async def send(self, client_id: str, data: dict):
        ws = self.active.get(client_id)
        if ws:
            try:
                await ws.send_json(data)
            except Exception:
                self.disconnect(client_id)


manager = ConnectionManager()

# Semaphore: max 2 concurrent downloads
download_semaphore = asyncio.Semaphore(2)

active_downloads: int = 0
queued_downloads: int = 0


# ── Schemas ──────────────────────────────────────────────────────────────────
class AnalyzeRequest(BaseModel):
    url: str


class DownloadRequest(BaseModel):
    url: str
    format_id: str
    client_id: str


# ── Routes ───────────────────────────────────────────────────────────────────
@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/check-ffmpeg")
async def check_ffmpeg_route():
    ok = check_ffmpeg()
    return {
        "ffmpeg_available": ok,
        "message": "FFmpeg is ready." if ok else "FFmpeg NOT found."
    }


@app.get("/queue-status")
async def queue_status():
    return {
        "active": active_downloads,
        "queued": queued_downloads,
        "max_concurrent": 2,
    }


@app.post("/analyze")
async def analyze(request: AnalyzeRequest):
    try:
        info = await asyncio.to_thread(get_video_info, request.url)
        return info
    except Exception as e:
        error_msg = str(e)
        if "403" in error_msg or "Forbidden" in error_msg:
            return {"error": "YouTube blocked this video (HTTP 403). Ensure yt-dlp is updated or browser cookies are accessible."}
        return {"error": error_msg}


@app.get("/files/{filename}")
async def get_file(filename: str):
    file_path = os.path.join(DOWNLOADS_DIR, filename)
    if os.path.exists(file_path):
        return FileResponse(
            path=file_path,
            filename=filename,
            media_type='application/octet-stream'
        )
    return {"error": "File not found."}


@app.post("/cancel/{client_id}")
async def cancel_endpoint(client_id: str):
    """Trigger cancellation for a specific download."""
    cancel_download(client_id)
    return {"status": "cancelled", "message": "Cancellation request sent."}


@app.post("/pause/{client_id}")
async def pause_endpoint(client_id: str):
    """Trigger pause for a specific download."""
    pause_download(client_id)
    return {"status": "paused", "message": "Pause request sent."}


@app.post("/resume")
async def resume_endpoint(request: DownloadRequest, background_tasks: BackgroundTasks):
    """Resume a download by starting it again (yt-dlp handles resume natively)."""
    background_tasks.add_task(
        _run_download, request.url, request.format_id, request.client_id
    )
    return {"status": "resumed", "message": "Download resumed."}


@app.websocket("/ws/{client_id}")
async def websocket_endpoint(websocket: WebSocket, client_id: str):
    await manager.connect(client_id, websocket)
    try:
        while True:
            await websocket.receive_text()
    except WebSocketDisconnect:
        manager.disconnect(client_id)


async def _run_download(url: str, format_id: str, client_id: str):
    global active_downloads, queued_downloads
    queued_downloads += 1
    await manager.send(client_id, {"status": "queued", "message": "Waiting in queue…"})

    async with download_semaphore:
        queued_downloads = max(0, queued_downloads - 1)
        active_downloads += 1
        loop = asyncio.get_running_loop()

        async def progress_hook(data: dict):
            await manager.send(client_id, data)

        try:
            final_dest = await download_video(url, format_id, DOWNLOADS_DIR, progress_hook, loop, client_id)
            
            filename = os.path.basename(final_dest)
            download_url = f"http://localhost:8000/files/{urllib.parse.quote(filename)}"

            await manager.send(
                client_id,
                {
                    "status": "complete", 
                    "message": "Download complete! Ready for browser save. 🎉",
                    "download_url": download_url,
                    "filename": filename
                },
            )
        except DownloadCancelledException:
            await manager.send(
                client_id,
                {"status": "error", "message": "Download cancelled by user."},
            )
        except DownloadPausedException:
            await manager.send(
                client_id,
                {"status": "paused", "message": "Download paused."},
            )
        except Exception as e:
            await manager.send(
                client_id,
                {"status": "error", "message": str(e)},
            )
        finally:
            active_downloads = max(0, active_downloads - 1)


@app.post("/download")
async def start_download(request: DownloadRequest, background_tasks: BackgroundTasks):
    background_tasks.add_task(
        _run_download, request.url, request.format_id, request.client_id
    )
    return {"status": "queued", "message": "Download added to queue."}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("app.main:app", host="0.0.0.0", port=8000, reload=True)
