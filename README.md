# Cosmic-Gen DeepFace Studio 🎭

Standalone Real-Time DeepFace & Live Webcam Face Swapping Application.

## Features
- **Real-Time Webcam Face Swapping**: High-speed neural face replacement using InsightFace and INSwapper.
- **GFPGAN 4K Enhancement**: Embedded face super-resolution for crystal-clear HD output.
- **Virtual Camera & OBS Output**: Stream live swapped webcam feed directly to Zoom, Discord, Google Meet, and OBS Studio via MJPEG / Virtual Camera (`http://127.0.0.1:8000/api/face/stream`).
- **Target Face Picker**: Preset library + one-click upload of any custom face photo.
- **Pro Membership Integration**: Includes Pro $4.99/month licensing and Gumroad instant activation.

## Quick Start

### 1. Start Python Engine
```bash
./start_engine.sh
```
(On Windows: double-click `start_engine.bat`)

### 2. Run Desktop App (Flutter)
```bash
cd flutter_app
flutter run -d windows # or linux / macos
```

## Virtual Camera (OBS / Zoom / Meet Setup)
1. In OBS Studio, add a **Media Source** or **Browser Source**.
2. Set URL to: `http://127.0.0.1:8000/api/face/stream`.
3. In OBS, click **Start Virtual Camera**.
4. In Zoom / Discord / Google Meet, select **OBS Virtual Camera** as your video device!
