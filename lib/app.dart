import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'books/import_screen.dart';
import 'ui/course_screen.dart';
import 'ui/lesson_screen.dart';
import 'ui/library_screen.dart';
import 'ui/settings_screen.dart';

final _router = GoRouter(
  routes: [
    GoRoute(path: '/', builder: (_, _) => const LibraryScreen()),
    GoRoute(
      path: '/course/:id',
      builder: (_, state) => CourseScreen(courseId: state.pathParameters['id']!),
    ),
    GoRoute(
      path: '/lesson/:id',
      builder: (_, state) => LessonScreen(lessonId: state.pathParameters['id']!),
    ),
    GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
    GoRoute(path: '/import-book', builder: (_, _) => const BookImportScreen()),
  ],
);

class LearnMathApp extends StatelessWidget {
  const LearnMathApp({super.key});

  static const _seed = Color(0xFF3F51B5);

  ThemeData _theme(Brightness brightness) => ThemeData(
        colorScheme:
            ColorScheme.fromSeed(seedColor: _seed, brightness: brightness),
        useMaterial3: true,
      );

  @override
  Widget build(BuildContext context) => MaterialApp.router(
        title: 'LearnMath',
        debugShowCheckedModeBanner: false,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        routerConfig: _router,
      );
}
