import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'app.dart';
import 'core/providers.dart';
import 'core/storage.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Lock-screen / notification controls and playback while the app is in the
  // background.
  await JustAudioBackground.init(
    androidNotificationChannelId: 'dev.axel.learnmath.audio',
    androidNotificationChannelName: 'Lecture playback',
    androidNotificationOngoing: true,
  );

  final paths = await AppPaths.resolve();
  final db = await openAppDatabase(paths);
  final settingsStore = SettingsStore(db);
  final services = AppServices(
    paths: paths,
    repo: LibraryRepository(db, paths),
    settingsStore: settingsStore,
    initialSettings: await settingsStore.load(),
  );

  final container = ProviderContainer(
    overrides: [appServicesProvider.overrideWithValue(services)],
  );
  await container.read(generationProvider).recoverInterrupted();

  runApp(UncontrolledProviderScope(
    container: container,
    child: const LearnMathApp(),
  ));
}
