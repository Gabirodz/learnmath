import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/core/models.dart';
import 'package:learnmath/ui/model_picker.dart';

ModelChoice? last;

Widget host(ModelChoice initial, {bool allowBatch = false}) {
  var value = initial;
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: StatefulBuilder(
          builder: (context, setState) => ModelPicker(
            value: value,
            allowBatch: allowBatch,
            onChanged: (c) => setState(() {
              value = c;
              last = c;
            }),
          ),
        ),
      ),
    ),
  );
}

Future<void> _choose(WidgetTester tester, Finder dropdown, String item) async {
  await tester.ensureVisible(dropdown);
  await tester.pumpAndSettle();
  await tester.tap(dropdown);
  await tester.pumpAndSettle();
  await tester.tap(find.text(item).last);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => last = null);

  testWidgets('batch picker shows the batch preset and opens its menu',
      (tester) async {
    await tester.pumpWidget(host(
      const ModelChoice(
          model: 'openai/gpt-6.1-sol', effort: 'high', batch: true),
      allowBatch: true,
    ));
    expect(find.text('GPT-6.1 Sol (batch) · recommended'), findsOneWidget);
    expect(find.text('High · recommended'), findsOneWidget);
    expect(find.text('Model id'), findsNothing);
    expect(find.text('Use the Batch API'), findsNothing);

    await tester.tap(find.text('GPT-6.1 Sol (batch) · recommended'));
    await tester.pumpAndSettle();
    expect(find.text('GPT-6.1 Terra (batch)'), findsOneWidget);
    expect(find.text('GPT-6 Luna (batch)'), findsOneWidget);
    expect(find.text('GPT-6 Luna (immediate)'), findsOneWidget);
    expect(find.text('Custom model…'), findsOneWidget);

    await tester.tap(find.text('GPT-6.1 Terra (batch)').last);
    await tester.pumpAndSettle();
    expect(
        last,
        const ModelChoice(
            model: 'openai/gpt-6.1-terra', effort: 'high', batch: true));
    expect(tester.takeException(), isNull);
  });

  testWidgets('batch and immediate Luna keep the effort and switch batch',
      (tester) async {
    await tester.pumpWidget(host(
      const ModelChoice(
          model: 'openai/gpt-6.1-sol', effort: 'high', batch: true),
      allowBatch: true,
    ));
    await _choose(tester, find.text('GPT-6.1 Sol (batch) · recommended'),
        'GPT-6 Luna (batch)');
    expect(
        last,
        const ModelChoice(
            model: 'openai/gpt-6-luna', effort: 'high', batch: true));

    await _choose(tester, find.text('GPT-6 Luna (batch)'),
        'GPT-6 Luna (immediate)');
    expect(
        last,
        const ModelChoice(model: 'openai/gpt-6-luna', effort: 'high'));
    expect(last!.batch, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('without batch the menu offers no batch presets',
      (tester) async {
    await tester.pumpWidget(host(
      const ModelChoice(model: 'openai/gpt-6.1-sol', effort: 'high'),
    ));
    expect(find.text('GPT-6.1 Sol · recommended'), findsOneWidget);
    expect(find.textContaining('(batch)'), findsNothing);

    await tester.tap(find.text('GPT-6.1 Sol · recommended'));
    await tester.pumpAndSettle();
    expect(find.text('GPT-6.1 Terra'), findsOneWidget);
    expect(find.text('GPT-6 Luna'), findsOneWidget);
    expect(find.text('Custom model…'), findsOneWidget);
    expect(find.textContaining('(batch)'), findsNothing);
    expect(find.textContaining('(immediate)'), findsNothing);

    await tester.tap(find.text('GPT-6 Luna').last);
    await tester.pumpAndSettle();
    expect(
        last, const ModelChoice(model: 'openai/gpt-6-luna', effort: 'high'));
    expect(last!.batch, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('effort can be changed and reset to model default',
      (tester) async {
    await tester.pumpWidget(host(
      const ModelChoice(model: 'openai/gpt-6.1-sol', effort: 'high'),
    ));
    await _choose(tester, find.text('High · recommended'), 'Extra high');
    expect(last!.effort, 'xhigh');
    expect(last!.model, 'openai/gpt-6.1-sol');

    await _choose(tester, find.text('Extra high'), 'Model default');
    expect(last!.effort, isNull);
    expect(last!.model, 'openai/gpt-6.1-sol');
    expect(tester.takeException(), isNull);
  });

  testWidgets('custom model with batch: id field and batch switch stay',
      (tester) async {
    await tester.pumpWidget(host(
      const ModelChoice(
          model: 'openai/gpt-6.1-sol', effort: 'high', batch: true),
      allowBatch: true,
    ));
    await _choose(tester, find.text('GPT-6.1 Sol (batch) · recommended'),
        'Custom model…');
    expect(find.widgetWithText(TextField, 'Model id'), findsOneWidget);
    expect(find.widgetWithText(SwitchListTile, 'Use the Batch API'),
        findsOneWidget);

    await tester.enterText(
        find.widgetWithText(TextField, 'Model id'), 'acme/big-model');
    await tester.pump();
    expect(last!.model, 'acme/big-model');
    final before = last!.batch;

    await tester.tap(find.widgetWithText(SwitchListTile, 'Use the Batch API'));
    await tester.pumpAndSettle();
    expect(last!.batch, !before);
    expect(last!.model, 'acme/big-model');

    // Still in custom mode: the id field is not replaced by a preset.
    expect(find.widgetWithText(TextField, 'Model id'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('custom model without batch: id field, no batch switch',
      (tester) async {
    await tester.pumpWidget(host(
      const ModelChoice(model: 'openai/gpt-6.1-sol', effort: 'high'),
    ));
    await _choose(tester, find.text('GPT-6.1 Sol · recommended'),
        'Custom model…');
    expect(find.text('Model id'), findsOneWidget);
    expect(find.text('Use the Batch API'), findsNothing);

    await tester.enterText(
        find.widgetWithText(TextField, 'Model id'), 'acme/x');
    await tester.pump();
    expect(last!.model, 'acme/x');
    expect(last!.batch, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a model that is not a preset starts in custom mode',
      (tester) async {
    await tester.pumpWidget(host(
      const ModelChoice(model: 'acme/m', effort: null),
    ));
    expect(find.text('Model id'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'acme/m'), findsOneWidget);
    expect(find.text('Model default'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ModelButton shows the model and picks one in a sheet',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ModelButton(
          title: 'Chat model',
          value: const ModelChoice(
              model: 'openai/gpt-6.1-terra', effort: 'high'),
          onChanged: (c) => last = c,
        ),
      ),
    ));
    expect(find.text('GPT-6.1 Terra · high'), findsOneWidget);

    await tester.tap(find.text('GPT-6.1 Terra · high'));
    await tester.pumpAndSettle();
    expect(find.text('Chat model'), findsOneWidget);
    expect(find.byType(ModelPicker), findsOneWidget);

    await _choose(tester, find.text('GPT-6.1 Terra').last, 'GPT-6 Luna');
    expect(
        last, const ModelChoice(model: 'openai/gpt-6-luna', effort: 'high'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('custom + batch layout does not overflow at 320x640',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(
      const ModelChoice(
          model: 'openai/gpt-6.1-sol', effort: 'high', batch: true),
      allowBatch: true,
    ));
    await _choose(tester, find.text('GPT-6.1 Sol (batch) · recommended'),
        'Custom model…');
    expect(find.widgetWithText(SwitchListTile, 'Use the Batch API'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('plain functions', () {
    test('effortLabel', () {
      expect(effortLabel(''), 'Model default');
      expect(effortLabel('xhigh'), 'Extra high');
      expect(effortLabel('high'), 'High');
    });

    test('ModelChoice.label', () {
      expect(
        const ModelChoice(
                model: 'openai/gpt-6.1-sol', effort: 'high', batch: true)
            .label,
        'GPT-6.1 Sol (batch) · high',
      );
      expect(const ModelChoice(model: 'acme/m').label, 'acme/m');
    });
  });
}
