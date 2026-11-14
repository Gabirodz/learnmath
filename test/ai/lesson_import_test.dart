import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/ai/lesson_import.dart';
import 'package:learnmath/ai/prompts.dart';
import 'package:learnmath/core/models.dart';

const _notes = '# Sylow Theorems\n\n'
    r'Let $G$ be a finite group of order $p^k m$ with $p \nmid m$.'
    '\n\n## Summary\n\n- Sylow subgroups exist.';

const _checks = 'CHECK: Example 1\nassert 12 == 2**2 * 3\n'
    'CHECK: Example 2\nn = 4\nassert n % 3 == 1';

const _script = 'SECTION: Introduction\n'
    'SAY: Welcome. Today we count subgroups.\n'
    'SAY: Take a finite group of order p to the k times m.\n'
    r'SHOW: $|G| = p^k m$'
    '\nPAUSE: 2\n'
    'SECTION: Recap\n'
    'SAY: So Sylow subgroups always exist.';

String _answer({String notes = _notes, String? checks = _checks, String script = _script}) =>
    '<<<NOTES\n$notes\nNOTES>>>\n'
    '${checks == null ? '' : '<<<CHECKS\n$checks\nCHECKS>>>\n'}'
    '<<<SCRIPT\n$script\nSCRIPT>>>';

