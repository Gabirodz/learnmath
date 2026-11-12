/// Pure-Dart chapter planning for imported books (no Flutter imports).
library;

/// One flattened bookmark of a PDF.
class OutlineEntry {
  const OutlineEntry(this.title, this.page, this.level);
  final String title;

  /// 1-based page.
  final int page;

  /// 0 = top level.
  final int level;

  @override
  String toString() => 'OutlineEntry($title, p$page, L$level)';
}

class ChapterPlan {
  ChapterPlan({
    required this.title,
    required this.startPage,
    required this.endPage,
    this.stopBefore,
    this.startsMidPage = true,
  });

  String title;
  int startPage;
  int endPage;

  /// Title of the next chapter, which may begin on [endPage].
  String? stopBefore;

  /// False for synthetic chapters (even splits) that begin exactly at the top
  /// of [startPage]; the previous chapter then ends on the page before.
  bool startsMidPage;

  int get pageCount => endPage - startPage + 1;

  ChapterPlan copy() => ChapterPlan(
      title: title,
      startPage: startPage,
      endPage: endPage,
      stopBefore: stopBefore,
      startsMidPage: startsMidPage);

  @override
  String toString() => 'ChapterPlan($title, $startPage-$endPage, stop: $stopBefore)';
}

const _skipTitles = {
  'cover',
  'front cover',
  'back cover',
  'title page',
  'half title',
  'copyright',
  'copyright page',
  'contents',
  'table of contents',
  'brief contents',
  'detailed contents',
  'index',
  'subject index',
  'author index',
  'bibliography',
  'references',
  'colophon',
  'about the author',
  'about the authors',
};

bool _isSkippable(String title) =>
    _skipTitles.contains(title.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' '));

class _Node {
  _Node(this.title, this.page, this.skip);
  final String title;
  final int page;
  final bool skip;
  final List<_Node> children = [];
}

class _Piece {
  _Piece(this.title, this.page, this.skip);
  final String title;
  final int page;
  final bool skip;
}

