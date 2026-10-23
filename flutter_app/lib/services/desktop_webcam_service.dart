import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';

/// Desktop webcam device information.
class DesktopWebcamDevice {
  final int index;
  final String path;
  final String name;

  const DesktopWebcamDevice({
    required this.index,
    required this.path,
    required this.name,
  });

  @override
  String toString() => name;
}

/// Zero-dependency Desktop Webcam Capture Service.
///
/// Captures physical webcam video frames directly from Linux (/dev/v4l2) and
/// Windows (DirectShow) without requiring the user to install any Python
/// packages or run external terminal scripts.
class DesktopWebcamService {
  static final DesktopWebcamService instance = DesktopWebcamService._();
  DesktopWebcamService._();

  Process? _captureProcess;
  StreamController<String>? _frameController;
  bool _isStreaming = false;

  bool get isStreaming => _isStreaming;

  /// Detects available physical cameras connected to the system.
  Future<List<DesktopWebcamDevice>> getAvailableCameras() async {
    final devices = <DesktopWebcamDevice>[];

    if (Platform.isLinux) {
      final devDir = Directory('/dev');
      if (await devDir.exists()) {
        try {
          final entries = await devDir
              .list()
              .where((entity) => entity.path.contains('/dev/video'))
              .toList();

          entries.sort((a, b) => a.path.compareTo(b.path));

          for (final entry in entries) {
            final path = entry.path;
            // Only include even-numbered video devices (standard V4L2 capture nodes)
            final match = RegExp(r'/dev/video(\d+)').firstMatch(path);
            if (match != null) {
              final num = int.tryParse(match.group(1)!) ?? 0;
              // On Linux, capture nodes are usually /dev/video0, /dev/video2, etc.
              devices.add(DesktopWebcamDevice(
                index: num,
                path: path,
                name: 'Webcam #$num ($path)',
              ));
            }
          }
        } catch (e) {
          debugPrint('[DesktopWebcamService] Error listing Linux video devices: $e');
        }
      }
    } else if (Platform.isWindows) {
      // Default primary Windows camera
      devices.add(const DesktopWebcamDevice(
        index: 0,
        path: '0',
        name: 'Default Windows Camera',
      ));
    }

    if (devices.isEmpty) {
      devices.add(const DesktopWebcamDevice(
        index: 0,
        path: '/dev/video0',
        name: 'Default Webcam (/dev/video0)',
      ));
    }

    return devices;
  }

  /// Starts streaming JPEG frames from the specified physical webcam.
  /// Yields base64-encoded Data URIs (`data:image/jpeg;base64,...`).
  Stream<String> startStreaming({
    int cameraIndex = 0,
    int width = 640,
    int height = 480,
    int fps = 25,
  }) {
    stopStreaming();

    _frameController = StreamController<String>.broadcast();
    _isStreaming = true;

    _launchCapture(
      cameraIndex: cameraIndex,
      width: width,
      height: height,
      fps: fps,
    );

    return _frameController!.stream;
  }

  Future<void> _launchCapture({
    required int cameraIndex,
    required int width,
    required int height,
    required int fps,
  }) async {
    try {
      // 1. Preferred capture engine: system ffmpeg (standard on Linux & Windows)
      final hasFfmpeg = await _checkExecutable('ffmpeg');
      if (hasFfmpeg) {
        final started = await _startFfmpegCapture(
          cameraIndex: cameraIndex,
          width: width,
          height: height,
          fps: fps,
        );
        if (started) return;
      }

      // 2. Fallback: Python engine sidecar if ffmpeg is unavailable
      final startedPy = await _startPythonCapture(
        cameraIndex: cameraIndex,
        width: width,
        height: height,
        fps: fps,
      );
      if (startedPy) return;

      _frameController?.addError(
        'Unable to open webcam: neither ffmpeg nor camera capture tools were found.',
      );
      stopStreaming();
    } catch (e) {
      debugPrint('[DesktopWebcamService] Capture error: $e');
      _frameController?.addError('Camera capture error: $e');
      stopStreaming();
    }
  }

  Future<bool> _startFfmpegCapture({
    required int cameraIndex,
    required int width,
    required int height,
    required int fps,
  }) async {
    try {
      final List<String> args;

      if (Platform.isLinux) {
        final devPath = '/dev/video$cameraIndex';
        args = [
          '-hide_banner',
          '-loglevel',
          'error',
          '-f',
          'v4l2',
          '-video_size',
          '${width}x$height',
          '-framerate',
          '$fps',
          '-i',
          devPath,
          '-f',
          'image2pipe',
          '-vcodec',
          'mjpeg',
          '-q:v',
          '4',
          'pipe:1',
        ];
      } else if (Platform.isWindows) {
        args = [
          '-hide_banner',
          '-loglevel',
          'error',
          '-f',
          'dshow',
          '-video_size',
          '${width}x$height',
          '-framerate',
          '$fps',
          '-i',
          'video=0',
          '-f',
          'image2pipe',
          '-vcodec',
          'mjpeg',
          '-q:v',
          '4',
          'pipe:1',
        ];
      } else {
        return false;
      }

      debugPrint('[DesktopWebcamService] Spawning ffmpeg: ${args.join(" ")}');
      _captureProcess = await Process.start('ffmpeg', args);

      _consumeMjpegStream(_captureProcess!.stdout);

      _captureProcess!.exitCode.then((code) {
        debugPrint('[DesktopWebcamService] ffmpeg process exited with code $code');
        if (_isStreaming) {
          stopStreaming();
        }
      });

      return true;
    } catch (e) {
      debugPrint('[DesktopWebcamService] ffmpeg start failed: $e');
      return false;
    }
  }

