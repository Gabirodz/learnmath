import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/ai/openrouter_client.dart';
import 'package:learnmath/notify/background_batches.dart';
import 'package:learnmath/notify/notifications.dart';

WaitingBatch w(String batch, String lesson) =>
    WaitingBatch(batchId: batch, lessonId: lesson, lessonTitle: 'T $lesson');

void main() {
  Future<BatchInfo> Function(String) statuses(Map<String, String> m,
      [List<String>? asked]) {
    return (id) async {
      asked?.add(id);
      return BatchInfo(id: id, status: m[id]!);
    };
  }

  test('announces a terminal batch once', () async {
    final get = statuses({'b1': 'completed'});
    final r1 = await checkWaitingBatches(
        waiting: [w('b1', 'l1')], announced: {}, getBatch: get);
    expect(r1.announce.map((e) => e.lessonId), ['l1']);
    expect(r1.announced, {'b1'});
    final r2 = await checkWaitingBatches(
        waiting: [w('b1', 'l1')], announced: r1.announced, getBatch: get);
    expect(r2.announce, isEmpty);
    expect(r2.announced, {'b1'});
  });

  test('does not announce a batch still running', () async {
    final r = await checkWaitingBatches(
        waiting: [w('b1', 'l1')],
        announced: {},
        getBatch: statuses({'b1': 'in_progress'}));
    expect(r.announce, isEmpty);
    expect(r.announced, isEmpty);
  });

  test('failed batches count as arrived', () async {
    final r = await checkWaitingBatches(
        waiting: [w('b1', 'l1')],
        announced: {},
        getBatch: statuses({'b1': 'failed'}));
    expect(r.announce, hasLength(1));
  });

  test('prunes announced ids that are no longer waiting', () async {
    final r = await checkWaitingBatches(
        waiting: [w('b2', 'l2')],
        announced: {'b1', 'b2'},
        getBatch: statuses({'b2': 'completed'}));
    expect(r.announced, {'b2'});
    expect(r.announce, isEmpty);
  });

  test('one status request per batch id, one announcement per lesson',
      () async {
    final asked = <String>[];
    final r = await checkWaitingBatches(
        waiting: [w('b1', 'l1'), w('b1', 'l2')],
        announced: {},
        getBatch: statuses({'b1': 'completed'}, asked));
    expect(asked, ['b1']);
    expect(r.announce.map((e) => e.lessonId), ['l1', 'l2']);
  });

  test('an error for one batch does not stop the others', () async {
    final r = await checkWaitingBatches(
        waiting: [w('bad', 'l1'), w('b2', 'l2')],
        announced: {},
        getBatch: (id) async {
          if (id == 'bad') throw OpenRouterException('boom', statusCode: 500);
          return BatchInfo(id: id, status: 'completed');
        });
    expect(r.announce.map((e) => e.lessonId), ['l2']);
    expect(r.announced, {'b2'});
  });

  test('WaitingBatch JSON round trip', () {
    final b = w('b1', 'l1');
    final back = WaitingBatch.fromJson(b.toJson())!;
    expect(back.batchId, 'b1');
    expect(back.lessonId, 'l1');
    expect(back.lessonTitle, 'T l1');
    expect(WaitingBatch.fromJson('nope'), isNull);
    expect(WaitingBatch.fromJson({'batchId': 'x'}), isNull);
  });
}
