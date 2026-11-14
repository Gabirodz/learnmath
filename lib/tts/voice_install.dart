import '../notify/notifications.dart';
import 'on_device_tts.dart';

/// Installs [model] if needed, mirroring the download in a progress
/// notification so the user can leave the app while it runs.
/// [onProgress] gets 0..1 while downloading and null while unpacking.
Future<void> installVoiceModel(
  VoiceModelManager manager,
  VoiceModel model,
  AppNotifications notifications, {
  void Function(double? fraction)? onProgress,
}) async {
  if (await manager.isInstalled(model)) return;
  const key = AppNotifications.voiceModelKey;
  try {
    await manager.install(model, onProgress: (f) {
      onProgress?.call(f);
      notifications.progress(
        key,
        title: f == null ? 'Unpacking voice model' : 'Downloading voice model',
        body: f == null
            ? model.label
            : '${model.label} · ${(f * 100).round()}% of ${model.downloadMb} MB',
        fraction: f,
      );
    });
  } finally {
    await notifications.clearProgress(key);
  }
  await notifications.voiceModelReady(model.label);
}
