import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'books/import_screen.dart';
import 'ui/course_screen.dart';
import 'ui/import_lesson_screen.dart';
import 'ui/lesson_screen.dart';
import 'ui/library_screen.dart';
import 'ui/settings_screen.dart';

/// Shared so a tapped notification can open its lesson.
final appRouter = GoRouter(
  routes: [
    GoRoute(path: '/', builder: (_, _) => const LibraryScreen()),
    GoRoute(
      path: '/course/:id',
      builder: (_, state) => CourseScreen(courseId: state.pathParameters['id']!),
    ),
    GoRoute(
      path: '/lesson/:id',
      builder: (_, state) => LessonScreen(
        lessonId: state.pathParameters['id']!,
        quizTab: state.uri.queryParameters['tab'] == 'quiz',
      ),
    ),
    GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
    GoRoute(path: '/import-book', builder: (_, _) => const BookImportScreen()),
    GoRoute(
      path: '/import-lesson',
      builder: (_, state) => ImportLessonScreen(
        topic: state.uri.queryParameters['topic'] ?? '',
        lessonId: state.uri.queryParameters['lesson'],
      ),
    ),
    GoRoute(
      path: '/import-course',
      builder: (_, state) => ImportLessonScreen(
        topic: state.uri.queryParameters['topic'] ?? '',
        course: true,
        continues: state.uri.queryParameters['continues'],
      ),
    ),
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
        routerConfig: appRouter,
      );
}
