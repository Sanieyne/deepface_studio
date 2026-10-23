import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/generation_item.dart';
import '../models/lora.dart';
import '../models/project_item.dart';

/// SQLite persistence (studio.db) + local disk image cache.
/// Images live in the app-support directory; the DB stores file paths.
class DatabaseService {
  static final DatabaseService instance = DatabaseService._internal();
  DatabaseService._internal();

  /// Legacy popup labels (e.g. 'SDXL 1.0 (Live RTX 3090)') -> current model names.
  static String normalizeModelName(String raw) {
    const legacy = {
      'SDXL 1.0 (Live RTX 3090)': 'RealVisXL V4.0',
      'SDXL 0.9 (Research)': 'SDXL Base 1.0',
      'Stable Diffusion XL': 'SDXL Base 1.0',
    };
    if (legacy.containsKey(raw)) return legacy[raw]!;
    if (raw.contains('RTX 3090') || raw.contains('Vast')) return 'RealVisXL V4.0';
    return raw;
  }

  Database? _db;
  Directory? _imagesDir;

  Future<void> init() async {
    if (_db != null) return;

    final appDir = await getApplicationSupportDirectory();
    final dbPath = p.join(appDir.path, 'ai_image_studio.db');

    _imagesDir = Directory(p.join(appDir.path, 'saved_generations'));
    if (!await _imagesDir!.exists()) {
      await _imagesDir!.create(recursive: true);
    }

    _db = await openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE projects (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            is_pinned INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''');

        await db.execute('''
          CREATE TABLE generations (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            prompt TEXT NOT NULL,
            negative_prompt TEXT,
            aspect_ratio TEXT NOT NULL,
            model_name TEXT NOT NULL,
            timestamp INTEGER NOT NULL,
            status TEXT NOT NULL,
            image_path TEXT,
            seed INTEGER,
            inference_time_ms INTEGER,
            active_loras TEXT,
            error_message TEXT,
            FOREIGN KEY (project_id) REFERENCES projects (id) ON DELETE CASCADE
          )
        ''');

        await db.execute(
          'CREATE INDEX idx_generations_project ON generations(project_id)',
        );
      },
      onOpen: (db) async {
        // One-time cleanup of legacy model labels from the old popup.
        const legacy = {
          'SDXL 1.0 (Live RTX 3090)': 'RealVisXL V4.0',
          'SDXL 0.9 (Research)': 'SDXL Base 1.0',
          'Stable Diffusion XL': 'SDXL Base 1.0',
        };
        for (final e in legacy.entries) {
          await db.update(
            'generations',
            {'model_name': e.value},
            where: 'model_name = ?',
            whereArgs: [e.key],
          );
        }
      },
    );
  }

  Database get db {
    if (_db == null) throw StateError('DatabaseService is not initialized');
    return _db!;
  }

  // --- App Settings (Key-Value Cache) ---

  Future<void> setSetting(String key, String value) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS app_settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    await db.insert(
      'app_settings',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String?> getSetting(String key) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS app_settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    final rows = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      return rows.first['value'] as String?;
    }
    return null;
  }

  // --- Projects ---

  Future<List<ProjectItem>> getAllProjects() async {
    final rows = await db.query('projects', orderBy: 'updated_at DESC');
    return rows.map(ProjectItem.fromMap).toList();
  }

  Future<void> insertProject(ProjectItem project) async {
    await db.insert('projects', project.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> updateProjectTitle(String id, String newTitle) async {
    await db.update(
      'projects',
      {
        'title': newTitle,
        'updated_at': DateTime.now().millisecondsSinceEpoch
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> toggleProjectPinned(String id, bool isPinned) async {
    await db.update(
      'projects',
      {
        'is_pinned': isPinned ? 1 : 0,
        'updated_at': DateTime.now().millisecondsSinceEpoch
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> touchProject(String id) async {
    await db.update(
      'projects',
      {'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deleteProject(String id) async {
    final generations = await getGenerationsForProject(id);
    for (final gen in generations) {
      if (gen.imagePath != null) {
        final f = File(gen.imagePath!);
        if (await f.exists()) await f.delete();
      }
    }
    await db.delete('generations',
        where: 'project_id = ?', whereArgs: [id]);
    await db.delete('projects', where: 'id = ?', whereArgs: [id]);
  }

  // --- Generations ---

  Future<List<GenerationItem>> getGenerationsForProject(
      String projectId) async {
    final rows = await db.query(
      'generations',
      where: 'project_id = ?',
      whereArgs: [projectId],
      orderBy: 'timestamp ASC',
    );

    final items = <GenerationItem>[];
    for (final r in rows) {
      Uint8List? bytes;
      bool isVideo = false;
      String? videoPath;
      bool isAudio = false;
      String? audioPath;
      final imagePath = r['image_path'] as String?;
      if (imagePath != null) {
        if (imagePath.endsWith('.mp4')) {
          isVideo = true;
          videoPath = imagePath;
          final thumbFile = File(imagePath.replaceAll('.mp4', '_thumb.jpg'));
          if (await thumbFile.exists()) {
            bytes = await thumbFile.readAsBytes();
          } else {
            try {
              await Process.run('ffmpeg', [
                '-y',
                '-i',
                imagePath,
                '-ss',
                '00:00:00',
                '-vframes',
                '1',
                thumbFile.path,
              ]);
              if (await thumbFile.exists()) {
                bytes = await thumbFile.readAsBytes();
              }
            } catch (_) {}
          }
        } else if (imagePath.endsWith('.wav') || imagePath.endsWith('.mp3')) {
          isAudio = true;
          audioPath = imagePath;
          final file = File(imagePath);
          if (await file.exists()) bytes = await file.readAsBytes();
        } else {
          final file = File(imagePath);
          if (await file.exists()) bytes = await file.readAsBytes();
        }
      }

      Map<String, LoraInfo> loras = {};
      final lorasRaw = r['active_loras'] as String?;
      if (lorasRaw != null && lorasRaw.isNotEmpty) {
        try {
          final decoded = jsonDecode(lorasRaw) as Map<String, dynamic>;
          loras = decoded.map((k, v) =>
              MapEntry(k, LoraInfo.fromJson(v as Map<String, dynamic>)));
        } catch (_) {}
      }

      GenerationStatus status;
      try {
        status = GenerationStatus.values
            .firstWhere((s) => s.name == r['status']);
      } catch (_) {
        status = GenerationStatus.failed;
      }

      items.add(GenerationItem(
        id: r['id'] as String,
        projectId: projectId,
        prompt: r['prompt'] as String,
        negativePrompt: r['negative_prompt'] as String? ?? '',
        aspectRatio: r['aspect_ratio'] as String? ?? '9:16',
        modelName: DatabaseService.normalizeModelName(r['model_name'] as String? ?? ''),
        timestamp: DateTime.fromMillisecondsSinceEpoch(
            (r['timestamp'] as int?) ?? 0),
        status: status,
        imagePath: imagePath,
        imageBytes: bytes,
        seed: r['seed'] as int?,
        inferenceTimeMs: r['inference_time_ms'] as int?,
        activeLoras: loras,
        errorMessage: r['error_message'] as String?,
        isVideo: isVideo,
        videoPath: videoPath,
        isAudio: isAudio,
        audioPath: audioPath,
      ));
    }
    return items;
  }

  Future<void> insertGeneration(GenerationItem item) async {
    await db.insert('generations', {
      'id': item.id,
      'project_id': item.projectId,
      'prompt': item.prompt,
      'negative_prompt': item.negativePrompt,
      'aspect_ratio': item.aspectRatio,
      'model_name': item.modelName,
      'timestamp': item.timestamp.millisecondsSinceEpoch,
      'status': item.status.name,
      'image_path': item.imagePath,
      'seed': item.seed,
      'inference_time_ms': item.inferenceTimeMs,
      'active_loras': jsonEncode(item.activeLoras.map(
          (k, v) => MapEntry(k, {'path': v.path, 'weight': v.weight}))),
      'error_message': item.errorMessage,
    });
    await db.update(
      'projects',
      {'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [item.projectId],
    );
  }

  Future<String?> updateGenerationResult({
    required String id,
    required GenerationStatus status,
    required Uint8List? bytes,
    required int? seed,
    required int? durationMs,
    required Map<String, LoraInfo> loras,
    String? error,
    bool isVideo = false,
    bool isAudio = false,
  }) async {
    String? savedFilePath;
    if (bytes != null && bytes.isNotEmpty && _imagesDir != null) {
      final isMp4 = isVideo ||
          (bytes.length > 8 &&
              bytes[4] == 0x66 &&
              bytes[5] == 0x74 &&
              bytes[6] == 0x79 &&
              bytes[7] == 0x70);
      final isWav = isAudio ||
          (bytes.length > 12 &&
              bytes[0] == 0x52 &&
              bytes[1] == 0x49 &&
              bytes[2] == 0x46 &&
              bytes[3] == 0x46);
      final ext = isMp4 ? 'mp4' : (isWav ? 'wav' : 'jpg');
      final file = File(p.join(_imagesDir!.path, '$id.$ext'));
      await file.writeAsBytes(bytes);
      savedFilePath = file.path;

      if (isMp4) {
        final thumbPath = p.join(_imagesDir!.path, '${id}_thumb.jpg');
        try {
          await Process.run('ffmpeg', [
            '-y',
            '-i',
            file.path,
            '-ss',
            '00:00:00',
            '-vframes',
            '1',
            thumbPath,
          ]);
        } catch (_) {}
      }
    }
    await db.update(
      'generations',
      {
        'status': status.name,
        'image_path': savedFilePath,
        'seed': seed,
        'inference_time_ms': durationMs,
        'active_loras': jsonEncode(loras.map(
            (k, v) => MapEntry(k, {'path': v.path, 'weight': v.weight}))),
        'error_message': error,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    return savedFilePath;
  }
}
