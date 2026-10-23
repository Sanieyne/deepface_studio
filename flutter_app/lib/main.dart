import 'dart:io';
import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'screens/deepface_home_screen.dart';
import 'services/auth_service.dart';
import 'services/database_service.dart';
import 'theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Desktop SQLite initialisation
  if (Platform.isWindows || Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  // Initialise secure session & local DB
  await DatabaseService.instance.init();
  await AuthService.instance.init();

  runApp(const DeepFaceApp());
}

class DeepFaceApp extends StatefulWidget {
  const DeepFaceApp({super.key});

  @override
  State<DeepFaceApp> createState() => _DeepFaceAppState();
}

class _DeepFaceAppState extends State<DeepFaceApp> {
  bool _isDark = true;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cosmic-Gen DeepFace Studio',
      debugShowCheckedModeBanner: false,
      theme: LuminaTheme.lightTheme,
      darkTheme: LuminaTheme.darkTheme,
      themeMode: _isDark ? ThemeMode.dark : ThemeMode.light,
      home: DeepFaceHomeScreen(
        isDark: _isDark,
        onThemeToggle: () => setState(() => _isDark = !_isDark),
      ),
    );
  }
}
