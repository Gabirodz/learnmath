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
  LocalNotifications({required this.onOpenLesson, required this.isForeground});

  /// Called with the lesson id when the user taps a lesson notification while
  /// the app is running.
  final void Function(String lessonId) onOpenLesson;

  /// Whether the app is visible. The screen already shows what happened then,
  /// so nothing is posted.
  final bool Function() isForeground;

  /// Set by [init] when the app was started by tapping a lesson notification.
  String? launchLessonId;

  static const _lessonsChannel = 'lessons';
  static const _progressChannel = 'progress';
  static const _payloadPrefix = 'lesson:';
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
        launchLessonId = lessonIdFromPayload(
            launch?.notificationResponse?.payload);
      }
    } catch (e) {
      debugPrint('Notifications unavailable: $e');
    }
  }

  void _handleTap(String? payload) {
    final id = lessonIdFromPayload(payload);
    if (id != null) onOpenLesson(id);
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
  Future<void> lessonFailed(String lessonId, String title, String reason) =>
      _showLesson(lessonId, 'Lesson failed', '$title: $reason');

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
  /// [LocalNotifications] instance: tells the user a waiting batch finished.
  static Future<void> showBatchArrived(WaitingBatch b) async {
    if (!_supported) return;
    try {
      final plugin = FlutterLocalNotificationsPlugin();
      await _setUp(plugin);
      await plugin.show(
          id: _lessonId(b.lessonId),
          title: 'Your lesson is ready to continue',
          body: '${b.lessonTitle}: the answer has arrived. '
              'Open LearnMath to finish it.',
          notificationDetails: _lessonDetails,
          payload: '$_payloadPrefix${b.lessonId}');
    } catch (_) {}
  }
}
