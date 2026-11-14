import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'app.dart';
import 'core/providers.dart';
import 'core/storage.dart';
import 'notify/background_batches.dart';
import 'notify/keep_alive_service.dart';
import 'notify/local_notifications.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Lock-screen / notification controls and playback while the app is in the
  // background.
  await JustAudioBackground.init(
    androidNotificationChannelId: 'dev.axel.learnmath.audio',
    androidNotificationChannelName: 'Lecture playback',
    androidNotificationOngoing: true,
  );

  // Lessons written through the Batch API arrive long after the user has
  // left the screen, so the app tells them with a notification, and keeps
  // checking for the answer while it is not running.
  final notifications = LocalNotifications(
    onOpenLesson: (id) => appRouter.push('/lesson/$id'),
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
    ],
  );
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
  if (launched != null) {
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => appRouter.push('/lesson/$launched'));
  }
}
