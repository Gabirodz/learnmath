import 'package:learnmath/ai/narration_parser.dart';
import 'package:learnmath/ai/openrouter_client.dart';
import 'package:learnmath/ai/prompts.dart';
import 'package:learnmath/core/models.dart';

/// Turns topics into outlines, lecture notes and narration scripts.
class LessonGenerator {
  LessonGenerator(this.client, {required this.model});

  final OpenRouterClient client;
  final String model;

  Future<CourseOutline> generateOutline(String topic, {int? lessonCount}) async {
    final raw = await client.chat(
      model: model,
      temperature: 0.4,
      messages: [
        const ChatMessage.system(Prompts.outlineSystem),
        ChatMessage.user(Prompts.outlineUser(topic, lessonCount: lessonCount)),
      ],
    );
    return parseOutline(raw);
  }

  Future<String> generateNotes({
    required String title,
    required String brief,
    CourseContext? course,
    void Function(int chars)? onProgress,
  }) async {
    final raw = await client.chat(
      model: model,
      temperature: 0.5,
      messages: [
        const ChatMessage.system(Prompts.notesSystem),
        ChatMessage.user(
            Prompts.notesUser(title: title, brief: brief, course: course)),
      ],
      onProgress: onProgress,
    );
    final notes = cleanNotes(raw);
    if (notes.isEmpty) {
      throw const FormatException('The model returned empty lecture notes.');
    }
    return notes;
  }

  Future<List<NarrationSegment>> generateNarration({
    required String title,
    required String notesMarkdown,
    CourseContext? course,
    bool fromBook = false,
    NarrationPart? part,
    void Function(int chars)? onProgress,
  }) async {
    final raw = await client.chat(
      model: model,
      temperature: 0.6,
      messages: [
        const ChatMessage.system(Prompts.narrationSystem),
        ChatMessage.user(Prompts.narrationUser(
          title: title,
          notesMarkdown: notesMarkdown,
          course: course,
          fromBook: fromBook,
          part: part,
        )),
      ],
      onProgress: onProgress,
    );
    final segments = parseNarration(raw);
    if (segments.length < 3) {
      throw const FormatException(
          'The model did not return a usable lecture script.');
    }
    return segments;
  }
}
