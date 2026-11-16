import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/providers.dart';

/// "High", "Extra high", "Model default".
String effortLabel(String effort) => switch (effort) {
      '' => 'Model default',
      'xhigh' => 'Extra high',
      _ => '${effort[0].toUpperCase()}${effort.substring(1)}',
    };

/// Picks the model for one kind of request: one of the ready-made models or
/// any OpenRouter model id, and how hard it thinks.
///
/// With [allowBatch] the request can wait (a lesson, a review), so the
/// models are offered through the Batch API. Without it the student waits
/// for the answer (chat, a quiz) and the same models are asked right away.
class ModelPicker extends StatefulWidget {
  const ModelPicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.allowBatch = false,
    this.enabled = true,
  });

  final ModelChoice value;
  final ValueChanged<ModelChoice> onChanged;
  final bool allowBatch;
  final bool enabled;

  @override
  State<ModelPicker> createState() => _ModelPickerState();
}

class _ModelPickerState extends State<ModelPicker> {
  late final TextEditingController _slug;

  /// Whether "Custom model…" is selected, which the value alone cannot say
  /// while the typed id is that of a ready-made model.
  late bool _custom;

  List<LessonModelPreset> get _presets => widget.allowBatch
      ? LessonModelPreset.all
      : LessonModelPreset.immediate;

  LessonModelPreset? _presetOf(ModelChoice c) {
    for (final p in _presets) {
      if (p.model == c.model && (!widget.allowBatch || p.batch == c.batch)) {
        return p;
      }
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _custom = _presetOf(widget.value) == null;
    _slug = TextEditingController(text: widget.value.model);
  }

  @override
  void dispose() {
    _slug.dispose();
    super.dispose();
  }

  void _emit({String? model, bool? batch, String? effort}) {
    final v = widget.value;
    widget.onChanged(ModelChoice(
      model: model ?? v.model,
      batch: widget.allowBatch && (batch ?? v.batch),
      // '' is the menu's "Model default".
      effort: effort == null ? v.effort : (effort.isEmpty ? null : effort),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final muted = text.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final v = widget.value;
    final preset = _custom ? null : _presetOf(v);
    final selected = preset?.id ?? LessonModelPreset.customId;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        DropdownButtonFormField<String>(
          key: ValueKey('model $selected'),
          isExpanded: true,
          initialValue: selected,
          decoration: const InputDecoration(
            labelText: 'Model',
            border: OutlineInputBorder(),
          ),
          items: [
            for (final p in _presets)
              DropdownMenuItem(
                value: p.id,
                child: Text(
                  '${widget.allowBatch ? p.label : p.name}'
                  '${p.id == AppSettings.defaultLessonPreset ? ' · recommended' : ''}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            const DropdownMenuItem(
              value: LessonModelPreset.customId,
              child: Text('Custom model…'),
            ),
          ],
          onChanged: !widget.enabled
              ? null
              : (id) {
                  if (id == null || id == selected) return;
                  final p = LessonModelPreset.byId(id);
                  setState(() => _custom = p == null);
                  if (p == null) {
                    _slug.text = v.model;
                  } else {
                    _emit(model: p.model, batch: p.batch);
                  }
                },
        ),
        const SizedBox(height: 6),
        if (preset != null)
          Text(
            widget.allowBatch
                ? preset.description
                : '${preset.model} · answers right away, so the batch '
                    'discount does not apply here.',
            style: muted,
          )
        else ...[
          const SizedBox(height: 6),
          TextField(
            controller: _slug,
            enabled: widget.enabled,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'Model id',
              hintText: AppSettings.defaultChatModel,
              border: OutlineInputBorder(),
              helperText: 'Any model id from openrouter.ai/models',
            ),
            onChanged: (t) {
              if (t.trim().isNotEmpty) _emit(model: t.trim());
            },
            onTapOutside: (_) => FocusScope.of(context).unfocus(),
          ),
          if (widget.allowBatch)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Use the Batch API'),
              subtitle: const Text('Half price; arrives later'),
              value: v.batch,
              onChanged:
                  widget.enabled ? (b) => _emit(batch: b) : null,
            ),
        ],
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          key: ValueKey('effort ${v.effort}'),
          isExpanded: true,
          initialValue: v.effort ?? '',
          decoration: const InputDecoration(
            labelText: 'Reasoning effort',
            border: OutlineInputBorder(),
          ),
          items: [
            for (final e in reasoningEfforts)
              DropdownMenuItem(
                value: e,
                child: Text(e == recommendedEffort
                    ? '${effortLabel(e)} · recommended'
                    : effortLabel(e)),
              ),
          ],
          onChanged: !widget.enabled
              ? null
              : (e) {
                  if (e != null) _emit(effort: e);
                },
        ),
      ],
    );
  }
}

