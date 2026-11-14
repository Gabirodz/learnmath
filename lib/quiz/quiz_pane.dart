import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import '../notes/notes_view.dart';
import '../ui/widgets.dart';
import 'quiz_controller.dart';
import 'quiz_models.dart';
import 'quiz_prompts.dart';

/// The Quiz tab of a lesson: choose difficulty, kind and length, answer the
/// questions, and come back to earlier quizzes.
class QuizPane extends ConsumerStatefulWidget {
  const QuizPane({super.key, required this.lessonId});
  final String lessonId;

  @override
  ConsumerState<QuizPane> createState() => _QuizPaneState();
}

class _QuizPaneState extends ConsumerState<QuizPane>
    with AutomaticKeepAliveClientMixin {
  QuizDifficulty _difficulty = QuizDifficulty.medium;
  QuizKind _kind = QuizKind.choice;
  int _count = 5;

  /// The quiz being answered; null shows the setup.
  String? _open;

  @override
  bool get wantKeepAlive => true;

  QuizController get _controller =>
      ref.read(quizControllerProvider(widget.lessonId).notifier);

  void _say(String message) => ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));

  Future<void> _start() async {
    final id = await _controller.generate(
        difficulty: _difficulty, kind: _kind, count: _count);
    if (id != null && mounted) setState(() => _open = id);
  }

  Future<String?> _prompt() async {
    final lesson =
        await ref.read(repositoryProvider).getLesson(widget.lessonId);
    if (lesson == null || !lesson.hasNotes) return null;
    return QuizPrompts.external(
      title: lesson.title,
      notesMarkdown: lesson.notesMarkdown!,
      difficulty: _difficulty,
      kind: _kind,
      count: _count,
      avoid: _controller.asked,
    );
  }

  Future<void> _copyPrompt() async {
    final prompt = await _prompt();
    if (prompt == null) return;
    await Clipboard.setData(ClipboardData(text: prompt));
    if (!mounted) return;
    _say('Prompt copied, with the lesson in it. Paste it into your '
        'assistant.');
  }

  Future<void> _paste() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    if (!mounted) return;
    if (text.trim().isEmpty) {
      _say('The clipboard is empty. Copy the assistant\'s answer first.');
      return;
    }
    try {
      final id = await _controller.import(text, difficulty: _difficulty);
      if (mounted) setState(() => _open = id);
    } on FormatException {
      if (mounted) {
        _say('No quiz questions found in the clipboard. Copy the code block '
            'of the assistant\'s answer.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final state = ref.watch(quizControllerProvider(widget.lessonId));
    final hasNotes = ref.watch(lessonProvider(widget.lessonId)
        .select((a) => a.value?.hasNotes ?? false));
    if (!hasNotes) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Quizzes are made from the notes, once they are ready.',
              textAlign: TextAlign.center),
        ),
      );
    }
    if (!state.loaded) return const Center(child: CircularProgressIndicator());

    final quiz = state.byId(_open);
    final hasKey = ref.watch(settingsProvider.select((s) => s.hasApiKey));
    return quiz == null
        ? _setup(context, state, hasKey)
        : _QuizView(
            key: ValueKey(quiz.id),
            lessonId: widget.lessonId,
            quiz: quiz,
            state: state,
            hasKey: hasKey,
            onClose: () => setState(() => _open = null),
          );
  }

  Widget _setup(BuildContext context, QuizState state, bool hasKey) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final busy = state.writing;
    return CentredListView(
      maxWidth: kNotesMaxWidth,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Text('Difficulty', style: tt.labelLarge),
        const SizedBox(height: 8),
        SegmentedButton<QuizDifficulty>(
          showSelectedIcon: false,
          segments: [
            for (final d in QuizDifficulty.values)
              ButtonSegment(value: d, label: Text(d.label)),
          ],
          selected: {_difficulty},
          onSelectionChanged:
              busy ? null : (s) => setState(() => _difficulty = s.first),
        ),
        const SizedBox(height: 16),
        Text('Questions', style: tt.labelLarge),
        const SizedBox(height: 8),
        SegmentedButton<QuizKind>(
          showSelectedIcon: false,
          segments: [
            for (final k in QuizKind.values)
              ButtonSegment(value: k, label: Text(k.label)),
          ],
          selected: {_kind},
          onSelectionChanged:
              busy ? null : (s) => setState(() => _kind = s.first),
        ),
        const SizedBox(height: 8),
        Text(
          switch (_kind) {
            QuizKind.choice => 'Four options each; tap the right one.',
            QuizKind.free => hasKey
                ? 'You type a few sentences and the model judges the idea, '
                    'not the wording.'
                : 'You type a few sentences, then compare with the reference '
                    'answer yourself.',
            QuizKind.mixed => 'Some to tap, some to answer in your own words.',
          },
          style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        Text('How many', style: tt.labelLarge),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          for (final n in const [3, 5, 8, 10])
            ChoiceChip(
              label: Text('$n'),
              selected: _count == n,
              onSelected: busy ? null : (_) => setState(() => _count = n),
            ),
        ]),
        const SizedBox(height: 24),
        if (busy)
          Row(children: [
            const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2.5)),
            const SizedBox(width: 12),
            Expanded(
                child: Text('Writing $_count questions…', style: tt.bodyLarge)),
          ])
        else if (hasKey)
          FilledButton.icon(
            onPressed: _start,
            icon: const Icon(Icons.quiz_outlined),
            label: const Text('Start quiz'),
          ),
        if (state.error != null && state.ungraded == null && !busy)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(state.error!,
                style: tt.bodyMedium?.copyWith(color: cs.error)),
          ),
        const SizedBox(height: 16),
        Text(
          hasKey
              ? 'Or have your own assistant write it'
              : 'Have your own assistant write it (no OpenRouter key needed)',
          style: tt.labelLarge,
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(
            onPressed: busy ? null : _copyPrompt,
            icon: const Icon(Icons.copy),
            label: const Text('1. Copy prompt'),
          ),
          OutlinedButton.icon(
            onPressed: busy ? null : _paste,
            icon: const Icon(Icons.content_paste),
            label: const Text('2. Paste answer'),
          ),
        ]),
        if (state.quizzes.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text('Earlier quizzes', style: tt.labelLarge),
          for (final q in state.quizzes)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(q.finished
                  ? Icons.check_circle_outline
                  : Icons.pending_outlined),
              title: Text([
                if (q.difficulty != null) q.difficulty!.label,
                '${q.questions.length} questions',
                if (q.imported) 'imported',
              ].join(' · ')),
              subtitle: Text(q.finished
                  ? 'Score ${_points(q.score)} of ${q.questions.length}'
                  : '${q.answered} of ${q.questions.length} answered'),
              trailing: IconButton(
                tooltip: 'Delete quiz',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _controller.delete(q.id),
              ),
              onTap: () => setState(() => _open = q.id),
            ),
        ],
      ],
    );
  }
}

