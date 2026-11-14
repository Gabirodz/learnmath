import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sembast/sembast.dart';

import '../checks/math_check.dart';
import '../checks/pyodide_runner.dart';
import '../notify/notifications.dart';
import '../pipeline/generation_service.dart';
import '../player/lecture_player.dart';
import '../tts/on_device_tts.dart';
import 'models.dart';
import 'storage.dart';

/// Opened in `main()` and injected through overrides.
class AppServices {
  const AppServices({
    required this.paths,
    required this.db,
    required this.repo,
    required this.settingsStore,
    required this.initialSettings,
  });

  final AppPaths paths;
  final Database db;
  final LibraryRepository repo;
  final SettingsStore settingsStore;
  final AppSettings initialSettings;
}

final appServicesProvider = Provider<AppServices>(
    (ref) => throw UnimplementedError('overridden in main()'));

final repositoryProvider =
    Provider<LibraryRepository>((ref) => ref.watch(appServicesProvider).repo);

final databaseProvider =
    Provider<Database>((ref) => ref.watch(appServicesProvider).db);

final appPathsProvider =
    Provider<AppPaths>((ref) => ref.watch(appServicesProvider).paths);

class SettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.watch(appServicesProvider).initialSettings;

  Future<void> update(AppSettings Function(AppSettings) change) async {
    state = change(state);
    await ref.read(appServicesProvider).settingsStore.save(state);
  }
}

final settingsProvider =
    NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);

final voiceModelsProvider = Provider<VoiceModelManager>(
    (ref) => VoiceModelManager(ref.watch(appPathsProvider).modelsDir));

/// Overridden in `main()` with the plugin-backed implementations.
final notificationsProvider =
    Provider<AppNotifications>((ref) => const NoNotifications());

final batchBackgroundProvider =
    Provider<BatchBackground>((ref) => const NoBatchBackground());

final keepAliveProvider =
    Provider<KeepAlive>((ref) => const NoKeepAlive());

/// SymPy runs in a hidden WebView, which only the mobile platforms have.
final checkRunnerFactoryProvider = Provider<MathCheckRunner Function()?>(
    (ref) => Platform.isAndroid || Platform.isIOS
        ? PyodideCheckRunner.new
        : null);

/// Live progress per lesson id while generation jobs run.
class JobProgressNotifier extends Notifier<Map<String, JobProgress>> {
  @override
  Map<String, JobProgress> build() => const {};

  void set(String lessonId, JobProgress? progress) {
    final next = {...state};
    if (progress == null) {
      next.remove(lessonId);
    } else {
      next[lessonId] = progress;
    }
    state = next;
  }
}

final jobProgressProvider =
    NotifierProvider<JobProgressNotifier, Map<String, JobProgress>>(
        JobProgressNotifier.new);

final generationProvider = Provider<GenerationService>((ref) {
  return GenerationService(
    repo: ref.watch(repositoryProvider),
    paths: ref.watch(appPathsProvider),
    readSettings: () => ref.read(settingsProvider),
    voices: ref.watch(voiceModelsProvider),
    onProgress: (id, p) => ref.read(jobProgressProvider.notifier).set(id, p),
    notifications: ref.watch(notificationsProvider),
    batchBackground: ref.watch(batchBackgroundProvider),
    keepAlive: ref.watch(keepAliveProvider),
    createCheckRunner: ref.watch(checkRunnerFactoryProvider),
  );
});

final coursesProvider = StreamProvider<List<Course>>(
    (ref) => ref.watch(repositoryProvider).watchCourses());

final courseProvider = StreamProvider.family<Course?, String>(
    (ref, id) => ref.watch(repositoryProvider).watchCourse(id));

final standaloneLessonsProvider = StreamProvider<List<Lesson>>(
    (ref) => ref.watch(repositoryProvider).watchLessons());

final courseLessonsProvider = StreamProvider.family<List<Lesson>, String>(
    (ref, courseId) =>
        ref.watch(repositoryProvider).watchLessons(courseId: courseId));

final lessonProvider = StreamProvider.family<Lesson?, String>(
    (ref, id) => ref.watch(repositoryProvider).watchLesson(id));

/// One player for the whole app so audio keeps going across screens.
final lecturePlayerProvider = Provider<LecturePlayer>((ref) {
  final player = LecturePlayer(
    ref.watch(repositoryProvider),
    autoPlayNext: () => ref.read(settingsProvider).autoPlayNext,
    speed: () => ref.read(settingsProvider).playbackSpeed,
  );
  ref.onDispose(player.dispose);
  return player;
});