void main() {
  group('parseImportedLesson', () {
    test('reads notes, checks and script from a well-formed answer', () {
      final l = parseImportedLesson(_answer());
      expect(l.title, 'Sylow Theorems');
      expect(l.notes, _notes);
      expect(l.checks.map((c) => c.title), ['Example 1', 'Example 2']);
      expect(l.checks[1].code, 'n = 4\nassert n % 3 == 1');
      expect(l.segments, hasLength(3));
      expect(l.segments.first.section, 'Introduction');
      expect(l.segments[1].show, r'$|G| = p^k m$');
      expect(l.segments[1].pauseMs, 2000);
      expect(l.cutOff, isFalse);
      expect(l.warnings, isEmpty);
      expect(l.estimatedDuration.inSeconds, greaterThan(5));
    });

    test('ignores the code fence and chat text around the answer', () {
      final l = parseImportedLesson(
          'Here is your lesson:\n\n````text\n${_answer()}\n````\n\nEnjoy!');
      expect(l.notes, _notes);
      expect(l.checks, hasLength(2));
      expect(l.segments, hasLength(3));
      expect(l.warnings, isEmpty);
    });

    test('Windows line ends and lower-case markers', () {
      final l = parseImportedLesson(_answer()
          .replaceAll('<<<NOTES', '<<< notes')
          .replaceAll('\n', '\r\n'));
      expect(l.notes, _notes);
      expect(l.segments, hasLength(3));
    });

    test('an answer without checks', () {
      final l = parseImportedLesson(_answer(checks: null));
      expect(l.checks, isEmpty);
      expect(l.segments, hasLength(3));
    });

    test('a cut-off answer is flagged, and completed by its continuation', () {
      final whole = '````\n${_answer()}\n````';
      final cut = whole.indexOf('SECTION: Recap');
      final first = '${whole.substring(0, cut)}````';
      final l = parseImportedLesson(first);
      expect(l.cutOff, isTrue);
      expect(l.warnings.single, contains('continue'));

      final joined = parseImportedLesson(
          '$first\n````\n${whole.substring(cut)}');
      expect(joined.cutOff, isFalse);
      expect(joined.segments, hasLength(3));
      expect(joined.segments.last.section, 'Recap');
      expect(joined.warnings, isEmpty);
    });

    test('cut off before the script: no segments, asks to continue', () {
      final l = parseImportedLesson('<<<NOTES\n$_notes\nNOTES>>>\n<<<CHECKS\n$_checks');
      expect(l.hasScript, isFalse);
      expect(l.cutOff, isTrue);
      expect(l.checks, hasLength(2));
    });

    test('plain Markdown notes without markers are a notes-only lesson', () {
      final l = parseImportedLesson(_notes);
      expect(l.notes, _notes);
      expect(l.hasScript, isFalse);
      expect(l.cutOff, isFalse);
      expect(l.warnings.single, contains('No lecture script'));
    });

    test('notes followed by a script, with no markers at all', () {
      final l = parseImportedLesson('```markdown\n$_notes\n\n$_script\n```');
      expect(l.notes, _notes);
      expect(l.segments, hasLength(3));
    });

    test('warns when the formulas were lost and when SAY has symbols', () {
      final l = parseImportedLesson(_answer(
        notes: '# Title\n\nLet G be a group of order pkm.',
        script: 'SAY: One.\nSAY: Two.\n'
            r'SAY: Then $x^2 = 1$ holds.',
      ));
      expect(l.warnings, hasLength(2));
      expect(l.warnings[0], contains('no formulas'));
      expect(l.warnings[1], contains('1 spoken line contains'));
    });

    test('nothing usable throws', () {
      expect(() => parseImportedLesson('   '), throwsFormatException);
      expect(() => parseImportedLesson('<<<SCRIPT\n$_script\nSCRIPT>>>'),
          throwsFormatException);
    });
  });

  group('Prompts.externalLesson', () {
    test('names the topic, the three regions and the rules of each part', () {
      final p = Prompts.externalLesson('Sylow theorems');
      expect(p, contains('Lesson topic: Sylow theorems'));
      for (final marker in [
        '<<<NOTES', 'NOTES>>>', '<<<CHECKS', 'CHECKS>>>', '<<<SCRIPT', 'SCRIPT>>>',
      ]) {
        expect(p, contains(marker));
      }
      expect(p, contains('KaTeX-compatible'));
      expect(p, contains('from sympy import *'));
      expect(p, contains('SAY is spoken by a text-to-speech engine'));
      expect(p, contains('Check yourself'));
      // The rules that only fit an answer holding one part are left out.
      expect(p, isNot(contains('do NOT wrap the document in a code fence')));
      expect(p, isNot(contains('write nothing after')));
      expect(p, isNot(contains('Output nothing else')));
    });

    test('without checks and recall questions', () {
      final p = Prompts.externalLesson('X', withChecks: false, recall: false);
      expect(p, isNot(contains('CHECKS')));
      expect(p, isNot(contains('sympy')));
      expect(p, isNot(contains('Check yourself')));
      expect(p, contains('PART 2: LECTURE SCRIPT'));
    });

    test('a lesson of a course carries its brief and its place', () {
      final p = Prompts.externalLesson(
        'Splitting fields',
        brief: 'Existence and uniqueness.',
        course: const CourseContext(
          courseTitle: 'Galois Theory',
          courseDescription: 'Fields and their symmetries.',
          lessonTitles: ['Field extensions', 'Splitting fields', 'Galois groups'],
          lessonIndex: 1,
        ),
      );
      expect(p, contains('What it should cover: Existence and uniqueness.'));
      expect(p, contains('This lesson is part of a course: "Galois Theory".'));
      expect(p, contains('2. Splitting fields  <-- this lesson'));
      expect(p, contains('Lessons 1 to 1 are already known'));
      expect(p, contains('(lesson 2 of 3), and at the end hint'));
      expect(Prompts.externalLesson('X'), isNot(contains('part of a course')));
    });

    test('the course plan prompt asks for the outline in a code block', () {
      final p = Prompts.externalOutline('Galois theory', lessonCount: 8);
      expect(p, contains('COURSE: <course title>'));
      expect(p, contains('BRIEF:'));
      expect(p, contains('Galois theory'));
      expect(p, contains('Plan exactly 8 lessons.'));
      expect(p, contains('ONE code block'));
      expect(p, isNot(contains('no code fences')));
      expect(Prompts.externalOutline('X'), contains('between 6 and 12'));
      // What the app sends itself is unchanged.
      expect(Prompts.outlineSystem, contains('no code fences, nothing before'));
    });

    test('the prompts the app sends itself keep their own rules', () {
      expect(Prompts.notesSystem,
          contains('do NOT wrap the document in a code fence.\n- Start with'));
      expect(Prompts.checksAddendum,
          endsWith('and write nothing after `CHECKS>>>`.'));
      expect(Prompts.narrationSystem,
          contains('no blank-line prose.\n- Length: aim'));
    });
  });
}
