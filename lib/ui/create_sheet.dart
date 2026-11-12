import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
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
                        'Add your OpenRouter API key in Settings to generate lessons.',
                        style: text.bodyMedium
                            ?.copyWith(color: scheme.onTertiaryContainer),
                      ),
                      const SizedBox(height: 8),
                      FilledButton.tonal(
                        onPressed: () {
                          final router = widget.router;
                          Navigator.of(context).pop();
                          router.push('/settings');
                        },
                        child: const Text('Open settings'),
                      ),
                    ],
                  ),
                ),
              )
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
                        ? 'Create lesson'
                        : 'Create course'),
              ),
          ],
        ),
      ),
    );
  }
}
