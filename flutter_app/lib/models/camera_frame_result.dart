import 'dart:convert';
import 'dart:typed_data';

/// Detailed face bounding box and framing quality metrics from InsightFace.
class CameraFaceMetrics {
  final List<int> bbox;
  final double score;
  final double areaRatio;
  final double offsetX;
  final double offsetY;
  final int width;
  final int height;

  const CameraFaceMetrics({
    required this.bbox,
    required this.score,
    required this.areaRatio,
    required this.offsetX,
    required this.offsetY,
    required this.width,
    required this.height,
  });

  factory CameraFaceMetrics.fromJson(Map<String, dynamic> json) {
    return CameraFaceMetrics(
      bbox: (json['bbox'] as List<dynamic>?)?.map((e) => (e as num).toInt()).toList() ?? [],
      score: (json['score'] as num?)?.toDouble() ?? 0.0,
      areaRatio: (json['area_ratio'] as num?)?.toDouble() ?? 0.0,
      offsetX: (json['offset_x'] as num?)?.toDouble() ?? 0.0,
      offsetY: (json['offset_y'] as num?)?.toDouble() ?? 0.0,
      width: (json['width'] as num?)?.toInt() ?? 0,
      height: (json['height'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Response returned by GET /api/camera/frame.
class CameraFrameResult {
  final bool success;
  final String? imageBase64;
  final Uint8List? imageBytes;
  final int? width;
  final int? height;
  final int facesCount;
  final String feedbackCode;
  final String feedbackText;
  final bool canCapture;
  final CameraFaceMetrics? faceMetrics;
  final String? error;

  const CameraFrameResult({
    required this.success,
    this.imageBase64,
    this.imageBytes,
    this.width,
    this.height,
    this.facesCount = 0,
    required this.feedbackCode,
    required this.feedbackText,
    required this.canCapture,
    this.faceMetrics,
    this.error,
  });

  factory CameraFrameResult.fromJson(Map<String, dynamic> json) {
    final b64 = json['image_base64'] as String?;
    Uint8List? bytes;
    if (b64 != null && b64.isNotEmpty) {
      try {
        bytes = base64Decode(b64);
      } catch (_) {}
    }

    return CameraFrameResult(
      success: json['success'] as bool? ?? false,
      imageBase64: b64,
      imageBytes: bytes,
      width: (json['width'] as num?)?.toInt(),
      height: (json['height'] as num?)?.toInt(),
      facesCount: (json['faces_count'] as num?)?.toInt() ?? 0,
      feedbackCode: json['feedback_code'] as String? ?? 'unknown',
      feedbackText: json['feedback_text'] as String? ?? '',
      canCapture: json['can_capture'] as bool? ?? false,
      faceMetrics: json['face_metrics'] != null
          ? CameraFaceMetrics.fromJson(json['face_metrics'] as Map<String, dynamic>)
          : null,
      error: json['error'] as String?,
    );
  }
}

/// Response returned by POST /api/camera/capture.
class CameraCaptureResult {
  final bool success;
  final String filePath;
  final String fileName;
  final String timestamp;
  final int width;
  final int height;
  final String feedbackCode;
  final String feedbackText;
  final bool canCapture;
  final CameraFaceMetrics? faceMetrics;
  final String? imageBase64;
  final Uint8List? imageBytes;
  final String? error;

  const CameraCaptureResult({
    required this.success,
    required this.filePath,
    required this.fileName,
    required this.timestamp,
    required this.width,
    required this.height,
    required this.feedbackCode,
    required this.feedbackText,
    required this.canCapture,
    this.faceMetrics,
    this.imageBase64,
    this.imageBytes,
    this.error,
  });

  factory CameraCaptureResult.fromJson(Map<String, dynamic> json) {
    final b64 = json['image_base64'] as String?;
    Uint8List? bytes;
    if (b64 != null && b64.isNotEmpty) {
      try {
        bytes = base64Decode(b64);
      } catch (_) {}
    }

    return CameraCaptureResult(
      success: json['success'] as bool? ?? false,
      filePath: json['file_path'] as String? ?? '',
      fileName: json['file_name'] as String? ?? '',
      timestamp: json['timestamp'] as String? ?? '',
      width: (json['width'] as num?)?.toInt() ?? 0,
      height: (json['height'] as num?)?.toInt() ?? 0,
      feedbackCode: json['feedback_code'] as String? ?? '',
      feedbackText: json['feedback_text'] as String? ?? '',
      canCapture: json['can_capture'] as bool? ?? false,
      faceMetrics: json['face_metrics'] != null
          ? CameraFaceMetrics.fromJson(json['face_metrics'] as Map<String, dynamic>)
          : null,
      imageBase64: b64,
      imageBytes: bytes,
      error: json['error'] as String?,
    );
  }
}
