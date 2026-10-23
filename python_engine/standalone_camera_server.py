"""Standalone Lightweight Camera & Face Detection Server.

Runs locally on Windows, macOS, or Linux with zero GPU/PyTorch requirements.
Opens physical webcam via cv2.VideoCapture(0) and runs InsightFace AntelopeV2
detection with real-time framing quality assessment.
"""
import base64
import logging
import os
import sys
import threading
import time
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
import uuid

import cv2
import numpy as np
from fastapi import FastAPI, HTTPException, status
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import uvicorn

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("camera_server")

# Default staging directory
STAGING_DIR = Path("./staging/captures")
STAGING_DIR.mkdir(parents=True, exist_ok=True)


class CameraFaceMetrics(BaseModel):
    bbox: List[int]
    score: float
    area_ratio: float
    offset_x: float
    offset_y: float
    width: int
    height: int


class CameraFrameResponse(BaseModel):
    success: bool
    image_base64: Optional[str] = None
    width: Optional[int] = None
    height: Optional[int] = None
    faces_count: int = 0
    feedback_code: str
    feedback_text: str
    can_capture: bool
    face_metrics: Optional[CameraFaceMetrics] = None
    error: Optional[str] = None


class CameraCaptureResponse(BaseModel):
    success: bool
    file_path: Optional[str] = ""
    file_name: Optional[str] = ""
    timestamp: Optional[str] = ""
    width: Optional[int] = 0
    height: Optional[int] = 0
    feedback_code: str
    feedback_text: str
    can_capture: bool
    face_metrics: Optional[CameraFaceMetrics] = None
    image_base64: Optional[str] = None
    error: Optional[str] = None


class CameraReleaseResponse(BaseModel):
    released: bool
    message: str


class CameraStatusResponse(BaseModel):
    active: bool
    source: Optional[str] = None
    is_mock_feed: bool = False
    idle_seconds: Optional[float] = None
    inactivity_timeout: float = 5.0


