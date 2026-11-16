import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/models.dart';
import '../core/providers.dart';
import 'model_picker.dart';

/// Opens the sheet that plans the next part of [course]'s series.
/// [nextPart] is the number the new part gets.
Future<void> showContinueSheet(BuildContext context,
    {required Course course, required int nextPart}) {
  final router = GoRouter.of(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (_) =>
        _ContinueSheet(course: course, nextPart: nextPart, router: router),
  );
}

class _ContinueSheet extends ConsumerStatefulWidget {
  const _ContinueSheet(
      {required this.course, required this.nextPart, required this.router});
  final Course course;
  final int nextPart;
  final GoRouter router;

  @override
  ConsumerState<_ContinueSheet> createState() => _ContinueSheetState();
}

class _ContinueSheetState extends ConsumerState<_ContinueSheet> {
  final _steer = TextEditingController();
  int? _count; // null = the planner decides
  late ModelChoice _model = ref.read(settingsProvider).lessonChoice;
  bool _busy = false;
  String? _status;
  String? _error;

  @override
  void dispose() {
    _steer.dispose();
    super.dispose();
  }

  Future<void> _plan() async {
    final gen = ref.read(generationProvider);
    final router = widget.router;
    final navigator = Navigator.of(context);
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      final id = await gen.continueCourse(
        widget.course.id,
        steer: _steer.text,
        lessonCount: _count,
        model: _model,
        planner: ref.read(settingsProvider).plannerModel,
        onStatus: (s) {
          if (mounted) setState(() => _status = s);
        },
      );
      // The sheet may have been dismissed meanwhile.
      if (mounted) navigator.pop();
      router.push('/course/$id');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString();
      });
    }
  }

  void _ownAssistant() {
    final router = widget.router;
    Navigator.of(context).pop();
    router.push(Uri(path: '/import-course', queryParameters: {
      'continues': widget.course.id,
      if (_steer.text.trim().isNotEmpty) 'topic': _steer.text.trim(),
    }).toString());
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final hasKey = ref.watch(settingsProvider.select((s) => s.hasApiKey));
    final n = widget.nextPart;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Continue with part $n', style: text.titleLarge),
            const SizedBox(height: 6),
            Text(
              'Part $n is planned from what the earlier parts established, '
              'so it builds on them without repeating them. Each of its '
              'lessons is written knowing the earlier lessons it uses.',
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _steer,
              enabled: !_busy,
              minLines: 1,
              maxLines: 4,
              decoration: InputDecoration(
                labelText: 'What should part $n cover? (optional)',
                hintText: 'For example: go on to unbounded operators',
                border: const OutlineInputBorder(),
              ),
              onTapOutside: (_) => FocusScope.of(context).unfocus(),
            ),
            const SizedBox(height: 16),
            Text('Number of lessons', style: text.labelLarge),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              for (final c in const <int?>[null, 4, 6, 8, 10, 12])
                ChoiceChip(
                  label: Text(c == null ? 'Auto' : '$c'),
                  selected: _count == c,
                  onSelected: _busy ? null : (_) => setState(() => _count = c),
                ),
            ]),
            const SizedBox(height: 16),
            if (hasKey) ...[
              CourseModelButtons(
                planHeading: 'Plans part $n',
                writeHeading: 'Writes its lessons',
                writer: _model,
                enabled: !_busy,
                onWriterChanged: (c) => setState(() => _model = c),
              ),
              const SizedBox(height: 8),
              Text(
                'The plan is made now. Earlier lessons without a key summary '
                'get one first (kept for reviews and later parts).'
                '${_model.batch ? ' The lessons you then generate go through '
                    'the batch queue.' : ''}',
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(_error!,
                    style: text.bodyMedium?.copyWith(color: scheme.error)),
              ),
            if (_busy)
              Row(children: [
                const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.5)),
                const SizedBox(width: 12),
                Expanded(
                    child: Text(_status ?? 'Planning part $n…',
                        style: text.bodyLarge)),
              ])
            else ...[
              if (hasKey)
                FilledButton(
                  onPressed: _plan,
                  child: Text(_error != null ? 'Try again' : 'Plan part $n'),
                ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _ownAssistant,
                child: Text(hasKey
                    ? 'Or plan it with your own AI assistant'
                    : 'Plan it with your own AI assistant'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
