import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../ai/lesson_import.dart';
import '../ai/narration_parser.dart';
import '../ai/prompts.dart';
import '../core/models.dart';
import '../core/providers.dart';
import 'widgets.dart';

/// A lesson written by the student's own assistant (ChatGPT, Claude,
/// Gemini, …) instead of through OpenRouter: the app hands out the prompt,
/// and reads the answer back from the clipboard or a file.
///
/// Three uses: a standalone lesson on a topic; the plan of a course
/// ([course]), whose lessons are then pending; and the content of one such
/// planned lesson ([lessonId]).
class ImportLessonScreen extends ConsumerStatefulWidget {
  const ImportLessonScreen({
    super.key,
    this.topic = '',
    this.course = false,
    this.lessonId,
    this.continues,
  });

  /// What the student had already typed in the create sheet.
  final String topic;

  /// Plan a course instead of writing a lesson.
  final bool course;

  /// The planned lesson of a course to write, instead of a new one.
  final String? lessonId;

  /// With [course]: plan the next part of this course's series; the topic
  /// field then says what the new part should cover (optional).
  final String? continues;

  @override
  ConsumerState<ImportLessonScreen> createState() => _ImportLessonScreenState();
}

class _ImportLessonScreenState extends ConsumerState<ImportLessonScreen> {
  late final _topic = TextEditingController(text: widget.topic);
  String _answer = '';
  ImportedLesson? _lesson;
  CourseOutline? _outline;
  int? _count; // lessons in the course; null = the assistant decides
  String? _error;
  bool _importing = false;

  /// The planned lesson being written and its place in the course.
  Lesson? _target;
  CourseContext? _context;
  bool _targetMissing = false;

  @override
  void initState() {
    super.initState();
    _topic.addListener(() => setState(() {}));
    final id = widget.lessonId;
    if (id != null) _loadTarget(id);
  }

  Future<void> _loadTarget(String id) async {
    final lesson = await ref.read(repositoryProvider).getLesson(id);
    final context = lesson == null
        ? null
        : await ref.read(generationProvider).courseContext(lesson);
    if (!mounted) return;
    setState(() {
      _target = lesson;
      _context = context;
      _targetMissing = lesson == null;
    });
  }

  @override
  void dispose() {
    _topic.dispose();
    super.dispose();
  }

  /// The prompt to hand over; a continuation's is read from the earlier
  /// parts.
  Future<String> _promptText() async {
    final continues = widget.continues;
    if (continues == null) return _prompt;
    return ref.read(generationProvider).continuationPrompt(continues,
        steer: _topic.text, lessonCount: _count);
  }

  String get _prompt {
    if (widget.course) {
      return Prompts.externalOutline(_topic.text, lessonCount: _count);
    }
    final settings = ref.read(settingsProvider);
    final target = _target;
    return Prompts.externalLesson(
      target?.title ?? _topic.text,
      brief: target?.brief ?? '',
      course: _context,
      withChecks: settings.mathChecks,
      recall: settings.recallQuestions,
    );
  }

