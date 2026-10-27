// Separate entry point for trying the Quran AI Teacher (Stage 1) without
// touching the existing app's navigation:
//   flutter run -t lib/main_ai_teacher.dart
import 'package:flutter/material.dart';

import 'main.dart' show settings;
import 'quran_ai_teacher.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await settings.load();
  runApp(const _TeacherApp());
}

class _TeacherApp extends StatelessWidget {
  const _TeacherApp();

  ThemeData _theme(Brightness b) => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF1E7A3E), brightness: b),
      );

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'مامۆستای قورئان',
      themeMode: settings.dark ? ThemeMode.dark : ThemeMode.light,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      builder: (context, child) => Directionality(
        textDirection: TextDirection.rtl,
        child: child ?? const SizedBox.shrink(),
      ),
      home: const QuranAiTeacherPage(),
    );
  }
}
