import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

import '../core/models.dart';
import '../core/storage.dart';
import 'next_lesson.dart';
import 'player_controls.dart';

/// Wraps the audio player with lecture-level concepts: segments (subtitles),
/// sections (chapters), relative skips and resume positions.
///
/// When a lecture of a course ends and [autoPlayNext] allows it, the next
/// lesson of the course that has audio is loaded and played after
/// [advanceDelay].
class LecturePlayer implements PlayerControls {
  LecturePlayer(
    this._repo, {
    bool Function()? autoPlayNext,
    double Function()? speed,
    this.advanceDelay = const Duration(seconds: 2),
  }) : _autoPlayNext = autoPlayNext ?? (() => false),
       _speed = speed ?? (() => 1.0) {
    _subs.add(_audio.positionStream.listen(_onPosition));
    _subs.add(
      _audio.playerStateStream.listen((s) {
        if (_clipActive) {
          // A "re-explain" clip owns the audio player for a moment; its
          // position and end must not touch the lecture's bookkeeping.
          if (s.processingState == ProcessingState.completed) {
            _clipDone?.complete();
          }
          return;
        }
        if (s.processingState == ProcessingState.completed) {
          _onCompleted();
        } else {
          _completionHandled = false;
          if (!s.playing) _savePosition();
        }
      }),
    );
  }

  final LibraryRepository _repo;
  final bool Function() _autoPlayNext;
  final double Function() _speed;

  /// Pause between the end of a lecture and the start of the next one.
  final Duration advanceDelay;
  final AudioPlayer _audio = AudioPlayer();
  final _subs = <StreamSubscription<Object?>>[];

  /// Index into the lesson's segments of the one being spoken (or last spoken).
  final ValueNotifier<int> segmentIndex = ValueNotifier(0);

  List<NarrationSegment> _segments = const [];
  int _lastSavedMs = -1;

  /// Position of the last checkpoint written during playback.
  int _lastCheckpointMs = -1;
  bool _sessionConfigured = false;
  String? _album;

  /// Bumped by anything that makes a pending auto-advance obsolete.
  int _advanceToken = 0;
  bool _completionHandled = false;

  bool _clipActive = false;
  int _clipResumeMs = 0;
  Completer<void>? _clipDone;

  /// The lesson currently loaded, if any.
  @override
  final ValueNotifier<Lesson?> lesson = ValueNotifier(null);

