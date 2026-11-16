import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../core/backup.dart';
import '../core/models.dart';
import '../core/providers.dart';

/// The "Your data" part of Settings: everything in the library as one file,
/// to move to another phone or to keep, and the way back in.
class BackupSection extends ConsumerStatefulWidget {
  const BackupSection({super.key});

  @override
  ConsumerState<BackupSection> createState() => _BackupSectionState();
}

class _BackupSectionState extends ConsumerState<BackupSection> {
  bool _recordings = false;

  /// What is running, for the progress line; null when idle.
  String? _busy;
  String? _message;
  bool _failed = false;

  BackupService get _service => BackupService(
      ref.read(databaseProvider), ref.read(appPathsProvider));

  static String _count(int n, String what) => '$n $what${n == 1 ? '' : 's'}';

  static String _describe(BackupSummary s) => [
        _count(s.lessons, 'lesson'),
        if (s.courses > 0) _count(s.courses, 'course'),
        if (s.recordings > 0) _count(s.recordings, 'recording'),
        if (s.books > 0) _count(s.books, 'book'),
      ].join(', ');

  Future<void> _export() async {
    setState(() {
      _busy = 'Packing your library…';
      _message = null;
    });
    try {
      final dir = p.join(ref.read(appPathsProvider).support, 'export');
      final day = DateTime.now().toIso8601String().substring(0, 10);
      final path = p.join(dir, 'learnmath-backup-$day.zip');
      final summary = await _service.export(path, recordings: _recordings);
      if (!mounted) return;
      setState(() {
        _busy = null;
        _failed = false;
        _message = 'Exported ${_describe(summary)}. Save the file somewhere '
            'you can reach from the other phone.';
      });
      await SharePlus.instance.share(ShareParams(
        files: [XFile(path, mimeType: 'application/zip')],
        subject: 'LearnMath backup',
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = null;
        _failed = true;
        _message = 'The export failed: $e';
      });
    }
  }

  Future<void> _import() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['zip'],
    );
    if (files.isEmpty || !mounted) return;
    final path = files.first.path;
    if (path == null) {
      setState(() {
        _failed = true;
        _message = 'Could not access that file. Pick a backup stored on this '
            'device.';
      });
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Import this backup?'),
        content: const Text(
            'Its courses, lessons, chats and quizzes are added to this '
            'library. A lesson that is already here is replaced by the copy '
            'in the backup, and the settings are taken from the backup. '
            'Nothing else is removed. Your API keys stay as they are.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Import')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _busy = 'Importing…';
      _message = null;
    });
    try {
      final summary = await _service.import(path);
      final settings = summary.settings;
      if (settings != null) {
        // The keys are not in a backup: keep the ones on this device.
        await ref.read(settingsProvider.notifier).update((s) =>
            AppSettings.fromJson(settings,
                apiKey: s.apiKey, mathpixAppKey: s.mathpixAppKey));
      }
      if (!mounted) return;
      setState(() {
        _busy = null;
        _failed = false;
        _message = 'Imported ${_describe(summary)}.'
            '${summary.recordings == 0 && summary.lessons > 0 ? ' The backup has no recordings: open a lesson that was finished and tap "Record the lecture" to record it on this device.' : ''}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = null;
        _failed = true;
        _message = e is BackupException ? e.message : 'The import failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final busy = _busy != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 24, bottom: 8),
          child: Semantics(
            header: true,
            child: Text('Your data',
                style: text.titleMedium?.copyWith(color: scheme.primary)),
          ),
        ),
        Text(
          'Everything in your library as one file, for moving to another '
          'phone or keeping a copy: courses, lessons with their notes and '
          'lecture scripts, chats, quizzes, flashcards, imported books and '
          'these settings. Your API keys are not included.',
          style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Include the recordings'),
          subtitle: const Text(
              'Off: a small file, and lectures are recorded again on the '
              'other phone from their scripts (no key needed). On: about '
              '3 MB per minute of lecture.'),
          value: _recordings,
          onChanged: busy ? null : (v) => setState(() => _recordings = v),
        ),
        const SizedBox(height: 4),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.tonalIcon(
            onPressed: busy ? null : _export,
            icon: const Icon(Icons.upload_file_outlined),
            label: const Text('Export all data'),
          ),
          OutlinedButton.icon(
            onPressed: busy ? null : _import,
            icon: const Icon(Icons.download_outlined),
            label: const Text('Import a backup'),
          ),
        ]),
        if (busy)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(children: [
              const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 12),
              Expanded(child: Text(_busy!, style: text.bodyMedium)),
            ]),
          ),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_message!,
                style: text.bodyMedium
                    ?.copyWith(color: _failed ? scheme.error : null)),
          ),
      ],
    );
  }
}
