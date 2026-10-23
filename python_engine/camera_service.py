"""Webcam capture and real-time face framing evaluation service.

Uses OpenCV for camera access and InsightFace (AntelopeV2 SCRFD detector)
for face detection and framing quality assessment.
Includes automatic inactivity release to avoid locking the camera device.
"""
from __future__ import annotations

import base64
import logging
import os
import threading
import time
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
import uuid

import cv2
import numpy as np

log = logging.getLogger(__name__)

# Default paths
ENGINE_ROOT = Path(__file__).resolve().parent.parent
STAGING_CAPTURES_DIR = ENGINE_ROOT.parent / "staging" / "captures"


class CameraService:
    """Manages webcam capture, InsightFace detection, and framing evaluation."""

    _instance: Optional[CameraService] = None
    _instance_lock = threading.Lock()

    @classmethod
    def get_instance(cls) -> CameraService:
        with cls._instance_lock:
            if cls._instance is None:
                cls._instance = CameraService()
            return cls._instance

    def __init__(self, inactivity_timeout: float = 5.0) -> None:
        self.inactivity_timeout = inactivity_timeout
        self._cap: Optional[cv2.VideoCapture] = None
        self._camera_source: Any = None
        self._is_mock_feed: bool = False
        self._last_access_time: float = 0.0
        self._lock = threading.Lock()

        # InsightFace app (lazy loaded)
        self._face_app = None
        self._face_app_lock = threading.Lock()

        # Watchdog thread
        self._stop_watchdog = threading.Event()
        self._watchdog_thread = threading.Thread(target=self._watchdog_loop, daemon=True)
        self._watchdog_thread.start()

    def _resolve_antelopev2_root(self) -> Optional[Path]:
        """Find the root directory that contains models/antelopev2."""
        candidates = [
            Path("/root/models_staging/instantid"),
            Path("/root/models/instantid"),
            ENGINE_ROOT.parent / "models_staging" / "instantid",
            ENGINE_ROOT / "models" / "instantid",
        ]
        try:
            from generation.model_paths import models_root
            candidates.append(models_root() / "instantid")
        except Exception:
            pass

        for p in candidates:
            if (p / "models" / "antelopev2").exists():
                return p
            if (p / "antelopev2").exists():
                return p.parent

        return None

    def _get_face_app(self):
        """Lazy loader for InsightFace FaceAnalysis with graceful fallbacks."""
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

                    log.info("Initializing InsightFace AntelopeV2 from %s", root_dir)
                    available_providers = ort.get_available_providers()
                    if "CUDAExecutionProvider" in available_providers:
                        providers = ["CUDAExecutionProvider", "CPUExecutionProvider"]
                        ctx_id = 0
                        device_str = "cuda"
                    else:
                        providers = ["CPUExecutionProvider"]
                        ctx_id = -1
                        device_str = "cpu"

                    app = FaceAnalysis(name="antelopev2", root=str(root_dir), providers=providers)
                    app.prepare(ctx_id=ctx_id, det_size=(640, 640))
                    self._face_app = app
                    log.info("InsightFace FaceAnalysis ready (ctx_id=%d, device=%s)", ctx_id, device_str)
                    return self._face_app
                except Exception as e:
                    log.warning("Could not initialize AntelopeV2 from %s: %s", root_dir, e)

            # 2. Try default InsightFace buffalo_s / buffalo_l on CPU if installed
            try:
                from insightface.app import FaceAnalysis
                app = FaceAnalysis(name="buffalo_s", providers=["CPUExecutionProvider"])
                app.prepare(ctx_id=-1, det_size=(640, 640))
                self._face_app = app
                log.info("InsightFace FaceAnalysis ready (buffalo_s fallback)")
                return self._face_app
            except Exception as e:
                log.warning("InsightFace default model unavailable: %s", e)

            # 3. Fallback dummy detector (returns empty list, prevents 500 crash)
            class _SafeFallbackDetector:
                def get(self, frame):
                    return []

            self._face_app = _SafeFallbackDetector()
            return self._face_app

    def _determine_source(self) -> Any:
        """Determine camera source: env var, default device 0, or fallback test feed."""
        env_source = os.environ.get("AI_STUDIO_CAMERA_SOURCE", "").strip()
        if env_source:
            if env_source.isdigit():
                return int(env_source)
            return env_source

        import sys
        if sys.platform.startswith("linux"):
            available_nodes = [i for i in range(10) if Path(f"/dev/video{i}").exists()]
            if available_nodes:
                return available_nodes[0]
            # No /dev/video* detected on Linux (e.g. headless container)
            test_video = ENGINE_ROOT / "examples" / "test_camera_feed.mp4"
            if test_video.exists():
                log.info("No /dev/video* found. Using test video feed: %s", test_video)
                return str(test_video)

        return 0

    def _ensure_camera(self) -> cv2.VideoCapture:
        """Ensure VideoCapture is open. Must be called while holding self._lock."""
        self._last_access_time = time.time()

        if self._cap is not None and self._cap.isOpened():
            return self._cap

        source = self._determine_source()
        log.info("Opening camera capture from source: %s", source)

        import sys
        cap = None
        # On Linux, try V4L2 first if source is an integer index
        if isinstance(source, int) and sys.platform.startswith("linux"):
            try:
                cap = cv2.VideoCapture(source, cv2.CAP_V4L2)
                if not cap.isOpened():
                    cap.release()
                    cap = None
            except Exception:
                cap = None

        if cap is None or not cap.isOpened():
            cap = cv2.VideoCapture(source)

        # If primary index failed on Linux, try other available video nodes
        if not cap.isOpened() and isinstance(source, int) and sys.platform.startswith("linux"):
            for alt_idx in [1, 2, 3]:
                if Path(f"/dev/video{alt_idx}").exists():
                    log.info("Trying alternate video device: %d", alt_idx)
                    try:
                        cap = cv2.VideoCapture(alt_idx, cv2.CAP_V4L2)
                    except Exception:
                        cap = cv2.VideoCapture(alt_idx)
                    if cap.isOpened():
                        source = alt_idx
                        break

        if not cap.isOpened():
            test_video = ENGINE_ROOT / "examples" / "test_camera_feed.mp4"
            if test_video.exists() and source != str(test_video):
                log.warning("Camera index %s could not open; falling back to test video: %s", source, test_video)
                source = str(test_video)
                cap = cv2.VideoCapture(source)

        if not cap.isOpened():
            raise RuntimeError(
                f"Could not open camera device (index {source}). "
                "Verify your physical webcam is connected, user has video permissions "
                "(sudo usermod -a -G video $USER), and camera is not open in another app."
            )

        self._camera_source = source
        self._is_mock_feed = isinstance(source, str) and source.endswith(".mp4")
        self._cap = cap
        return self._cap

    def _watchdog_loop(self) -> None:
        """Background thread that releases camera handle after inactivity."""
        while not self._stop_watchdog.is_set():
            time.sleep(1.0)
            with self._lock:
                if self._cap is not None and self._cap.isOpened():
                    idle_time = time.time() - self._last_access_time
                    if idle_time > self.inactivity_timeout:
                        log.info(
                            "Camera inactive for %.1fs (> %.1fs threshold). Auto-releasing handle.",
                            idle_time,
                            self.inactivity_timeout,
                        )
                        self._cap.release()
                        self._cap = None

    def release(self) -> Dict[str, Any]:
        """Explicitly release the camera handle."""
        with self._lock:
            if self._cap is not None:
                log.info("Explicitly releasing camera capture handle.")
                self._cap.release()
                self._cap = None
                return {"released": True, "message": "Camera handle released."}
            return {"released": False, "message": "Camera was not active."}

    def get_status(self) -> Dict[str, Any]:
        """Return the current camera state."""
        with self._lock:
            is_active = self._cap is not None and self._cap.isOpened()
            idle_seconds = round(time.time() - self._last_access_time, 2) if is_active else None
            return {
                "active": is_active,
                "source": str(self._camera_source) if self._camera_source is not None else None,
                "is_mock_feed": self._is_mock_feed,
                "idle_seconds": idle_seconds,
                "inactivity_timeout": self.inactivity_timeout,
            }

    def evaluate_framing(
        self,
        frame: np.ndarray,
        faces: List[Any],
    ) -> Tuple[str, str, bool, Optional[Dict[str, Any]]]:
        """Evaluate face framing quality against framing rules.

        Returns: (feedback_code, feedback_text, can_capture, face_metrics)
        """
        frame_h, frame_w = frame.shape[:2]
        frame_area = frame_h * frame_w

        if not faces:
            return "no_face", "No face detected", False, None

        # Pick primary face by maximum bounding box area
        primary_face = max(
            faces,
            key=lambda f: (f.bbox[2] - f.bbox[0]) * (f.bbox[3] - f.bbox[1]),
        )

        bbox = [int(val) for val in primary_face.bbox]
        x1, y1, x2, y2 = bbox
        face_w = max(0, x2 - x1)
        face_h = max(0, y2 - y1)
        face_area = face_w * face_h
        area_ratio = face_area / float(frame_area) if frame_area > 0 else 0.0

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

        # Quality evaluation thresholds
        if score < 0.60:
            return (
                "low_confidence",
                "Face unclear. Improve lighting or face the camera directly.",
                False,
                metrics,
            )

        if abs(offset_x) > 0.22:
            direction = "right" if offset_x < 0 else "left"
            return "off_center", f"Center your face in the frame (move {direction})", False, metrics

        if area_ratio < 0.04:
            return "too_far", "Move closer to the camera", False, metrics

        if area_ratio > 0.35:
            return "too_close", "Move back slightly", False, metrics

        return "good", "Face detected, good framing", True, metrics

    def get_frame_and_eval(self, seek_frame: Optional[int] = None) -> Dict[str, Any]:
        """Capture a frame, run face detection & framing evaluation, return base64 preview."""
        with self._lock:
            cap = self._ensure_camera()
            if seek_frame is not None and self._is_mock_feed:
                cap.set(cv2.CAP_PROP_POS_FRAMES, seek_frame)
            ret, frame = cap.read()

            # If video file loop finished, seek to start
            if not ret and self._is_mock_feed:
                cap.set(cv2.CAP_PROP_POS_FRAMES, 0)
                ret, frame = cap.read()

            if not ret or frame is None:
                return {
                    "success": False,
                    "error": "Failed to read frame from camera",
                    "feedback_code": "camera_error",
                    "feedback_text": "Failed to read camera frame",
                    "can_capture": False,
                }

            self._last_access_time = time.time()

        # Run face analysis outside the camera I/O lock
        face_app = self._get_face_app()
        faces = face_app.get(frame)

        feedback_code, feedback_text, can_capture, metrics = self.evaluate_framing(frame, faces)

        # Encode frame as JPEG base64 for preview display
        h, w = frame.shape[:2]
        _, buffer = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 80])
        jpg_b64 = base64.b64encode(buffer).decode("utf-8")

        return {
            "success": True,
            "image_base64": jpg_b64,
            "width": w,
            "height": h,
            "faces_count": len(faces),
            "feedback_code": feedback_code,
            "feedback_text": feedback_text,
            "can_capture": can_capture,
            "face_metrics": metrics,
        }

    def capture_confirmed_frame(
        self,
        staging_dir: Optional[Path] = None,
        seek_frame: Optional[int] = None,
    ) -> Dict[str, Any]:
        """Capture confirmed high quality snapshot and save to local staging."""
        target_dir = staging_dir or STAGING_CAPTURES_DIR
        target_dir.mkdir(parents=True, exist_ok=True)

        with self._lock:
            cap = self._ensure_camera()
            if seek_frame is not None and self._is_mock_feed:
                cap.set(cv2.CAP_PROP_POS_FRAMES, seek_frame)
            ret, frame = cap.read()

            if not ret and self._is_mock_feed:
                cap.set(cv2.CAP_PROP_POS_FRAMES, 0)
                ret, frame = cap.read()

            if not ret or frame is None:
                raise RuntimeError("Failed to read frame from camera for capture")

            self._last_access_time = time.time()

        face_app = self._get_face_app()
        faces = face_app.get(frame)
        feedback_code, feedback_text, can_capture, metrics = self.evaluate_framing(frame, faces)

        # Save high quality JPEG (quality 95)
        timestamp_str = datetime.now().strftime("%Y%m%d_%H%M%S")
        unique_id = uuid.uuid4().hex[:6]
        file_name = f"capture_{timestamp_str}_{unique_id}.jpg"
        file_path = target_dir / file_name

        success = cv2.imwrite(str(file_path), frame, [cv2.IMWRITE_JPEG_QUALITY, 95])
        if not success:
            raise RuntimeError(f"Failed to write image file to {file_path}")

        log.info("Saved confirmed webcam capture to %s (quality: %s)", file_path, feedback_code)

        # Return snapshot info and preview
        _, buffer = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 85])
        jpg_b64 = base64.b64encode(buffer).decode("utf-8")

        return {
            "success": True,
            "file_path": str(file_path),
            "file_name": file_name,
            "timestamp": timestamp_str,
            "width": frame.shape[1],
            "height": frame.shape[0],
            "feedback_code": feedback_code,
            "feedback_text": feedback_text,
            "can_capture": can_capture,
            "face_metrics": metrics,
            "image_base64": jpg_b64,
        }


# Global accessor
def get_camera_service() -> CameraService:
    return CameraService.get_instance()
