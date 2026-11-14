import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/core/models.dart';
import 'package:learnmath/player/next_lesson.dart';

Lesson lesson(
  String id,
  int order, {
  String? courseId = 'c',
  bool audio = true,
  LessonStage? stage,
}) => Lesson(
  id: id,
  title: id,
  brief: '',
  createdAt: DateTime(2026),
  courseId: courseId,
  order: order,
  stage: stage ?? (audio ? LessonStage.ready : LessonStage.pending),
  audioPath: audio ? '/x/$id.wav' : null,
  segments: audio ? const [NarrationSegment(say: 'hi')] : const [],
);

void main() {
  test('picks the next lesson with audio', () {
    final ls = [lesson('a', 0), lesson('b', 1), lesson('c', 2)];
    expect(nextToPlay(ls[0], ls)?.id, 'b');
  });

  test('skips lessons without a recording', () {
    final ls = [
      lesson('a', 0),
      lesson('b', 1, audio: false),
      lesson('c', 2, audio: true, stage: LessonStage.failed),
      lesson('d', 3),
    ];
    expect(nextToPlay(ls[0], ls)?.id, 'd');
  });

  test('last lesson has no successor', () {
    final ls = [lesson('a', 0), lesson('b', 1), lesson('c', 2, audio: false)];
    expect(nextToPlay(ls[1], ls), isNull);
  });

  test('standalone lessons have no successor', () {
    final a = lesson('a', 0, courseId: null);
    expect(nextToPlay(a, [a, lesson('b', 1, courseId: null)]), isNull);
  });

  test('goes by order, not list position', () {
    final ls = [lesson('c', 2), lesson('b', 1), lesson('a', 0)];
    expect(nextToPlay(ls[2], ls)?.id, 'b');
    expect(nextToPlay(ls[1], ls)?.id, 'c');
  });
}
