/// [KeepAlive] on top of flutter_foreground_task (Android foreground service).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'notifications.dart';

/// Entry point the plugin runs in the service's own isolate. The service only
/// exists to keep the process alive; the real work happens in the main
/// isolate, so the handler does nothing.
@pragma('vm:entry-point')
void keepAliveCallback() {
  FlutterForegroundTask.setTaskHandler(_IdleTaskHandler());
}

class _IdleTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

/// Holds an Android foreground service (type `dataSync`) with a persistent
/// notification while lessons are being made, so generation continues with
/// the screen off. Best-effort: a failure (notifications denied, Android
/// refusing a background start) is only logged; the periodic background batch
/// check remains as the fallback.
///
/// Calls are queued and run one after another, so start/stop never interleave
/// and the end state always matches the last call.
class ForegroundKeepAlive implements KeepAlive {
  /// The function parameters exist so tests can drive the sequencing without
  /// the plugin. They must throw on failure. Defaults call the plugin and do
  /// nothing off Android.
  ForegroundKeepAlive({
    Future<void> Function(String status)? start,
    Future<void> Function(String status)? update,
    Future<void> Function()? stop,
    Future<bool> Function()? isRunning,
  })  : _start = start ?? _pluginStart,
        _update = update ?? _pluginUpdate,
        _stop = stop ?? _pluginStop,
        _isRunning = isRunning ?? _pluginIsRunning;

  final Future<void> Function(String status) _start;
  final Future<void> Function(String status) _update;
  final Future<void> Function() _stop;
  final Future<bool> Function() _isRunning;

  Future<void> _queue = Future.value();

  /// The text currently shown, or null when we believe nothing is running.
  String? _shown;

  static const _title = 'LearnMath';

  /// Call once from `main`, before the first [hold].
  static Future<void> initialize() async {
    if (!_supported) return;
    try {
      FlutterForegroundTask.initCommunicationPort();
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'keepalive',
          channelName: 'Lesson generation',
          channelDescription:
              'Shown while lessons are being made in the background.',
          channelImportance: NotificationChannelImportance.LOW,
          priority: NotificationPriority.LOW,
          playSound: false,
          enableVibration: false,
        ),
        iosNotificationOptions: const IOSNotificationOptions(),
        foregroundTaskOptions: ForegroundTaskOptions(
          // No periodic event: nothing to do inside the service isolate.
          eventAction: ForegroundTaskEventAction.nothing(),
          autoRunOnBoot: false,
          autoRunOnMyPackageReplaced: false,
          allowWakeLock: true,
        ),
      );
    } catch (e) {
      debugPrint('Keep-alive service unavailable: $e');
    }
  }

  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<void> hold(String status) => _enqueue(() => _hold(status));

  @override
  Future<void> release() => _enqueue(_release);

  Future<void> _enqueue(Future<void> Function() job) {
    final result = _queue.then((_) => job());
    // Jobs never throw, but keep the chain alive whatever happens.
    _queue = result.catchError((Object _) {});
    return result;
  }

  Future<void> _hold(String status) async {
    try {
      final running = await _isRunning();
      if (!running) {
        _shown = null;
        await _start(status);
        _shown = status;
      } else if (_shown != status) {
        await _update(status);
        _shown = status;
      }
    } catch (e) {
      debugPrint('Keep-alive hold failed: $e');
    }
  }

  Future<void> _release() async {
    try {
      if (await _isRunning()) await _stop();
      _shown = null;
    } catch (e) {
      debugPrint('Keep-alive release failed: $e');
    }
  }

  static Future<void> _pluginStart(String status) async {
    if (!_supported) return;
    // Android 13+: without this permission the service still runs but its
    // notification is hidden. Not fatal, so the answer is ignored.
    if (await FlutterForegroundTask.checkNotificationPermission() !=
        NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    _check(await FlutterForegroundTask.startService(
      serviceTypes: [ForegroundServiceTypes.dataSync],
      notificationTitle: _title,
      notificationText: status,
      callback: keepAliveCallback,
    ));
  }

  static Future<void> _pluginUpdate(String status) async {
    if (!_supported) return;
    _check(await FlutterForegroundTask.updateService(
      notificationTitle: _title,
      notificationText: status,
    ));
  }

  static Future<void> _pluginStop() async {
    if (!_supported) return;
    _check(await FlutterForegroundTask.stopService());
  }

  static Future<bool> _pluginIsRunning() async {
    if (!_supported) return false;
    return FlutterForegroundTask.isRunningService;
  }

  static void _check(ServiceRequestResult result) {
    if (result is ServiceRequestFailure) throw result.error;
  }
}
