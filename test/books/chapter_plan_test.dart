import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/books/chapter_plan.dart';

OutlineEntry e(String t, int p, [int l = 0]) => OutlineEntry(t, p, l);

void main() {
  group('planFromOutline', () {
    test('flat outline with stopBefore and last chapter to pageCount', () {
      final plan = planFromOutline(
          [e('1 Sets', 5), e('2 Maps', 20), e('3 Groups', 40)], 60);
      expect(plan.map((c) => (c.startPage, c.endPage, c.stopBefore)), [
        (5, 20, '2 Maps'),
        (20, 40, '3 Groups'),
        (40, 60, null),
      ]);
    });

    test('same-page entries end on their own page', () {
      final plan = planFromOutline([e('A', 3), e('B', 3), e('C', 10)], 20);
      expect(plan[0].endPage, 3);
      expect(plan[0].stopBefore, 'B');
      expect(plan[1].endPage, 10);
    });

    test('nested long chapter is split with intro piece', () {
      final plan = planFromOutline([
        e('Part One', 1),
        e('1.1 Basics', 10, 1),
        e('1.2 More', 30, 1),
        e('Part Two', 60),
      ], 80);
      expect(plan.map((c) => c.title),
          ['Part One', '1.1 Basics', '1.2 More', 'Part Two']);
      expect(plan[0].endPage, 10);
      expect(plan[2].endPage, 60);
      expect(plan[2].stopBefore, 'Part Two');
    });

    test('child without number gets parent prefix; no intro when same page', () {
      final plan = planFromOutline([
        e('Analysis', 1),
        e('Limits', 1, 1),
        e('Series', 30, 1),
      ], 60);
      expect(plan.map((c) => c.title), ['Analysis — Limits', 'Analysis — Series']);
    });

    test('short parent is kept whole', () {
      final plan = planFromOutline(
          [e('Ch 1', 1), e('1.1', 2, 1), e('Ch 2', 10)], 20);
      expect(plan.length, 2);
    });

    test('skips front and back matter but uses them as boundaries', () {
      final plan = planFromOutline([
        e('Cover', 1),
        e('Table of Contents', 3),
        e('Preface', 5),
        e('1 Intro', 9),
        e('Index', 50),
      ], 55);
      expect(plan.map((c) => c.title), ['Preface', '1 Intro']);
      expect(plan.last.endPage, 50);
      expect(plan.last.stopBefore, 'Index');
    });

    test('dedupes, sorts, clamps', () {
      final plan = planFromOutline(
          [e('B', 10), e('A', 2), e('A', 2), e('Z', 999)], 30);
      expect(plan.map((c) => c.title), ['A', 'B', 'Z']);
      for (final c in plan) {
        expect(c.startPage >= 1 && c.startPage <= c.endPage && c.endPage <= 30, true);
      }
    });

    test('empty outline gives empty plan', () {
      expect(planFromOutline([], 10), isEmpty);
    });
  });

  group('planEvenly', () {
    test('splits without overlap', () {
      final plan = planEvenly(40);
      expect(plan.map((c) => (c.startPage, c.endPage)), [(1, 15), (16, 30), (31, 40)]);
      expect(plan.first.stopBefore, isNull);
    });
  });

  group('normalizePlan', () {
    test('sorts and recomputes ends', () {
      final plan = normalizePlan([
        ChapterPlan(title: 'B', startPage: 20, endPage: 20),
        ChapterPlan(title: 'A', startPage: 5, endPage: 5),
        ChapterPlan(title: '  ', startPage: 7, endPage: 7),
      ], 50);
      expect(plan.map((c) => (c.title, c.startPage, c.endPage, c.stopBefore)),
          [('A', 5, 20, 'B'), ('B', 20, 50, null)]);
    });

    test('even-split chapters stay exclusive after normalize', () {
      final plan = normalizePlan(planEvenly(40), 40);
      expect(plan[0].endPage, 15);
      expect(plan[0].stopBefore, isNull);
    });
  });

  group('parseTocResponse', () {
    test('applies offset and normalizes', () {
      final plan = parseTocResponse(
          'OFFSET: 12\nCHAPTER: Limits | 1\nCHAPTER: Series | 30\nCHAPTER: Too far | 500\n',
          100);
      expect(plan.map((c) => (c.title, c.startPage, c.endPage)),
          [('Limits', 13, 42), ('Series', 42, 100)]);
      expect(plan.first.stopBefore, 'Series');
    });

    test('tolerates sloppy formatting', () {
      final plan = parseTocResponse(
          'Here you go:\n**OFFSET:** 0\n- **Chapter:** 1. Sets | p. 3\n'
          'chapter - Maps | 20.\nCHAPTER: Back | 10\n',
          50);
      expect(plan.map((c) => c.startPage), [3, 20]);
      expect(plan.first.title, '1. Sets');
    });

    test('garbage throws FormatException', () {
      expect(() => parseTocResponse('I cannot read this.', 50),
          throwsFormatException);
      expect(() => parseTocResponse('CHAPTER: Only | 3', 50), throwsFormatException);
    });
  });
}
