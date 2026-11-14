// Live check of OpenRouter's Batch API: submits one tiny batch, polls until
// it finishes (up to 30 minutes), checks the answer and deletes the batch.
// Costs a fraction of a cent. Skipped unless OPENROUTER_API_KEY is set.
@TestOn('vm')
@Timeout(Duration(minutes: 35))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/ai/openrouter_client.dart';

void main() {
  final key = Platform.environment['OPENROUTER_API_KEY'];

  test('one tiny batch is submitted, completes and is deleted', () async {
    final client = OpenRouterClient(apiKey: key!);
    String? id;
    try {
      final created = await client.createBatch(
        model: 'openai/gpt-6.1-sol',
        requests: const [
          BatchRequest(
              customId: 'live:0',
              messages: [ChatMessage.user('Reply with the word blue.')]),
        ],
      );
      id = created.id;
      expect(id, isNotEmpty);
      expect(created.isTerminal, isFalse);

      final deadline = DateTime.now().add(const Duration(minutes: 30));
      var info = created;
      while (!info.isTerminal) {
        if (DateTime.now().isAfter(deadline)) {
          fail('batch $id did not finish within 30 minutes '
              '(last status: ${info.status})');
        }
        await Future<void>.delayed(const Duration(seconds: 20));
        info = await client.getBatch(id);
      }

      expect(info.status, 'completed', reason: info.error);
      expect(info.isDone, isTrue);
      final result = info.results['live:0'];
      expect(result, isNotNull);
      expect(result!.error, isNull);
      expect(result.text!.toLowerCase(), contains('blue'));
    } finally {
      if (id != null) await client.deleteBatch(id);
      client.close();
    }
  }, skip: key == null || key.isEmpty ? 'OPENROUTER_API_KEY not set' : false);
}
