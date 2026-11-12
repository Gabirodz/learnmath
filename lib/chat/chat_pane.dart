import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import '../notes/notes_view.dart';
import 'chat_controller.dart';
import 'chat_models.dart';

const _defaultQuestion = 'Can you explain this?';
const _suggestions = [
  'Summarise the key ideas',
  'What are the prerequisites?',
  'Quiz me on this lesson',
  'Give me an intuition for the main theorem',
];
const _quoteActions = [
  'Explain this',
  'Simpler, please',
  'Give an example',
  'Why is this true?',
];

/// Chat with a tutor about one lesson's notes. No Scaffold; embed anywhere.
class ChatPane extends ConsumerStatefulWidget {
  const ChatPane({super.key, required this.lessonId});

  final String lessonId;

  @override
  ConsumerState<ChatPane> createState() => _ChatPaneState();
}

class _ChatPaneState extends ConsumerState<ChatPane> {
  final _field = TextEditingController();
  final _scroll = ScrollController();
  bool _stick = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.hasClients) {
        _stick = _scroll.position.extentAfter < 80;
      }
    });
  }

  @override
  void dispose() {
    _field.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_stick || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  void _send(String raw) {
    final chat = ref.read(chatControllerProvider(widget.lessonId));
    if (chat.busy) return;
    final quote = ref.read(chatQuoteProvider(widget.lessonId));
    var text = raw.trim();
    if (text.isEmpty && quote != null) text = _defaultQuestion;
    if (text.isEmpty) return;
    _field.clear();
    _stick = true;
    ref.read(chatQuoteProvider(widget.lessonId).notifier).set(null);
    ref
        .read(chatControllerProvider(widget.lessonId).notifier)
        .send(text, quote: quote);
    _scrollToEnd();
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear conversation?'),
        content: const Text('All messages about this lesson will be deleted.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Clear')),
        ],
      ),
    );
    if (ok == true && mounted) {
      ref.read(chatControllerProvider(widget.lessonId).notifier).clear();
    }
  }

  Future<void> _copy(String markdown) async {
    await Clipboard.setData(ClipboardData(text: markdown));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Copied to clipboard')));
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.lessonId;
    final chat = ref.watch(chatControllerProvider(id));
    final quote = ref.watch(chatQuoteProvider(id));
    final lessonAsync = ref.watch(lessonProvider(id));
    final cs = Theme.of(context).colorScheme;

    ref.listen(chatControllerProvider(id), (prev, next) {
      if (prev == null ||
          prev.turns.length != next.turns.length ||
          prev.streaming != next.streaming ||
          prev.busy != next.busy ||
          prev.error != next.error) {
        _scrollToEnd();
      }
    });

    final lesson = lessonAsync.value;
    if (lesson == null) {
      return Center(
        child: lessonAsync.isLoading
            ? const CircularProgressIndicator()
            : const Text('Lesson not found.'),
      );
    }
    if (!lesson.hasNotes) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.forum_outlined, size: 40, color: cs.outline),
              const SizedBox(height: 12),
              Text(
                'The chat becomes available once the lesson notes have been generated.',
                textAlign: TextAlign.center,
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }

    final insets = MediaQuery.viewInsetsOf(context).bottom;
    final empty = chat.turns.isEmpty && !chat.busy && chat.error == null;

    return Padding(
      padding: EdgeInsets.only(bottom: insets),
      child: Column(
        children: [
          if (chat.turns.isNotEmpty)
            Align(
              alignment: Alignment.centerRight,
              child: PopupMenuButton<String>(
                tooltip: 'Chat options',
                icon: const Icon(Icons.more_vert),
                onSelected: (_) => _confirmClear(),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'clear', child: Text('Clear conversation')),
                ],
              ),
            ),
          Expanded(
            child: !chat.loaded
                ? const Center(child: CircularProgressIndicator())
                : empty
                    ? _EmptyState(onPick: _send)
                    : _messages(chat),
          ),
          SafeArea(
            top: false,
            bottom: insets == 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (quote != null) _pendingQuote(quote, chat.busy),
                _inputRow(chat.busy, quote != null),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _messages(ChatState chat) {
    final cs = Theme.of(context).colorScheme;
    final extra = (chat.busy ? 1 : 0) + (chat.error != null ? 1 : 0);
    final canRetry = chat.turns.isNotEmpty && chat.turns.last.fromUser;
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      itemCount: chat.turns.length + extra,
      itemBuilder: (context, i) {
        if (i < chat.turns.length) {
          final t = chat.turns[i];
          return t.fromUser ? _UserBubble(turn: t) : _assistant(t.text);
        }
        if (chat.busy && i == chat.turns.length) {
          return _Streaming(text: chat.streaming);
        }
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Icon(Icons.error_outline, color: cs.error, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(chat.error!, style: TextStyle(color: cs.error)),
              ),
              if (canRetry)
                TextButton(
                  onPressed: () => ref
                      .read(chatControllerProvider(widget.lessonId).notifier)
                      .retry(),
                  child: const Text('Retry'),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _assistant(String text) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: () {
          HapticFeedback.mediumImpact();
          _copy(text);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: MarkdownMath(text, dense: true),
        ),
      );

  Widget _pendingQuote(String quote, bool busy) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text('Asking about:',
                          style: Theme.of(context)
                              .textTheme
                              .labelMedium
                              ?.copyWith(color: cs.onSurfaceVariant)),
                    ),
                    IconButton(
                      tooltip: 'Remove quote',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => ref
                          .read(chatQuoteProvider(widget.lessonId).notifier)
                          .set(null),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: _QuoteExcerpt(markdown: quote),
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final a in _quoteActions)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ActionChip(
                      label: Text(a),
                      onPressed: busy ? null : () => _send(a),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _inputRow(bool busy, bool hasQuote) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _field,
              minLines: 1,
              maxLines: 5,
              textCapitalization: TextCapitalization.sentences,
              keyboardType: TextInputType.multiline,
              decoration: InputDecoration(
                hintText: 'Ask about this lesson…',
                filled: true,
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _field,
            builder: (context, v, _) {
              final canSend = !busy && (v.text.trim().isNotEmpty || hasQuote);
              return IconButton.filled(
                tooltip: 'Send',
                icon: const Icon(Icons.arrow_upward),
                onPressed: canSend ? () => _send(v.text) : null,
              );
            },
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onPick});
  final void Function(String) onPick;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.forum_outlined, size: 40, color: cs.primary),
            const SizedBox(height: 12),
            Text(
              'Ask anything about this lesson. Answers use the lesson notes. '
              'Long-press a passage in the notes to ask about it.',
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final s in _suggestions)
                  ActionChip(label: Text(s), onPressed: () => onPick(s)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.turn});
  final ChatTurn turn;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.85,
        ),
        decoration: BoxDecoration(
          color: cs.primaryContainer,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (turn.quote != null) ...[
              _QuoteExcerpt(markdown: turn.quote!),
              const SizedBox(height: 8),
            ],
            Text(turn.text, style: TextStyle(color: cs.onPrimaryContainer)),
          ],
        ),
      ),
    );
  }
}

/// Compact left-bordered excerpt (about four lines) of quoted Markdown.
class _QuoteExcerpt extends StatelessWidget {
  const _QuoteExcerpt({required this.markdown});
  final String markdown;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final maxH = MediaQuery.textScalerOf(context).scale(88);
    return Container(
      padding: const EdgeInsets.only(left: 8),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: cs.primary, width: 3)),
      ),
      child: ClipRect(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxH),
          child: SingleChildScrollView(
            physics: const NeverScrollableScrollPhysics(),
            child: MarkdownMath(markdown, dense: true),
          ),
        ),
      ),
    );
  }
}

class _Streaming extends StatelessWidget {
  const _Streaming({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (text.isNotEmpty) MarkdownMath(text, dense: true),
          const SizedBox(height: 6),
          const SizedBox(
            width: 48,
            child: LinearProgressIndicator(minHeight: 2),
          ),
        ],
      ),
    );
  }
}
