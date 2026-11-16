/// Checks on waiting OpenRouter batches while the app is closed.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:workmanager/workmanager.dart';

import '../ai/openrouter_client.dart';
import 'local_notifications.dart';
import 'notifications.dart';

const _taskName = 'learnmath.batch-check';
const _waitingFile = 'waiting_batches.json';
const _announcedFile = 'announced_batches.json';

/// Keeps a periodic WorkManager task alive while any batch is outstanding.
///
/// The task runs in its own isolate and must not open the app's database, so
/// the main isolate hands over the waiting list as a small JSON file.
class WorkmanagerBatchBackground implements BatchBackground {
  /// Call once from `main`, before [update].
  static Future<void> initialize() async {
    if (!_supported) return;
    try {
      await Workmanager().initialize(batchCheckDispatcher);
    } catch (e) {
      debugPrint('Background batch checks unavailable: $e');
    }
  }

  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<void> update(List<WaitingBatch> waiting) async {
    if (!_supported) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File(p.join(dir.path, _waitingFile));
      if (waiting.isEmpty) {
        if (await file.exists()) await file.delete();
        await Workmanager().cancelByUniqueName(_taskName);
        return;
      }
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(
          jsonEncode([for (final w in waiting) w.toJson()]),
          flush: true);
      await tmp.rename(file.path);
      // WorkManager's minimum period. `keep` leaves an already scheduled task
      // alone so each update does not push its next run back.
      await Workmanager().registerPeriodicTask(_taskName, _taskName,
          frequency: const Duration(minutes: 15),
          constraints: Constraints(networkType: NetworkType.connected),
          existingWorkPolicy: ExistingPeriodicWorkPolicy.keep);
    } catch (e) {
      debugPrint('Could not update background batch check: $e');
    }
  }
}

/// Entry point WorkManager starts in a fresh isolate.
@pragma('vm:entry-point')
void batchCheckDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      return await _runBatchCheck();
    } catch (e) {
      debugPrint('Background batch check failed: $e');
      return true;
    }
  });
}

Future<bool> _runBatchCheck() async {
  final dir = await getApplicationDocumentsDirectory();
  final waitingFile = File(p.join(dir.path, _waitingFile));
  final announcedFile = File(p.join(dir.path, _announcedFile));

  final waiting = await _readWaiting(waitingFile);
  if (waiting.isEmpty) return true;

  String? apiKey;
  try {
    apiKey = await const FlutterSecureStorage().read(key: 'openrouter_api_key');
  } catch (_) {}
  if (apiKey == null || apiKey.isEmpty) return true;

  final announcedBefore = await _readAnnounced(announcedFile);
  final client = OpenRouterClient(apiKey: apiKey);
  try {
    final r = await checkWaitingBatches(
        waiting: waiting,
        announced: announcedBefore,
        getBatch: client.getBatch);
    // One notification per batch: a course generated at once shares one.
    final byBatch = <String, List<WaitingBatch>>{};
    for (final b in r.announce) {
      byBatch.putIfAbsent(b.batchId, () => []).add(b);
    }
    for (final lessons in byBatch.values) {
      await LocalNotifications.showBatchArrived(lessons);
    }
    try {
      await announcedFile.writeAsString(jsonEncode(r.announced.toList()),
          flush: true);
    } catch (_) {}
    return true;
  } on SocketException {
    return false; // offline: let WorkManager retry
  } on TimeoutException {
    return false;
  } on http.ClientException {
    return false;
  } finally {
    client.close();
  }
}

Future<List<WaitingBatch>> _readWaiting(File f) async {
  try {
    final j = jsonDecode(await f.readAsString());
    if (j is! List) return const [];
    return [for (final e in j) ?WaitingBatch.fromJson(e)];
  } catch (_) {
    return const [];
  }
}

Future<Set<String>> _readAnnounced(File f) async {
  try {
    final j = jsonDecode(await f.readAsString());
    if (j is! List) return {};
    return {for (final e in j) if (e is String) e};
  } catch (_) {
    return {};
  }
}

/// Decides which of [waiting] to tell the user about.
///
/// Asks for the status of each distinct batch id once. A batch that reached a
/// terminal status and is not in [announced] yet is announced, once per
/// waiting lesson. The returned `announced` set is [announced] plus the new
/// ones, limited to ids still being waited for. A batch whose status request
/// fails is skipped this time; the others are still checked.
Future<({List<WaitingBatch> announce, Set<String> announced})>
    checkWaitingBatches({
  required List<WaitingBatch> waiting,
  required Set<String> announced,
  required Future<BatchInfo> Function(String id) getBatch,
}) async {
  final stillWaiting = {for (final w in waiting) w.batchId};
  final next = {...announced}..retainWhere(stillWaiting.contains);
  final announce = <WaitingBatch>[];
  for (final id in stillWaiting) {
    if (next.contains(id)) continue;
    try {
      final info = await getBatch(id);
      if (!info.isTerminal) continue;
      next.add(id);
      announce.addAll(waiting.where((w) => w.batchId == id));
    } on OpenRouterException {
      continue;
    }
  }
  return (announce: announce, announced: next);
}
