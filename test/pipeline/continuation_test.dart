import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/ai/prompts.dart';
import 'package:learnmath/core/models.dart';
import 'package:learnmath/player/next_lesson.dart';
import 'package:learnmath/ui/library_screen.dart' show seriesGroups;

import 'fakes.dart';

String _system(Map<String, Object?> body) =>
    '${((body['messages'] as List).first as Map)['content']}';
String _user(Map<String, Object?> body) =>
    '${((body['messages'] as List).last as Map)['content']}';

const _part2Plan = 'COURSE: Unbounded operators\n'
    'DESCRIPTION: Beyond bounded operators.\n'
    'LESSON: Closed operators\n'
    'BRIEF: Graphs and closedness.\n'
    'ASSUMES: E1, E2\n'
    'LESSON: Self-adjoint extensions\n'
    'BRIEF: Deficiency indices.\n'
    'ASSUMES: none\n';

const _part3Plan = 'COURSE: Spectral theory, unbounded\n'
    'DESCRIPTION: The spectral theorem for unbounded operators.\n'
    'LESSON: Resolvents\n'
    'BRIEF: Resolvent sets.\n'
    'ASSUMES: E1, E3\n';

void main() {
  late Env env;
  late String part1;

  setUp(() async {
    env = Env();
    await env.init();
    part1 = await env.service.importCourse(const CourseOutline(
      title: 'Bounded operators',
      description: 'Banach and Hilbert space operators.',
      lessons: [
        OutlineLesson(title: 'Banach spaces', brief: 'Norms, completeness.'),
        OutlineLesson(title: 'Hilbert spaces', brief: 'Inner products.'),
      ],
    ));
    // The first lesson is written, the second only planned.
    final first = (await env.repo.getCourseLessons(part1)).first;
    await env.repo.updateLesson(
        first.id,
        (l) => l.copyWith(
            notesMarkdown: '# Banach spaces\n\nText.\n\n## Summary\n\n'
                '- A Banach space is a complete normed space.'));
    env.fake.extraAnswer = (body) {
      final sys = _system(body);
      if (sys.contains('condense the lecture notes')) {
        return '## Banach spaces\n\nDIGEST: complete normed spaces.';
      }
      if (sys.contains('This course continues a series')) {
        return _user(body).contains('Plan part 2') ? _part2Plan : _part3Plan;
      }
      return null;
    };
  });
  tearDown(() => env.dispose());

  test('part 2: missing summaries are written first, the plan builds on '
      'part 1, and the new course is linked', () async {
    final status = <String>[];
    final part2 = await env.service
        .continueCourse(part1, steer: 'towards unbounded operators',
            onStatus: status.add);

    // The written lesson got its key summary, kept for reviews.
    final p1 = await env.repo.getCourseLessons(part1);
    expect(p1.first.digest, contains('DIGEST'));
    expect(p1.last.digest, isNull); // not written: nothing to summarise
    expect(status.first, 'Summarising earlier lessons (0 of 1)…');
    expect(status.last, 'Planning part 2…');

    // The planner saw every earlier lesson, numbered, with what it set up.
    final plan = env.fake.chatBodies.lastWhere(
        (b) => _system(b).contains('This course continues a series'));
    final request = _user(plan);
    expect(request, contains('Plan part 2 of the series "Bounded operators"'));
    expect(request, contains('towards unbounded operators'));
    expect(request, contains('E1. Banach spaces\n## Banach spaces\n\nDIGEST'));
    expect(request, contains('E2. Hilbert spaces\nNot written yet. Planned: '
        'Inner products.'));

    final course = (await env.repo.getCourse(part2))!;
    expect(course.part, 2);
    expect(course.continues, part1);
    expect(course.series, part1);
    final lessons = await env.repo.getCourseLessons(part2);
    expect(lessons.map((l) => l.title), ['Closed operators', 'Self-adjoint extensions']);
    expect(lessons.first.buildsOn, [p1[0].id, p1[1].id]);
    expect(lessons.last.buildsOn, isEmpty);
  });

  test('part 3 continues after part 2, from any part, with every earlier '
      'lesson numbered across parts', () async {
    final part2 = await env.service.continueCourse(part1);
    // Asked from part 1: still the next part of the series.
    final part3 = await env.service.continueCourse(part1);
    final course = (await env.repo.getCourse(part3))!;
    expect(course.part, 3);
    expect(course.continues, part2);
    expect(course.series, part1);

    final request = _user(env.fake.chatBodies.lastWhere(
        (b) => _system(b).contains('This course continues a series')));
    expect(request, contains('=== PART 1: Bounded operators ==='));
    expect(request, contains('=== PART 2: Unbounded operators ==='));
    expect(request, contains('E3. Closed operators'));
    expect(request, contains('E4. Self-adjoint extensions'));

    // A lesson of part 3 is written knowing the earlier parts and the
    // summaries of the lessons it builds on (E1 and E3).
    final lesson = (await env.repo.getCourseLessons(part3)).single;
    final ctx = (await env.service.courseContext(lesson))!;
    expect(ctx.part, 3);
    expect(ctx.earlierParts.map((p) => p.title),
        ['Bounded operators', 'Unbounded operators']);
    expect(ctx.foundations.map((f) => f.title),
        ['Banach spaces', 'Closed operators']);
    final notesRequest = Prompts.notesUser(
        title: lesson.title, brief: lesson.brief, course: ctx);
    expect(notesRequest, contains('part 3 of a series'));
    expect(notesRequest, contains('### Banach spaces'));
    expect(notesRequest, contains('DIGEST'));
  });

  test('a summary that fails does not stop the plan', () async {
    env.fake.extraAnswer = (body) {
      final sys = _system(body);
      if (sys.contains('This course continues a series')) return _part2Plan;
      return null;
    };
    env.fake.modelAnswers[env.settings.lessonChoice.model] = (body) =>
        _system(body).contains('condense') ? '' : null;
    final part2 = await env.service.continueCourse(part1);
    expect((await env.repo.getCourse(part2))!.part, 2);
    // No summary stored; the notes' Summary section stood in.
    final request = _user(env.fake.chatBodies.lastWhere(
        (b) => _system(b).contains('This course continues a series')));
    expect(request, contains('A Banach space is a complete normed space.'));
  });

  test('the prompt for an outside assistant needs no key and the pasted '
      'plan is linked the same way', () async {
    env.settings = const AppSettings();
    final prompt = await env.service.continuationPrompt(part1, steer: 'more');
    expect(prompt, contains('ASSUMES:'));
    expect(prompt, contains('E1. Banach spaces'));
    expect(env.fake.chatBodies, isEmpty);

    final p1 = await env.repo.getCourseLessons(part1);
    final part2 = await env.service.importContinuation(
        part1,
        const CourseOutline(title: 'Next', description: '', lessons: [
          OutlineLesson(title: 'A', brief: '', assumes: [2, 9]),
        ]));
    final lesson = (await env.repo.getCourseLessons(part2)).single;
    expect(lesson.buildsOn, [p1[1].id]); // 9 does not exist: dropped
    expect((await env.repo.getCourse(part2))!.part, 2);
  });

  group('series helpers', () {
    Course c(String id, int part, {String? series, int day = 1}) => Course(
        id: id,
        title: id,
        description: '',
        createdAt: DateTime(2026, 1, day),
        seriesId: series,
        part: part);

    test('nextPart skips a deleted part; the last part has none', () {
      final all = [c('a', 1), c('c', 3, series: 'a'), c('x', 1)];
      expect(nextPart(all[0], all)?.id, 'c');
      expect(nextPart(all[1], all), isNull);
      expect(nextPart(all[2], all), isNull);
    });

    test('firstToPlay takes the first recorded lesson', () {
      Lesson l(String id, int order, {bool audio = true}) => Lesson(
          id: id,
          title: id,
          brief: '',
          createdAt: DateTime(2026),
          order: order,
          stage: audio ? LessonStage.ready : LessonStage.pending,
          audioPath: audio ? '/a.wav' : null,
          segments: const [NarrationSegment(say: 'Hello.')]);
      expect(firstToPlay([l('b', 1), l('a', 0, audio: false), l('c', 2)])?.id,
          'b');
      expect(firstToPlay([l('a', 0, audio: false)]), isNull);
    });

    test('seriesGroups keeps parts together, newest series first', () {
      final groups = seriesGroups([
        c('old', 1, day: 1),
        c('s1', 1, day: 2),
        c('s3', 3, series: 's1', day: 9),
        c('s2', 2, series: 's1', day: 5),
      ]);
      expect([for (final g in groups) g.map((x) => x.id).toList()], [
        ['s1', 's2', 's3'],
        ['old'],
      ]);
    });
  });

  test('the planner plans the part; the lesson model writes the summaries '
      'right away', () async {
    await env.service.continueCourse(part1,
        model: const ModelChoice(model: 'acme/lessons', batch: true),
        planner: const ModelChoice(model: 'acme/planner', effort: 'xhigh'));
    expect(env.fake.submitted, isEmpty);
    final summary = env.fake.requests
        .firstWhere((r) => _system(r.body).contains('condense'));
    expect(summary.model, 'acme/lessons');
    final plan = env.fake.requests.firstWhere(
        (r) => _system(r.body).contains('This course continues a series'));
    expect(plan.model, 'acme/planner');
    expect(plan.effort, 'xhigh');
  });
}
