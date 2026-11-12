import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ai/openrouter_client.dart';
import '../core/providers.dart';
import 'chat_models.dart';
import 'chat_prompts.dart';
import 'chat_store.dart';

class ChatState {
  const ChatState({
    this.turns = const [],
    this.loaded = false,
    this.busy = false,
    this.streaming = '',
    this.error,
  });

  final List<ChatTurn> turns;
  final bool loaded;
  final bool busy;

  /// Partial assistant text while [busy].
  final String streaming;
  final String? error;

  ChatState copyWith({
    List<ChatTurn>? turns,
    bool? loaded,
    bool? busy,
    String? streaming,
    String? error,
    bool clearError = false,
  }) =>
      ChatState(
        turns: turns ?? this.turns,
        loaded: loaded ?? this.loaded,
        busy: busy ?? this.busy,
        streaming: streaming ?? this.streaming,
        error: clearError ? null : (error ?? this.error),
      );
}

const _deltaThrottle = Duration(milliseconds: 50);

class ChatController extends Notifier<ChatState> {
  ChatController(this.lessonId);

  final String lessonId;

  bool _disposed = false;
  int _generation = 0; // bumped by clear(); stale answers are dropped
  Future<void>? _loading;
  Timer? _timer;
  final _acc = StringBuffer();

  ChatStore get _store => ChatStore(ref.read(databaseProvider));

  @override
  ChatState build() {
    ref.onDispose(() {
      _disposed = true;
      _timer?.cancel();
    });
    _loading = _load();
    return const ChatState();
  }

  Future<void> _load() async {
    try {
      final turns = await _store.load(lessonId);
      if (_disposed) return;
      state = state.copyWith(turns: [...turns, ...state.turns], loaded: true);
    } catch (_) {
      if (!_disposed) state = state.copyWith(loaded: true);
    }
  }

  Future<void> _persist() async {
    try {
      await _store.save(lessonId, state.turns);
    } catch (_) {
      // Chat still works in memory if persisting fails.
    }
  }

  Future<void> send(String text, {String? quote}) async {
    text = text.trim();
    if (text.isEmpty || state.busy) return;
    await _loading;
    if (_disposed || state.busy) return;
    final q = quote?.trim();
    state = state.copyWith(
      turns: [
        ...state.turns,
        ChatTurn(
          fromUser: true,
          text: text,
          quote: (q == null || q.isEmpty) ? null : q,
          createdAt: DateTime.now(),
        ),
      ],
      clearError: true,
    );
    await _persist();
    await _answer();
  }

  /// Re-asks when the last turn is a user turn that has no answer.
  Future<void> retry() async {
    if (state.busy || state.turns.isEmpty || !state.turns.last.fromUser) return;
    await _answer();
  }

  Future<void> clear() async {
    _generation++;
    _timer?.cancel();
    _acc.clear();
    state = state.copyWith(
      turns: const [],
      busy: false,
      streaming: '',
      clearError: true,
    );
    try {
      await _store.clear(lessonId);
    } catch (_) {}
  }

  void _flush(int gen) {
    _timer = null;
    if (_disposed || gen != _generation) return;
    state = state.copyWith(streaming: _acc.toString());
  }

  Future<void> _answer() async {
    final settings = ref.read(settingsProvider);
    if (!settings.hasApiKey) {
      state = state.copyWith(error: 'Add your OpenRouter API key in Settings first.');
      return;
    }
    final gen = _generation;
    _acc.clear();
    state = state.copyWith(busy: true, streaming: '', clearError: true);
    try {
      final lesson = await ref.read(lessonProvider(lessonId).future);
      if (lesson == null) throw OpenRouterException('This lesson no longer exists.');
      final reply = await OpenRouterClient(apiKey: settings.apiKey).chat(
        model: settings.chatModel,
        messages: buildChatMessages(lesson: lesson, history: state.turns),
        onDelta: (d) {
          if (_disposed || gen != _generation) return;
          _acc.write(d);
          _timer ??= Timer(_deltaThrottle, () => _flush(gen));
        },
      );
      _timer?.cancel();
      _timer = null;
      if (_disposed || gen != _generation) return;
      final answer = reply.trim();
      if (answer.isEmpty) {
        state = state.copyWith(
            busy: false,
            streaming: '',
            error: 'The model returned an empty answer. Please retry.');
        return;
      }
      state = state.copyWith(
        turns: [
          ...state.turns,
          ChatTurn(fromUser: false, text: answer, createdAt: DateTime.now()),
        ],
        busy: false,
        streaming: '',
      );
      await _persist();
    } catch (e) {
      _timer?.cancel();
      _timer = null;
      if (_disposed || gen != _generation) return;
      state = state.copyWith(
        busy: false,
        streaming: '',
        error: e is OpenRouterException
            ? e.message
            : 'Something went wrong. Please try again. ($e)',
      );
    }
  }
}

final chatControllerProvider =
    NotifierProvider.family<ChatController, ChatState, String>(
        ChatController.new);

/// Pending quote ("Ask about this") for a lesson's next chat message.
class ChatQuote extends Notifier<String?> {
  ChatQuote(this.lessonId);

  final String lessonId;

  @override
  String? build() => null;

  void set(String? quote) => state = quote;
}

final chatQuoteProvider =
    NotifierProvider.family<ChatQuote, String?, String>(ChatQuote.new);
