import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../ai/openrouter_client.dart';
import '../ai/prerequisites.dart';
import '../core/providers.dart';

Future<void> showCreateSheet(BuildContext context) {
  final router = GoRouter.of(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (_) => _CreateSheet(router: router),
  );
}

enum _Mode { lesson, course }

const _lessonExamples = [
  'The spectral theorem for compact self-adjoint operators, with proof',
  'Sylow theorems',
  'Fundamental group of the circle',
];
const _courseExamples = [
  'Measure theory, from sigma-algebras to the Radon–Nikodym theorem',
  'Introduction to algebraic topology',
  'Galois theory',
];

class _CreateSheet extends ConsumerStatefulWidget {
  const _CreateSheet({required this.router});
  final GoRouter router;

  @override
  ConsumerState<_CreateSheet> createState() => _CreateSheetState();
}

class _CreateSheetState extends ConsumerState<_CreateSheet> {
  final _controller = TextEditingController();
  _Mode _mode = _Mode.lesson;
  int? _count; // null = auto
  bool _busy = false;
  String? _error;

  /// What the lesson assumes, once looked up; null before that.
  List<Prerequisite>? _prereqs;

  /// The request [_prereqs] belongs to.
  String _checkedText = '';

  /// Missing prerequisites the student wants lessons for as well.
  final _alsoCreate = <int>{};
  bool _checking = false;
  int _checkRun = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {
          // The list belongs to the request it was made for.
          if (_prereqs != null && _controller.text.trim() != _checkedText) {
            _prereqs = null;
            _alsoCreate.clear();
          }
        }));
  }

  /// Looks up what the lesson assumes. Returns true when there is something
  /// to show the student before creating, and null when the student skipped
  /// the lookup meanwhile. Any failure just lets the lesson be created.
  Future<bool?> _checkPrerequisites(String text) async {
    final settings = ref.read(settingsProvider);
    if (!settings.prerequisiteCheck || !settings.hasApiKey) return false;
    final run = ++_checkRun;
    setState(() => _checking = true);
    final client = OpenRouterClient(apiKey: settings.apiKey);
    List<Prerequisite> found = const [];
    try {
      found = await checkPrerequisites(
        client: client,
        model: settings.lessonModel,
        request: text,
        library: await ref.read(repositoryProvider).getAllLessons(),
      ).timeout(const Duration(seconds: 30));
    } catch (_) {
      // Not worth stopping the student for.
    } finally {
      client.close();
    }
    if (!mounted || run != _checkRun) return null;
    setState(() {
      _checking = false;
      if (found.isNotEmpty) {
        _prereqs = found;
        _checkedText = text;
      }
    });
    return found.isNotEmpty;
  }

  /// Creates the lesson without waiting for the prerequisite lookup.
  void _skipCheck() {
    _checkRun++;
    setState(() {
      _checking = false;
      _busy = false;
      _prereqs = const [];
      _checkedText = _controller.text.trim();
    });
    _submit();
  }

  /// Hands the request to the screen for lessons written outside the app.
  void _openImport() {
    final router = widget.router;
    final topic = _controller.text.trim();
    Navigator.of(context).pop();
    router.push(Uri(
      path: _mode == _Mode.lesson ? '/import-lesson' : '/import-course',
      queryParameters: topic.isEmpty ? null : {'topic': topic},
    ).toString());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _busy) return;
    final gen = ref.read(generationProvider);
    final router = widget.router;
    final navigator = Navigator.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_mode == _Mode.lesson) {
        if (_prereqs == null) {
          final found = await _checkPrerequisites(text);
          // Skipped: the skip has started its own creation.
          if (found == null) return;
          if (found) {
            if (mounted) setState(() => _busy = false);
            return;
          }
        }
        // Gaps first, so they are generated before the lesson that needs them.
        final prereqs = _prereqs ?? const <Prerequisite>[];
        for (final i in _alsoCreate.toList()..sort()) {
          await gen.createLesson(prereqs[i].lessonRequest);
        }
        final id = await gen.createLesson(text);
        navigator.pop();
        router.push('/lesson/$id');
      } else {
        final id = await gen.createCourse(text, lessonCount: _count);
        navigator.pop();
        router.push('/course/$id');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final hasKey = ref.watch(settingsProvider.select((s) => s.hasApiKey));
    final batch = ref.watch(settingsProvider.select((s) => s.lessonBatch));
    final isLesson = _mode == _Mode.lesson;
    final examples = isLesson ? _lessonExamples : _courseExamples;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            SegmentedButton<_Mode>(
              segments: const [
                ButtonSegment(
                    value: _Mode.lesson,
                    icon: Icon(Icons.article_outlined),
                    label: Text('Single lesson')),
                ButtonSegment(
                    value: _Mode.course,
                    icon: Icon(Icons.library_books_outlined),
                    label: Text('Course')),
              ],
              selected: {_mode},
              onSelectionChanged: _busy
                  ? null
                  : (s) => setState(() {
                        _mode = s.first;
                        _error = null;
                      }),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.picture_as_pdf_outlined),
                label: const Text('Or import your own PDF book'),
                onPressed: _busy
                    ? null
                    : () {
                        final router = widget.router;
                        Navigator.of(context).pop();
                        router.push('/import-book');
                      },
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.content_paste_go),
                label: Text(isLesson
                    ? 'Or write it with your own AI assistant'
                    : 'Or plan it with your own AI assistant'),
                onPressed: _busy ? null : _openImport,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _controller,
              enabled: !_busy,
              minLines: 3,
              maxLines: 6,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: isLesson ? 'What do you want to learn?' : 'Course topic',
                hintText: examples.first,
                border: const OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final e in examples)
                  ActionChip(
                    label: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 240),
                      child: Text(e, overflow: TextOverflow.ellipsis),
                    ),
                    tooltip: e,
                    onPressed: _busy ? null : () => _controller.text = e,
                  ),
              ],
            ),
            if (!isLesson) ...[
              const SizedBox(height: 16),
              Text('Number of lessons', style: text.labelLarge),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final n in const <int?>[null, 4, 6, 8, 10, 12])
                    ChoiceChip(
                      label: Text(n == null ? 'Auto' : '$n'),
                      selected: _count == n,
                      onSelected: _busy ? null : (_) => setState(() => _count = n),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            if (batch && hasKey)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  isLesson
                      ? 'Written through the batch queue: ready in minutes to '
                          'hours, and you get a notification. Pick an '
                          'immediate model in Settings if you want to wait '
                          'for it here.'
                      : 'The outline is planned now. Lessons you generate '
                          'then go through the batch queue and arrive in '
                          'minutes to hours, with a notification.',
                  style: text.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            if (isLesson && (_prereqs?.isNotEmpty ?? false))
              _PrerequisiteList(
                prereqs: _prereqs!,
                picked: _alsoCreate,
                enabled: !_busy,
                onOpen: (id) {
                  final router = widget.router;
                  Navigator.of(context).pop();
                  router.push('/lesson/$id');
                },
                onPick: (i, v) => setState(
                    () => v ? _alsoCreate.add(i) : _alsoCreate.remove(i)),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(_error!,
                    style: text.bodyMedium?.copyWith(color: scheme.error)),
              ),
            if (!hasKey)
              Card(
                color: scheme.tertiaryContainer,
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Add your OpenRouter API key in Settings to generate '
                        'lessons, or have an assistant you already use '
                        '${isLesson ? 'write this one' : 'plan the course'}.',
                        style: text.bodyMedium
                            ?.copyWith(color: scheme.onTertiaryContainer),
                      ),
                      const SizedBox(height: 8),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        FilledButton.tonal(
                          onPressed: () {
                            final router = widget.router;
                            Navigator.of(context).pop();
                            router.push('/settings');
                          },
                          child: const Text('Open settings'),
                        ),
                        OutlinedButton(
                          onPressed: _openImport,
                          child: const Text('Use my own assistant'),
                        ),
                      ]),
                    ],
                  ),
                ),
              )
            else if (_checking)
              Row(children: [
                const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.5)),
                const SizedBox(width: 12),
                Expanded(
                    child: Text('Checking what this lesson builds on…',
                        style: text.bodyLarge)),
                TextButton(onPressed: _skipCheck, child: const Text('Skip')),
              ])
            else if (_busy && !isLesson)
              Row(children: [
                const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.5)),
                const SizedBox(width: 12),
                Expanded(child: Text('Planning the course…', style: text.bodyLarge)),
              ])
            else
              FilledButton(
                onPressed:
                    _controller.text.trim().isEmpty || _busy ? null : _submit,
                child: Text(_error != null
                    ? 'Try again'
                    : isLesson
                        ? (_alsoCreate.isEmpty
                            ? 'Create lesson'
                            : 'Create ${_alsoCreate.length + 1} lessons')
                        : 'Create course'),
              ),
          ],
        ),
      ),
    );
  }
}

/// What the requested lesson assumes: covered items link to their lesson,
/// gaps can be ticked to get a lesson of their own.
class _PrerequisiteList extends StatelessWidget {
  const _PrerequisiteList({
    required this.prereqs,
    required this.picked,
    required this.enabled,
    required this.onOpen,
    required this.onPick,
  });

  final List<Prerequisite> prereqs;
  final Set<int> picked;
  final bool enabled;
  final void Function(String lessonId) onOpen;
  final void Function(int index, bool picked) onPick;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('This lesson builds on', style: text.labelLarge),
          for (var i = 0; i < prereqs.length; i++)
            if (prereqs[i].covered)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.check_circle_outline, color: scheme.primary),
                title: Text(prereqs[i].concept),
                subtitle: Text('In your library: ${prereqs[i].lessonTitle}',
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                trailing: const Icon(Icons.chevron_right),
                onTap: enabled ? () => onOpen(prereqs[i].lessonId!) : null,
              )
            else
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: picked.contains(i),
                onChanged: enabled ? (v) => onPick(i, v ?? false) : null,
                title: Text(prereqs[i].concept),
                subtitle: const Text('Not in your library. Tick to create a '
                    'lesson on it too.'),
              ),
        ],
      ),
    );
  }
}
