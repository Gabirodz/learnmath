import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/core/models.dart';

AppSettings _roundTrip(AppSettings s) => AppSettings.fromJson(
    (jsonDecode(jsonEncode(s.toJson())) as Map).cast<String, Object?>());

void main() {
  group('presets', () {
    test('ids are unique and the default exists', () {
      final ids = LessonModelPreset.all.map((p) => p.id).toList();
      expect(ids.toSet(), hasLength(ids.length));
      expect(LessonModelPreset.byId(AppSettings.defaultLessonPreset), isNotNull);
      expect(AppSettings.defaultLessonPreset, 'sol-batch');
      expect(LessonModelPreset.byId('nope'), isNull);
      expect(LessonModelPreset.byId(LessonModelPreset.customId), isNull);
    });

    test('sol and terra are batch with high effort, luna is immediate', () {
      expect(LessonModelPreset.solBatch.model, 'openai/gpt-6.1-sol');
      expect(LessonModelPreset.solBatch.batch, isTrue);
      expect(LessonModelPreset.solBatch.effort, 'high');
      expect(LessonModelPreset.terraBatch.model, 'openai/gpt-6.1-terra');
      expect(LessonModelPreset.terraBatch.batch, isTrue);
      expect(LessonModelPreset.terraBatch.effort, 'high');
      expect(LessonModelPreset.luna.model, 'openai/gpt-6-luna');
      expect(LessonModelPreset.luna.batch, isFalse);
      expect(LessonModelPreset.luna.effort, isNull);
    });
  });

  group('getters', () {
    test('defaults: Sol batch with high effort', () {
      const s = AppSettings();
      expect(s.lessonModel, 'openai/gpt-6.1-sol');
      expect(s.lessonBatch, isTrue);
      expect(s.lessonEffort, 'high');
      expect(s.mathChecks, isTrue);
    });

    test('each preset drives model, batch and effort', () {
      final luna = const AppSettings().copyWith(lessonPreset: 'luna');
      expect(luna.lessonModel, 'openai/gpt-6-luna');
      expect(luna.lessonBatch, isFalse);
      expect(luna.lessonEffort, isNull);
      final terra = const AppSettings().copyWith(lessonPreset: 'terra-batch');
      expect(terra.lessonModel, 'openai/gpt-6.1-terra');
      expect(terra.lessonBatch, isTrue);
    });

    test('a preset ignores the custom fields', () {
      final s = const AppSettings().copyWith(
          lessonPreset: 'luna',
          chatModel: 'x/y',
          customBatch: true,
          customEffort: 'max');
      expect(s.lessonModel, 'openai/gpt-6-luna');
      expect(s.lessonBatch, isFalse);
      expect(s.lessonEffort, isNull);
    });

    test('custom preset uses chatModel, customBatch and customEffort', () {
      final s = const AppSettings().copyWith(
          lessonPreset: LessonModelPreset.customId,
          chatModel: 'acme/model',
          customBatch: true,
          customEffort: 'low');
      expect(s.lessonModel, 'acme/model');
      expect(s.lessonBatch, isTrue);
      expect(s.lessonEffort, 'low');
    });

    test('a preset uses the effort chosen for it, or its own', () {
      const s = AppSettings();
      expect(s.copyWith(presetEffort: 'low').lessonEffort, 'low');
      expect(s.copyWith(presetEffort: '').lessonEffort, isNull);
      expect(
          s.copyWith(presetEffort: 'low').copyWith(clearPresetEffort: true)
              .lessonEffort,
          'high');
      final luna = s.copyWith(lessonPreset: 'luna', presetEffort: 'medium');
      expect(luna.lessonEffort, 'medium');
      // The custom model keeps its own setting.
      final custom = s.copyWith(
          lessonPreset: LessonModelPreset.customId,
          presetEffort: 'max',
          customEffort: 'low');
      expect(custom.lessonEffort, 'low');
    });

    test('presetEffort survives JSON; an unknown level is dropped', () {
      final back = AppSettings.fromJson(
          const AppSettings().copyWith(presetEffort: 'minimal').toJson());
      expect(back.presetEffort, 'minimal');
      expect(AppSettings.fromJson(const AppSettings().toJson()).presetEffort,
          isNull);
      expect(AppSettings.fromJson({'presetEffort': 'ludicrous'}).presetEffort,
          isNull);
    });

    test('custom with empty effort has no effort', () {
      final s = const AppSettings()
          .copyWith(lessonPreset: LessonModelPreset.customId);
      expect(s.lessonEffort, isNull);
      expect(s.lessonBatch, isFalse);
    });

    test('an unknown preset id falls back to the custom fields', () {
      final s = const AppSettings()
          .copyWith(lessonPreset: 'gone', chatModel: 'acme/m');
      expect(s.lessonModel, 'acme/m');
    });

    test('hasApiKey / hasMathpix ignore whitespace', () {
      expect(const AppSettings().hasApiKey, isFalse);
      expect(const AppSettings(apiKey: '  ').hasApiKey, isFalse);
      expect(const AppSettings(apiKey: 'k').hasApiKey, isTrue);
      expect(const AppSettings(mathpixAppId: 'a').hasMathpix, isFalse);
      expect(
          const AppSettings(mathpixAppId: 'a', mathpixAppKey: ' ').hasMathpix,
          isFalse);
      expect(
          const AppSettings(mathpixAppId: 'a', mathpixAppKey: 'b').hasMathpix,
          isTrue);
    });
  });

  group('JSON', () {
    test('round trip keeps every non-secret field', () {
      const s = AppSettings(
        apiKey: 'secret',
        mathpixAppKey: 'secret2',
        lessonPreset: 'custom',
        chatModel: 'acme/m',
        customBatch: true,
        customEffort: 'xhigh',
        mathChecks: false,
        ttsBackend: TtsBackend.openRouter,
        voiceModel: 'piper-lessac',
        voiceSpeaker: 3,
        openRouterTtsModel: 'a/b',
        openRouterTtsVoice: 'v',
        pauseScale: 1.5,
        playbackSpeed: 1.25,
        skipSeconds: 30,
        transcriptionBackend: TranscriptionBackend.mathpix,
        visionModel: 'vis/model',
        mathpixAppId: 'id',
      );
      final back = _roundTrip(s);
      expect(back.lessonPreset, 'custom');
      expect(back.chatModel, 'acme/m');
      expect(back.customBatch, isTrue);
      expect(back.customEffort, 'xhigh');
      expect(back.mathChecks, isFalse);
      expect(back.ttsBackend, TtsBackend.openRouter);
      expect(back.voiceModel, 'piper-lessac');
      expect(back.voiceSpeaker, 3);
      expect(back.openRouterTtsModel, 'a/b');
      expect(back.openRouterTtsVoice, 'v');
      expect(back.pauseScale, 1.5);
      expect(back.playbackSpeed, 1.25);
      expect(back.skipSeconds, 30);
      expect(back.transcriptionBackend, TranscriptionBackend.mathpix);
      expect(back.visionModel, 'vis/model');
      expect(back.mathpixAppId, 'id');
    });

    test('secrets are not serialized and come from the arguments', () {
      const s = AppSettings(apiKey: 'secret', mathpixAppKey: 'm');
      final text = jsonEncode(s.toJson());
      expect(text, isNot(contains('secret')));
      final back = AppSettings.fromJson(s.toJson(),
          apiKey: 'K', mathpixAppKey: 'M');
      expect(back.apiKey, 'K');
      expect(back.mathpixAppKey, 'M');
    });

    test('empty JSON gives the defaults', () {
      final s = AppSettings.fromJson({});
      expect(s.lessonPreset, 'sol-batch');
      expect(s.chatModel, AppSettings.defaultChatModel);
      expect(s.lessonBatch, isTrue);
      expect(s.ttsBackend, TtsBackend.onDevice);
      expect(s.voiceModel, 'kokoro');
      expect(s.voiceSpeaker, 0);
      expect(s.mathChecks, isTrue);
    });

    test('invalid customEffort is dropped', () {
      expect(AppSettings.fromJson({'customEffort': 'ludicrous'}).customEffort,
          '');
      expect(AppSettings.fromJson({'customEffort': 'max'}).customEffort, 'max');
    });

    test('numbers stored as ints or doubles are accepted', () {
      final s = AppSettings.fromJson(
          {'pauseScale': 2, 'playbackSpeed': 1, 'skipSeconds': 15.0});
      expect(s.pauseScale, 2.0);
      expect(s.playbackSpeed, 1.0);
      expect(s.skipSeconds, 15);
    });

    test('unknown enum names fall back to defaults', () {
      final s = AppSettings.fromJson(
          {'ttsBackend': 'zzz', 'transcriptionBackend': 'zzz'});
      expect(s.ttsBackend, TtsBackend.onDevice);
      expect(s.transcriptionBackend, TranscriptionBackend.openRouterVision);
    });
  });

  group('migration of settings saved before presets', () {
    test('the old default model moves to sol-batch', () {
      final s = AppSettings.fromJson({'chatModel': 'openai/gpt-6-luna'});
      expect(s.lessonPreset, 'sol-batch');
      expect(s.lessonModel, 'openai/gpt-6.1-sol');
      expect(s.lessonBatch, isTrue);
      expect(s.chatModel, AppSettings.defaultChatModel);
    });

    test('a user-typed model becomes the custom preset', () {
      final s = AppSettings.fromJson({'chatModel': 'anthropic/foo'});
      expect(s.lessonPreset, LessonModelPreset.customId);
      expect(s.chatModel, 'anthropic/foo');
      expect(s.lessonModel, 'anthropic/foo');
      expect(s.lessonBatch, isFalse);
      expect(s.lessonEffort, isNull);
    });

    test('no model at all gives the default preset', () {
      expect(AppSettings.fromJson({'pauseScale': 1.2}).lessonPreset,
          'sol-batch');
    });

    test('an explicit preset wins over the legacy rule', () {
      final s = AppSettings.fromJson(
          {'lessonPreset': 'luna', 'chatModel': 'openai/gpt-6-luna'});
      expect(s.lessonPreset, 'luna');
      expect(s.lessonModel, 'openai/gpt-6-luna');
      // With a preset present the stored chatModel is kept as it is.
      expect(s.chatModel, 'openai/gpt-6-luna');
    });

    test('an explicit custom preset keeps a model equal to the old default',
        () {
      final s = AppSettings.fromJson(
          {'lessonPreset': 'custom', 'chatModel': 'openai/gpt-6-luna'});
      expect(s.lessonPreset, 'custom');
      expect(s.lessonModel, 'openai/gpt-6-luna');
    });

    test('legacy kokoroVoice is read as voiceSpeaker', () {
      expect(AppSettings.fromJson({'kokoroVoice': 7}).voiceSpeaker, 7);
    });

    test('voiceSpeaker wins over kokoroVoice', () {
      expect(
          AppSettings.fromJson({'voiceSpeaker': 2, 'kokoroVoice': 7})
              .voiceSpeaker,
          2);
    });

    test('legacy ttsBackend "kokoro" is the on-device engine', () {
      expect(AppSettings.fromJson({'ttsBackend': 'kokoro'}).ttsBackend,
          TtsBackend.onDevice);
      expect(TtsBackend.parse('kokoro'), TtsBackend.onDevice);
      expect(TtsBackend.parse('openRouter'), TtsBackend.openRouter);
      expect(TtsBackend.parse('onDevice'), TtsBackend.onDevice);
      expect(TtsBackend.parse(null), isNull);
    });
  });

  group('recall / review / prerequisite / autoplay switches', () {
    test('default to true', () {
      const s = AppSettings();
      expect(s.recallQuestions, isTrue);
      expect(s.spacedReview, isTrue);
      expect(s.prerequisiteCheck, isTrue);
      expect(s.autoPlayNext, isTrue);
    });

    test('round-trip through JSON when off', () {
      final s = const AppSettings().copyWith(
          recallQuestions: false,
          spacedReview: false,
          prerequisiteCheck: false,
          autoPlayNext: false);
      final back = AppSettings.fromJson(
          jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
      expect(back.recallQuestions, isFalse);
      expect(back.spacedReview, isFalse);
      expect(back.prerequisiteCheck, isFalse);
      expect(back.autoPlayNext, isFalse);
    });

    test('each switch is independent', () {
      final s = const AppSettings().copyWith(spacedReview: false);
      final back = AppSettings.fromJson(
          jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
      expect(back.spacedReview, isFalse);
      expect(back.recallQuestions, isTrue);
      expect(back.prerequisiteCheck, isTrue);
      expect(back.autoPlayNext, isTrue);
    });

    test('old JSON without them reads as true', () {
      final s = AppSettings.fromJson({'pauseScale': 1.2});
      expect(s.recallQuestions, isTrue);
      expect(s.spacedReview, isTrue);
      expect(s.prerequisiteCheck, isTrue);
      expect(s.autoPlayNext, isTrue);
    });
  });

  group('model choices', () {
    const sol = 'openai/gpt-6.1-sol';
    const terra = 'openai/gpt-6.1-terra';
    const luna = 'openai/gpt-6-luna';

    test('Sol, Terra and Luna are all offered through the batch API', () {
      expect([for (final p in LessonModelPreset.all) p.label], [
        'GPT-6.1 Sol (batch)',
        'GPT-6.1 Terra (batch)',
        'GPT-6 Luna (batch)',
        'GPT-6 Luna (immediate)',
      ]);
      expect(LessonModelPreset.lunaBatch.model, luna);
      expect(LessonModelPreset.lunaBatch.batch, isTrue);
      expect(LessonModelPreset.lunaBatch.effort, recommendedEffort);
      expect([for (final p in LessonModelPreset.immediate) p.name],
          ['GPT-6.1 Sol', 'GPT-6.1 Terra', 'GPT-6 Luna']);
    });

    test('matching tells the two Luna presets apart by batch', () {
      expect(LessonModelPreset.matching(luna, batch: true)!.id, 'luna-batch');
      expect(LessonModelPreset.matching(luna, batch: false)!.id, 'luna');
      expect(LessonModelPreset.matching(sol, batch: false), isNull);
      expect(LessonModelPreset.matching(sol)!.id, 'sol-batch');
      expect(LessonModelPreset.matching('acme/m'), isNull);
    });

    test('lessonChoice is what the preset fields say', () {
      expect(const AppSettings().lessonChoice,
          const ModelChoice(model: sol, effort: 'high', batch: true));
      expect(const AppSettings(lessonPreset: 'luna').lessonChoice,
          const ModelChoice(model: luna));
    });

    test('withLessonChoice remembers a preset, its effort, or a custom model',
        () {
      const s = AppSettings();
      for (final c in const [
        ModelChoice(model: terra, effort: 'high', batch: true),
        ModelChoice(model: luna, effort: 'xhigh', batch: true),
        ModelChoice(model: luna),
        ModelChoice(model: sol, batch: true),
        ModelChoice(model: 'acme/m', effort: 'low', batch: true),
        ModelChoice(model: 'acme/m'),
        // Sol asked right away is no preset: kept as a custom model.
        ModelChoice(model: sol, effort: 'high'),
      ]) {
        final back = AppSettings.fromJson(s.withLessonChoice(c).toJson());
        expect(back.lessonChoice, c, reason: c.label);
      }
      expect(
          s
              .withLessonChoice(
                  const ModelChoice(model: luna, effort: 'high', batch: true))
              .lessonPreset,
          'luna-batch');
      expect(s.withLessonChoice(const ModelChoice(model: 'acme/m')).lessonPreset,
          LessonModelPreset.customId);
    });

    test('chat and quiz follow the lesson model at high effort until picked',
        () {
      const s = AppSettings(lessonPreset: 'terra-batch', presetEffort: 'low');
      expect(s.tutorModel, const ModelChoice(model: terra, effort: 'high'));
      expect(s.quizModel, const ModelChoice(model: terra, effort: 'high'));

      final picked = s.copyWith(
        tutorChoice: const ModelChoice(model: luna, effort: 'medium'),
        quizChoice: const ModelChoice(model: 'acme/q'),
      );
      expect(picked.tutorModel, const ModelChoice(model: luna, effort: 'medium'));
      expect(picked.quizModel, const ModelChoice(model: 'acme/q'));
      // Picking them does not change what lessons are written with.
      expect(picked.lessonChoice, s.lessonChoice);
    });

    test('chat and quiz are never batched', () {
      final s = const AppSettings().copyWith(
        tutorChoice: const ModelChoice(model: sol, effort: 'high', batch: true),
        quizChoice: const ModelChoice(model: sol, batch: true),
      );
      expect(s.tutorModel.batch, isFalse);
      expect(s.quizModel.batch, isFalse);
      expect(s.tutorModel.model, sol);
    });

    test('the choices survive JSON; junk is dropped', () {
      final s = const AppSettings().copyWith(
        tutorChoice: const ModelChoice(model: luna, effort: 'medium'),
        quizChoice: const ModelChoice(model: 'acme/q'),
      );
      final back = AppSettings.fromJson(s.toJson());
      expect(back.tutorChoice, s.tutorChoice);
      expect(back.quizChoice, s.quizChoice);
      expect(AppSettings.fromJson(const AppSettings().toJson()).tutorChoice,
          isNull);
      expect(AppSettings.fromJson({'tutorChoice': 'x'}).tutorChoice, isNull);
      expect(AppSettings.fromJson({'quizChoice': {'model': ' '}}).quizChoice,
          isNull);
      expect(
          AppSettings.fromJson({
            'quizChoice': {'model': 'acme/q', 'effort': 'ludicrous'}
          }).quizChoice,
          const ModelChoice(model: 'acme/q'));
    });

    test('label names the model, how it is called and the effort', () {
      expect(const ModelChoice(model: sol, effort: 'high', batch: true).label,
          'GPT-6.1 Sol (batch) · high');
      expect(const ModelChoice(model: luna).label, 'GPT-6 Luna');
      expect(const ModelChoice(model: 'acme/m', batch: true).label,
          'acme/m (batch)');
    });
  });
}
