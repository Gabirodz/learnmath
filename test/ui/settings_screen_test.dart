import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/core/models.dart';
import 'package:learnmath/core/providers.dart';
import 'package:learnmath/tts/on_device_tts.dart';
import 'package:learnmath/ui/settings_screen.dart';

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();

  @override
  Future<void> update(AppSettings Function(AppSettings) change) async {
    state = change(state);
  }
}

late Directory _tmp;
late ProviderContainer _container;

Future<void> _pump(
  WidgetTester tester, {
  AppSettings? initial,
  Size size = const Size(320, 640),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  _tmp = Directory.systemTemp.createTempSync('settings_test');
  addTearDown(() => _tmp.deleteSync(recursive: true));
  _container = ProviderContainer(
    overrides: [
      settingsProvider.overrideWith(_Settings.new),
      voiceModelsProvider.overrideWithValue(VoiceModelManager(_tmp.path)),
    ],
  );
  addTearDown(_container.dispose);
  if (initial != null) {
    await _container.read(settingsProvider.notifier).update((_) => initial);
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: _container,
      child: MaterialApp(
        theme: ThemeData(colorSchemeSeed: Colors.indigo),
        home: const SettingsScreen(),
      ),
    ),
  );
  await _settleIo(tester);
}

/// Lets real file-system calls (the installed check) finish.
Future<void> _settleIo(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pumpAndSettle();
}

