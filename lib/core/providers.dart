import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../pipeline/generation_service.dart';
import '../player/lecture_player.dart';
import '../tts/kokoro_engine.dart';
import 'models.dart';
import 'storage.dart';

/// Opened in `main()` and injected through overrides.
class AppServices {
  const AppServices({
    required this.paths,
    required this.repo,
    required this.settingsStore,
    required this.initialSettings,
  });

  final AppPaths paths;
  final LibraryRepository repo;
  final SettingsStore settingsStore;
  final AppSettings initialSettings;
}

final appServicesProvider = Provider<AppServices>(
    (ref) => throw UnimplementedError('overridden in main()'));

final repositoryProvider =
    Provider<LibraryRepository>((ref) => ref.watch(appServicesProvider).repo);

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

final kokoroModelProvider = Provider<KokoroModelManager>(
    (ref) => KokoroModelManager(ref.watch(appPathsProvider).modelsDir));

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
    kokoro: ref.watch(kokoroModelProvider),
    onProgress: (id, p) => ref.read(jobProgressProvider.notifier).set(id, p),
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
  final player = LecturePlayer(ref.watch(repositoryProvider));
  ref.onDispose(player.dispose);
  return player;
});