class CameraService:
    """Manages physical webcam capture and InsightFace AntelopeV2 evaluation."""

    def __init__(self, inactivity_timeout: float = 5.0) -> None:
        self.inactivity_timeout = inactivity_timeout
        self._cap: Optional[cv2.VideoCapture] = None
        self._camera_source: Any = None
        self._is_mock_feed: bool = False
        self._last_access_time: float = 0.0
        self._lock = threading.Lock()

        self._face_app = None
        self._face_app_lock = threading.Lock()

        # Watchdog auto-release thread
        self._stop_watchdog = threading.Event()
        self._watchdog_thread = threading.Thread(target=self._watchdog_loop, daemon=True)
        self._watchdog_thread.start()

    def _resolve_antelopev2_root(self) -> Optional[Path]:
        """Find directory containing models/antelopev2."""
        candidates = [
            Path("/root/models_staging/instantid"),
            Path("/root/models/instantid"),
            Path("./models/instantid"),
            Path("./models"),
            Path.home() / "models" / "instantid",
            Path.home() / "models",
            Path(os.environ.get("AI_STUDIO_MODELS_DIR", ".")) / "instantid",
            Path(os.environ.get("AI_STUDIO_MODELS_DIR", ".")),
            Path(__file__).resolve().parent,
        ]
        for p in candidates:
            if (p / "models" / "antelopev2").exists():
                return p
            if (p / "antelopev2").exists():
                return p.parent

        return None

    def _get_face_app(self):
        """Lazy load InsightFace AntelopeV2 SCRFD with graceful fallback."""
        if self._face_app is not None:
            return self._face_app

        with self._face_app_lock:
            if self._face_app is not None:
                return self._face_app

            # 1. Try AntelopeV2 if models exist locally
            root_dir = self._resolve_antelopev2_root()
            if root_dir is not None:
                try:
                    from insightface.app import FaceAnalysis
                    import onnxruntime as ort

                    log.info("Loading InsightFace AntelopeV2 models from %s...", root_dir)
                    available_providers = ort.get_available_providers()
                    if "CUDAExecutionProvider" in available_providers:
                        providers = ["CUDAExecutionProvider", "CPUExecutionProvider"]
                        ctx_id = 0
                        dev = "CUDA"
                    else:
                        providers = ["CPUExecutionProvider"]
                        ctx_id = -1
                        dev = "CPU"

                    app = FaceAnalysis(name="antelopev2", root=str(root_dir), providers=providers)
                    app.prepare(ctx_id=ctx_id, det_size=(640, 640))
                    self._face_app = app
                    log.info("InsightFace AntelopeV2 loaded and ready on %s", dev)
                    return self._face_app
                except Exception as e:
                    log.warning("Could not initialize AntelopeV2 from %s: %s", root_dir, e)

            # 2. Try default InsightFace buffalo_s on CPU if installed
            try:
                from insightface.app import FaceAnalysis
                app = FaceAnalysis(name="buffalo_s", providers=["CPUExecutionProvider"])
                app.prepare(ctx_id=-1, det_size=(640, 640))
                self._face_app = app
                log.info("InsightFace buffalo_s fallback loaded and ready")
                return self._face_app
            except Exception as e:
                log.warning("InsightFace default model unavailable: %s", e)

            # 3. Fallback dummy detector (prevents 500 crash, keeps camera preview live)
            class _SafeFallbackDetector:
                def get(self, frame):
                    return []

            self._face_app = _SafeFallbackDetector()
            return self._face_app

    def _ensure_camera(self) -> cv2.VideoCapture:
        self._last_access_time = time.time()
        if self._cap is not None and self._cap.isOpened():
            return self._cap

        source = 0
        env_source = os.environ.get("AI_STUDIO_CAMERA_SOURCE", "").strip()
        if env_source:
            source = int(env_source) if env_source.isdigit() else env_source

        log.info("Opening webcam capture device: %s", source)
        if sys.platform.startswith("win"):
            # cv2.CAP_DSHOW provides fast initialization on Windows
            cap = cv2.VideoCapture(source, cv2.CAP_DSHOW)
            if not cap.isOpened():
                cap = cv2.VideoCapture(source)
        else:
            cap = cv2.VideoCapture(source)

        if not cap.isOpened():
            raise RuntimeError(f"Could not open physical webcam (device index {source})")

        self._camera_source = source
        self._is_mock_feed = isinstance(source, str) and source.endswith(".mp4")
        self._cap = cap
        log.info("Physical webcam successfully opened!")
        return self._cap

    def _watchdog_loop(self) -> None:
        while not self._stop_watchdog.is_set():
            time.sleep(1.0)
            with self._lock:
                if self._cap is not None and self._cap.isOpened():
                    idle = time.time() - self._last_access_time
                    if idle > self.inactivity_timeout:
                        log.info("Webcam idle for %.1fs. Auto-releasing hardware handle.", idle)
                        self._cap.release()
                        self._cap = None

    def release(self) -> Dict[str, Any]:
        with self._lock:
            if self._cap is not None:
                log.info("Releasing webcam hardware handle.")
                self._cap.release()
                self._cap = None
                return {"released": True, "message": "Camera handle released."}
            return {"released": False, "message": "Camera was not active."}

    def get_status(self) -> Dict[str, Any]:
        with self._lock:
            is_active = self._cap is not None and self._cap.isOpened()
            idle = round(time.time() - self._last_access_time, 2) if is_active else None
            return {
                "active": is_active,
                "source": str(self._camera_source) if self._camera_source is not None else None,
                "is_mock_feed": self._is_mock_feed,
                "idle_seconds": idle,
                "inactivity_timeout": self.inactivity_timeout,
            }

    def evaluate_framing(self, frame: np.ndarray, faces: List[Any]) -> Tuple[str, str, bool, Optional[Dict[str, Any]]]:
        frame_h, frame_w = frame.shape[:2]
        frame_area = frame_h * frame_w

        if not faces:
            return "no_face", "No face detected", False, None

        primary_face = max(faces, key=lambda f: (f.bbox[2] - f.bbox[0]) * (f.bbox[3] - f.bbox[1]))
        bbox = [int(v) for v in primary_face.bbox]
        x1, y1, x2, y2 = bbox
        face_w = max(0, x2 - x1)
        face_h = max(0, y2 - y1)
        area_ratio = (face_w * face_h) / float(frame_area) if frame_area > 0 else 0.0

        center_x = (x1 + x2) / 2.0
        center_y = (y1 + y2) / 2.0
        offset_x = (center_x - (frame_w / 2.0)) / (frame_w / 2.0)
        offset_y = (center_y - (frame_h / 2.0)) / (frame_h / 2.0)
        score = float(primary_face.det_score) if hasattr(primary_face, "det_score") else 1.0

        metrics = {
            "bbox": bbox,
            "score": round(score, 3),
            "area_ratio": round(area_ratio, 3),
            "offset_x": round(offset_x, 3),
            "offset_y": round(offset_y, 3),
            "width": face_w,
            "height": face_h,
        }

        if score < 0.60:
            return "low_confidence", "Face unclear. Improve lighting or face camera directly.", False, metrics
        if abs(offset_x) > 0.22:
            direction = "right" if offset_x < 0 else "left"
            return "off_center", f"Center your face in the frame (move {direction})", False, metrics
        if area_ratio < 0.04:
            return "too_far", "Move closer to the camera", False, metrics
        if area_ratio > 0.35:
            return "too_close", "Move back slightly", False, metrics

        return "good", "Face detected, good framing", True, metrics

    def get_frame_and_eval(self) -> Dict[str, Any]:
        with self._lock:
            cap = self._ensure_camera()
            ret, frame = cap.read()
            if not ret or frame is None:
                return {
                    "success": False,
                    "error": "Failed to read frame from physical webcam",
                    "feedback_code": "camera_error",
                    "feedback_text": "Failed to read camera frame",
                    "can_capture": False,
                }
            self._last_access_time = time.time()

        face_app = self._get_face_app()
        faces = face_app.get(frame)
        code, text, can_capture, metrics = self.evaluate_framing(frame, faces)

        h, w = frame.shape[:2]
        _, buffer = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 80])
        jpg_b64 = base64.b64encode(buffer).decode("utf-8")

        return {
            "success": True,
            "image_base64": jpg_b64,
            "width": w,
            "height": h,
            "faces_count": len(faces),
            "feedback_code": code,
            "feedback_text": text,
            "can_capture": can_capture,
            "face_metrics": metrics,
        }

    def capture_confirmed_frame(self) -> Dict[str, Any]:
        with self._lock:
            cap = self._ensure_camera()
            ret, frame = cap.read()
            if not ret or frame is None:
                raise RuntimeError("Failed to read frame for capture")
            self._last_access_time = time.time()

        face_app = self._get_face_app()
        faces = face_app.get(frame)
        code, text, can_capture, metrics = self.evaluate_framing(frame, faces)

        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        uid = uuid.uuid4().hex[:6]
        fname = f"capture_{ts}_{uid}.jpg"
        fpath = STAGING_DIR / fname

        cv2.imwrite(str(fpath), frame, [cv2.IMWRITE_JPEG_QUALITY, 95])
        log.info("Saved confirmed snapshot to %s", fpath)

        _, buffer = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 85])
        jpg_b64 = base64.b64encode(buffer).decode("utf-8")

        return {
            "success": True,
            "file_path": str(fpath.resolve()),
            "file_name": fname,
            "timestamp": ts,
            "width": frame.shape[1],
            "height": frame.shape[0],
            "feedback_code": code,
            "feedback_text": text,
            "can_capture": can_capture,
            "face_metrics": metrics,
            "image_base64": jpg_b64,
        }


