import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/live_cam_models.dart';

class DeepFaceApiService {
  static const String defaultEngineUrl = 'http://127.0.0.1:8000';
  String baseUrl;
  final http.Client _client = http.Client();

  DeepFaceApiService({this.baseUrl = defaultEngineUrl});

  Future<bool> checkEngineHealth() async {
    try {
      final res = await _client.get(Uri.parse('$baseUrl/health')).timeout(const Duration(seconds: 2));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<LiveCamStatus> getLiveCamStatus() async {
    try {
      final res = await _client.get(Uri.parse('$baseUrl/api/face/status')).timeout(const Duration(seconds: 3));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        return LiveCamStatus(
          active: data['active'] == true,
          sourceName: data['sourceName'] as String?,
          fps: (data['fps'] as num?)?.toDouble() ?? 0.0,
          streamUrl: (data['streamUrl'] as String?) ?? '$baseUrl/api/face/stream',
        );
      }
    } catch (e) {
      debugPrint('[DeepFaceApi] getLiveCamStatus error: $e');
    }
    return const LiveCamStatus(active: false);
  }

  Future<List<LiveCamPreset>> getLiveCamPresets() async {
    try {
      final res = await _client.get(Uri.parse('$baseUrl/api/face/presets')).timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final list = jsonDecode(res.body) as List<dynamic>;
        return list.map((item) {
          final m = item as Map<String, dynamic>;
          return LiveCamPreset(
            id: m['id'] as String,
            name: m['name'] as String,
            thumbnailBase64: m['thumbnailBase64'] as String?,
          );
        }).toList();
      }
    } catch (e) {
      debugPrint('[DeepFaceApi] getLiveCamPresets error: $e');
    }
    return [];
  }

  Future<bool> startLiveCam({
    String? targetName,
    String? targetImageBase64,
    String? presetId,
    bool enhanceFace = false,
    int cameraIndex = 0,
  }) async {
    try {
      final res = await _client
          .post(
            Uri.parse('$baseUrl/api/face/start'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'target_name': targetName ?? 'Custom',
              'target_image_base64': targetImageBase64,
              'preset_id': presetId,
              'enhance_face': enhanceFace,
              'camera_index': cameraIndex,
            }),
          )
          .timeout(const Duration(seconds: 8));
      return res.statusCode == 200;
    } catch (e) {
      debugPrint('[DeepFaceApi] startLiveCam error: $e');
      return false;
    }
  }

  Future<bool> stopLiveCam() async {
    try {
      final res = await _client
          .post(Uri.parse('$baseUrl/api/face/stop'))
          .timeout(const Duration(seconds: 4));
      return res.statusCode == 200;
    } catch (e) {
      debugPrint('[DeepFaceApi] stopLiveCam error: $e');
      return false;
    }
  }

  Future<LiveCamFrameResult> getLiveCamFrame() async {
    try {
      final res = await _client
          .get(Uri.parse('$baseUrl/api/face/frame'))
          .timeout(const Duration(milliseconds: 1200));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        return LiveCamFrameResult(
          hasFrame: data['hasFrame'] == true,
          frameBase64: data['frameBase64'] as String?,
          fps: (data['fps'] as num?)?.toDouble() ?? 0.0,
        );
      }
    } catch (_) {}
    return const LiveCamFrameResult(hasFrame: false);
  }

  Future<String?> swapSingleFrame({
    required String frameBase64,
    String? targetImageBase64,
    String? presetId,
    bool enhanceFace = false,
  }) async {
    try {
      final res = await _client
          .post(
            Uri.parse('$baseUrl/api/face/swap_frame'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'frame_base64': frameBase64,
              'target_image_base64': targetImageBase64,
              'preset_id': presetId,
              'enhance_face': enhanceFace,
            }),
          )
          .timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        return data['swapped_frame_base64'] as String?;
      }
    } catch (e) {
      debugPrint('[DeepFaceApi] swapSingleFrame error: $e');
    }
    return null;
  }
}
