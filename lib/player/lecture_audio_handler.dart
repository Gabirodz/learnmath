import 'package:audio_service/audio_service.dart';

/// What the media notification, the lock screen, Bluetooth and headset
/// buttons can ask the lecture player to do.
abstract interface class MediaCommands {
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration to);

  /// Back or forward by the player's skip interval ([forward] false/true).
  Future<void> skipBy({required bool forward});
  Future<void> previousSection();
  Future<void> nextSection();
}

/// The app's media session: the notification with its controls (like a
/// music app's), lock-screen controls, Bluetooth and headset buttons.
///
/// It is created by `AudioService.init` before the app runs, while the
/// lecture player is created later; the player [attach]es itself and then
/// publishes [mediaItem] and [playbackState] here. Commands arriving before
/// that are ignored.
class LectureAudioHandler extends BaseAudioHandler with SeekHandler {
  MediaCommands? _player;

  void attach(MediaCommands player) => _player = player;

  /// The buttons shown: previous section, back, play or pause, forward,
  /// next section. The compact notification shows the middle three.
  static List<MediaControl> controlsFor({required bool playing}) => [
        MediaControl.skipToPrevious,
        MediaControl.rewind,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.fastForward,
        MediaControl.skipToNext,
      ];

  static const compactIndices = [1, 2, 3];

  @override
  Future<void> play() async => _player?.play();

  @override
  Future<void> pause() async => _player?.pause();

  @override
  Future<void> stop() async {
    await _player?.stop();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) async => _player?.seek(position);

  @override
  Future<void> rewind() async => _player?.skipBy(forward: false);

  @override
  Future<void> fastForward() async => _player?.skipBy(forward: true);

  @override
  Future<void> skipToPrevious() async => _player?.previousSection();

  @override
  Future<void> skipToNext() async => _player?.nextSection();

  /// Swiping the app away from recents while paused ends the session, so no
  /// dead notification stays behind; while playing, the lecture goes on.
  @override
  Future<void> onTaskRemoved() async {
    if (!playbackState.value.playing) await stop();
  }
}
