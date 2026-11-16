import 'package:flutter/foundation.dart';

import '../core/models.dart';

/// The small slice of the lecture player that the mini-player needs, so the
/// bar can be built and tested without a real audio device.
abstract interface class PlayerControls {
  /// The lesson currently loaded, if any.
  ValueListenable<Lesson?> get lesson;

  /// True while audio is actually playing (false once the lecture ended).
  Stream<bool> get playingStream;
  bool get playing;

  Stream<Duration> get positionStream;
  Duration get position;
  Duration get duration;

  Future<void> toggle();

  /// Back or forward by the skip interval of the settings.
  Future<void> skipBy({required bool forward});

  /// Stops playback and unloads the lesson.
  Future<void> stop();
}
