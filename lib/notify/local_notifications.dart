/// [AppNotifications] on top of flutter_local_notifications (Android).
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'notifications.dart';

/// Posts system notifications. Everything here is best-effort: a failing
/// plugin call must never break lesson generation, so every method swallows
/// its exceptions, and on platforms without the plugin (tests on Linux) the
/// methods do nothing.
class LocalNotifications implements AppNotifications {
  LocalNotifications({
    required this.onOpenLesson,
    required this.isForeground,
    this.onOpenCourse,
    this.onOpenQuiz,
  });

  /// Called with the lesson id when the user taps a lesson notification while
  /// the app is running.
  final void Function(String lessonId) onOpenLesson;

  /// The same for a course notification.
  final void Function(String courseId)? onOpenCourse;

  /// The same for a quiz notification: the lesson, on its Quiz tab.
  final void Function(String lessonId)? onOpenQuiz;

  /// Whether the app is visible. The screen already shows what happened then,
  /// so nothing is posted.
  final bool Function() isForeground;

  /// Set by [init] when the app was started by tapping a lesson notification.
  String? launchLessonId;

  /// Set by [init] when the app was started by tapping a course notification.
  String? launchCourseId;

  /// Set by [init] when the app was started by tapping a quiz notification:
  /// the lesson whose Quiz tab to open.
  String? launchQuizLessonId;

  static const _lessonsChannel = 'lessons';
  static const _progressChannel = 'progress';
  static const _payloadPrefix = 'lesson:';
  static const _coursePrefix = 'course:';
  static const _quizPrefix = 'quiz:';
  static const _minProgressGap = Duration(milliseconds: 500);

  static bool get _supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _permissionAsked = false;

  /// Per progress key: when it was last posted and what it showed.
  final _lastProgress = <String, ({DateTime at, int? percent, String body})>{};

