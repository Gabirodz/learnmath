import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/notify/keep_alive_service.dart';

class _Fake {
  final calls = <String>[];
  bool running = false;
  bool failStart = false;

  late final keepAlive = ForegroundKeepAlive(
    isRunning: () async {
      await Future<void>.delayed(Duration.zero);
      return running;
    },
    start: (s) async {
      calls.add('start:$s');
      await Future<void>.delayed(Duration.zero);
      if (failStart) throw StateError('refused');
      running = true;
    },
    update: (s) async {
      calls.add('update:$s');
      await Future<void>.delayed(Duration.zero);
    },
    stop: () async {
      calls.add('stop');
      await Future<void>.delayed(Duration.zero);
      running = false;
    },
  );
}

void main() {
  test('first hold starts once', () async {
    final f = _Fake();
    await f.keepAlive.hold('a');
    expect(f.calls, ['start:a']);
  });

  test('same status does nothing', () async {
    final f = _Fake();
    await f.keepAlive.hold('a');
    await f.keepAlive.hold('a');
    expect(f.calls, ['start:a']);
  });

  test('changed status updates without restarting', () async {
    final f = _Fake();
    await f.keepAlive.hold('a');
    await f.keepAlive.hold('b');
    expect(f.calls, ['start:a', 'update:b']);
  });

  test('release stops', () async {
    final f = _Fake();
    await f.keepAlive.hold('a');
    await f.keepAlive.release();
    expect(f.calls, ['start:a', 'stop']);
    expect(f.running, isFalse);
  });

  test('release when not running does nothing', () async {
    final f = _Fake();
    await f.keepAlive.release();
    expect(f.calls, isEmpty);
  });

  test('hold, release, hold in quick succession ends with last status',
      () async {
    final f = _Fake();
    final k = f.keepAlive;
    final all = [k.hold('a'), k.release(), k.hold('b')];
    await Future.wait(all);
    expect(f.calls, ['start:a', 'stop', 'start:b']);
    expect(f.running, isTrue);
  });

  test('throwing start does not throw and a later hold retries', () async {
    final f = _Fake()..failStart = true;
    await f.keepAlive.hold('a');
    expect(f.running, isFalse);
    f.failStart = false;
    await f.keepAlive.hold('a');
    expect(f.calls, ['start:a', 'start:a']);
    expect(f.running, isTrue);
  });
}
