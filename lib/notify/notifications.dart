/// System notifications, behind an interface so the pipeline and tests do
/// not depend on a plugin.
library;

/// Notifications the app posts about work that outlives the user's
/// attention: batch lessons that arrive minutes or hours later, voice model
/// downloads and lecture recordings.
abstract class AppNotifications {
  /// Asks for the notification permission (Android 13+) the first time it is
  /// needed. Safe to call repeatedly.
  Future<void> requestPermission();

  /// A lesson finished. [hasAudio] is false for a lesson that is ready to
  /// read but has no recording.
  Future<void> lessonReady(String lessonId, String title,
      {required bool hasAudio});

  Future<void> lessonFailed(String lessonId, String title, String reason);

  /// Shows or updates an ongoing progress notification. [key] identifies it
  /// (a lesson id, or [voiceModelKey]); [fraction] is 0..1 or null when
  /// indeterminate.
  Future<void> progress(String key,
      {required String title, required String body, double? fraction});

  /// Removes the progress notification for [key].
  Future<void> clearProgress(String key);

  /// A voice model finished downloading and is ready to use.
  Future<void> voiceModelReady(String modelLabel);

  /// [progress] key for the voice model download.
  static const voiceModelKey = 'voice-model';
}

/// Posts nothing. Used in tests and on platforms without notifications.
class NoNotifications implements AppNotifications {
  const NoNotifications();

  @override
  Future<void> requestPermission() async {}

  @override
  Future<void> lessonReady(String lessonId, String title,
      {required bool hasAudio}) async {}

  @override
  Future<void> lessonFailed(
      String lessonId, String title, String reason) async {}

  @override
  Future<void> progress(String key,
      {required String title, required String body, double? fraction}) async {}

  @override
  Future<void> clearProgress(String key) async {}

  @override
  Future<void> voiceModelReady(String modelLabel) async {}
}

/// A batch the app is waiting for, as the background check needs it.
class WaitingBatch {
  const WaitingBatch({
    required this.batchId,
    required this.lessonId,
    required this.lessonTitle,
  });

  final String batchId;
  final String lessonId;
  final String lessonTitle;

  Map<String, Object?> toJson() =>
      {'batchId': batchId, 'lessonId': lessonId, 'lessonTitle': lessonTitle};

  static WaitingBatch? fromJson(Object? j) {
    if (j is! Map) return null;
    final b = j['batchId'], l = j['lessonId'], t = j['lessonTitle'];
    if (b is! String || l is! String) return null;
    return WaitingBatch(
        batchId: b, lessonId: l, lessonTitle: t is String ? t : 'Lesson');
  }
}

/// Keeps checking on batches while the app itself is not running, and tells
/// the user when one has arrived.
abstract class BatchBackground {
  /// Called whenever the set of batches being waited for changes; an empty
  /// list stops the background checks.
  Future<void> update(List<WaitingBatch> waiting);
}

class NoBatchBackground implements BatchBackground {
  const NoBatchBackground();

  @override
  Future<void> update(List<WaitingBatch> waiting) async {}
}

/// Keeps the app running while lessons are being made, so that work goes on
/// with the screen off or the app in the background (on Android: a
/// foreground service with a persistent notification).
abstract class KeepAlive {
  /// Starts holding the app alive, or updates the text shown to the user
  /// ("Working on 2 lessons", "Waiting for 3 batch answers").
  Future<void> hold(String status);

  /// Nothing is left to do; lets the system suspend the app again.
  Future<void> release();
}

class NoKeepAlive implements KeepAlive {
  const NoKeepAlive();

  @override
  Future<void> hold(String status) async {}

  @override
  Future<void> release() async {}
}
