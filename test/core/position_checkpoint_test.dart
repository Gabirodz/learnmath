import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/core/models.dart';

import '../pipeline/fakes.dart';

void main() {
  late Env env;
  setUp(() async {
    env = Env();
    await env.init();
  });
  tearDown(() => env.dispose());

  test('a checkpoint does not touch the lesson record or its watchers',
      () async {
    await env.repo.saveLesson(
        Lesson(id: 'a', title: 'A', brief: '', createdAt: DateTime(2026)));
    final seen = <List<Lesson>>[];
    final sub = env.repo.watchLessons().listen(seen.add);
    await pumpEventQueue();
    final before = seen.length;

    await env.repo.checkpointPosition('a', 12000);
    await env.repo.checkpointPosition('a', 17000);
    await pumpEventQueue();

    expect(seen, hasLength(before));
    expect(await env.repo.positionCheckpoint('a'), 17000);
    expect((await env.lesson('a')).lastPositionMs, 0);
    await sub.cancel();
  });

  test('cleared explicitly and with the lesson', () async {
    await env.repo.saveLesson(
        Lesson(id: 'a', title: 'A', brief: '', createdAt: DateTime(2026)));
    await env.repo.checkpointPosition('a', 5000);
    await env.repo.clearPositionCheckpoint('a');
    expect(await env.repo.positionCheckpoint('a'), isNull);

    await env.repo.checkpointPosition('a', 5000);
    await env.repo.deleteLesson('a');
    expect(await env.repo.positionCheckpoint('a'), isNull);
  });
}
