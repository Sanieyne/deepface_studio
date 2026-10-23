"""
Cosmic-Gen DeepFace Studio Backend Server
Real-Time Webcam Face Swapping & Virtual Camera Streaming API.
"""
import base64
import io
import logging
import os
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional, Any

import cv2
import numpy as np
from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
import uvicorn

# Set up logging
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("DeepFaceServer")

# Initialize FastAPI
app = FastAPI(title="Cosmic-Gen DeepFace Studio Server", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Import LiveFaceSwap
sys.path.insert(0, str(Path(__file__).parent))
try:
    from live_face_swap import LiveFaceSwapEngine
    engine = LiveFaceSwapEngine()
    logger.info("LiveFaceSwapEngine initialized successfully.")
except Exception as e:
    logger.warning(f"LiveFaceSwapEngine failed to import or initialize: {e}")
    engine = None

class SwapTargetRequest(BaseModel):
    target_name: Optional[str] = "Custom"
    target_image_base64: Optional[str] = None
    preset_id: Optional[str] = None
    enhance_face: Optional[bool] = False
    camera_index: Optional[int] = 0

class SwapFrameRequest(BaseModel):
    frame_base64: str
    target_image_base64: Optional[str] = None
    preset_id: Optional[str] = None
    enhance_face: Optional[bool] = False

@app.get("/health")
def health():
    return {
        "status": "ok",
        "service": "deepface-studio-engine",
        "engine_ready": engine is not None,
    }

@app.get("/api/face/status")
def get_status():
    if not engine:
        return {"active": False, "sourceName": None, "fps": 0.0, "error": "Engine not initialized"}
    return {
        "active": engine.is_running,
        "sourceName": engine.current_target_name,
        "fps": engine.current_fps,
        "enhance": engine.enhance_face,
        "streamUrl": "http://127.0.0.1:8000/api/face/stream",
    }

@app.get("/api/face/presets")
def get_presets():
    if not engine:
        return []
    presets = []
    presets_dir = Path(__file__).parent.parent / "models" / "deep_live_cam" / "presets"
    if not presets_dir.exists():
        presets_dir = Path(__file__).parent / "presets"

    if presets_dir.exists():
        for f in sorted(presets_dir.glob("*.jpg")) + sorted(presets_dir.glob("*.png")):
            try:
                with open(f, "rb") as img_f:
                    b64 = base64.b64encode(img_f.read()).decode("utf-8")
                presets.append({
                    "id": f.stem,
                    "name": f.stem.replace("_", " ").title(),
                    "thumbnailBase64": b64,
                })
            except Exception as e:
                logger.warning(f"Failed to load preset {f.name}: {e}")
    return presets

@app.post("/api/face/start")
def start_face_swap(req: SwapTargetRequest):
    if not engine:
        raise HTTPException(status_code=503, detail="Face swap engine is not initialized.")

    target_bytes = None
    if req.target_image_base64:
        target_bytes = base64.b64decode(req.target_image_base64.split(",")[-1])

    success = engine.start_stream(
        target_image_bytes=target_bytes,
        preset_id=req.preset_id,
        target_name=req.target_name or "Custom",
        enhance_face=req.enhance_face or False,
        camera_index=req.camera_index or 0,
    )

    if not success:
        raise HTTPException(status_code=400, detail="Failed to start face swap stream.")

    return {
        "success": True,
        "message": f"Face swap active: {req.target_name}",
        "streamUrl": "http://127.0.0.1:8000/api/face/stream",
    }

@app.post("/api/face/stop")
def stop_face_swap():
    if engine and engine.is_running:
        engine.stop_stream()
    return {"success": True, "message": "Face swap stopped."}

@app.post("/api/face/swap_frame")
def swap_frame(req: SwapFrameRequest):
    if not engine:
        raise HTTPException(status_code=503, detail="Engine not ready")

    try:
        frame_data = base64.b64decode(req.frame_base64.split(",")[-1])
        nparr = np.frombuffer(frame_data, np.uint8)
        frame = cv2.imdecode(nparr, cv2.IMREAD_COLOR)

        target_bytes = None
        if req.target_image_base64:
            target_bytes = base64.b64decode(req.target_image_base64.split(",")[-1])

        swapped = engine.process_single_frame(
            frame,
            target_image_bytes=target_bytes,
            preset_id=req.preset_id,
            enhance=req.enhance_face or False,
        )

        _, buf = cv2.imencode(".jpg", swapped, [int(cv2.IMWRITE_JPEG_QUALITY), 85])
        out_b64 = base64.b64encode(buf.tobytes()).decode("utf-8")
        return {"success": True, "swapped_frame_base64": out_b64}
    except Exception as e:
        logger.error(f"Error swapping frame: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/api/face/frame")
def get_latest_frame():
    if not engine or not engine.is_running:
        return {"hasFrame": False, "frameBase64": None, "fps": 0.0}

    frame = engine.get_latest_frame()
    if frame is None:
        return {"hasFrame": False, "frameBase64": None, "fps": 0.0}

    _, buf = cv2.imencode(".jpg", frame, [int(cv2.IMWRITE_JPEG_QUALITY), 80])
    b64 = base64.b64encode(buf.tobytes()).decode("utf-8")
    return {
        "hasFrame": True,
        "frameBase64": b64,
        "fps": engine.current_fps,
    }

def _mjpeg_generator():
    while True:
        if engine and engine.is_running:
            frame = engine.get_latest_frame()
            if frame is not None:
                _, buf = cv2.imencode(".jpg", frame, [int(cv2.IMWRITE_JPEG_QUALITY), 80])
                yield (b"--frame\r\n"
                       b"Content-Type: image/jpeg\r\n\r\n" + buf.tobytes() + b"\r\n")
        time.sleep(0.033)

@app.get("/api/face/stream")
def mjpeg_stream():
    return StreamingResponse(
        _mjpeg_generator(),
        media_type="multipart/x-mixed-replace; boundary=frame"
    )

if __name__ == "__main__":
    uvicorn.run("server:app", host="127.0.0.1", port=8000, reload=False)
