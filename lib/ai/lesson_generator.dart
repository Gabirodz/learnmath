import 'package:learnmath/ai/narration_parser.dart';
import 'package:learnmath/ai/openrouter_client.dart';
import 'package:learnmath/ai/prompts.dart';
import 'package:learnmath/cards/card_models.dart';
import 'package:learnmath/cards/card_parser.dart';
import 'package:learnmath/checks/check_parser.dart';
import 'package:learnmath/checks/math_check.dart';
import 'package:learnmath/checks/proof_review.dart';
import 'package:learnmath/core/models.dart';

/// Lecture notes as the model wrote them, with their SymPy checks.
class NotesDraft {
  const NotesDraft({required this.notes, required this.checks});
  final String notes;
  final List<MathCheck> checks;
}

/// Builds the model requests for outlines, lecture notes and narration
/// scripts and parses the answers. Requests and parsers are separate so the
/// same lesson can be written immediately or through the Batch API.
class LessonGenerator {
  LessonGenerator(this.client, {required this.model, this.effort});

  final OpenRouterClient client;
  final String model;

  /// `reasoning.effort` for notes and scripts; null for the model default.
  final String? effort;

  Future<CourseOutline> generateOutline(String topic, {int? lessonCount}) async {
    final raw = await client.chat(
      model: model,
      temperature: 0.4,
      reasoningEffort: effort,
      messages: [
        const ChatMessage.system(Prompts.outlineSystem),
        ChatMessage.user(Prompts.outlineUser(topic, lessonCount: lessonCount)),
      ],
    );
    return parseOutline(raw);
  }

  static const notesTemperature = 0.5;
  static const narrationTemperature = 0.6;

  /// Refereeing and judging want the same answer every time.
  static const reviewTemperature = 0.2;

  static List<ChatMessage> notesMessages({
    required String title,
    required String brief,
    CourseContext? course,
    bool withChecks = false,
  }) =>
      [
        ChatMessage.system(_notesSystem(withChecks)),
        ChatMessage.user(
            Prompts.notesUser(title: title, brief: brief, course: course)),
      ];

  /// Asks for one targeted rewrite of notes whose checks failed.
  static List<ChatMessage> repairMessages({
    required String title,
    required String notesMarkdown,
    required List<MathCheck> checks,
    required List<CheckOutcome> outcomes,
  }) =>
      [
        ChatMessage.system(_notesSystem(true)),
        ChatMessage.user(Prompts.repairUser(
          title: title,
          notesMarkdown: notesMarkdown,
          checksBlock: formatChecks(checks),
          failures: formatFailures(checks, outcomes),
        )),
      ];

  static List<ChatMessage> verifyMessages({
    required String title,
    required String notesMarkdown,
  }) =>
      [
        const ChatMessage.system(Prompts.verifySystem),
        ChatMessage.user(
            Prompts.verifyUser(title: title, notesMarkdown: notesMarkdown)),
      ];

  /// Has the lesson model judge which of the reviewer's [issues] are real.
  static List<ChatMessage> judgeMessages({
    required String title,
    required String notesMarkdown,
    required List<ProofIssue> issues,
  }) =>
      [
        const ChatMessage.system(Prompts.judgeSystem),
        ChatMessage.user(Prompts.judgeUser(
          title: title,
          notesMarkdown: notesMarkdown,
          issues: formatIssues(issues),
        )),
      ];

  static List<ChatMessage> proofRepairMessages({
    required String title,
    required String notesMarkdown,
    required List<ProofIssue> issues,
    bool withChecks = false,
  }) =>
      [
        ChatMessage.system(_notesSystem(withChecks)),
        ChatMessage.user(Prompts.proofRepairUser(
          title: title,
          notesMarkdown: notesMarkdown,
          issues: formatIssues(issues),
        )),
      ];

  static String _notesSystem(bool withChecks) => withChecks
      ? Prompts.notesSystem + Prompts.checksAddendum
      : Prompts.notesSystem;

  static List<ChatMessage> narrationMessages({
    required String title,
    required String notesMarkdown,
    CourseContext? course,
    bool fromBook = false,
    NarrationPart? part,
    bool recall = false,
  }) =>
      [
        const ChatMessage.system(Prompts.narrationSystem),
        ChatMessage.user(Prompts.narrationUser(
          title: title,
          notesMarkdown: notesMarkdown,
          course: course,
          fromBook: fromBook,
          part: part,
          recall: recall,
        )),
      ];

  /// Script of the short review lecture of a lesson listened to earlier.
  static List<ChatMessage> recapMessages({
    required String title,
    required String notesMarkdown,
  }) =>
      [
        const ChatMessage.system(Prompts.narrationSystem),
        ChatMessage.user(
            Prompts.recapUser(title: title, notesMarkdown: notesMarkdown)),
      ];

  /// Key summary of one lesson, for the reviews that cover it.
  static List<ChatMessage> digestMessages({
    required String title,
    required String notesMarkdown,
  }) =>
      [
        const ChatMessage.system(Prompts.digestSystem),
        ChatMessage.user(
            Prompts.digestUser(title: title, notesMarkdown: notesMarkdown)),
      ];

  /// Short lesson and flashcards of a review of [lessons].
  static List<ChatMessage> reviewMessages(
          List<({String title, String digest})> lessons) =>
      [
        const ChatMessage.system(Prompts.reviewSystem),
        ChatMessage.user(Prompts.reviewUser(lessons)),
      ];

  /// The short lesson of a review and the flashcards that follow it.
  static ({String notes, List<Flashcard> cards}) parseReview(String raw) {
    final split = splitNotesAndCards(raw);
    return (notes: parseNotes(split.notes).notes, cards: split.cards);
  }

  static NotesDraft parseNotes(String raw) {
    final split = splitNotesAndChecks(raw);
    final notes = cleanNotes(split.notes);
    if (notes.isEmpty) {
      throw const FormatException('The model returned empty lecture notes.');
    }
    return NotesDraft(notes: notes, checks: split.checks);
  }

  static List<NarrationSegment> parseScript(String raw) {
    final segments = parseNarration(raw);
    if (segments.length < 3) {
      throw const FormatException(
          'The model did not return a usable lecture script.');
    }
    return segments;
  }

  /// Sends one notes or script request and waits for the full answer.
  /// [model] and [effort] override the lesson model for this request (the
  /// proof reviewer is a different model).
  Future<String> ask(
    List<ChatMessage> messages, {
    required double temperature,
    String? model,
    String? effort,
    void Function(int chars)? onProgress,
  }) =>
      client.chat(
        model: model ?? this.model,
        temperature: temperature,
        reasoningEffort: model == null ? this.effort : effort,
        messages: messages,
        onProgress: onProgress,
      );
}
