import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart' show PdfException, PdfPasswordException;

import '../ai/openrouter_client.dart';
import '../core/providers.dart';
import '../ui/widgets.dart';
import 'book_importer.dart';
import 'chapter_plan.dart';
import 'pdf_source.dart';
import 'toc_detector.dart';

class BookImportScreen extends ConsumerStatefulWidget {
  const BookImportScreen({super.key});

  @override
  ConsumerState<BookImportScreen> createState() => _BookImportScreenState();
}

class _BookImportScreenState extends ConsumerState<BookImportScreen> {
  final _titleCtrl = TextEditingController();
  PdfSource? _pdf;
  String? _path;
  int _pageCount = 0;
  List<ChapterPlan> _chapters = [];
  bool _noOutline = false;
  bool _reading = false;
  bool _detecting = false;
  bool _importing = false;
  String? _status;
  String? _error;
  String? _aiError;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _pdf?.close();
    super.dispose();
  }

  static String _cleanTitle(String path) {
    final base = p.basenameWithoutExtension(path);
    return base.replaceAll(RegExp(r'[_]+'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  Future<void> _pick() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
    );
    if (files.isEmpty || !mounted) return;
    final path = files.first.path;
    if (path == null) {
      setState(() => _error = 'Could not access that file. Pick a PDF stored on this device.');
      return;
    }
    await _load(path);
  }

  Future<void> _load(String path) async {
    final old = _pdf;
    setState(() {
      _reading = true;
      _error = null;
      _aiError = null;
      _pdf = null;
      _path = null;
      _chapters = [];
    });
    await old?.close();
    PdfSource? pdf;
    try {
      pdf = await PdfSource.open(path);
      if (pdf.pageCount < 1) throw const FormatException('This PDF has no pages.');
      final outline = await pdf.outline();
      var plan = planFromOutline(outline, pdf.pageCount);
      var none = false;
      if (plan.length < 2) {
        none = true;
        plan = planEvenly(pdf.pageCount);
      }
      if (!mounted) {
        await pdf.close();
        return;
      }
      setState(() {
        _pdf = pdf;
        _path = path;
        _pageCount = pdf!.pageCount;
        _chapters = plan;
        _noOutline = none;
        _titleCtrl.text = _cleanTitle(path);
        _reading = false;
      });
    } catch (e) {
      await pdf?.close();
      if (!mounted) return;
      setState(() {
        _reading = false;
        _error = e is PdfPasswordException
            ? 'This PDF is password-protected. Remove the password and try again.'
            : e is PdfException
                ? 'This PDF could not be read. It may be damaged or encrypted.'
                : e is FormatException
                    ? e.message
                    : 'This PDF could not be opened: $e';
      });
    }
  }

  Future<void> _detect() async {
    final pdf = _pdf;
    if (pdf == null) return;
    final settings = ref.read(settingsProvider);
    setState(() {
      _detecting = true;
      _aiError = null;
      _status = 'Starting…';
    });
    final client = OpenRouterClient(apiKey: settings.apiKey);
    try {
      final plan = await detectChaptersWithAi(
        pdf: pdf,
        client: client,
        model: settings.visionModel,
        onStatus: (s) {
          if (mounted) setState(() => _status = s);
        },
      );
      if (!mounted) return;
      setState(() {
        _chapters = plan;
        _noOutline = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _aiError = e is FormatException ? e.message : e.toString());
      }
    } finally {
      client.close();
      if (mounted) setState(() => _detecting = false);
    }
  }

  void _setChapters(List<ChapterPlan> list) =>
      setState(() => _chapters = normalizePlan(list, _pageCount));

  Future<void> _edit({int? index}) async {
    final existing = index == null ? null : _chapters[index];
    final result = await showDialog<(String, int)>(
      context: context,
      builder: (_) => _ChapterDialog(
        pageCount: _pageCount,
        title: existing?.title ?? '',
        startPage: existing?.startPage ?? 1,
        isNew: existing == null,
      ),
    );
    if (result == null) return;
    final list = [for (final c in _chapters) c.copy()];
    if (existing == null) {
      list.add(ChapterPlan(
          title: result.$1, startPage: result.$2, endPage: result.$2));
    } else {
      list[index!]
        ..title = result.$1
        ..startPage = result.$2
        ..startsMidPage = existing.startPage == result.$2 ? existing.startsMidPage : true;
    }
    _setChapters(list);
  }

  void _delete(int i) {
    final list = [for (final c in _chapters) c.copy()]..removeAt(i);
    _setChapters(list);
  }

  void _mergePrev(int i) {
    if (i == 0) return;
    final list = [for (final c in _chapters) c.copy()]..removeAt(i);
    _setChapters(list);
  }

  Future<void> _import() async {
    final path = _path;
    if (path == null || _chapters.isEmpty) return;
    setState(() => _importing = true);
    try {
      final id = await BookImporter(
        repo: ref.read(repositoryProvider),
        paths: ref.read(appPathsProvider),
      ).import(
        sourcePath: path,
        title: _titleCtrl.text,
        pageCount: _pageCount,
        chapters: _chapters,
      );
      if (!mounted) return;
      context.go('/course/$id');
    } catch (e) {
      if (!mounted) return;
      setState(() => _importing = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Import failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final loaded = _pdf != null;
    final busy = _reading || _detecting || _importing;

    Widget body;
    if (_reading) {
      body = const Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        CircularProgressIndicator(),
        SizedBox(height: 16),
        Text('Reading the table of contents…'),
      ]));
    } else if (!loaded) {
      body = ListView(padding: const EdgeInsets.all(16), children: [
        const SizedBox(height: 24),
        Icon(Icons.menu_book_outlined, size: 64, color: cs.primary),
        const SizedBox(height: 16),
        Text('Import your own textbook',
            style: tt.titleLarge, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text(
          'The book stays on this device. Pages are only sent to the AI '
          'service when you open a chapter.',
          style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        Center(
          child: FilledButton.icon(
            onPressed: _pick,
            icon: const Icon(Icons.upload_file),
            label: const Padding(
                padding: EdgeInsets.symmetric(vertical: 14, horizontal: 8),
                child: Text('Choose a PDF')),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          Card(
            color: cs.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_error!, style: TextStyle(color: cs.onErrorContainer)),
            ),
          ),
        ],
      ]);
    } else {
      final hasKey = ref.watch(settingsProvider).hasApiKey;
      body = ListView(padding: const EdgeInsets.all(16), children: [
        TextField(
          controller: _titleCtrl,
          enabled: !busy,
          decoration: const InputDecoration(
              labelText: 'Book title', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 8),
        Text(
          '$_pageCount pages · ${_chapters.length} chapters',
          style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: busy ? null : _pick,
          icon: const Icon(Icons.swap_horiz),
          label: const Text('Choose a different PDF'),
        ),
        if (_noOutline)
          Card(
            color: cs.secondaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(Icons.info_outline, color: cs.onSecondaryContainer),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'This PDF has no bookmarks. Chapters were split every 15 pages.',
                        style: TextStyle(color: cs.onSecondaryContainer),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  if (_detecting)
                    Row(children: [
                      const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: 12),
                      Expanded(
                          child: Text(_status ?? '',
                              style: TextStyle(color: cs.onSecondaryContainer))),
                    ])
                  else if (hasKey)
                    FilledButton.tonalIcon(
                      onPressed: busy ? null : _detect,
                      icon: const Icon(Icons.auto_awesome),
                      label: const Text('Detect chapters with AI'),
                    )
                  else
                    Text('Add an OpenRouter API key in Settings to detect chapters with AI.',
                        style: tt.bodySmall?.copyWith(color: cs.onSecondaryContainer)),
                  if (_aiError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(_aiError!, style: TextStyle(color: cs.error)),
                    ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 8),
        for (var i = 0; i < _chapters.length; i++) _row(context, i, busy),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: busy ? null : () => _edit(),
            icon: const Icon(Icons.add),
            label: const Text('Add chapter'),
          ),
        ),
      ]);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Import a book')),
      body: SafeArea(
        child: Column(children: [
          Expanded(child: ContentWidth(maxWidth: 800, child: body)),
          if (loaded)
            Material(
              elevation: 3,
              color: cs.surfaceContainer,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: ContentWidth(
                    maxWidth: 800,
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: busy || _chapters.isEmpty ? null : _import,
                        child: _importing
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2))
                            : const Text('Import'),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ]),
      ),
    );
  }

  Widget _row(BuildContext context, int i, bool busy) {
    final cs = Theme.of(context).colorScheme;
    final c = _chapters[i];
    final long = c.pageCount > 40;
    final range = c.startPage == c.endPage
        ? 'p. ${c.startPage} (1 page)'
        : 'pp. ${c.startPage}–${c.endPage} (${c.pageCount} pages)';
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: busy ? null : () => _edit(index: i),
        title: Text(c.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          long ? '$range\nlong chapter — lectures will be long' : range,
          style: TextStyle(color: long ? cs.tertiary : null),
        ),
        isThreeLine: long,
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (i > 0)
            IconButton(
              tooltip: 'Merge with previous',
              icon: const Icon(Icons.call_merge),
              onPressed: busy ? null : () => _mergePrev(i),
            ),
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline),
            onPressed: busy ? null : () => _delete(i),
          ),
        ]),
      ),
    );
  }
}