/// A compact line naming the model in use; tapping it opens a [ModelPicker]
/// in a sheet. For the chat and the quiz, where the picker would be in the
/// way most of the time.
class ModelButton extends StatelessWidget {
  const ModelButton({
    super.key,
    required this.value,
    required this.onChanged,
    this.allowBatch = false,
    this.title = 'Model',
    this.enabled = true,
    this.alignment = Alignment.centerLeft,
    this.maxLines = 1,
  });

  final ModelChoice value;
  final ValueChanged<ModelChoice> onChanged;
  final bool allowBatch;

  /// Heading of the sheet ("Chat model").
  final String title;
  final bool enabled;
  final AlignmentGeometry alignment;

  /// Lines the model's name may take; more than one where the button
  /// shares its row ("GPT-6.1 Sol (batch) · high" in half a phone's width).
  final int maxLines;

  @override
  Widget build(BuildContext context) => Align(
        alignment: alignment,
        child: TextButton.icon(
          icon: const Icon(Icons.memory, size: 18),
          label: Text(
            value.label,
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
          ),
          onPressed: enabled
              ? () => showModelSheet(
                    context,
                    title: title,
                    value: value,
                    allowBatch: allowBatch,
                    onChanged: onChanged,
                  )
              : null,
        ),
      );
}

/// Opens a [ModelPicker] in a bottom sheet; every change is reported at once.
Future<void> showModelSheet(
  BuildContext context, {
  required String title,
  required ModelChoice value,
  required ValueChanged<ModelChoice> onChanged,
  bool allowBatch = false,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (context) {
        var current = value;
        return StatefulBuilder(
          builder: (context, setState) => Padding(
            padding: EdgeInsets.only(
                bottom: MediaQuery.viewInsetsOf(context).bottom),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 16),
                  ModelPicker(
                    value: current,
                    allowBatch: allowBatch,
                    onChanged: (c) {
                      setState(() => current = c);
                      onChanged(c);
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );

/// The model that plans courses and their later parts, apart from the one
/// that writes the lessons. Immediate only: the student waits for the plan.
/// The choice is remembered in the settings.
class PlannerButton extends ConsumerWidget {
  const PlannerButton({super.key, this.enabled = true, this.maxLines = 1});
  final bool enabled;
  final int maxLines;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ModelButton(
        title: 'Course planner',
        enabled: enabled,
        maxLines: maxLines,
        value: ref.watch(settingsProvider.select((s) => s.plannerModel)),
        onChanged: (c) => ref
            .read(settingsProvider.notifier)
            .update((s) => s.copyWith(plannerChoice: c)),
      );
}

/// The [ModelButton] for the model that writes lessons (or a review), which
/// may go through the Batch API, under a heading such as "Writes the
/// lessons".
class WriterButton extends StatelessWidget {
  const WriterButton({
    super.key,
    required this.heading,
    required this.value,
    required this.onChanged,
    this.title = 'Lesson writer',
    this.enabled = true,
    this.maxLines = 1,
  });

  final String heading;
  final ModelChoice value;
  final ValueChanged<ModelChoice> onChanged;

  /// Heading of the sheet it opens.
  final String title;
  final bool enabled;
  final int maxLines;

  @override
  Widget build(BuildContext context) => _Headed(
        heading: heading,
        child: ModelButton(
          title: title,
          value: value,
          allowBatch: true,
          enabled: enabled,
          maxLines: maxLines,
          onChanged: onChanged,
        ),
      );
}

/// The two models of a course side by side: the [PlannerButton] that plans
/// it (or a later part) and the [WriterButton] that writes its lessons.
class CourseModelButtons extends StatelessWidget {
  const CourseModelButtons({
    super.key,
    required this.planHeading,
    required this.writeHeading,
    required this.writer,
    required this.onWriterChanged,
    this.enabled = true,
  });

  final String planHeading;
  final String writeHeading;
  final ModelChoice writer;
  final ValueChanged<ModelChoice> onWriterChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _Headed(
              heading: planHeading,
              child: PlannerButton(enabled: enabled, maxLines: 2),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: WriterButton(
              heading: writeHeading,
              value: writer,
              enabled: enabled,
              maxLines: 2,
              onChanged: onWriterChanged,
            ),
          ),
        ],
      );
}

class _Headed extends StatelessWidget {
  const _Headed({required this.heading, required this.child});
  final String heading;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(heading, style: Theme.of(context).textTheme.labelLarge),
          child,
        ],
      );
}