  void _say(String message) => ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));

  Future<void> _copyPrompt() async {
    await Clipboard.setData(ClipboardData(text: await _promptText()));
    if (!mounted) return;
    _say('Prompt copied. Paste it into your assistant.');
  }

  Future<void> _sharePrompt() async =>
      SharePlus.instance.share(ShareParams(text: await _promptText()));

  /// Reads [text] as the answer, or as its continuation when [append].
  void _take(String text, {bool append = false}) {
    final answer = append ? '$_answer\n$text' : text;
    setState(() {
      _answer = answer;
      _lesson = null;
      _outline = null;
      _error = null;
      try {
        if (widget.course) {
          _outline = parseOutline(answer);
        } else {
          _lesson = parseImportedLesson(answer);
        }
      } on FormatException catch (e) {
        _error = widget.course
            ? 'No course plan found. Copy the whole answer, from COURSE: to '
                'the last BRIEF: line.'
            : e.message;
      }
    });
  }

  Future<void> _paste({bool append = false}) async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    if (!mounted) return;
    if (text.trim().isEmpty) {
      _say('The clipboard is empty. Copy the assistant\'s answer first.');
      return;
    }
    _take(text, append: append);
  }

  Future<void> _pickFile() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['md', 'markdown', 'txt'],
    );
    if (files.isEmpty || !mounted) return;
    final file = files.first;
    try {
      // A browser has no file system, so read the picked file's bytes.
      final String text;
      if (kIsWeb) {
        text = utf8.decode(await file.readAsBytes(), allowMalformed: true);
      } else {
        final path = file.path;
        if (path == null) throw const FileSystemException();
        text = await File(path).readAsString();
      }
      if (mounted) _take(text);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _lesson = null;
        _outline = null;
        _error = 'Could not read that file. Pick a text or Markdown file '
            'stored on this device.';
      });
    }
  }

  Future<void> _import() async {
    final lesson = _lesson;
    final outline = _outline;
    if ((lesson == null && outline == null) || _importing) return;
    setState(() => _importing = true);
    final router = GoRouter.of(context);
    final gen = ref.read(generationProvider);
    try {
      if (outline != null) {
        final continues = widget.continues;
        final id = continues == null
            ? await gen.importCourse(outline)
            : await gen.importContinuation(continues, outline);
        router.pushReplacement('/course/$id');
      } else if (widget.lessonId != null) {
        // Back to the course, where the next lesson is waiting.
        await gen.importLesson(lesson!, into: widget.lessonId);
        router.pop();
      } else {
        final id = await gen.importLesson(lesson!);
        router.pushReplacement('/lesson/$id');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _importing = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final hasKey = ref.watch(settingsProvider.select((s) => s.hasApiKey));
    final lesson = _lesson;
    final outline = _outline;
    final target = _target;
    final isCourse = widget.course;
    if (_targetMissing) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('This lesson no longer exists.')),
      );
    }
    final hasTopic = widget.lessonId != null
        ? target != null
        : widget.continues != null || _topic.text.trim().isNotEmpty;
    // Without a script the app has to write one itself.
    final canImport =
        outline != null || (lesson != null && (lesson.hasScript || hasKey));

    return Scaffold(
      appBar: AppBar(
          title: Text(widget.continues != null
              ? 'Plan the next part with your own AI'
              : isCourse
              ? 'Plan a course with your own AI'
              : 'Write it with your own AI')),
      body: SafeArea(
        child: CentredListView(
            maxWidth: 640,
            padding: const EdgeInsets.all(16),
            children: [
            Text(
              isCourse
                  ? 'No OpenRouter key needed: an assistant you already use '
                      '(ChatGPT, Claude, Gemini, …) plans the course. Its '
                      'lessons are then written the same way, one at a time, '
                      'from the course page.'
                  : 'No OpenRouter key needed: an assistant you already use '
                      '(ChatGPT, Claude, Gemini, …) writes the lesson, and '
                      'this app checks it and records the lecture on your '
                      'device.',
              style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Text('1. Give your assistant the prompt', style: tt.titleMedium),
            const SizedBox(height: 8),
            if (widget.lessonId != null)
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: target == null
                      ? const LinearProgressIndicator()
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (_context != null)
                              Text(
                                'Lesson ${_context!.lessonIndex + 1} of '
                                '${_context!.lessonTitles.length} · '
                                '${_context!.courseTitle}',
                                style: tt.labelMedium
                                    ?.copyWith(color: cs.onSurfaceVariant),
                              ),
                            Text(target.title, style: tt.titleMedium),
                            if (target.brief.isNotEmpty)
                              Text(target.brief, style: tt.bodyMedium),
                          ],
                        ),
                ),
              )
            else
              TextField(
                controller: _topic,
                enabled: !_importing,
                minLines: 2,
                maxLines: 5,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: widget.continues != null
                      ? 'What should the next part cover? (optional)'
                      : isCourse
                          ? 'Course topic'
                          : 'What do you want to learn?',
                  hintText: widget.continues != null
                      ? 'Go on to unbounded operators'
                      : isCourse
                          ? 'Galois theory'
                          : 'Sylow theorems',
                  border: const OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
            if (isCourse) ...[
              const SizedBox(height: 12),
              Text('Number of lessons', style: tt.labelLarge),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                for (final n in const <int?>[null, 4, 6, 8, 10, 12])
                  ChoiceChip(
                    label: Text(n == null ? 'Auto' : '$n'),
                    selected: _count == n,
                    onSelected: _importing
                        ? null
                        : (_) => setState(() => _count = n),
                  ),
              ]),
            ],
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.tonalIcon(
                onPressed: hasTopic ? _copyPrompt : null,
                icon: const Icon(Icons.copy),
                label: const Text('Copy prompt'),
              ),
              OutlinedButton.icon(
                onPressed: hasTopic ? _sharePrompt : null,
                icon: const Icon(Icons.share_outlined),
                label: const Text('Send to an app'),
              ),
            ]),
            const SizedBox(height: 8),
            Text(
              'Use the strongest model you have, with thinking switched on. '
              'The answer comes as one code block.',
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            Text('2. Bring the answer back', style: tt.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Tap the copy button of the code block, not of the whole '
              'message, then paste here.',
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.tonalIcon(
                onPressed: _importing ? null : _paste,
                icon: const Icon(Icons.content_paste),
                label: Text(_answer.isEmpty ? 'Paste answer' : 'Paste again'),
              ),
              OutlinedButton.icon(
                onPressed: _importing ? null : _pickFile,
                icon: const Icon(Icons.description_outlined),
                label: const Text('Open a file'),
              ),
            ]),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!,
                    style: tt.bodyMedium?.copyWith(color: cs.error)),
              ),
            if (lesson != null) ...[
              const SizedBox(height: 12),
              _Found(
                lesson: lesson,
                onContinue:
                    lesson.cutOff && !_importing ? () => _paste(append: true) : null,
              ),
              if (!lesson.hasScript && !hasKey)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Without the script there is nothing to record, and '
                    'writing one here needs an OpenRouter key.',
                    style: tt.bodyMedium?.copyWith(color: cs.error),
                  ),
                ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: canImport && !_importing ? _import : null,
                child: Text(lesson.hasScript
                    ? 'Import and record the lecture'
                    : 'Import and write the script here'),
              ),
            ],
            if (outline != null) ...[
              const SizedBox(height: 12),
              _Plan(outline: outline),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _importing ? null : _import,
                child: const Text('Create course'),
              ),
            ],
          ]),
      ),
    );
  }
}

