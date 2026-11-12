import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/providers.dart';
import '../tts/kokoro_engine.dart';
import 'widgets.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late final TextEditingController _key;
  late final TextEditingController _model;
  late final TextEditingController _ttsModel;
  late final TextEditingController _ttsVoice;
  Timer? _debounce;
  bool _showKey = false;

  bool? _installed;
  bool _installing = false;
  double? _installFraction;
  String? _installError;

  @override
  void initState() {
    super.initState();
    final s = ref.read(settingsProvider);
    _key = TextEditingController(text: s.apiKey);
    _model = TextEditingController(text: s.chatModel);
    _ttsModel = TextEditingController(text: s.openRouterTtsModel);
    _ttsVoice = TextEditingController(text: s.openRouterTtsVoice);
    _refreshInstalled();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _key.dispose();
    _model.dispose();
    _ttsModel.dispose();
    _ttsVoice.dispose();
    super.dispose();
  }

  Future<void> _refreshInstalled() async {
    final v = await ref.read(kokoroModelProvider).isInstalled();
    if (mounted) setState(() => _installed = v);
  }

  void _update(AppSettings Function(AppSettings) f) =>
      ref.read(settingsProvider.notifier).update(f);

  /// Saves text edits shortly after the user stops typing.
  void _debounced(AppSettings Function(AppSettings) f) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () => _update(f));
  }

  Future<void> _install() async {
    setState(() {
      _installing = true;
      _installFraction = 0;
      _installError = null;
    });
    try {
      await ref.read(kokoroModelProvider).install(onProgress: (f) {
        if (mounted) setState(() => _installFraction = f);
      });
    } catch (e) {
      if (mounted) setState(() => _installError = e.toString());
    }
    if (!mounted) return;
    setState(() => _installing = false);
    _refreshInstalled();
  }

  Future<void> _deleteModel() async {
    if (!await confirmDelete(context, what: 'the downloaded voice model')) {
      return;
    }
    await ref.read(kokoroModelProvider).delete();
    _refreshInstalled();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    Widget section(String title) => Padding(
          padding: const EdgeInsets.fromLTRB(0, 24, 0, 8),
          child: Semantics(
            header: true,
            child: Text(title,
                style: text.titleMedium?.copyWith(color: scheme.primary)),
          ),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: ContentWidth(
          maxWidth: 640,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
            children: [
              section('OpenRouter'),
              TextField(
                controller: _key,
                obscureText: !_showKey,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.visiblePassword,
                decoration: InputDecoration(
                  labelText: 'API key',
                  border: const OutlineInputBorder(),
                  helperText:
                      'Stored only on this device, in secure storage. Create a key at openrouter.ai/keys.',
                  helperMaxLines: 3,
                  suffixIcon: IconButton(
                    tooltip: _showKey ? 'Hide key' : 'Show key',
                    icon: Icon(_showKey
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined),
                    onPressed: () => setState(() => _showKey = !_showKey),
                  ),
                ),
                onChanged: (v) => _debounced((s) => s.copyWith(apiKey: v.trim())),
                onSubmitted: (v) => _update((s) => s.copyWith(apiKey: v.trim())),
                onTapOutside: (_) => FocusScope.of(context).unfocus(),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _model,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: 'Lesson model',
                  hintText: AppSettings.defaultChatModel,
                  border: const OutlineInputBorder(),
                  helperText: 'Default: ${AppSettings.defaultChatModel}',
                  suffixIcon: s.chatModel == AppSettings.defaultChatModel
                      ? null
                      : IconButton(
                          tooltip: 'Reset to default',
                          icon: const Icon(Icons.restart_alt),
                          onPressed: () {
                            _debounce?.cancel();
                            _model.text = AppSettings.defaultChatModel;
                            _update((s) => s.copyWith(
                                chatModel: AppSettings.defaultChatModel));
                          },
                        ),
                ),
                onChanged: (v) => _debounced((s) => s.copyWith(
                    chatModel: v.trim().isEmpty
                        ? AppSettings.defaultChatModel
                        : v.trim())),
                onTapOutside: (_) => FocusScope.of(context).unfocus(),
              ),
              section('Voice'),
              SegmentedButton<TtsBackend>(
                segments: const [
                  ButtonSegment(
                      value: TtsBackend.kokoro, label: Text('On-device (Kokoro)')),
                  ButtonSegment(
                      value: TtsBackend.openRouter, label: Text('OpenRouter')),
                ],
                selected: {s.ttsBackend},
                onSelectionChanged: (v) =>
                    _update((s) => s.copyWith(ttsBackend: v.first)),
              ),
              const SizedBox(height: 16),
              if (s.ttsBackend == TtsBackend.kokoro) ...[
                DropdownButtonFormField<int>(
                  isExpanded: true,
                  initialValue: s.kokoroVoice.clamp(0, kokoroVoices.length - 1),
                  decoration: const InputDecoration(
                      labelText: 'Voice', border: OutlineInputBorder()),
                  items: [
                    for (var i = 0; i < kokoroVoices.length; i++)
                      DropdownMenuItem(
                          value: i,
                          child: Text(kokoroVoices[i],
                              overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (v) {
                    if (v != null) _update((s) => s.copyWith(kokoroVoice: v));
                  },
                ),
                const SizedBox(height: 12),
                _modelRow(text, scheme),
              ] else ...[
                TextField(
                  controller: _ttsModel,
                  autocorrect: false,
                  decoration: const InputDecoration(
                      labelText: 'TTS model', border: OutlineInputBorder()),
                  onChanged: (v) => _debounced(
                      (s) => s.copyWith(openRouterTtsModel: v.trim())),
                  onTapOutside: (_) => FocusScope.of(context).unfocus(),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _ttsVoice,
                  autocorrect: false,
                  decoration: const InputDecoration(
                      labelText: 'Voice name', border: OutlineInputBorder()),
                  onChanged: (v) => _debounced(
                      (s) => s.copyWith(openRouterTtsVoice: v.trim())),
                  onTapOutside: (_) => FocusScope.of(context).unfocus(),
                ),
              ],
              section('Lecture pacing'),
              Text('Thinking pauses', style: text.bodyLarge),
              Slider(
                value: s.pauseScale.clamp(0.5, 2.5),
                min: 0.5,
                max: 2.5,
                divisions: 8,
                label: '${_fmt(s.pauseScale)}×',
                semanticFormatterCallback: (v) => '${_fmt(v)} times',
                onChanged: (v) => _update((s) => s.copyWith(pauseScale: v)),
              ),
              Text(
                '${_fmt(s.pauseScale)}× · Applies to lectures recorded from now on.',
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 20),
              Text('Double-tap skip', style: text.bodyLarge),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final n in const [5, 10, 15, 30])
                    ChoiceChip(
                      label: Text('$n s'),
                      selected: s.skipSeconds == n,
                      onSelected: (_) =>
                          _update((s) => s.copyWith(skipSeconds: n)),
                    ),
                ],
              ),
              section('About'),
              Text(
                'LearnMath turns your questions into graduate-level lectures, written and narrated by AI. Check important results against a textbook.',
                style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _fmt(double v) {
    final t = v.toStringAsFixed(2);
    return t.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }

  Widget _modelRow(TextTheme text, ColorScheme scheme) {
    if (_installing) {
      final f = _installFraction;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
              f == null
                  ? 'Unpacking voice model…'
                  : 'Downloading voice model… ${(f * 100).round()}%',
              style: text.bodyMedium),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: f),
        ],
      );
    }
    final installed = _installed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
                installed == true
                    ? Icons.check_circle_outline
                    : Icons.download_for_offline_outlined,
                color: scheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                installed == null
                    ? 'Checking voice model…'
                    : installed
                        ? 'Voice model installed'
                        : 'Not downloaded (about 100 MB)',
                style: text.bodyLarge,
              ),
            ),
            if (installed == true)
              TextButton(onPressed: _deleteModel, child: const Text('Delete'))
            else if (installed == false)
              FilledButton.tonal(
                  onPressed: _install, child: const Text('Download')),
          ],
        ),
        if (_installError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_installError!,
                style: text.bodyMedium?.copyWith(color: scheme.error)),
          ),
      ],
    );
  }
}
