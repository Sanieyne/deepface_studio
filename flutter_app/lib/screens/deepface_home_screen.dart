import 'dart:async';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/live_cam_models.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/database_service.dart';
import '../services/desktop_webcam_service.dart';
import '../theme/app_theme.dart';
import '../widgets/subscription_dialog.dart';

class CustomCloneFace {
  final String id;
  final String name;
  final String base64Data;
  final Uint8List thumbnailBytes;

  const CustomCloneFace({
    required this.id,
    required this.name,
    required this.base64Data,
    required this.thumbnailBytes,
  });
}

class DeepFaceHomeScreen extends StatefulWidget {
  final bool isDark;
  final VoidCallback onThemeToggle;

  const DeepFaceHomeScreen({
    super.key,
    required this.isDark,
    required this.onThemeToggle,
  });

  @override
  State<DeepFaceHomeScreen> createState() => _DeepFaceHomeScreenState();
}

class _DeepFaceHomeScreenState extends State<DeepFaceHomeScreen> {
  final DeepFaceApiService _api = DeepFaceApiService();
  final DesktopWebcamService _webcam = DesktopWebcamService.instance;

  bool _engineOnline = false;
  bool _isLive = false;
  bool _isStarting = false;
  bool _enhanceFace = true;
  bool _mirrorCamera = true;
  double _fps = 0.0;
  String? _frameBase64;
  Timer? _frameTimer;
  Timer? _healthTimer;

  List<LiveCamPreset> _presets = [];
  LiveCamPreset? _selectedPreset;

  final List<CustomCloneFace> _customFaces = [];
  CustomCloneFace? _selectedCustomFace;

  List<DesktopWebcamDevice> _availableCameras = [];
  DesktopWebcamDevice? _selectedCamera;

  bool _isLocallySubscribed = false;
  bool _copiedUrl = false;

  @override
  void initState() {
    super.initState();
    _checkSubscription();
    _checkHealth();
    _loadAvailableCameras();
    _loadPresets();
    _healthTimer = Timer.periodic(const Duration(seconds: 4), (_) => _checkHealth());
  }

  @override
  void dispose() {
    _healthTimer?.cancel();
    _frameTimer?.cancel();
    _webcam.stopStreaming();
    _api.stopLiveCam();
    super.dispose();
  }

  Future<void> _checkSubscription() async {
    final status = await DatabaseService.instance.getSetting('user_subscription_status');
    if (status != null && status != 'free' && status != 'none') {
      if (mounted) setState(() => _isLocallySubscribed = true);
    }
  }

  Future<void> _checkHealth() async {
    final ok = await _api.checkEngineHealth();
    if (mounted && ok != _engineOnline) {
      setState(() => _engineOnline = ok);
      if (ok && _presets.isEmpty) {
        _loadPresets();
      }
    }
  }

  Future<void> _loadAvailableCameras() async {
    try {
      final cameras = await _webcam.getAvailableCameras();
      if (mounted) {
        setState(() {
          _availableCameras = cameras;
          if (cameras.isNotEmpty && _selectedCamera == null) {
            _selectedCamera = cameras.first;
          }
        });
      }
    } catch (e) {
      debugPrint('[DeepFace] Camera detection error: $e');
    }
  }

  Future<void> _loadPresets() async {
    final presets = await _api.getLiveCamPresets();
    if (mounted) {
      setState(() {
        _presets = presets;
        if (presets.isNotEmpty && _selectedPreset == null && _selectedCustomFace == null) {
          _selectedPreset = presets.first;
        }
      });
    }
  }

  void _startFramePolling() {
    _frameTimer?.cancel();
    _frameTimer = Timer.periodic(const Duration(milliseconds: 40), (_) async {
      if (!_isLive || !mounted) return;
      final res = await _api.getLiveCamFrame();
      if (res.hasFrame && res.frameBase64 != null && mounted) {
        setState(() {
          _frameBase64 = res.frameBase64;
          _fps = res.fps;
        });
      }
    });
  }

