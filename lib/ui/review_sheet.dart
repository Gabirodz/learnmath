import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/models.dart';
import '../core/providers.dart';
import 'model_picker.dart';

/// Offers a review of the lessons studied so far: flashcards, a short
/// lesson with its lecture, and quizzes and chat over all of them.
Future<void> showReviewSheet(BuildContext context) {
  final router = GoRouter.of(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (_) => _ReviewSheet(router: router),
  );
}

class _ReviewSheet extends ConsumerStatefulWidget {
  const _ReviewSheet({required this.router});
  final GoRouter router;

  @override
  ConsumerState<_ReviewSheet> createState() => _ReviewSheetState();
}

class _ReviewSheetState extends ConsumerState<_ReviewSheet> {
  /// Null while loading.
  List<Lesson>? _studied;
  final _picked = <String>{};
  late ModelChoice _model = ref.read(settingsProvider).lessonChoice;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final studied = await ref.read(generationProvider).studiedLessons();
    if (!mounted) return;
    setState(() {
      _studied = studied;
      _picked.addAll([for (final l in studied) l.id]);
    });
  }

  Future<void> _create() async {
    final studied = _studied;
    if (studied == null || _picked.isEmpty || _busy) return;
    final navigator = Navigator.of(context);
    final model = _model;
    setState(() {
      _busy = true;
      _error = null;
    });
    unawaited(ref
        .read(settingsProvider.notifier)
        .update((s) => s.withLessonChoice(model)));
    try {
      final id = await ref.read(generationProvider).createReview(
        // In the order they were studied.
        [for (final l in studied) if (_picked.contains(l.id)) l.id],
        model: model,
      );
      // Not when the sheet was dismissed meanwhile: that would close the
      // screen beneath it.
      if (mounted) navigator.pop();
      widget.router.push('/lesson/$id');
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
    final muted = text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant);
    final hasKey = ref.watch(settingsProvider.select((s) => s.hasApiKey));
    final studied = _studied;

    final List<Widget> body;
    if (studied == null) {
      body = const [
        Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    } else if (studied.isEmpty) {
      body = [
        Text(
          'Nothing studied yet. A lesson counts as studied once you have '
          'listened to its lecture to the end, or marked it as studied from '
          'the menu of the lesson.',
          style: muted,
        ),
      ];
    } else {
      final all = _picked.length == studied.length;
      body = [
        Text(
          'Flashcards that come back at growing intervals, a short lesson '
          'with its lecture, and quizzes and a chat that cover all the '
          'lessons you pick. It is written from a key summary of each '
          'lesson, made once and kept.',
          style: muted,
        ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: Text('${_picked.length} of ${studied.length} studied '
                '${studied.length == 1 ? 'lesson' : 'lessons'}',
                style: text.labelLarge),
          ),
          TextButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                      _picked.clear();
                      if (!all) _picked.addAll([for (final l in studied) l.id]);
                    }),
            child: Text(all ? 'Select none' : 'Select all'),
          ),
        ]),
        for (final l in studied)
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _picked.contains(l.id),
            onChanged: _busy
                ? null
                : (v) => setState(() =>
                    v ?? false ? _picked.add(l.id) : _picked.remove(l.id)),
            title: Text(l.title, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
        const SizedBox(height: 12),
        if (hasKey) ...[
          WriterButton(
            heading: 'Writes the review',
            title: 'Review writer',
            value: _model,
            enabled: !_busy,
            onChanged: (c) => setState(() => _model = c),
          ),
          const SizedBox(height: 12),
        ] else
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
                'Add your OpenRouter API key in Settings to create a review.',
                style: text.bodyMedium?.copyWith(color: scheme.error)),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(_error!,
                style: text.bodyMedium?.copyWith(color: scheme.error)),
          ),
        FilledButton.icon(
          onPressed: hasKey && _picked.isNotEmpty && !_busy ? _create : null,
          icon: const Icon(Icons.style_outlined),
          label: const Text('Create review'),
        ),
      ];
    }

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Review what you studied', style: text.titleLarge),
            const SizedBox(height: 8),
            ...body,
          ],
        ),
      ),
    );
  }
}