/// Builds chapters from a bookmark outline.
List<ChapterPlan> planFromOutline(List<OutlineEntry> outline, int pageCount,
    {int maxPages = 25}) {
  if (pageCount < 1) return [];
  // Build the tree from levels.
  final roots = <_Node>[];
  final stack = <(int, _Node)>[];
  for (final e in outline) {
    final title = e.title.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (title.isEmpty) continue;
    final node = _Node(title, e.page.clamp(1, pageCount), _isSkippable(title));
    final level = e.level < 0 ? 0 : e.level;
    while (stack.isNotEmpty && stack.last.$1 >= level) {
      stack.removeLast();
    }
    if (stack.isEmpty) {
      roots.add(node);
    } else {
      stack.last.$2.children.add(node);
    }
    stack.add((level, node));
  }

  final pieces = <_Piece>[];
  void expand(List<_Node> siblings, int boundPage, String? prefix) {
    for (var i = 0; i < siblings.length; i++) {
      final n = siblings[i];
      final nextPage = i + 1 < siblings.length ? siblings[i + 1].page : boundPage;
      final span = nextPage - n.page + 1;
      final title = prefix == null || RegExp(r'^\d').hasMatch(n.title)
          ? n.title
          : '$prefix — ${n.title}';
      if (!n.skip && span > maxPages && n.children.isNotEmpty) {
        if (n.children.first.page > n.page) {
          pieces.add(_Piece(title, n.page, false));
        }
        expand(n.children, nextPage, title);
      } else {
        pieces.add(_Piece(title, n.page, n.skip));
      }
    }
  }

  expand(roots, pageCount, null);

  // Stable sort by page, dedupe same title+page.
  final indexed = [for (var i = 0; i < pieces.length; i++) (i, pieces[i])];
  indexed.sort((a, b) {
    final c = a.$2.page.compareTo(b.$2.page);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  final seen = <String>{};
  final flat = <_Piece>[];
  for (final (_, p) in indexed) {
    if (seen.add('${p.title}\u0000${p.page}')) flat.add(p);
  }

  final out = <ChapterPlan>[];
  for (var i = 0; i < flat.length; i++) {
    final p = flat[i];
    if (p.skip) continue;
    if (i + 1 < flat.length) {
      final next = flat[i + 1];
      out.add(ChapterPlan(
        title: p.title,
        startPage: p.page,
        endPage: next.page > p.page ? next.page : p.page,
        stopBefore: next.title,
      ));
    } else {
      out.add(ChapterPlan(title: p.title, startPage: p.page, endPage: pageCount));
    }
  }
  return out;
}

/// Splits the book into fixed-size chunks.
List<ChapterPlan> planEvenly(int pageCount, {int pagesPerChapter = 15}) {
  if (pageCount < 1) return [];
  final per = pagesPerChapter < 1 ? 1 : pagesPerChapter;
  final out = <ChapterPlan>[];
  for (var start = 1, i = 1; start <= pageCount; start += per, i++) {
    final end = start + per - 1 > pageCount ? pageCount : start + per - 1;
    out.add(ChapterPlan(
        title: 'Chapter $i', startPage: start, endPage: end, startsMidPage: false));
  }
  return out;
}

/// Recomputes endPage/stopBefore after edits; sorts by startPage (stable).
List<ChapterPlan> normalizePlan(List<ChapterPlan> chapters, int pageCount) {
  final items = [
    for (final c in chapters)
      if (c.title.trim().isNotEmpty && pageCount >= 1)
        c.copy()
          ..title = c.title.trim()
          ..startPage = c.startPage.clamp(1, pageCount)
  ];
  final indexed = [for (var i = 0; i < items.length; i++) (i, items[i])];
  indexed.sort((a, b) {
    final c = a.$2.startPage.compareTo(b.$2.startPage);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  final sorted = [for (final e in indexed) e.$2];
  for (var i = 0; i < sorted.length; i++) {
    final c = sorted[i];
    if (i + 1 == sorted.length) {
      c.endPage = pageCount;
      c.stopBefore = null;
      continue;
    }
    final next = sorted[i + 1];
    if (next.startPage > c.startPage) {
      if (next.startsMidPage) {
        c.endPage = next.startPage;
        c.stopBefore = next.title;
      } else {
        c.endPage = next.startPage - 1;
        c.stopBefore = null;
      }
    } else {
      c.endPage = c.startPage;
      c.stopBefore = next.title;
    }
  }
  return sorted;
}

/// Parses the AI table-of-contents answer (see toc_detector.dart).
List<ChapterPlan> parseTocResponse(String raw, int pageCount) {
  var offset = 0;
  final off = RegExp(r'OFFSET\s*[:=]\s*(-?\d+)', caseSensitive: false).firstMatch(raw);
  if (off != null) offset = int.parse(off.group(1)!);

  final line = RegExp(
      r'CHAPTER\s*[:\-]?\s*(.+?)\s*[|｜]\s*(?:p{1,2}\.?\s*)?(-?\d+)\s*[.*_]*\s*$',
      caseSensitive: false);
  final found = <ChapterPlan>[];
  var last = 0;
  for (final l in raw.split(RegExp(r'\r?\n'))) {
    final m = line.firstMatch(l.replaceAll(RegExp(r'[*`_]'), ''));
    if (m == null) continue;
    final title = m.group(1)!.trim().replaceAll(RegExp(r'\s+'), ' ');
    final printed = int.tryParse(m.group(2)!);
    if (title.isEmpty || printed == null) continue;
    final page = printed + offset;
    if (page < 1 || page > pageCount || page <= last) continue;
    last = page;
    found.add(ChapterPlan(title: title, startPage: page, endPage: page));
  }
  final plan = normalizePlan(found, pageCount);
  if (plan.length < 2) {
    throw const FormatException(
        'The AI could not find a table of contents in the first pages of this book.');
  }
  return plan;
}