  Future<void> init() async {
    if (!_supported) return;
    try {
      await _setUp(_plugin, onTap: (r) => _handleTap(r.payload));
      final launch = await _plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp ?? false) {
        final payload = launch?.notificationResponse?.payload;
        launchLessonId = lessonIdFromPayload(payload);
        launchCourseId = courseIdFromPayload(payload);
        launchQuizLessonId = quizLessonIdFromPayload(payload);
      }
    } catch (e) {
      debugPrint('Notifications unavailable: $e');
    }
  }

  void _handleTap(String? payload) {
    final id = lessonIdFromPayload(payload);
    if (id != null) onOpenLesson(id);
    final course = courseIdFromPayload(payload);
    if (course != null) onOpenCourse?.call(course);
    final quiz = quizLessonIdFromPayload(payload);
    if (quiz != null) (onOpenQuiz ?? onOpenLesson)(quiz);
  }

  /// `quiz:<lesson id>` -> `<lesson id>`; null for anything else.
  @visibleForTesting
  static String? quizLessonIdFromPayload(String? payload) {
    if (payload == null || !payload.startsWith(_quizPrefix)) return null;
    final id = payload.substring(_quizPrefix.length);
    return id.isEmpty ? null : id;
  }

  /// `course:<id>` -> `<id>`; null for anything else.
  @visibleForTesting
  static String? courseIdFromPayload(String? payload) {
    if (payload == null || !payload.startsWith(_coursePrefix)) return null;
    final id = payload.substring(_coursePrefix.length);
    return id.isEmpty ? null : id;
  }

  /// `lesson:<id>` -> `<id>`; null for anything else.
  @visibleForTesting
  static String? lessonIdFromPayload(String? payload) {
    if (payload == null || !payload.startsWith(_payloadPrefix)) return null;
    final id = payload.substring(_payloadPrefix.length);
    return id.isEmpty ? null : id;
  }

  /// Initializes [plugin] and creates the channels. Shared with the
  /// background isolate, which has no tap handling.
  static Future<void> _setUp(FlutterLocalNotificationsPlugin plugin,
      {void Function(NotificationResponse)? onTap}) async {
    await plugin.initialize(
      settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher')),
      onDidReceiveNotificationResponse: onTap,
    );
    final android = plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(const AndroidNotificationChannel(
        _lessonsChannel, 'Lessons',
        description: 'A lesson is ready, or could not be made.'));
    await android?.createNotificationChannel(const AndroidNotificationChannel(
        _progressChannel, 'Downloads and recording',
        description: 'Progress of downloads and recordings.',
        importance: Importance.low,
        playSound: false,
        enableVibration: false));
  }

  @override
  Future<void> requestPermission() async {
    if (!_supported || _permissionAsked) return;
    _permissionAsked = true;
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } catch (_) {}
  }

  /// Positive 31-bit id from [s]. FNV-1a, because `String.hashCode` differs
  /// between isolates and runs and a later notification must replace the
  /// earlier one for the same lesson.
  @visibleForTesting
  static int stableId(String s) {
    var h = 0x811c9dc5;
    for (final b in utf8.encode(s)) {
      h = ((h ^ b) * 0x01000193) & 0xffffffff;
    }
    return h & 0x7fffffff;
  }

  static int _lessonId(String lessonId) => stableId('lesson\u0000$lessonId');
  static int _progressId(String key) => stableId('progress\u0000$key');

  static const _lessonDetails = NotificationDetails(
      android: AndroidNotificationDetails(_lessonsChannel, 'Lessons'));

  Future<void> _showLesson(
      String lessonId, String title, String body) async {
    if (!_supported || isForeground()) return;
    try {
      await _plugin.show(
          id: _lessonId(lessonId),
          title: title,
          body: body,
          notificationDetails: _lessonDetails,
          payload: '$_payloadPrefix$lessonId');
    } catch (_) {}
  }

  @override
  Future<void> lessonReady(String lessonId, String title,
          {required bool hasAudio}) =>
      _showLesson(lessonId, 'Lesson ready',
          '$title is ready to ${hasAudio ? 'listen to' : 'read'}.');

  @override
  Future<void> courseReady(String courseId, String title, int lessons) async {
    if (!_supported || isForeground()) return;
    try {
      await _plugin.show(
          id: stableId('course\u0000$courseId'),
          title: 'Course ready',
          body: '$title: $lessons lessons are ready to listen to.',
          notificationDetails: _lessonDetails,
          payload: '$_coursePrefix$courseId');
    } catch (_) {}
  }

  @override
  Future<void> lessonFailed(String lessonId, String title, String reason) =>
      _showLesson(lessonId, 'Lesson failed', '$title: $reason');

  Future<void> _showQuiz(String lessonId, String title, String body) async {
    if (!_supported || isForeground()) return;
    try {
      await _plugin.show(
          id: stableId('quiz\u0000$lessonId'),
          title: title,
          body: body,
          notificationDetails: _lessonDetails,
          payload: '$_quizPrefix$lessonId');
    } catch (_) {}
  }

  @override
  Future<void> quizReady(String lessonId, String lessonTitle, int questions) =>
      _showQuiz(lessonId, 'Quiz ready',
          '$lessonTitle: your quiz of $questions questions is ready.');

  @override
  Future<void> quizFailed(String lessonId, String lessonTitle, String reason) =>
      _showQuiz(lessonId, 'Quiz not written', '$lessonTitle: $reason');

  @override
  Future<void> progress(String key,
      {required String title, required String body, double? fraction}) async {
    if (!_supported || isForeground()) return;
    final percent =
        fraction == null ? null : (fraction.clamp(0.0, 1.0) * 100).floor();
    final now = DateTime.now();
    final last = _lastProgress[key];
    if (last != null) {
      if (last.percent == percent && last.body == body) return;
      if (now.difference(last.at) < _minProgressGap) return;
    }
    _lastProgress[key] = (at: now, percent: percent, body: body);
    try {
      await _plugin.show(
          id: _progressId(key),
          title: title,
          body: body,
          notificationDetails: NotificationDetails(
              android: AndroidNotificationDetails(
                  _progressChannel, 'Downloads and recording',
                  importance: Importance.low,
                  priority: Priority.low,
                  playSound: false,
                  enableVibration: false,
                  ongoing: true,
                  onlyAlertOnce: true,
                  showProgress: true,
                  maxProgress: 100,
                  progress: percent ?? 0,
                  indeterminate: percent == null)));
    } catch (_) {}
  }

  @override
  Future<void> clearProgress(String key) async {
    _lastProgress.remove(key);
    if (!_supported) return;
    try {
      await _plugin.cancel(id: _progressId(key));
    } catch (_) {}
  }

  @override
  Future<void> voiceModelReady(String modelLabel) async {
    if (!_supported || isForeground()) return;
    try {
      await _plugin.show(
          id: stableId('voice-model-ready'),
          title: 'Voice model ready',
          body: '$modelLabel is installed.',
          notificationDetails: _lessonDetails);
    } catch (_) {}
  }

  /// For the background check, which runs in its own isolate with no
  /// [LocalNotifications] instance: tells the user that the batch the
  /// lessons [waiting] share has finished. One notification per batch,
  /// however many lessons are in it.
  static Future<void> showBatchArrived(List<WaitingBatch> waiting) async {
    if (!_supported || waiting.isEmpty) return;
    final text = batchArrivedText(waiting);
    try {
      final plugin = FlutterLocalNotificationsPlugin();
      await _setUp(plugin);
      await plugin.show(
          id: stableId('batch\u0000${waiting.first.batchId}'),
          title: text.title,
          body: text.body,
          notificationDetails: _lessonDetails,
          // A single lesson (or quiz) opens; several just open the app.
          payload: waiting.length != 1
              ? null
              : waiting.single.isQuiz
                  ? '$_quizPrefix${waiting.single.lessonId}'
                  : '$_payloadPrefix${waiting.single.lessonId}');
    } catch (_) {}
  }

  /// The wording of [showBatchArrived]. An arrived answer is a step, not
  /// the finished lesson (the script and the recording may still follow),
  /// so it does not say "ready".
  @visibleForTesting
  static ({String title, String body}) batchArrivedText(
      List<WaitingBatch> waiting) {
    final n = waiting.length;
    if (n == 1 && waiting.single.isQuiz) {
      return (
        title: 'A quiz has arrived',
        body: '${waiting.single.lessonTitle}: the quiz you ordered is back '
            'from the batch queue. Open LearnMath to take it.',
      );
    }
    return n == 1
        ? (
            title: 'A lesson can continue',
            body: '${waiting.single.lessonTitle}: its answer from the batch '
                'queue has arrived. Open LearnMath to go on with it; it is '
                'not finished yet.',
          )
        : (
            title: '$n lessons can continue',
            body: 'Their answers from the batch queue have arrived. Open '
                'LearnMath to go on with them; they are not finished yet.',
          );
  }
}
