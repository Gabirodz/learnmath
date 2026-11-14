import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../checks/check_banner.dart';
import '../core/providers.dart';
import '../notes/notes_view.dart';
import 'exercise_controller.dart';
import 'exercise_help.dart';
import 'exercise_parser.dart';

/// Opens the exercises of a lesson with a hint and a worked solution on
/// demand for each.
Future<void> showExercisesSheet(BuildContext context, String lessonId) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.92,
        minChildSize: 0.5,
        maxChildSize: 1.0,
        builder: (context, scroll) =>
            ExercisesSheet(lessonId: lessonId, scrollController: scroll),
      ),
    );

class ExercisesSheet extends ConsumerStatefulWidget {
  const ExercisesSheet({
    super.key,
    required this.lessonId,
    this.scrollController,
  });

  final String lessonId;
  final ScrollController? scrollController;

  @override
  ConsumerState<ExercisesSheet> createState() => _ExercisesSheetState();
}

class _ExercisesSheetState extends ConsumerState<ExercisesSheet> {
  // What the student has opened; a solution stays hidden until asked for.
  final _hintOpen = <int>{};
  final _solutionOpen = <int>{};

  void _toggle(int i, HelpKind kind, ExerciseHelp? help) {
    final open = kind == HelpKind.hint ? _hintOpen : _solutionOpen;
    final stored = (kind == HelpKind.hint ? help?.hint : help?.solution) != null;
    final ctl = ref.read(exerciseControllerProvider(widget.lessonId).notifier);
    setState(() {
      if (open.contains(i) && stored) {
        open.remove(i);
      } else {
        open.add(i);
      }
    });
    if (!stored) {
      kind == HelpKind.hint ? ctl.requestHint(i) : ctl.requestSolution(i);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lesson = ref.watch(lessonProvider(widget.lessonId)).value;
    final state = ref.watch(exerciseControllerProvider(widget.lessonId));
    final hasKey = ref.watch(settingsProvider.select((s) => s.hasApiKey));
    final exercises = parseExercises(lesson?.notesMarkdown ?? '');
    final helps = {for (final h in lesson?.exerciseHelp ?? const []) h.index: h};

    return ListView(
      controller: widget.scrollController,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      children: [
        Text('Exercises', style: theme.textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          'Try them first. A hint points the way; a solution gives it away.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        if (!hasKey)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(
              children: [
                Icon(Icons.key_off_outlined,
                    size: 18, color: theme.colorScheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Add your OpenRouter API key in Settings to ask for new hints and solutions.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.error),
                  ),
                ),
              ],
            ),
          ),
        if (lesson != null && exercises.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 24),
            child: Text('These notes have no exercises.'),
          ),
        for (var i = 0; i < exercises.length; i++)
          _ExerciseCard(
            key: ValueKey('exercise-$i'),
            number: i + 1,
            text: exercises[i],
            help: helps[i],
            state: state,
            index: i,
            canAsk: hasKey,
            hintOpen: _hintOpen.contains(i),
            solutionOpen: _solutionOpen.contains(i),
            onHint: () => _toggle(i, HelpKind.hint, helps[i]),
            onSolution: () => _toggle(i, HelpKind.solution, helps[i]),
            onRetry: (k) {
              final ctl =
                  ref.read(exerciseControllerProvider(widget.lessonId).notifier);
              k == HelpKind.hint ? ctl.requestHint(i) : ctl.requestSolution(i);
            },
            onCancel: () => ref
                .read(exerciseControllerProvider(widget.lessonId).notifier)
                .cancel(),
          ),
      ],
    );
  }
}

class _ExerciseCard extends StatelessWidget {
  const _ExerciseCard({
    super.key,
    required this.number,
    required this.index,
    required this.text,
    required this.help,
    required this.state,
    required this.canAsk,
    required this.hintOpen,
    required this.solutionOpen,
    required this.onHint,
    required this.onSolution,
    required this.onRetry,
    required this.onCancel,
  });

  final int number;
  final int index;
  final String text;
  final ExerciseHelp? help;
  final ExerciseState state;
  final bool canAsk;
  final bool hintOpen;
  final bool solutionOpen;
  final VoidCallback onHint;
  final VoidCallback onSolution;
  final void Function(HelpKind) onRetry;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final busyHere = state.busyIndex == index;
    final otherBusy = state.busy && !busyHere;
    final hasHint = help?.hint != null;
    final hasSolution = help?.solution != null;

    Widget section(HelpKind kind) {
      final stored = kind == HelpKind.hint ? help?.hint : help?.solution;
      final loading = busyHere && state.busyKind == kind;
      final err = state.errors[index];
      final error = err != null && err.kind == kind ? err.message : null;
      final shown = stored ?? (loading ? state.streaming : '');
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          decoration: BoxDecoration(
            color: kind == HelpKind.hint
                ? cs.secondaryContainer.withValues(alpha: 0.5)
                : cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(kind == HelpKind.hint ? 'Hint' : 'Solution',
                  style: theme.textTheme.labelLarge),
              if (kind == HelpKind.solution &&
                  stored != null &&
                  help!.checks.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: CheckBanner(
                        checks: help!.checks, report: help!.checkReport),
                  ),
                ),
              if (shown.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: MarkdownMath(shown, dense: true),
                ),
              if (loading)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    children: [
                      const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          state.checking ? 'Checking with SymPy…' : 'Writing…',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                      TextButton(
                          onPressed: onCancel, child: const Text('Cancel')),
                    ],
                  ),
                ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline, color: cs.error, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                          child: Text(error, style: TextStyle(color: cs.error))),
                      TextButton(
                          onPressed: () => onRetry(kind),
                          child: const Text('Retry')),
                    ],
                  ),
                ),
            ],
          ),
        ),
      );
    }

    return Card(
      margin: const EdgeInsets.only(top: 16),
      elevation: 0,
      color: cs.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Exercise $number',
                style: theme.textTheme.labelLarge?.copyWith(color: cs.primary)),
            const SizedBox(height: 4),
            MarkdownMath(text),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                OutlinedButton.icon(
                  onPressed: (canAsk || hasHint) && !otherBusy ? onHint : null,
                  icon: Icon(
                      hintOpen && hasHint
                          ? Icons.expand_less
                          : Icons.lightbulb_outline,
                      size: 18),
                  label: Text(hintOpen && hasHint ? 'Hide hint' : 'Hint'),
                ),
                OutlinedButton.icon(
                  onPressed:
                      (canAsk || hasSolution) && !otherBusy ? onSolution : null,
                  icon: Icon(
                      solutionOpen && hasSolution
                          ? Icons.expand_less
                          : Icons.task_alt,
                      size: 18),
                  label: Text(
                      solutionOpen && hasSolution ? 'Hide solution' : 'Solution'),
                ),
              ],
            ),
            if (hintOpen) section(HelpKind.hint),
            if (solutionOpen) section(HelpKind.solution),
          ],
        ),
      ),
    );
  }
}