Future<void> _scrollTo(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(
    f,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

AppSettings get _s => _container.read(settingsProvider);

Future<void> _choose(WidgetTester tester, Finder dropdown, String item) async {
  await tester.ensureVisible(dropdown);
  await tester.pumpAndSettle();
  await tester.tap(dropdown);
  await tester.pumpAndSettle();
  await tester.tap(find.text(item).last);
  await _settleIo(tester);
}

void main() {
  for (final (scale, words) in const [
    (0.75, 'Shorter pauses (0.75× the scripted length)'),
    (1.0, 'Pauses as the lecturer scripted them.'),
    (1.5, 'Longer pauses (1.5× the scripted length)'),
  ]) {
    testWidgets('pauses at $scale say in words what they do', (tester) async {
      await _pump(tester, initial: AppSettings(pauseScale: scale));
      await _scrollTo(tester, find.text('Thinking pauses'));
      expect(find.textContaining(words), findsOneWidget);
      expect(find.textContaining('does not change how fast the voice speaks'),
          findsOneWidget);
    });
  }

  testWidgets('default shows Sol batch preset and no custom fields', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.text('GPT-6.1 Sol (batch) · recommended'), findsOneWidget);
    expect(find.textContaining('Most accurate'), findsOneWidget);
    expect(
      find.textContaining('openai/gpt-6.1-sol · reasoning effort high'),
      findsOneWidget,
    );
    expect(find.textContaining('notification'), findsOneWidget);
    expect(find.text('Model'), findsNothing);
    expect(find.text('Use the Batch API'), findsNothing);
    expect(find.text('Reasoning effort'), findsOneWidget);
    expect(find.text('High · recommended'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the effort of a preset can be changed; another model starts '
      'from its own again', (tester) async {
    await _pump(tester);
    await _choose(tester, find.text('High · recommended'), 'Extra high');
    expect(_s.presetEffort, 'xhigh');
    expect(_s.lessonEffort, 'xhigh');
    expect(_s.lessonModel, 'openai/gpt-6.1-sol');

    await _choose(tester, find.text('Extra high'), 'Model default');
    expect(_s.lessonEffort, isNull);

    await tester.drag(find.byType(Scrollable).first, const Offset(0, 800));
    await tester.pumpAndSettle();
    await _choose(
        tester, find.text('GPT-6.1 Sol (batch) · recommended'), 'GPT-6.1 Terra (batch)');
    expect(_s.presetEffort, isNull);
    expect(_s.lessonEffort, 'high');
    expect(find.text('High · recommended'), findsOneWidget);
  });

  testWidgets('choosing Luna updates the lesson model', (tester) async {
    await _pump(tester);
    await _choose(tester, find.text('GPT-6.1 Sol (batch) · recommended'), 'GPT-6 Luna');
    expect(_s.lessonModel, 'openai/gpt-6-luna');
    expect(_s.lessonBatch, isFalse);
    expect(find.textContaining('notification'), findsNothing);
  });

  testWidgets('custom model reveals fields and batch toggle works', (
    tester,
  ) async {
    await _pump(tester);
    await _choose(tester, find.text('GPT-6.1 Sol (batch) · recommended'), 'Custom model…');
    expect(_s.lessonPreset, LessonModelPreset.customId);
    expect(find.text('Model'), findsOneWidget);
    expect(find.text('Use the Batch API'), findsOneWidget);
    expect(find.text('Reasoning effort'), findsOneWidget);
    expect(find.text('Model default'), findsOneWidget);

    final sw = find.widgetWithText(SwitchListTile, 'Use the Batch API');
    await tester.ensureVisible(sw);
    await tester.tap(sw);
    await tester.pumpAndSettle();
    expect(_s.customBatch, isTrue);
    expect(_s.lessonBatch, isTrue);

    await _choose(tester, find.text('Model default'), 'High · recommended');
    expect(_s.customEffort, 'high');
    expect(_s.lessonEffort, 'high');
  });

  testWidgets('switching voice model resets speaker and shows size', (
    tester,
  ) async {
    await _pump(
      tester,
      initial: const AppSettings(voiceModel: 'kokoro', voiceSpeaker: 3),
      // Tall enough that the lazily built list holds the voice dropdown and
      // the install row below it at the same time.
      size: const Size(320, 2400),
    );
    expect(find.textContaining('about 103 MB'), findsOneWidget);
    await _choose(tester, find.text('Kokoro').first, 'Kitten Nano 0.8');
    expect(_s.voiceModel, 'kitten-nano');
    expect(_s.voiceSpeaker, 0);
    expect(_s.ttsBackend, TtsBackend.onDevice);
    expect(find.textContaining('about 31 MB'), findsOneWidget);
    expect(find.text('Download'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no overflow at 320x640 with custom model and OpenRouter voice', (
    tester,
  ) async {
    await _pump(
      tester,
      initial: const AppSettings(
        lessonPreset: LessonModelPreset.customId,
        customBatch: true,
      ),
    );
    expect(tester.takeException(), isNull);
    await _scrollTo(tester, find.text('About'));
    expect(tester.takeException(), isNull);
    await tester.drag(find.byType(ListView), const Offset(0, 3000));
    await tester.pumpAndSettle();
    final seg = find.descendant(
      of: find.byType(SegmentedButton<TtsBackend>),
      matching: find.text('OpenRouter'),
    );
    await _scrollTo(tester, seg);
    await tester.tap(seg);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('the verify switch reveals the verifier model field', (
    tester,
  ) async {
    await _pump(tester);
    final sw = find.widgetWithText(
        SwitchListTile, 'Verify proofs with a second model');
    await _scrollTo(tester, sw);
    expect(_s.verifyProofs, isFalse);
    expect(find.text('Verifier model'), findsNothing);
    expect(
        find.textContaining('referees every new lesson'), findsOneWidget);

    await tester.tap(sw);
    await tester.pumpAndSettle();
    expect(_s.verifyProofs, isTrue);
    final field = find.widgetWithText(TextField, 'Verifier model');
    expect(field, findsOneWidget);
    expect(
        tester.widget<TextField>(field).controller!.text,
        AppSettings.defaultVerifierModel);

    // Edits are saved after a pause; empty input falls back to the default.
    await tester.enterText(field, ' acme/ref ');
    await tester.pump(const Duration(milliseconds: 500));
    expect(_s.verifierModel, 'acme/ref');
    await tester.enterText(field, '');
    await tester.pump(const Duration(milliseconds: 500));
    expect(_s.verifierModel, AppSettings.defaultVerifierModel);

    await tester.tap(sw);
    await tester.pumpAndSettle();
    expect(_s.verifyProofs, isFalse);
    expect(find.text('Verifier model'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
