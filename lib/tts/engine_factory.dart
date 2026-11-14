import '../ai/openrouter_client.dart';
import '../core/models.dart';
import 'on_device_tts.dart';
import 'tts_engine.dart';

/// The speech engine the user's settings ask for: the on-device voice model
/// or OpenRouter's cloud voice. Unlike lecture generation this never
/// downloads anything: with the on-device backend, [TtsEngine.prepare] fails
/// with a readable message when the voice model is not installed.
TtsEngine createTtsEngine(
  AppSettings settings,
  VoiceModelManager voices,
  OpenRouterClient client,
) {
  if (settings.ttsBackend == TtsBackend.onDevice) {
    return _InstalledOnlyEngine(
      manager: voices,
      model: VoiceModel.byId(settings.voiceModel),
      speakerId: settings.voiceSpeaker,
    );
  }
  return OpenRouterTtsEngine(
    client: client,
    model: settings.openRouterTtsModel,
    voice: settings.openRouterTtsVoice,
  );
}

/// The voice a lecture recorded with [settings] is spoken by, for showing
/// with the lesson.
String voiceLabel(AppSettings settings) {
  if (settings.ttsBackend == TtsBackend.onDevice) {
    final model = VoiceModel.byId(settings.voiceModel);
    final speaker = settings.voiceSpeaker;
    return speaker >= 0 && speaker < model.speakers.length
        ? '${model.label} · ${model.speakers[speaker]}'
        : model.label;
  }
  return '${settings.openRouterTtsModel} · ${settings.openRouterTtsVoice}';
}

class _InstalledOnlyEngine extends OnDeviceTtsEngine {
  _InstalledOnlyEngine({
    required super.manager,
    required super.model,
    required super.speakerId,
  });

  @override
  Future<void> prepare() async {
    if (!await manager.isInstalled(model)) {
      throw TtsException('Download the voice model in Settings first.');
    }
    return super.prepare();
  }
}
