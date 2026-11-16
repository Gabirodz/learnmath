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

/// Pages the settings screen asked the browser to open.
final _opened = <Uri>[];
bool _browserFails = false;

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
      linkOpenerProvider.overrideWithValue((url) async {
        if (_browserFails) throw StateError('no browser');
        _opened.add(url);
      }),
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
  setUp(() {
    _opened.clear();
    _browserFails = false;
  });

  testWidgets('About: the coffee and source buttons open their pages',
      (tester) async {
    await _pump(tester, size: const Size(400, 900));
    final coffee = find.text('Buy me a coffee');
    await tester.scrollUntilVisible(coffee, 300,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(coffee);
    await tester.pump();
    await tester.tap(find.text('Source code'));
    await tester.pump();
    expect(_opened.map((u) => u.toString()), [
      'https://buymeacoffee.com/gabirodz',
      'https://github.com/Gabirodz/learnmath',
    ]);
  });

  testWidgets('About: without a browser the address is shown instead',
      (tester) async {
    _browserFails = true;
    await _pump(tester, size: const Size(400, 900));
    final coffee = find.text('Buy me a coffee');
    await tester.scrollUntilVisible(coffee, 300,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(coffee);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.text('https://buymeacoffee.com/gabirodz'), findsOneWidget);
  });

  testWidgets('About shows the licence and opens the licences page',
      (tester) async {
    await _pump(tester, size: const Size(400, 900));
    final button = find.text('Open-source licences');
    await tester.scrollUntilVisible(button, 300,
        scrollable: find.byType(Scrollable).first);
    await tester.scrollUntilVisible(
        find.textContaining('GNU General Public License'), 100,
        scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(button);
    await tester.pump();
    await tester.tap(button);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(LicensePage), findsOneWidget);
    expect(find.text('LearnMath'), findsWidgets);
  });

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

  testWidgets('the model is not picked in Settings any more', (tester) async {
    await _pump(tester);
    expect(find.textContaining('The model is picked where it is used'),
        findsOneWidget);
    expect(find.text('Reasoning effort'), findsNothing);
    expect(find.textContaining('GPT-6.1 Sol'), findsNothing);
    expect(tester.takeException(), isNull);
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
