import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/providers.dart';
import '../tts/on_device_tts.dart';
import '../tts/voice_install.dart';
import 'widgets.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late final TextEditingController _key;
  late final TextEditingController _model;
  late final TextEditingController _verifier;
  late final TextEditingController _ttsModel;
  late final TextEditingController _ttsVoice;
  late final TextEditingController _visionModel;
  late final TextEditingController _mathpixId;
  late final TextEditingController _mathpixKey;
  Timer? _debounce;
  bool _showKey = false;

  bool? _installed;
  String? _installingId;
  double? _installFraction;
  String? _installError;

  @override
  void initState() {
    super.initState();
    final s = ref.read(settingsProvider);
    _key = TextEditingController(text: s.apiKey);
    _model = TextEditingController(text: s.chatModel);
    _verifier = TextEditingController(text: s.verifierModel);
    _ttsModel = TextEditingController(text: s.openRouterTtsModel);
    _ttsVoice = TextEditingController(text: s.openRouterTtsVoice);
    _visionModel = TextEditingController(text: s.visionModel);
    _mathpixId = TextEditingController(text: s.mathpixAppId);
    _mathpixKey = TextEditingController(text: s.mathpixAppKey);
    _refreshInstalled();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _key.dispose();
    _model.dispose();
    _verifier.dispose();
    _ttsModel.dispose();
    _ttsVoice.dispose();
    _visionModel.dispose();
    _mathpixId.dispose();
    _mathpixKey.dispose();
    super.dispose();
  }

  Future<void> _refreshInstalled() async {
    final model = VoiceModel.byId(ref.read(settingsProvider).voiceModel);
    final v = await ref.read(voiceModelsProvider).isInstalled(model);
    if (mounted &&
        VoiceModel.byId(ref.read(settingsProvider).voiceModel) == model) {
      setState(() => _installed = v);
    }
  }

  void _update(AppSettings Function(AppSettings) f) =>
      ref.read(settingsProvider.notifier).update(f);

  /// Saves text edits shortly after the user stops typing.
  void _debounced(AppSettings Function(AppSettings) f) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () => _update(f));
  }

  Future<void> _install(VoiceModel model) async {
    setState(() {
      _installingId = model.id;
      _installFraction = 0;
      _installError = null;
    });
    try {
      await installVoiceModel(
        ref.read(voiceModelsProvider),
        model,
        ref.read(notificationsProvider),
        onProgress: (f) {
          if (mounted) setState(() => _installFraction = f);
        },
      );
    } catch (e) {
      if (mounted) setState(() => _installError = e.toString());
    }
    if (!mounted) return;
    setState(() => _installingId = null);
    _refreshInstalled();
  }

  Future<void> _deleteModel(VoiceModel model) async {
    if (!await confirmDelete(context, what: 'the downloaded voice model')) {
      return;
    }
    await ref.read(voiceModelsProvider).delete(model);
    _refreshInstalled();
  }

  void _selectVoiceModel(String id) {
    setState(() {
      _installed = null;
      _installError = null;
    });
    _update((s) => s.copyWith(voiceModel: id, voiceSpeaker: 0));
    _refreshInstalled();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final preset = LessonModelPreset.byId(s.lessonPreset);
    final voice = VoiceModel.byId(s.voiceModel);

    Widget section(String title) => Padding(
      padding: const EdgeInsets.fromLTRB(0, 24, 0, 8),
      child: Semantics(
        header: true,
        child: Text(
          title,
          style: text.titleMedium?.copyWith(color: scheme.primary),
        ),
      ),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: CentredListView(
            maxWidth: 640,
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
                  helperText: 'Stored only on this device, in secure storage. Create a key at openrouter.ai/keys.',
                  helperMaxLines: 3,
                  suffixIcon: IconButton(
                    tooltip: _showKey ? 'Hide key' : 'Show key',
                    icon: Icon(
                      _showKey
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                    ),
                    onPressed: () => setState(() => _showKey = !_showKey),
                  ),
                ),
                onChanged: (v) =>
                    _debounced((s) => s.copyWith(apiKey: v.trim())),
                onSubmitted: (v) =>
                    _update((s) => s.copyWith(apiKey: v.trim())),
                onTapOutside: (_) => FocusScope.of(context).unfocus(),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: preset == null
                    ? LessonModelPreset.customId
                    : preset.id,
                decoration: const InputDecoration(
                  labelText: 'Lesson model',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final p in LessonModelPreset.all)
                    DropdownMenuItem(
                      value: p.id,
                      child: Text(
                        p.id == AppSettings.defaultLessonPreset
                            ? '${p.label} · recommended'
                            : p.label,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  const DropdownMenuItem(
                    value: LessonModelPreset.customId,
                    child: Text('Custom model…'),
                  ),
                ],
                onChanged: (v) {
                  // Another model starts from its own effort again.
                  if (v != null) {
                    _update((s) =>
                        s.copyWith(lessonPreset: v, clearPresetEffort: true));
                  }
                },
              ),
              const SizedBox(height: 8),
              if (preset != null) ...[
                Text(preset.description, style: text.bodySmall),
                const SizedBox(height: 2),
                Text(
                  '${preset.model} · ${s.lessonEffort == null ? 'default reasoning effort' : 'reasoning effort ${s.lessonEffort}'}',
                  style: text.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ] else ...[
                const SizedBox(height: 8),
                TextField(
                  controller: _model,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: 'Model',
                    hintText: AppSettings.defaultChatModel,
                    border: const OutlineInputBorder(),
                    helperText: 'Default: ${AppSettings.defaultChatModel}',
                    helperMaxLines: 2,
                    suffixIcon: s.chatModel == AppSettings.defaultChatModel
                        ? null
                        : IconButton(
                            tooltip: 'Reset to default',
                            icon: const Icon(Icons.restart_alt),
                            onPressed: () {
                              _debounce?.cancel();
                              _model.text = AppSettings.defaultChatModel;
                              _update(
                                (s) => s.copyWith(
                                  chatModel: AppSettings.defaultChatModel,
                                ),
                              );
                            },
                          ),
                  ),
                  onChanged: (v) => _debounced(
                    (s) => s.copyWith(
                      chatModel: v.trim().isEmpty
                          ? AppSettings.defaultChatModel
                          : v.trim(),
                    ),
                  ),
                  onTapOutside: (_) => FocusScope.of(context).unfocus(),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Use the Batch API'),
                  subtitle: const Text('Half price; lessons arrive later'),
                  value: s.customBatch,
                  onChanged: (v) => _update((s) => s.copyWith(customBatch: v)),
                ),
              ],
              if (s.lessonBatch) ...[
                const SizedBox(height: 8),
                Text(
                  'Batch lessons cost about half and are written in the background. '
                  'They usually arrive within minutes, at most a day, and LearnMath '
                  'sends a notification when a lesson is ready.',
                  style: text.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                // Rebuilt with the model: each preset has its own effort.
                key: ValueKey('effort ${s.lessonPreset}'),
                isExpanded: true,
                initialValue: s.lessonEffort ?? '',
                decoration: const InputDecoration(
                  labelText: 'Reasoning effort',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final e in reasoningEfforts)
                    DropdownMenuItem(
                      value: e,
                      child: Text(e == recommendedEffort
                          ? '${_effortLabel(e)} · recommended'
                          : _effortLabel(e)),
                    ),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  _update((s) => preset == null
                      ? s.copyWith(customEffort: v)
                      : s.copyWith(presetEffort: v));
                },
              ),
              const SizedBox(height: 8),
              Text(
                'How long the model thinks before it writes. Higher levels '
                'make fewer mistakes in proofs but cost more and take '
                'longer; lower ones are cheaper and quicker. A model that '
                'lacks a level uses the nearest one it has.',
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Check computations with SymPy'),
                subtitle: const Text(
                  "Each lesson's calculations are re-run on this device. The first check downloads about 15 MB.",
                ),
                value: s.mathChecks,
                onChanged: (v) => _update((s) => s.copyWith(mathChecks: v)),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Verify proofs with a second model'),
                subtitle: const Text(
                  'A model from another family referees every new lesson and the notes are corrected once. Costs several times more per lesson.',
                ),
                value: s.verifyProofs,
                onChanged: (v) => _update((s) => s.copyWith(verifyProofs: v)),
              ),
              if (s.verifyProofs) ...[
                const SizedBox(height: 8),
                TextField(
                  controller: _verifier,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: 'Verifier model',
                    hintText: AppSettings.defaultVerifierModel,
                    border: const OutlineInputBorder(),
                    helperText: 'Default: ${AppSettings.defaultVerifierModel}',
                    helperMaxLines: 2,
                  ),
                  onChanged: (v) => _debounced(
                    (s) => s.copyWith(
                      verifierModel: v.trim().isEmpty
                          ? AppSettings.defaultVerifierModel
                          : v.trim(),
                    ),
                  ),
                  onTapOutside: (_) => FocusScope.of(context).unfocus(),
                ),
              ],
              section('Voice'),
              SegmentedButton<TtsBackend>(
                segments: const [
                  ButtonSegment(
                    value: TtsBackend.onDevice,
                    label: Text('On-device'),
                  ),
                  ButtonSegment(
                    value: TtsBackend.openRouter,
                    label: Text('OpenRouter'),
                  ),
                ],
                selected: {s.ttsBackend},
                onSelectionChanged: (v) =>
                    _update((s) => s.copyWith(ttsBackend: v.first)),
              ),
              const SizedBox(height: 16),
              if (s.ttsBackend == TtsBackend.onDevice) ...[
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: voice.id,
                  decoration: InputDecoration(
                    labelText: 'Voice model',
                    border: const OutlineInputBorder(),
                    helperText: '${voice.downloadMb} MB · ${voice.speed}',
                    helperMaxLines: 2,
                  ),
                  items: [
                    for (final m in voiceModels)
                      DropdownMenuItem(
                        value: m.id,
                        child: Text(m.label, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (v) {
                    if (v != null && v != voice.id) {
                      _selectVoiceModel(v);
                    }
                  },
                ),
                if (voice.speakers.length > 1) ...[
                  const SizedBox(height: 16),
                  DropdownButtonFormField<int>(
                    key: ValueKey('speaker-${voice.id}'),
                    isExpanded: true,
                    initialValue: s.voiceSpeaker.clamp(
                      0,
                      voice.speakers.length - 1,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Voice',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      for (var i = 0; i < voice.speakers.length; i++)
                        DropdownMenuItem(
                          value: i,
                          child: Text(
                            voice.speakers[i],
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (v) {
                      if (v != null) {
                        _update((s) => s.copyWith(voiceSpeaker: v));
                      }
                    },
                  ),
                ],
                const SizedBox(height: 12),
                _modelRow(voice, text, scheme),
              ] else ...[
                TextField(
                  controller: _ttsModel,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'TTS model',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => _debounced(
                    (s) => s.copyWith(openRouterTtsModel: v.trim()),
                  ),
                  onTapOutside: (_) => FocusScope.of(context).unfocus(),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _ttsVoice,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Voice name',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => _debounced(
                    (s) => s.copyWith(openRouterTtsVoice: v.trim()),
                  ),
                  onTapOutside: (_) => FocusScope.of(context).unfocus(),
                ),
              ],
              section('Your books'),
              Text(
                'How the pages of an imported PDF are read into text and formulas.',
                style: text.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              SegmentedButton<TranscriptionBackend>(
                segments: const [
                  ButtonSegment(
                    value: TranscriptionBackend.openRouterVision,
                    label: Text('OpenRouter'),
                  ),
                  ButtonSegment(
                    value: TranscriptionBackend.mathpix,
                    label: Text('Mathpix'),
                  ),
                ],
                selected: {s.transcriptionBackend},
                onSelectionChanged: (v) =>
                    _update((s) => s.copyWith(transcriptionBackend: v.first)),
              ),
              const SizedBox(height: 16),
              if (s.transcriptionBackend ==
                  TranscriptionBackend.openRouterVision)
                TextField(
                  controller: _visionModel,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Page-reading model',
                    hintText: AppSettings.defaultVisionModel,
                    border: OutlineInputBorder(),
                    helperText:
                        'Must accept images. Default: ${AppSettings.defaultVisionModel}. '
                        'Try a stronger model if formulas come out wrong.',
                    helperMaxLines: 3,
                  ),
                  onChanged: (v) => _debounced(
                    (s) => s.copyWith(
                      visionModel: v.trim().isEmpty
                          ? AppSettings.defaultVisionModel
                          : v.trim(),
                    ),
                  ),
                  onTapOutside: (_) => FocusScope.of(context).unfocus(),
                )
              else ...[
                TextField(
                  controller: _mathpixId,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Mathpix app id',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) =>
                      _debounced((s) => s.copyWith(mathpixAppId: v.trim())),
                  onTapOutside: (_) => FocusScope.of(context).unfocus(),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _mathpixKey,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'Mathpix app key',
                    border: OutlineInputBorder(),
                    helperText: 'Stored only on this device. Chapters are uploaded to Mathpix when you open them.',
                    helperMaxLines: 3,
                  ),
                  onChanged: (v) =>
                      _debounced((s) => s.copyWith(mathpixAppKey: v.trim())),
                  onTapOutside: (_) => FocusScope.of(context).unfocus(),
                ),
              ],
              section('Studying'),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Questions at the end of a lecture'),
                subtitle: const Text(
                  'New lectures end with a few questions to answer from memory.',
                ),
                value: s.recallQuestions,
                onChanged: (v) =>
                    _update((s) => s.copyWith(recallQuestions: v)),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Review lectures'),
                subtitle: const Text(
                  'Three days after you finish a lecture, a three-minute review of it is made.',
                ),
                value: s.spacedReview,
                onChanged: (v) => _update((s) => s.copyWith(spacedReview: v)),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Check prerequisites'),
                subtitle: const Text(
                  'Before creating a lesson, see what it builds on and whether your library covers it.',
                ),
                value: s.prerequisiteCheck,
                onChanged: (v) =>
                    _update((s) => s.copyWith(prerequisiteCheck: v)),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Play the next lesson automatically'),
                subtitle: const Text('In a course, when a lecture ends.'),
                value: s.autoPlayNext,
                onChanged: (v) => _update((s) => s.copyWith(autoPlayNext: v)),
              ),
              section('Lecture pacing'),
              Text('Thinking pauses', style: text.bodyLarge),
              Text(
                'The silence the lecturer leaves after a definition, a '
                'theorem or a question. It does not change how fast the '
                'voice speaks; that is the speed button in the player.',
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
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
                '${_pacing(s.pauseScale)} Applies to lectures recorded '
                'from now on.',
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
                style: text.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
        ),
      ),
    );
  }

  static String _effortLabel(String effort) => switch (effort) {
        '' => 'Model default',
        'xhigh' => 'Extra high',
        _ => '${effort[0].toUpperCase()}${effort.substring(1)}',
      };

  /// What a pause setting does to a lecture, in words.
  String _pacing(double v) {
    if ((v - 1).abs() < 0.01) return 'Pauses as the lecturer scripted them.';
    final x = _fmt(v);
    return v < 1
        ? 'Shorter pauses ($x× the scripted length): the lecture moves on '
            'sooner and is shorter.'
        : 'Longer pauses ($x× the scripted length): more time to think, '
            'and a longer lecture.';
  }

  String _fmt(double v) {
    final t = v.toStringAsFixed(2);
    return t.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }

  Widget _modelRow(VoiceModel model, TextTheme text, ColorScheme scheme) {
    if (_installingId == model.id) {
      final f = _installFraction;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            f == null
                ? 'Unpacking…'
                : 'Downloading voice model… ${(f * 100).round()}%',
            style: text.bodyMedium,
          ),
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
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                installed == null
                    ? 'Checking voice model…'
                    : installed
                    ? 'Voice model installed'
                    : 'Not downloaded (about ${model.downloadMb} MB)',
                style: text.bodyLarge,
              ),
            ),
            if (installed == true)
              TextButton(
                onPressed: () => _deleteModel(model),
                child: const Text('Delete'),
              )
            else if (installed == false)
              FilledButton.tonal(
                onPressed: () => _install(model),
                child: const Text('Download'),
              ),
          ],
        ),
        if (_installError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _installError!,
              style: text.bodyMedium?.copyWith(color: scheme.error),
            ),
          ),
      ],
    );
  }
}