  Future<void> _toggleLiveFaceSwap() async {
    final user = AuthService.instance.currentUser;
    final isSub = user?.isSubscribed ?? _isLocallySubscribed;

    if (!isSub) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('🔒 Lifetime License required (\$35 one-time) for live face swapping.'),
          backgroundColor: LuminaColors.primaryEnd,
          duration: Duration(seconds: 4),
        ),
      );
      _handleOpenSubscriptionDialog();
      return;
    }

    if (_isLive) {
      setState(() => _isStarting = true);
      await _api.stopLiveCam();
      _frameTimer?.cancel();
      if (mounted) {
        setState(() {
          _isLive = false;
          _isStarting = false;
          _frameBase64 = null;
          _fps = 0.0;
        });
      }
      return;
    }

    setState(() => _isStarting = true);

    String? targetName;
    String? targetB64;
    String? presetId;

    if (_selectedCustomFace != null) {
      targetName = _selectedCustomFace!.name;
      targetB64 = _selectedCustomFace!.base64Data;
    } else if (_selectedPreset != null) {
      targetName = _selectedPreset!.name;
      presetId = _selectedPreset!.id;
    }

    final success = await _api.startLiveCam(
      targetName: targetName,
      targetImageBase64: targetB64,
      presetId: presetId,
      enhanceFace: _enhanceFace,
      cameraIndex: _selectedCamera?.index ?? 0,
    );

    if (mounted) {
      setState(() {
        _isStarting = false;
        _isLive = success;
      });

      if (success) {
        _startFramePolling();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not start face swap. Make sure your webcam is connected.'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  Future<void> _pickCustomFace() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png', 'webp'],
      withData: true,
    );

    if (result != null && result.files.single.bytes != null) {
      final file = result.files.single;
      final bytes = file.bytes!;
      final b64 = base64Encode(bytes);
      final custom = CustomCloneFace(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: file.name.replaceAll(RegExp(r'\.[^.]+$'), ''),
        base64Data: b64,
        thumbnailBytes: bytes,
      );

      setState(() {
        _customFaces.insert(0, custom);
        _selectedCustomFace = custom;
        _selectedPreset = null;
      });

      if (_isLive) {
        _toggleLiveFaceSwap().then((_) => _toggleLiveFaceSwap());
      }
    }
  }

  void _handleOpenSubscriptionDialog() {
    final user = AuthService.instance.currentUser;
    final isSub = user?.isSubscribed ?? _isLocallySubscribed;
    final plan = user?.subscriptionPlan ?? (_isLocallySubscribed ? 'Pro' : 'Free Tier');

    SubscriptionPlanDialog.show(
      context,
      isSubscribed: isSub,
      currentPlan: plan,
      onPlanChanged: (subscribed) {
        setState(() => _isLocallySubscribed = subscribed);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final dark = widget.isDark;
    final bg = dark ? LuminaColors.darkBg : LuminaColors.lightBg;
    final border = dark ? LuminaColors.darkBorder : LuminaColors.lightBorder;
    final muted = dark ? LuminaColors.darkMuted : LuminaColors.lightMuted;
    final user = AuthService.instance.currentUser;
    final isSub = user?.isSubscribed ?? _isLocallySubscribed;

    return Scaffold(
      backgroundColor: bg,
      body: Column(
        children: [
          // Top Navigation Bar
          Container(
            height: 64,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            decoration: BoxDecoration(
              color: dark ? LuminaColors.darkCard : LuminaColors.lightCard,
              border: Border(bottom: BorderSide(color: border)),
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    gradient: LuminaColors.primaryGradient,
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: [
                      BoxShadow(
                        color: LuminaColors.primaryGlow.withValues(alpha: 0.4),
                        blurRadius: 10,
                      ),
                    ],
                  ),
                  child: const Center(
                    child: Icon(Icons.face_retouching_natural, color: Colors.white, size: 20),
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'DEEPFACE STUDIO',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.0,
                      ),
                    ),
                    Row(
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _engineOnline ? const Color(0xFF10B981) : Colors.amber,
                          ),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          _engineOnline ? 'Engine Ready' : 'Connecting Engine...',
                          style: TextStyle(fontSize: 11, color: muted),
                        ),
                      ],
                    ),
                  ],
                ),
                const Spacer(),

                // Subscription Badge
                if (isSub) ...[
                  InkWell(
                    onTap: _handleOpenSubscriptionDialog,
                    borderRadius: BorderRadius.circular(20),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.5)),
                        color: const Color(0xFF10B981).withValues(alpha: 0.12),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.stars_rounded, size: 15, color: Color(0xFF10B981)),
                          SizedBox(width: 6),
                          Text(
                            'Pro Member',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF10B981)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ] else ...[
                  ElevatedButton.icon(
                    onPressed: _handleOpenSubscriptionDialog,
                    icon: const Icon(Icons.key_rounded, size: 15, color: Colors.white),
                    label: const Text('Buy License (\$35)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: LuminaColors.primaryEnd,
                      foregroundColor: Colors.white,
                      shape: const StadiumBorder(),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    ),
                  ),
                ],
                const SizedBox(width: 12),

                // Theme Toggle
                IconButton(
                  onPressed: widget.onThemeToggle,
                  icon: Icon(dark ? Icons.light_mode_rounded : Icons.dark_mode_rounded, size: 18),
                ),
              ],
            ),
          ),

          // Main Screen Body
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Live Video Canvas
                Expanded(
                  flex: 3,
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.black,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: _isLive ? const Color(0xFF10B981) : border,
                                width: _isLive ? 2.0 : 1.0,
                              ),
                              boxShadow: _isLive
                                  ? [
                                      BoxShadow(
                                        color: const Color(0xFF10B981).withValues(alpha: 0.25),
                                        blurRadius: 24,
                                      ),
                                    ]
                                  : null,
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                if (_frameBase64 != null)
                                  Transform(
                                    alignment: Alignment.center,
                                    transform: Matrix4.rotationY(_mirrorCamera ? 3.14159 : 0),
                                    child: Image.memory(
                                      base64Decode(_frameBase64!),
                                      fit: BoxFit.contain,
                                      gaplessPlayback: true,
                                    ),
                                  )
                                else
                                  Center(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          _isStarting ? Icons.sync : Icons.videocam_outlined,
                                          size: 56,
                                          color: muted.withValues(alpha: 0.5),
                                        ),
                                        const SizedBox(height: 12),
                                        Text(
                                          _isStarting
                                              ? 'Initializing Face Analysis & Neural Models...'
                                              : 'Camera Standby. Select a face and click "Start Face Swap"',
                                          style: TextStyle(fontSize: 13, color: muted),
                                        ),
                                      ],
                                    ),
                                  ),

                                // Top Overlay: Live Indicators
                                if (_isLive)
                                  Positioned(
                                    top: 14,
                                    left: 14,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withValues(alpha: 0.65),
                                        borderRadius: BorderRadius.circular(20),
                                        border: Border.all(color: Colors.redAccent.withValues(alpha: 0.6)),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Container(
                                            width: 8,
                                            height: 8,
                                            decoration: const BoxDecoration(
                                              shape: BoxShape.circle,
                                              color: Colors.redAccent,
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          const Text(
                                            'LIVE SWAP',
                                            style: TextStyle(
                                              fontSize: 10.5,
                                              fontWeight: FontWeight.w900,
                                              color: Colors.white,
                                              letterSpacing: 0.5,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            '${_fps.toStringAsFixed(1)} FPS',
                                            style: const TextStyle(fontSize: 10.5, color: Colors.white70),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),

                                // Bottom Controls Overlay
                                Positioned(
                                  bottom: 14,
                                  left: 14,
                                  right: 14,
                                  child: Row(
                                    children: [
                                      // Mirror Toggle
                                      IconButton.filledTonal(
                                        onPressed: () => setState(() => _mirrorCamera = !_mirrorCamera),
                                        icon: Icon(_mirrorCamera ? Icons.flip_rounded : Icons.flip_camera_android_rounded),
                                        tooltip: 'Mirror Camera Horizontal',
                                      ),
                                      const SizedBox(width: 8),
                                      // Enhance Toggle
                                      FilterChip(
                                        label: const Text('GFPGAN 4K Enhance', style: TextStyle(fontSize: 11.5)),
                                        selected: _enhanceFace,
                                        onSelected: (val) => setState(() => _enhanceFace = val),
                                      ),
                                      const Spacer(),
                                      // Start / Stop Main Button
                                      ElevatedButton.icon(
                                        onPressed: _isStarting ? null : _toggleLiveFaceSwap,
                                        icon: Icon(_isLive ? Icons.stop_rounded : Icons.play_arrow_rounded),
                                        label: Text(_isLive ? 'Stop Swap' : 'Start Live Face Swap'),
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: _isLive ? Colors.redAccent : const Color(0xFF10B981),
                                          foregroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),

                        // OBS Stream Link Card
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          decoration: BoxDecoration(
                            color: dark ? LuminaColors.darkCard : LuminaColors.lightCard,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: border),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.cast_connected_rounded, size: 18, color: muted),
                              const SizedBox(width: 10),
                              const Text(
                                'Virtual Camera Stream (OBS / Zoom / Meet):',
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'http://127.0.0.1:8000/api/face/stream',
                                  style: TextStyle(fontSize: 12, color: LuminaColors.primaryEnd, fontFamily: 'monospace'),
                                ),
                              ),
                              TextButton.icon(
                                onPressed: () {
                                  Clipboard.setData(const ClipboardData(text: 'http://127.0.0.1:8000/api/face/stream'));
                                  setState(() => _copiedUrl = true);
                                  Future.delayed(const Duration(seconds: 2), () {
                                    if (mounted) setState(() => _copiedUrl = false);
                                  });
                                },
                                icon: Icon(_copiedUrl ? Icons.check : Icons.copy_rounded, size: 14),
                                label: Text(_copiedUrl ? 'Copied' : 'Copy URL', style: const TextStyle(fontSize: 11.5)),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // Right Controls & Face Picker Panel
                Container(
                  width: 380,
                  decoration: BoxDecoration(
                    color: dark ? LuminaColors.darkCard : LuminaColors.lightCard,
                    border: Border(left: BorderSide(color: border)),
                  ),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Webcam Selection Dropdown
                        const Text('Webcam Device', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: border),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<DesktopWebcamDevice>(
                              value: _selectedCamera,
                              isExpanded: true,
                              hint: const Text('Detecting Cameras...', style: TextStyle(fontSize: 12.5)),
                              items: _availableCameras.map((cam) {
                                return DropdownMenuItem(
                                  value: cam,
                                  child: Text(cam.name, style: const TextStyle(fontSize: 12.5)),
                                );
                              }).toList(),
                              onChanged: (cam) {
                                setState(() => _selectedCamera = cam);
                                if (_isLive) {
                                  _toggleLiveFaceSwap().then((_) => _toggleLiveFaceSwap());
                                }
                              },
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),

                        // Face Clone Target Header
                        Row(
                          children: [
                            const Text('Target Face to Clone', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                            const Spacer(),
                            TextButton.icon(
                              onPressed: _pickCustomFace,
                              icon: const Icon(Icons.add_photo_alternate_rounded, size: 14),
                              label: const Text('Upload Photo', style: TextStyle(fontSize: 11.5)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),

                        // Custom Uploaded Faces (if any)
                        if (_customFaces.isNotEmpty) ...[
                          Text('Your Custom Faces', style: TextStyle(fontSize: 11, color: muted)),
                          const SizedBox(height: 6),
                          SizedBox(
                            height: 80,
                            child: ListView.separated(
                              scrollDirection: Axis.horizontal,
                              itemCount: _customFaces.length,
                              separatorBuilder: (_, __) => const SizedBox(width: 8),
                              itemBuilder: (ctx, i) {
                                final face = _customFaces[i];
                                final isPicked = _selectedCustomFace?.id == face.id;
                                return GestureDetector(
                                  onTap: () {
                                    setState(() {
                                      _selectedCustomFace = face;
                                      _selectedPreset = null;
                                    });
                                  },
                                  child: Container(
                                    width: 70,
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: isPicked ? const Color(0xFF10B981) : border,
                                        width: isPicked ? 2 : 1,
                                      ),
                                    ),
                                    clipBehavior: Clip.antiAlias,
                                    child: Image.memory(face.thumbnailBytes, fit: BoxFit.cover),
                                  ),
                                );
                              },
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],

                        // Preset Faces Gallery
                        Text('Presets Library', style: TextStyle(fontSize: 11, color: muted)),
                        const SizedBox(height: 8),
                        GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            mainAxisSpacing: 10,
                            crossAxisSpacing: 10,
                            childAspectRatio: 0.85,
                          ),
                          itemCount: _presets.length,
                          itemBuilder: (ctx, i) {
                            final preset = _presets[i];
                            final isPicked = _selectedPreset?.id == preset.id && _selectedCustomFace == null;
                            return GestureDetector(
                              onTap: () {
                                setState(() {
                                  _selectedPreset = preset;
                                  _selectedCustomFace = null;
                                });
                              },
                              child: Container(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: isPicked ? const Color(0xFF10B981) : border,
                                    width: isPicked ? 2.2 : 1,
                                  ),
                                ),
                                clipBehavior: Clip.antiAlias,
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    if (preset.thumbnailBase64 != null)
                                      Image.memory(
                                        base64Decode(preset.thumbnailBase64!),
                                        fit: BoxFit.cover,
                                      )
                                    else
                                      Container(color: Colors.grey.shade900),
                                    Positioned(
                                      bottom: 0,
                                      left: 0,
                                      right: 0,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                                        color: Colors.black.withValues(alpha: 0.7),
                                        child: Text(
                                          preset.name,
                                          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white),
                                          textAlign: TextAlign.center,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