  Future<bool> _startPythonCapture({
    required int cameraIndex,
    required int width,
    required int height,
    required int fps,
  }) async {
    final pythonCmd = Platform.isWindows ? 'python' : 'python3';
    final hasPython = await _checkExecutable(pythonCmd);
    if (!hasPython) return false;

    // Inline tiny Python bridge that emits base64 frames to stdout
    const inlineScript = '''
import cv2, base64, sys, time

cap = cv2.VideoCapture(int(sys.argv[1]))
cap.set(cv2.CAP_PROP_FRAME_WIDTH, int(sys.argv[2]))
cap.set(cv2.CAP_PROP_FRAME_HEIGHT, int(sys.argv[3]))
cap.set(cv2.CAP_PROP_FPS, int(sys.argv[4]))

if not cap.isOpened():
    sys.exit(1)

while True:
    ret, frame = cap.read()
    if not ret:
        time.sleep(0.01)
        continue
    ret, buf = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 75])
    if ret:
        b64 = base64.b64encode(buf).decode("ascii")
        sys.stdout.write(b64 + "\\n")
        sys.stdout.flush()
''';

    try {
      _captureProcess = await Process.start(pythonCmd, [
        '-u',
        '-c',
        inlineScript,
        '$cameraIndex',
        '$width',
        '$height',
        '$fps',
      ]);

      _captureProcess!.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        if (line.isNotEmpty && _isStreaming) {
          _frameController?.add('data:image/jpeg;base64,$line');
        }
      });

      _captureProcess!.exitCode.then((code) {
        debugPrint('[DesktopWebcamService] Python capture exited with code $code');
        if (_isStreaming) stopStreaming();
      });

      return true;
    } catch (e) {
      debugPrint('[DesktopWebcamService] Python capture failed: $e');
      return false;
    }
  }

  /// Parses binary MJPEG stream from ffmpeg stdout and emits base64 JPEGs.
  void _consumeMjpegStream(Stream<List<int>> byteStream) {
    final buffer = BytesBuilder(copy: false);

    byteStream.listen(
      (chunk) {
        if (!_isStreaming) return;
        buffer.add(chunk);

        final bytes = buffer.toBytes();
        int searchStart = 0;

        while (true) {
          // Look for JPEG SOI (0xFF, 0xD8)
          final soi = _indexOfJpegMarker(bytes, searchStart, 0xFF, 0xD8);
          if (soi == -1) {
            // No SOI found yet; retain last byte in case marker was split
            if (bytes.length > 1) {
              final remaining = bytes.sublist(bytes.length - 1);
              buffer.clear();
              buffer.add(remaining);
            }
            break;
          }

          // Look for JPEG EOI (0xFF, 0xD9) after SOI
          final eoi = _indexOfJpegMarker(bytes, soi + 2, 0xFF, 0xD9);
          if (eoi == -1) {
            // Incomplete frame; retain from SOI onward
            final partial = bytes.sublist(soi);
            buffer.clear();
            buffer.add(partial);
            break;
          }

          // Complete JPEG frame found [soi .. eoi + 2]
          final frameLength = (eoi + 2) - soi;
          final frameBytes = Uint8List.view(
            bytes.buffer,
            bytes.offsetInBytes + soi,
            frameLength,
          );

          final b64 = base64Encode(frameBytes);
          _frameController?.add('data:image/jpeg;base64,$b64');

          searchStart = eoi + 2;
          if (searchStart >= bytes.length) {
            buffer.clear();
            break;
          }
        }
      },
      onError: (err) {
        debugPrint('[DesktopWebcamService] Stream error: $err');
      },
      onDone: () {
        debugPrint('[DesktopWebcamService] Stream closed.');
      },
      cancelOnError: false,
    );
  }

  int _indexOfJpegMarker(Uint8List data, int start, int b1, int b2) {
    final len = data.length - 1;
    for (int i = start; i < len; i++) {
      if (data[i] == b1 && data[i + 1] == b2) {
        return i;
      }
    }
    return -1;
  }

  Future<bool> _checkExecutable(String exe) async {
    try {
      final res = await Process.run(
        Platform.isWindows ? 'where' : 'which',
        [exe],
      );
      return res.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Stops physical camera capture and releases hardware locks.
  void stopStreaming() {
    _isStreaming = false;
    if (_captureProcess != null) {
      try {
        _captureProcess!.kill(ProcessSignal.sigterm);
      } catch (_) {
        _captureProcess!.kill();
      }
      _captureProcess = null;
    }
    _frameController?.close();
    _frameController = null;
  }
}