/// The course found in the pasted answer.
class _Plan extends StatelessWidget {
  const _Plan({required this.outline});
  final CourseOutline outline;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(outline.title, style: tt.titleMedium),
            if (outline.description.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(outline.description,
                    style: tt.bodyMedium
                        ?.copyWith(color: cs.onSurfaceVariant)),
              ),
            const SizedBox(height: 8),
            for (var i = 0; i < outline.lessons.length; i++)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('${i + 1}. ${outline.lessons[i].title}',
                    style: tt.bodyMedium),
              ),
          ],
        ),
      ),
    );
  }
}

/// What was recognised in the pasted answer.
class _Found extends StatelessWidget {
  const _Found({required this.lesson, this.onContinue});

  final ImportedLesson lesson;

  /// Adds the clipboard as the continuation of a cut-off answer.
  final VoidCallback? onContinue;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final n = lesson.checks.length;
    final facts = [
      'Notes: ${lesson.notesWords} words',
      if (n > 0) '$n ${n == 1 ? 'computation' : 'computations'} to check',
      if (lesson.hasScript)
        'Lecture: about ${lesson.estimatedDuration.inMinutes.clamp(1, 999)} min',
    ];
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(lesson.title, style: tt.titleMedium),
            const SizedBox(height: 4),
            Text(facts.join(' · '),
                style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
            for (final w in lesson.warnings)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.warning_amber, size: 20, color: cs.tertiary),
                    const SizedBox(width: 8),
                    Expanded(child: Text(w, style: tt.bodyMedium)),
                  ],
                ),
              ),
            if (onContinue != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: onContinue,
                  icon: const Icon(Icons.playlist_add),
                  label: const Text('Paste the continuation'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