String _points(double score) =>
    score == score.roundToDouble() ? '${score.round()}' : score.toStringAsFixed(1);

class _QuizView extends ConsumerWidget {
  const _QuizView({
    super.key,
    required this.lessonId,
    required this.quiz,
    required this.state,
    required this.hasKey,
    required this.onClose,
  });

  final String lessonId;
  final Quiz quiz;
  final QuizState state;
  final bool hasKey;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final controller = ref.read(quizControllerProvider(lessonId).notifier);
    final n = quiz.questions.length;
    return LayoutBuilder(
      builder: (context, box) => ListView.builder(
      padding: centredPadding(box.maxWidth,
          const EdgeInsets.fromLTRB(16, 8, 16, 32), kNotesMaxWidth),
      itemCount: n + 1,
      itemBuilder: (context, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              TextButton.icon(
                onPressed: onClose,
                icon: const Icon(Icons.arrow_back),
                label: const Text('Quizzes'),
              ),
              const Spacer(),
              Text(
                quiz.finished
                    ? 'Score ${_points(quiz.score)} of $n'
                    : '${quiz.answered} of $n answered',
                style: tt.titleSmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ]),
          );
        }
        final index = i - 1;
        final q = quiz.questions[index];
        final grading = state.grading?.quizId == quiz.id &&
            state.grading?.index == index;
        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Question $i', style: tt.labelMedium),
                const SizedBox(height: 4),
                MarkdownMath(q.prompt, dense: true),
                const SizedBox(height: 8),
                if (q.isChoice)
                  _Options(
                    question: q,
                    onChoose: (o) => controller.choose(quiz.id, index, o),
                  )
                else
                  _FreeAnswer(
                    question: q,
                    grading: grading,
                    // One request at a time.
                    canGrade: hasKey && state.grading == null,
                    error: state.ungraded?.quizId == quiz.id &&
                            state.ungraded?.index == index
                        ? state.error
                        : null,
                    onGrade: (text) => controller.grade(quiz.id, index, text),
                    onSelfGrade: (text, v) =>
                        controller.selfGrade(quiz.id, index, text, v),
                  ),
              ],
            ),
          ),
        );
      },
      ),
    );
  }
}

Color _verdictColor(ColorScheme cs, Verdict v) => switch (v) {
      Verdict.correct => Colors.green.shade700,
      Verdict.partial => Colors.orange.shade800,
      Verdict.wrong => cs.error,
    };

