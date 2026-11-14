import '../core/models.dart';
import 'openrouter_client.dart';

/// Something a requested lesson assumes the student already knows.
class Prerequisite {
  const Prerequisite({required this.concept, this.lessonId, this.lessonTitle, this.brief});

  final String concept;

  /// The library lesson that covers it, if there is one.
  final String? lessonId;
  final String? lessonTitle;

  /// For a missing one: what a lesson on it should cover.
  final String? brief;

  bool get covered => lessonId != null;

  /// Request text for a lesson that fills the gap.
  String get lessonRequest =>
      brief == null || brief!.isEmpty ? concept : '$concept. $brief';
}

const _system = '''
A graduate student is about to study a new lesson in mathematics. Decide what it assumes beyond a standard undergraduate degree in mathematics (linear algebra, real analysis in one and several variables, basic abstract algebra, point-set topology, basic probability are taken as known), and whether the student's library already covers it.

List the two to five most important prerequisite concepts or results, most basic first. For each, look through the library titles: if a lesson there clearly covers it, it is covered.

Output format, strictly one line per prerequisite, nothing else:

HAVE: <concept> | <the library title, copied exactly>
MISSING: <concept> | <one sentence on what a lesson filling this gap should cover>

If the lesson assumes nothing beyond the undergraduate material above, output exactly:

NONE''';

String _user(String request, List<String> titles) {
  final b = StringBuffer()
    ..writeln('Lesson the student wants: ${request.trim()}')
    ..writeln()
    ..writeln(titles.isEmpty ? 'The library is empty.' : 'Library titles:');
  for (final t in titles) {
    b.writeln('- $t');
  }
  return b.toString().trimRight();
}

/// Parses the model's `HAVE:` / `MISSING:` lines. A `HAVE` whose title is not
/// in [library] is treated as missing: the model may not invent coverage.
List<Prerequisite> parsePrerequisites(String raw, List<Lesson> library) {
  // Letters and digits of any script, so "σ-algebras" and Cyrillic titles
  // keep something to match on.
  String norm(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
      .trim();
  final byTitle = {
    for (final l in library)
      if (norm(l.title).isNotEmpty) norm(l.title): l,
  };
  final out = <Prerequisite>[];
  final line = RegExp(r'^\s*[-*]?\s*\**(HAVE|MISSING)\**\s*:\**\s*(.+)$',
      caseSensitive: false);
  for (final l in raw.split(RegExp(r'\r?\n'))) {
    final m = line.firstMatch(l);
    if (m == null) continue;
    final parts = m.group(2)!.split('|');
    final concept = parts.first.trim();
    final rest = parts.length > 1 ? parts.sublist(1).join('|').trim() : '';
    if (concept.isEmpty) continue;
    final lesson =
        m.group(1)!.toUpperCase() == 'HAVE' ? byTitle[norm(rest)] : null;
    out.add(lesson != null
        ? Prerequisite(
            concept: concept, lessonId: lesson.id, lessonTitle: lesson.title)
        : Prerequisite(
            concept: concept,
            brief: m.group(1)!.toUpperCase() == 'HAVE' ? null : rest,
          ));
  }
  return out.length > 6 ? out.sublist(0, 6) : out;
}

/// Asks what [request] assumes and matches it against [library]. Immediate
/// and without extra reasoning: the student is waiting to create the lesson.
Future<List<Prerequisite>> checkPrerequisites({
  required OpenRouterClient client,
  required String model,
  required String request,
  required List<Lesson> library,
}) async {
  // Reviews and untitled drafts say nothing about what the library covers.
  final lessons = [
    for (final l in library)
      if (!l.isRecap && l.title.trim().isNotEmpty) l,
  ];
  final shown = lessons.length > 200 ? lessons.sublist(0, 200) : lessons;
  final raw = await client.chat(
    model: model,
    temperature: 0.2,
    messages: [
      const ChatMessage.system(_system),
      ChatMessage.user(_user(request, [for (final l in shown) l.title])),
    ],
  );
  return parsePrerequisites(raw, shown);
}
