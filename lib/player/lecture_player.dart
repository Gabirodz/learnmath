import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

import '../core/models.dart';
import '../core/storage.dart';

/// Wraps the audio player with lecture-level concepts: segments (subtitles),
/// sections (chapters), relative skips and resume positions.
class LecturePlayer {
  LecturePlayer(this._repo) {
    _subs.add(_audio.positionStream.listen(_onPosition));
    _subs.add(_audio.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed) {
        _onCompleted();
      } else if (!s.playing) {
        _savePosition();
      }
    }));
  }

  final LibraryRepository _repo;
  final AudioPlayer _audio = AudioPlayer();
  final _subs = <StreamSubscription<Object?>>[];

  /// The lesson currently loaded, if any.
  final ValueNotifier<Lesson?> lesson = ValueNotifier(null);

  /// Index into the lesson's segments of the one being spoken (or last spoken).
  final ValueNotifier<int> segmentIndex = ValueNotifier(0);

  List<NarrationSegment> _segments = const [];
  int _lastSavedMs = -1;
  bool _sessionConfigured = false;

  Stream<Duration> get positionStream => _audio.positionStream;
  Stream<PlayerState> get stateStream => _audio.playerStateStream;
  Stream<double> get speedStream => _audio.speedStream;
  Duration get position => _audio.position;
  Duration get duration =>
      _audio.duration ??
      Duration(milliseconds: lesson.value?.audioDurationMs ?? 0);
  bool get playing => _audio.playing;
  double get speed => _audio.speed;
  List<NarrationSegment> get segments => _segments;

  /// Loads [l] unless it is already loaded (same recording).
  Future<void> load(Lesson l, {String? album, double speed = 1.0}) async {
    final current = lesson.value;
    if (current != null &&
        current.id == l.id &&
        current.audioPath == l.audioPath &&
        current.audioDurationMs == l.audioDurationMs) {
      return;
    }
    if (!_sessionConfigured) {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.speech());
      _sessionConfigured = true;
    }
    await _savePosition();
    _segments = l.segments;
    lesson.value = l;
    final resumeMs = l.completed ? 0 : l.lastPositionMs;
    segmentIndex.value = _indexAt(resumeMs);
    await _audio.setAudioSource(
      AudioSource.file(
        l.audioPath!,
        tag: MediaItem(
          id: l.id,
          title: l.title,
          album: album ?? 'LearnMath',
          duration: l.audioDurationMs == null
              ? null
              : Duration(milliseconds: l.audioDurationMs!),
        ),
      ),
      initialPosition: Duration(milliseconds: resumeMs),
    );
    await _audio.setSpeed(speed);
  }

  Future<void> play() async {
    if (_audio.processingState == ProcessingState.completed) {
      await _audio.seek(Duration.zero);
    }
    unawaited(_audio.play());
  }

  Future<void> pause() => _audio.pause();

  Future<void> toggle() => playing ? pause() : play();

  Future<void> setSpeed(double speed) => _audio.setSpeed(speed);

  Future<void> seek(Duration to) {
    final max = duration;
    final clamped = to < Duration.zero ? Duration.zero : (to > max ? max : to);
    _onPosition(clamped);
    return _audio.seek(clamped);
  }

  Future<void> skip(int seconds) => seek(position + Duration(seconds: seconds));

  Future<void> seekToSegment(int index) {
    if (_segments.isEmpty) return Future.value();
    final i = index.clamp(0, _segments.length - 1);
    return seek(Duration(milliseconds: _segments[i].startMs ?? 0));
  }

  /// Indices of segments that start a section.
  List<int> get sectionStarts => [
        for (var i = 0; i < _segments.length; i++)
          if (_segments[i].section != null) i,
      ];

  /// Title of the section the playhead is in.
  String? get currentSection {
    for (var i = segmentIndex.value; i >= 0 && i < _segments.length; i--) {
      if (_segments[i].section != null) return _segments[i].section;
    }
    return null;
  }

  Future<void> nextSection() {
    for (final i in sectionStarts) {
      if (i > segmentIndex.value) return seekToSegment(i);
    }
    return Future.value();
  }

  /// Goes to the start of the current section, or to the previous one when
  /// already near its start (like the "previous track" button).
  Future<void> previousSection() {
    final starts = sectionStarts;
    final posMs = position.inMilliseconds;
    for (final i in starts.reversed) {
      final startMs = _segments[i].startMs ?? 0;
      if (startMs < posMs - 3000) return seekToSegment(i);
    }
    return seek(Duration.zero);
  }

  Future<void> stop() async {
    await _savePosition();
    await _audio.stop();
    lesson.value = null;
    _segments = const [];
  }

  void _onPosition(Duration pos) {
    if (_segments.isEmpty) return;
    final ms = pos.inMilliseconds;
    final i = _indexAt(ms);
    if (i != segmentIndex.value) segmentIndex.value = i;
    if ((ms - _lastSavedMs).abs() >= 5000) _savePosition();
  }

  /// Last segment whose start is <= [ms] (binary search).
  int _indexAt(int ms) {
    var lo = 0, hi = _segments.length - 1, ans = 0;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if ((_segments[mid].startMs ?? 0) <= ms) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }

  Future<void> _savePosition() async {
    final l = lesson.value;
    if (l == null) return;
    final ms = _audio.position.inMilliseconds;
    if (ms == _lastSavedMs) return;
    _lastSavedMs = ms;
    await _repo.updateLesson(l.id, (x) => x.copyWith(lastPositionMs: ms));
  }

  Future<void> _onCompleted() async {
    final l = lesson.value;
    if (l == null) return;
    await _audio.pause();
    await _repo.updateLesson(
        l.id, (x) => x.copyWith(completed: true, lastPositionMs: 0));
  }

  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    await _audio.dispose();
  }
}
