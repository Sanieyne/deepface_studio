class LiveCamPreset {
  final String name;
  final String filename;
  final String path;

  LiveCamPreset({
    required this.name,
    required this.filename,
    required this.path,
  });

  factory LiveCamPreset.fromJson(Map<String, dynamic> json) {
    return LiveCamPreset(
      name: json['name'] as String? ?? 'Preset',
      filename: json['filename'] as String? ?? '',
      path: json['path'] as String? ?? '',
    );
  }
}

class LiveCamStatusResult {
  final bool success;
  final String message;
  final bool active;
  final String? sourceName;
  final String? streamUrl;

  LiveCamStatusResult({
    required this.success,
    required this.message,
    this.active = false,
    this.sourceName,
    this.streamUrl,
  });

  factory LiveCamStatusResult.fromJson(Map<String, dynamic> json) {
    return LiveCamStatusResult(
      success: json['success'] as bool? ?? false,
      message: json['message'] as String? ?? '',
      active: json['active'] as bool? ?? false,
      sourceName: json['source_name'] as String?,
      streamUrl: json['stream_url'] as String?,
    );
  }
}

class LiveCamFrameResult {
  final bool active;
  final double fps;
  final String sourceName;
  final bool enhanceFace;
  final bool mirror;
  final String? frameBase64;
  final String? message;

  LiveCamFrameResult({
    required this.active,
    required this.fps,
    required this.sourceName,
    this.enhanceFace = false,
    this.mirror = true,
    this.frameBase64,
    this.message,
  });

  factory LiveCamFrameResult.fromJson(Map<String, dynamic> json) {
    return LiveCamFrameResult(
      active: json['active'] as bool? ?? false,
      fps: (json['fps'] as num?)?.toDouble() ?? 0.0,
      sourceName: json['source_name'] as String? ?? 'None',
      enhanceFace: json['enhance_face'] as bool? ?? false,
      mirror: json['mirror'] as bool? ?? true,
      frameBase64: json['frame_base64'] as String?,
      message: json['message'] as String?,
    );
  }
}

class FaceSwapImageResult {
  final bool success;
  final String? imageBase64;
  final int facesSwapped;
  final double similarityPercent;
  final bool verified;
  final double elapsedSeconds;
  final String? message;

  FaceSwapImageResult({
    required this.success,
    this.imageBase64,
    this.facesSwapped = 0,
    this.similarityPercent = 0.0,
    this.verified = false,
    this.elapsedSeconds = 0.0,
    this.message,
  });

  factory FaceSwapImageResult.fromJson(Map<String, dynamic> json) {
    return FaceSwapImageResult(
      success: json['success'] as bool? ?? false,
      imageBase64: json['image_base64'] as String?,
      facesSwapped: (json['faces_swapped'] as num?)?.toInt() ?? 0,
      similarityPercent: (json['similarity_percent'] as num?)?.toDouble() ?? 0.0,
      verified: json['verified'] as bool? ?? false,
      elapsedSeconds: (json['elapsed_seconds'] as num?)?.toDouble() ?? 0.0,
      message: json['message'] as String?,
    );
  }
}

class FaceSwapVideoResult {
  final bool success;
  final String? videoBase64;
  final int framesProcessed;
  final double fps;
  final double elapsedSeconds;
  final String? message;

  FaceSwapVideoResult({
    required this.success,
    this.videoBase64,
    this.framesProcessed = 0,
    this.fps = 0.0,
    this.elapsedSeconds = 0.0,
    this.message,
  });

  factory FaceSwapVideoResult.fromJson(Map<String, dynamic> json) {
    return FaceSwapVideoResult(
      success: json['success'] as bool? ?? false,
      videoBase64: json['video_base64'] as String?,
      framesProcessed: (json['frames_processed'] as num?)?.toInt() ?? 0,
      fps: (json['fps'] as num?)?.toDouble() ?? 0.0,
      elapsedSeconds: (json['elapsed_seconds'] as num?)?.toDouble() ?? 0.0,
      message: json['message'] as String?,
    );
  }
}

class FaceExtractResult {
  final bool success;
  final List<double> embedding;
  final List<int> bbox;
  final String? croppedFaceBase64;
  final String? gender;
  final int? age;
  final String? message;

  FaceExtractResult({
    required this.success,
    this.embedding = const [],
    this.bbox = const [],
    this.croppedFaceBase64,
    this.gender,
    this.age,
    this.message,
  });

  factory FaceExtractResult.fromJson(Map<String, dynamic> json) {
    return FaceExtractResult(
      success: json['success'] as bool? ?? false,
      embedding: (json['embedding'] as List?)?.map((e) => (e as num).toDouble()).toList() ?? const [],
      bbox: (json['bbox'] as List?)?.map((e) => (e as num).toInt()).toList() ?? const [],
      croppedFaceBase64: json['cropped_face_base64'] as String?,
      gender: json['gender'] as String?,
      age: (json['age'] as num?)?.toInt(),
      message: json['message'] as String?,
    );
  }
}

class FaceVerifyResult {
  final bool success;
  final bool match;
  final double similarityPercent;
  final double cosineDistance;
  final String? message;

  FaceVerifyResult({
    required this.success,
    this.match = false,
    this.similarityPercent = 0.0,
    this.cosineDistance = 1.0,
    this.message,
  });

  factory FaceVerifyResult.fromJson(Map<String, dynamic> json) {
    return FaceVerifyResult(
      success: json['success'] as bool? ?? false,
      match: json['match'] as bool? ?? false,
      similarityPercent: (json['similarity_percent'] as num?)?.toDouble() ?? 0.0,
      cosineDistance: (json['cosine_distance'] as num?)?.toDouble() ?? 1.0,
      message: json['message'] as String?,
    );
  }
}

