import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:audio_service/audio_service.dart';

import 'app.dart';
import 'core/licenses.dart';
import 'core/providers.dart';
import 'core/storage.dart';
import 'notify/background_batches.dart';
import 'notify/keep_alive_service.dart';
import 'notify/local_notifications.dart';
import 'player/lecture_audio_handler.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerAppLicenses();
  // The lecture as a media session: notification and lock-screen controls,
  // Bluetooth and headset buttons, playback while the app is in the
  // background. The lecture player attaches itself when it is created.
  final media = await AudioService.init(
    builder: LectureAudioHandler.new,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'dev.axel.learnmath.audio',
      androidNotificationChannelName: 'Lecture playback',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
    ),
  );

  // Lessons written through the Batch API arrive long after the user has
  // left the screen, so the app tells them with a notification, and keeps
  // checking for the answer while it is not running.
  final notifications = LocalNotifications(
    onOpenLesson: (id) => appRouter.push('/lesson/$id'),
    onOpenCourse: (id) => appRouter.push('/course/$id'),
    onOpenQuiz: (id) => appRouter.push('/lesson/$id?tab=quiz'),
    isForeground: () {
      final state = WidgetsBinding.instance.lifecycleState;
      return state == null || state == AppLifecycleState.resumed;
    },
  );
  await notifications.init();
  await WorkmanagerBatchBackground.initialize();
  // Generation goes on with the screen off or the app in the background.
  await ForegroundKeepAlive.initialize();

  final paths = await AppPaths.resolve();
  final db = await openAppDatabase(paths);
  final settingsStore = SettingsStore(db);
  final services = AppServices(
    paths: paths,
    db: db,
    repo: LibraryRepository(db, paths),
    settingsStore: settingsStore,
    initialSettings: await settingsStore.load(),
  );

  final container = ProviderContainer(
    overrides: [
      appServicesProvider.overrideWithValue(services),
      notificationsProvider.overrideWithValue(notifications),
      batchBackgroundProvider.overrideWithValue(WorkmanagerBatchBackground()),
      keepAliveProvider.overrideWithValue(ForegroundKeepAlive()),
      mediaHandlerProvider.overrideWithValue(media),
    ],
  );
  // Tapping the media notification opens the lesson that is playing.
  AudioService.notificationClicked.where((clicked) => clicked).listen((_) {
    final id = container.read(lecturePlayerProvider).lesson.value?.id;
    if (id == null) return;
    final path = '/lesson/$id';
    if (appRouter.routerDelegate.currentConfiguration.uri.path != path) {
      appRouter.push(path);
    }
  });
  final generation = container.read(generationProvider);
  await generation.recoverInterrupted();
  // Timers do not run while Android keeps the app frozen in the background,
  // so look for finished batches as soon as the user comes back.
  AppLifecycleListener(onResume: () {
    generation.pollBatches();
    generation.makeDueRecaps();
  });
  unawaited(generation.makeDueRecaps());

  runApp(UncontrolledProviderScope(
    container: container,
    child: const LearnMathApp(),
  ));

  final launched = notifications.launchLessonId;
  final launchedCourse = notifications.launchCourseId;
  if (launched != null) {
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => appRouter.push('/lesson/$launched'));
  } else if (launchedCourse != null) {
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => appRouter.push('/course/$launchedCourse'));
  } else if (notifications.launchQuizLessonId case final quizLesson?) {
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => appRouter.push('/lesson/$quizLesson?tab=quiz'));
  }
}