  @override
  Stream<Duration> get positionStream => _audio.positionStream;
  Stream<PlayerState> get stateStream => _audio.playerStateStream;
  Stream<double> get speedStream => _audio.speedStream;
  @override
  Duration get position => _audio.position;
  @override
  Duration get duration =>
      _audio.duration ??
      Duration(milliseconds: lesson.value?.audioDurationMs ?? 0);
  @override
  bool get playing => _audio.playing;
  @override
  Stream<bool> get playingStream => _audio.playerStateStream.map(
    (s) => s.playing && s.processingState != ProcessingState.completed,
  );
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
    _advanceToken++;
    await _endClip(restore: false);
    await _savePosition();
    _segments = l.segments;
    lesson.value = l;
    _album = album;
    _completionHandled = false;
    final resumeMs = l.completed
        ? 0
        : await _repo.positionCheckpoint(l.id) ?? l.lastPositionMs;
    _lastCheckpointMs = resumeMs;
    segmentIndex.value = _indexAt(resumeMs);
    await _setLectureSource(l, resumeMs);
    await _audio.setSpeed(speed);
  }

  Future<void> _setLectureSource(Lesson l, int positionMs) {
    return _audio.setAudioSource(
      AudioSource.file(
        l.audioPath!,
        tag: MediaItem(
          id: l.id,
          title: l.title,
          album: _album ?? 'LearnMath',
          duration: l.audioDurationMs == null
              ? null
              : Duration(milliseconds: l.audioDurationMs!),
        ),
      ),
      initialPosition: Duration(milliseconds: positionMs),
    );
  }

  /// Plays a short spoken clip (the "explain it differently" answer) through
  /// the lecture's own audio player and returns when it has ended or was cut
  /// short by [resumeFromSegment] / [abortClip]. just_audio_background allows
  /// only one player instance per app, so a second `AudioPlayer` is not an
  /// option. The lecture position is not touched; its source is put back by
  /// [resumeFromSegment] or [abortClip].
  Future<void> playClip(String path, {required int resumeSegment}) async {
    final l = lesson.value;
    if (l == null) return;
    _advanceToken++;
    await _savePosition();
    _clipResumeMs = _segments.isEmpty
        ? 0
        : _segments[resumeSegment.clamp(0, _segments.length - 1)].startMs ?? 0;
    _clipActive = true;
    final done = _clipDone = Completer<void>();
    try {
      await _audio.setAudioSource(
        AudioSource.file(
          path,
          tag: MediaItem(
            id: '${l.id}#again',
            title: 'Explained differently',
            album: l.title,
          ),
        ),
      );
      unawaited(_audio.play());
      await done.future;
    } catch (_) {
      await _endClip(restore: true);
      rethrow;
    }
  }

  /// Ends a running clip and leaves the lecture paused at the start of the
  /// segment the clip was played for.
  Future<void> abortClip() => _endClip(restore: true);

  /// Ends a running clip (if any), then plays the lecture from the start of
  /// segment [index].
  Future<void> resumeFromSegment(int index) async {
    await _endClip(restore: true);
    await seekToSegment(index);
    await play();
  }

  Future<void> _endClip({required bool restore}) async {
    if (!_clipActive) return;
    _clipActive = false;
    final done = _clipDone;
    _clipDone = null;
    if (done != null && !done.isCompleted) done.complete();
    await _audio.pause();
    final l = lesson.value;
    if (restore && l != null && l.audioPath != null) {
      _lastSavedMs = -1;
      await _setLectureSource(l, _clipResumeMs);
    }
  }

  Future<void> play() async {
    _advanceToken++;
    if (_clipActive) {
      unawaited(_audio.play());
      return;
    }
    if (_audio.processingState == ProcessingState.completed) {
      await _audio.seek(Duration.zero);
    }
    unawaited(_audio.play());
  }

  Future<void> pause() {
    _advanceToken++;
    return _audio.pause();
  }

  @override
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

  @override
  Future<void> stop() async {
    _advanceToken++;
    await _endClip(restore: false);
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
    if ((ms - _lastCheckpointMs).abs() >= 5000) {
      _lastCheckpointMs = ms;
      final id = lesson.value?.id;
      if (id != null) unawaited(_repo.checkpointPosition(id, ms));
    }
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
    _lastCheckpointMs = ms;
    await _repo.updateLesson(l.id, (x) => x.copyWith(lastPositionMs: ms));
    await _repo.clearPositionCheckpoint(l.id);
  }

  Future<void> _onCompleted() async {
    final l = lesson.value;
    if (l == null || _completionHandled) return;
    // Pausing below emits another "completed" state; handle the end once.
    _completionHandled = true;
    await _audio.pause();
    await _repo.updateLesson(
      l.id,
      (x) => x.copyWith(
        completed: true,
        lastPositionMs: 0,
        // The first time only: the review lecture is timed from it.
        completedAt: x.completedAt ?? DateTime.now(),
      ),
    );
    await _repo.clearPositionCheckpoint(l.id);
    if (!_autoPlayNext() || l.courseId == null) return;
    final token = ++_advanceToken;
    try {
      final done = (await _repo.getLesson(l.id)) ?? l;
      final next = nextToPlay(done, await _repo.getCourseLessons(l.courseId!));
      if (next == null) return;
      await Future<void>.delayed(advanceDelay);
      // The listener may have pressed play, picked another lesson or closed
      // the player during the pause.
      if (token != _advanceToken) return;
      final album = (await _repo.getCourse(l.courseId!))?.title;
      if (token != _advanceToken) return;
      await load(next, album: album, speed: _speed());
      await play();
    } catch (_) {
      // Playing on is a convenience; the lecture itself finished fine.
    }
  }

  Future<void> dispose() async {
    _advanceToken++;
    for (final s in _subs) {
      await s.cancel();
    }
    await _audio.dispose();
  }
}