class _Options extends StatelessWidget {
  const _Options({required this.question, required this.onChoose});
  final QuizQuestion question;
  final void Function(int option) onChoose;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final q = question;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var o = 0; o < q.options.length; o++)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Material(
              color: !q.answered
                  ? cs.surfaceContainerHighest
                  : o == q.correct
                      ? Colors.green.withValues(alpha: 0.18)
                      : o == q.chosen
                          ? cs.errorContainer
                          : cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: q.answered ? null : () => onChoose(o),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(children: [
                    Expanded(child: MarkdownMath(q.options[o], dense: true)),
                    if (q.answered && o == q.correct)
                      Icon(Icons.check, color: Colors.green.shade700)
                    else if (q.answered && o == q.chosen)
                      Icon(Icons.close, color: cs.error),
                  ]),
                ),
              ),
            ),
          ),
        if (q.answered && q.answer.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: MarkdownMath(q.answer, dense: true),
          ),
      ],
    );
  }
}

class _FreeAnswer extends StatefulWidget {
  const _FreeAnswer({
    required this.question,
    required this.grading,
    required this.canGrade,
    required this.error,
    required this.onGrade,
    required this.onSelfGrade,
  });

  final QuizQuestion question;
  final bool grading;
  final bool canGrade;

  /// Why grading failed; the student can then judge the answer themselves.
  final String? error;
  final void Function(String text) onGrade;
  final void Function(String text, Verdict verdict) onSelfGrade;

  @override
  State<_FreeAnswer> createState() => _FreeAnswerState();
}

class _FreeAnswerState extends State<_FreeAnswer> {
  late final _text = TextEditingController(text: widget.question.reply ?? '');

  /// The reference answer is shown for the student to compare with.
  bool _revealed = false;

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final q = widget.question;
    final verdict = q.verdict;

    if (verdict != null) {
      final color = _verdictColor(cs, verdict);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if ((q.reply ?? '').trim().isNotEmpty)
            Text(q.reply!,
                style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
          const SizedBox(height: 8),
          Row(children: [
            Icon(
              switch (verdict) {
                Verdict.correct => Icons.check_circle,
                Verdict.partial => Icons.adjust,
                Verdict.wrong => Icons.cancel,
              },
              color: color,
              size: 20,
            ),
            const SizedBox(width: 8),
            Text(
              switch (verdict) {
                Verdict.correct => 'Correct',
                Verdict.partial => 'Partly right',
                Verdict.wrong => 'Not quite',
              },
              style: tt.titleSmall?.copyWith(color: color),
            ),
          ]),
          if ((q.feedback ?? '').isNotEmpty) ...[
            const SizedBox(height: 4),
            MarkdownMath(q.feedback!, dense: true),
          ],
          const SizedBox(height: 8),
          Text('Reference answer', style: tt.labelMedium),
          MarkdownMath(q.answer, dense: true),
        ],
      );
    }

    final typed = _text.text.trim().isNotEmpty;
    final selfGrade = _revealed || (widget.error != null && typed);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _text,
          enabled: !widget.grading && !_revealed,
          minLines: 2,
          maxLines: 8,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            hintText: 'Your answer: the main idea in a few sentences',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        if (widget.grading)
          Row(children: [
            const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 12),
            Text('Reading your answer…', style: tt.bodyMedium),
          ])
        else if (!selfGrade)
          Align(
            alignment: Alignment.centerLeft,
            child: widget.canGrade
                ? FilledButton.tonal(
                    onPressed: typed ? () => widget.onGrade(_text.text) : null,
                    child: const Text('Check answer'),
                  )
                : FilledButton.tonal(
                    onPressed: typed
                        ? () => setState(() => _revealed = true)
                        : null,
                    child: const Text('Show reference answer'),
                  ),
          ),
        if (selfGrade && !widget.grading) ...[
          if (widget.error != null && !_revealed)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('${widget.error} You can judge it yourself:',
                  style: tt.bodySmall?.copyWith(color: cs.error)),
            ),
          Text('Reference answer', style: tt.labelMedium),
          MarkdownMath(q.answer, dense: true),
          const SizedBox(height: 8),
          Text('How did you do?', style: tt.labelMedium),
          const SizedBox(height: 4),
          Wrap(spacing: 8, children: [
            for (final (v, label) in const [
              (Verdict.correct, 'Got it'),
              (Verdict.partial, 'Partly'),
              (Verdict.wrong, 'Missed it'),
            ])
              OutlinedButton(
                onPressed: () => widget.onSelfGrade(_text.text, v),
                child: Text(label),
              ),
          ]),
        ],
      ],
    );
  }
}