# FastAPI Web App
camera_service = CameraService()
app = FastAPI(title="AI Image Studio Local Camera Engine")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/health")
def health():
    return {"status": "ok", "service": "local_camera_engine"}


@app.get("/api/camera/status", response_model=CameraStatusResponse)
def get_camera_status():
    return CameraStatusResponse(**camera_service.get_status())


@app.get("/api/camera/frame", response_model=CameraFrameResponse)
def get_camera_frame():
    try:
        data = camera_service.get_frame_and_eval()
        return CameraFrameResponse(**data)
    except Exception as e:
        log.exception("Camera frame evaluation error: %s", e)
        return CameraFrameResponse(
            success=False,
            feedback_code="camera_error",
            feedback_text=f"Camera error: {e}",
            can_capture=False,
            error=str(e),
        )


@app.post("/api/camera/capture", response_model=CameraCaptureResponse)
def capture_frame():
    try:
        data = camera_service.capture_confirmed_frame()
        return CameraCaptureResponse(**data)
    except Exception as e:
        log.exception("Camera capture error: %s", e)
        return CameraCaptureResponse(
            success=False,
            file_path="",
            file_name="",
            timestamp="",
            width=0,
            height=0,
            feedback_code="camera_error",
            feedback_text=f"Failed to capture frame: {e}",
            can_capture=False,
            error=str(e),
        )


@app.post("/api/camera/release", response_model=CameraReleaseResponse)
def release_camera():
    return CameraReleaseResponse(**camera_service.release())


def run_live_console():
    """Terminal mode: continuously captures webcam and prints live framing results."""
    print("=" * 70)
    print("STARTING LIVE LOCAL WEBCAM CONSOLE TEST")
    print("=" * 70)
    print("Initializing camera service & physical webcam cv2.VideoCapture(0)...")

    frame_count = 0
    try:
        while True:
            t0 = time.time()
            data = camera_service.get_frame_and_eval()
            elapsed_ms = int((time.time() - t0) * 1000)
            frame_count += 1

            if not data["success"]:
                print(f"[{frame_count}] Camera Error: {data.get('feedback_text')}")
            else:
                code = data["feedback_code"]
                text = data["feedback_text"]
                can_cap = "READY TO CAPTURE" if data["can_capture"] else "ADJUSTING"
                metrics = data.get("face_metrics")
                detail = ""
                if metrics:
                    detail = f"(Area: {metrics['area_ratio']*100:.1f}%, OffsetX: {metrics['offset_x']:+.2f}, Conf: {metrics['score']:.2f})"

                print(f"[{frame_count:03d} | {elapsed_ms}ms] {code.upper():12} -> {text:45} | {can_cap:16} {detail}")

            time.sleep(1.0)
    except KeyboardInterrupt:
        print("\nStopping live test and releasing webcam...")
        camera_service.release()
        print("Done.")


if __name__ == "__main__":
    if "--test" in sys.argv:
        run_live_console()
    else:
        print("Starting Local Camera Engine on http://127.0.0.1:8000 ...")
        uvicorn.run(app, host="127.0.0.1", port=8000)
