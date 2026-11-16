import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import '../notes/notes_view.dart';
import '../player/subtitle_text.dart';
import '../ui/widgets.dart';
import 'card_models.dart';
import 'card_store.dart';

/// The Cards tab of a review: flashcards asked again at growing intervals.
class CardsPane extends ConsumerStatefulWidget {
  const CardsPane({super.key, required this.lessonId, this.now});
  final String lessonId;

  /// The clock; tests fix it. Defaults to DateTime.now.
  final DateTime Function()? now;

  @override
  ConsumerState<CardsPane> createState() => _CardsPaneState();
}

class _CardsPaneState extends ConsumerState<CardsPane>
    with AutomaticKeepAliveClientMixin {
  /// Null while the cards are loading.
  List<Flashcard>? _cards;

  /// Indexes into [_cards] still to ask in this session.
  List<int> _queue = [];

  bool _flipped = false;

  @override
  bool get wantKeepAlive => true;

  DateTime _now() => (widget.now ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cards =
        await CardStore(ref.read(databaseProvider)).load(widget.lessonId);
    if (!mounted) return;
    setState(() {
      _cards = cards;
      _queue = dueCardIndexes(cards, _now());
      _flipped = false;
    });
  }

  Future<void> _grade(List<Flashcard> cards, bool known) async {
    final i = _queue.first;
    final updated = cards[i].graded(known: known, now: _now());
    final newCards = List.of(cards)..[i] = updated;
    setState(() {
      _cards = newCards;
      _queue = [..._queue.skip(1), if (!known) i];
      _flipped = false;
    });
    await CardStore(ref.read(databaseProvider)).save(widget.lessonId, newCards);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    ref.listen(
        lessonProvider(widget.lessonId)
            .select((a) => a.value?.hasNotes ?? false), (_, _) {
      _load();
    });
    final cards = _cards;
    if (cards == null) return const Center(child: CircularProgressIndicator());
    if (cards.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Cards appear here once the review has been written.',
              textAlign: TextAlign.center),
        ),
      );
    }
    if (_queue.isEmpty) return _caughtUp(context, cards);
    return _asking(context, cards);
  }

  Widget _caughtUp(BuildContext context, List<Flashcard> cards) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final now = _now();
    DateTime? nextDue;
    for (final c in cards) {
      final due = c.dueAt;
      if (due != null &&
          due.isAfter(now) &&
          (nextDue == null || due.isBefore(nextDue))) {
        nextDue = due;
      }
    }
    return CentredListView(
      maxWidth: kNotesMaxWidth,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Column(children: [
          const SizedBox(height: 48),
          Text('All caught up', style: tt.titleLarge),
          const SizedBox(height: 8),
          Text(
            '${cards.length} cards.'
            '${nextDue == null ? '' : ' The next one is due ${_when(nextDue, now)}.'}',
            textAlign: TextAlign.center,
            style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 24),
          FilledButton.tonal(
            onPressed: () => setState(() {
              _queue = [for (var i = 0; i < cards.length; i++) i];
              _flipped = false;
            }),
            child: const Text('Go through all cards now'),
          ),
        ]),
      ],
    );
  }

  Widget _asking(BuildContext context, List<Flashcard> cards) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final c = cards[_queue.first];
    final titleLarge = tt.titleLarge ?? const TextStyle();
    return CentredListView(
      maxWidth: kNotesMaxWidth,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Text('${_queue.length} to go',
            style: tt.labelMedium?.copyWith(color: cs.onSurfaceVariant)),
        if (c.topic != null)
          Text(c.topic!,
              style: tt.labelSmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        const SizedBox(height: 12),
        Card(
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: InkWell(
            key: const Key('card'),
            onTap: _flipped ? null : () => setState(() => _flipped = true),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 220),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(_flipped ? 'Answer' : 'Question',
                        style: tt.labelMedium?.copyWith(color: cs.primary)),
                    const SizedBox(height: 12),
                    SubtitleText(_flipped ? c.back : c.front,
                        style: titleLarge),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (!_flipped)
          Text('Recall the answer, then tap the card.',
              textAlign: TextAlign.center,
              style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant))
        else
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _grade(cards, false),
                icon: const Icon(Icons.replay),
                label: const Text('Again'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: () => _grade(cards, true),
                icon: const Icon(Icons.check),
                label: const Text('Got it'),
              ),
            ),
          ]),
      ],
    );
  }
}

/// How soon a card is due, in words: today, tomorrow or in N days.
String _when(DateTime due, DateTime now) {
  final d = due.difference(now);
  if (d < const Duration(hours: 24)) return 'today';
  if (d < const Duration(hours: 48)) return 'tomorrow';
  return 'in ${d.inDays} days';
}