class _ChapterDialog extends StatefulWidget {
  const _ChapterDialog({
    required this.pageCount,
    required this.title,
    required this.startPage,
    required this.isNew,
  });
  final int pageCount;
  final String title;
  final int startPage;
  final bool isNew;

  @override
  State<_ChapterDialog> createState() => _ChapterDialogState();
}

class _ChapterDialogState extends State<_ChapterDialog> {
  late final _title = TextEditingController(text: widget.title);
  late final _page = TextEditingController(text: widget.isNew ? '' : '${widget.startPage}');
  String? _err;

  @override
  void dispose() {
    _title.dispose();
    _page.dispose();
    super.dispose();
  }

  void _ok() {
    final t = _title.text.trim();
    final pg = int.tryParse(_page.text.trim());
    if (t.isEmpty) {
      setState(() => _err = 'Enter a title.');
    } else if (pg == null || pg < 1 || pg > widget.pageCount) {
      setState(() => _err = 'Start page must be between 1 and ${widget.pageCount}.');
    } else {
      Navigator.pop(context, (t, pg));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.isNew ? 'Add chapter' : 'Edit chapter'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: _title,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Title'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _page,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
                labelText: 'Start page (PDF page, 1–${widget.pageCount})',
                errorText: _err,
                errorMaxLines: 2),
            onSubmitted: (_) => _ok(),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _ok, child: const Text('Save')),
      ],
    );
  }
}
