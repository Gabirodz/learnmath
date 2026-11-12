/// One message in a lesson's chat thread.
class ChatTurn {
  const ChatTurn({
    required this.fromUser,
    required this.text,
    required this.createdAt,
    this.quote,
  });

  final bool fromUser;
  final String text;

  /// Excerpt of the notes (Markdown) or lecture the question refers to.
  final String? quote;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
        'fromUser': fromUser,
        'text': text,
        if (quote != null) 'quote': quote,
        'createdAt': createdAt.toIso8601String(),
      };

  factory ChatTurn.fromJson(Map<String, Object?> j) => ChatTurn(
        fromUser: j['fromUser'] == true,
        text: (j['text'] as String?) ?? '',
        quote: j['quote'] as String?,
        createdAt: DateTime.tryParse((j['createdAt'] as String?) ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );
}
