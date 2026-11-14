import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/core/models.dart';
import 'package:learnmath/player/mini_player.dart';
import 'package:learnmath/player/player_controls.dart';
import 'package:learnmath/player/player_view.dart';
import 'package:learnmath/player/reexplain.dart';

class FakeControls implements PlayerControls {
  @override
  final ValueNotifier<Lesson?> lesson = ValueNotifier<Lesson?>(
    Lesson(
      id: 'l1',
      title: 'Compactness and the Heine-Borel theorem for metric spaces',
      brief: '',
      createdAt: DateTime(2026),
    ),
  );
  final _playing = StreamController<bool>.broadcast();
  int toggles = 0, stops = 0;
  @override
  bool playing = false;
  @override
  Stream<bool> get playingStream => _playing.stream;
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  Duration get position => const Duration(seconds: 30);
  @override
  Duration get duration => const Duration(seconds: 60);
  @override
  Future<void> toggle() async {
    toggles++;
    playing = !playing;
    _playing.add(playing);
  }

  @override
  Future<void> stop() async {
    stops++;
    lesson.value = null;
  }
}

void main() {
  testWidgets('shows the title and toggles play/pause', (tester) async {
    final c = FakeControls();
    Lesson? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: MiniPlayer(
            controls: c,
            onOpen: (l) => opened = l,
          ),
        ),
      ),
    );
    expect(find.textContaining('Compactness'), findsOneWidget);
    expect(find.byTooltip('Play'), findsOneWidget);
    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    expect(c.toggles, 1);
    expect(find.byTooltip('Pause'), findsOneWidget);

    await tester.tap(find.textContaining('Compactness'));
    expect(opened?.id, 'l1');

    await tester.tap(find.byTooltip('Stop and close the player'));
    await tester.pump();
    expect(c.stops, 1);
    expect(find.textContaining('Compactness'), findsNothing);
  });

  testWidgets('fits 320 dp wide', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: MiniPlayer(
            controls: FakeControls(),
            onOpen: (_) {},
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('transport row does not overflow at 320 dp', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TransportButtons(
            stateStream: const Stream.empty(),
            onPrevious: () {},
            onToggle: () {},
            onNext: () {},
            onAsk: () {},
            reexplain: ValueNotifier<ReexplainState>(const ReexplainIdle()),
            onExplainAgain: () {},
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('Explain this again differently'), findsOneWidget);
    for (final b in tester.widgetList<IconButton>(find.byType(IconButton))) {
      expect(b.constraints, isNull); // default 48 dp minimum tap target
    }
    final box = tester.getRect(find.byType(TransportButtons));
    expect(box.right, lessThanOrEqualTo(320));
  });
}
