import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:learnmath/quiz/quiz_store.dart';
import 'package:learnmath/ai/openrouter_client.dart';
import 'package:learnmath/checks/math_check.dart';
import 'package:learnmath/core/models.dart';
import 'package:learnmath/core/storage.dart';
import 'package:learnmath/notify/notifications.dart';
import 'package:learnmath/pipeline/generation_service.dart';
import 'package:learnmath/tts/on_device_tts.dart';
import 'package:learnmath/tts/tts_engine.dart';
import 'package:sembast/sembast_memory.dart';

// ------------------------------------------------------------------ fakes

const notesWithChecks = '# Banach Fixed-Point Theorem\n\n'
    'A contraction has exactly one fixed point. For example 2 + 2 = 4.\n\n'
    '<<<CHECKS\n'
    'CHECK: Example A\nassert 2 + 2 == 4\n'
    'CHECK: Example B\nassert 3 * 3 == 9\n'
    'CHECKS>>>';

const repairedNotes = '# Banach Fixed-Point Theorem\n\n'
    'A contraction has exactly one fixed point. For example 2 + 3 = 5.\n\n'
    '<<<CHECKS\n'
    'CHECK: Example A fixed\nassert 2 + 3 == 5\n'
    'CHECKS>>>';

String scriptFor(String tag) =>
    'SECTION: $tag\nSAY: $tag one.\nSAY: $tag two.\nSAY: $tag three.';

/// A scripted OpenRouter. Records every request body. Answers are chosen by
/// what the request asks for, both for /chat/completions and for the
/// requests inside a batch.
class FakeOpenRouter {
  String notesAnswer = notesWithChecks;
  String repairAnswer = repairedNotes;

  /// Script text per request; defaults to [scriptFor] ('Script').
  String Function(Map<String, Object?> body)? scriptAnswer;

  /// Answers of the reviewer, one per verify request, in order; the last one
  /// repeats. Default: no issues.
  final verifierAnswers = <String>['NO ISSUES'];
  var _verifierCalls = 0;

  /// The judge's verdicts for a judge request; default: every issue real.
  String Function(Map<String, Object?> body)? judgeAnswer;

  /// The rewrite after confirmed issues; default [repairedNotes].
  String proofRepairAnswer = repairedNotes;

  /// Per-model override tried before everything else; return null to fall
  /// through to the kind-based answers. Lets a test script the reviewer and
  /// the lesson model separately.
  final modelAnswers = <String, String? Function(Map<String, Object?> body)>{};

  /// Tried first for every request, streamed or batched (requests inside a
  /// batch carry no model of their own); return null to fall through.
  String? Function(Map<String, Object?> body)? extraAnswer;

  /// Every request that carried a model, in order, whether it was streamed
  /// ('chat') or sent inside a batch ('batch').
  final requests = <RecordedRequest>[];

  /// Awaited before a streamed request is answered (not for batches).
  Future<void> Function(RecordedRequest request)? onChat;

  /// Makes `POST /batches` fail with this HTTP status (e.g. 429).
  int? failSubmitWith;

  final chatBodies = <Map<String, Object?>>[];
  final submitted = <Map<String, Object?>>[];
  final deleted = <String>[];
  final getCounts = <String, int>{};

  /// Statuses by batch id; 'in_progress' until a test finishes it.
  final status = <String, String>{};
  final batchError = <String, String>{};
  final batchRequests = <String, List<Map<String, Object?>>>{};

  /// Replaces the computed results of a batch.
  final resultOverride = <String, List<Map<String, Object?>>>{};
  final gone = <String>{};
  bool failGets = false;
  var _n = 0;

  late final http.Client client = MockClient.streaming((req, bodyStream) async {
    final path = req.url.path;
    final raw = await bodyStream.bytesToString();
    http.StreamedResponse json(Object body, [int code = 200]) =>
        http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(body))), code,
            headers: {'content-type': 'application/json'});

    if (req.method == 'POST' && path.endsWith('/chat/completions')) {
      final body = (jsonDecode(raw) as Map).cast<String, Object?>();
      chatBodies.add(body);
      requests.add(RecordedRequest('chat', body));
      await onChat?.call(requests.last);
      final text = answerFor(body);
      final chunk = jsonEncode({
        'choices': [
          {'delta': {'content': text}}
        ]
      });
      return http.StreamedResponse(
          Stream.value(utf8.encode('data: $chunk\n\ndata: [DONE]\n\n')), 200);
    }
    if (req.method == 'POST' && path.endsWith('/batches')) {
      final body = (jsonDecode(raw) as Map).cast<String, Object?>();
      final code = failSubmitWith;
      if (code != null) {
        return json({'error': {'message': 'nope', 'code': code}}, code);
      }
      submitted.add(body);
      for (final r in body['requests'] as List) {
        requests.add(RecordedRequest(
            'batch', ((r as Map)['body'] as Map).cast<String, Object?>(),
            batchModel: body['model'] as String?));
      }
      final id = 'batch_${++_n}';
      status[id] = 'in_progress';
      batchRequests[id] = [
        for (final r in body['requests'] as List) (r as Map).cast()
      ];
      return json({
        'id': id,
        'object': 'batch',
        'endpoint': '/v1/chat/completions',
        'model': body['model'],
        'status': 'validating',
        'created_at': 1782097200,
        'expires_at': 1782183600,
        'request_counts': {
          'total': (body['requests'] as List).length,
          'completed': 0,
          'failed': 0
        },
        'usage': null,
        'results': null,
        'error': null,
      }, 202);
    }
    final m = RegExp(r'/batches/([^/]+)$').firstMatch(path);
    if (m != null && req.method == 'GET') {
      final id = m.group(1)!;
      getCounts[id] = (getCounts[id] ?? 0) + 1;
      if (failGets) throw http.ClientException('offline');
      if (gone.contains(id)) return json({'error': 'gone'}, 410);
      final s = status[id]!;
      final done = s == 'completed';
      return json({
        'id': id,
        'object': 'batch',
        'status': s,
        'request_counts': {'total': batchRequests[id]!.length},
        'usage': done ? {'cost': 0.0123} : null,
        'results': done
            ? (resultOverride[id] ?? (_computed[id] ??= _results(id)))
            : null,
        'error': batchError[id] == null ? null : {'message': batchError[id]},
      });
    }
    if (m != null && req.method == 'DELETE') {
      deleted.add(m.group(1)!);
      return json({'deleted': true});
    }
    return json({'error': 'unrouted ${req.method} $path'}, 500);
  });

  // Answers are computed once per batch: scripted queues must not advance
  // each time the batch is read.
  final _computed = <String, List<Map<String, Object?>>>{};

  List<Map<String, Object?>> _results(String id) => [
        for (final r in batchRequests[id]!)
          okResult(r['custom_id'] as String,
              answerFor((r['body'] as Map).cast<String, Object?>())),
      ];

  static Map<String, Object?> okResult(String customId, String text) => {
        'custom_id': customId,
        'response': {
          'status_code': 200,
          'body': {
            'choices': [
              {
                'finish_reason': 'stop',
                'index': 0,
                'message': {'role': 'assistant', 'content': text}
              }
            ]
          }
        }
      };

  static String userText(Map<String, Object?> body) {
    final msgs = (body['messages'] as List).cast<Map>();
    return msgs.lastWhere((m) => m['role'] == 'user')['content'] as String;
  }

  static String systemText(Map<String, Object?> body) {
    final msgs = (body['messages'] as List).cast<Map>();
    return msgs.firstWhere((m) => m['role'] == 'system')['content'] as String;
  }

  /// 'repair', 'notes', 'script', 'verify', 'judge', 'proofRepair' or
  /// 'outline'.
  static String kind(Map<String, Object?> body) {
    final u = userText(body);
    if (systemText(body).contains('You are a referee')) return 'verify';
    if (systemText(body).contains('A referee has reported')) return 'judge';
    if (u.contains('Confirmed errors:')) return 'proofRepair';
    if (u.contains('Failed checks:')) return 'repair';
    if (u.startsWith('Write the lecture notes')) return 'notes';
    if (u.startsWith('Write the spoken lecture script')) return 'script';
    return 'outline';
  }

  String answerFor(Map<String, Object?> body) {
    final byModel =
        extraAnswer?.call(body) ?? modelAnswers[body['model']]?.call(body);
    return byModel ?? _answerByKind(body);
  }

  String _answerByKind(Map<String, Object?> body) => switch (kind(body)) {
        'repair' => repairAnswer,
        'verify' => verifierAnswers[
            math.min(_verifierCalls++, verifierAnswers.length - 1)],
        'judge' => judgeAnswer?.call(body) ??
            _allReal(userText(body)),
        'proofRepair' => proofRepairAnswer,
        'notes' => notesAnswer,
        'script' => scriptAnswer?.call(body) ?? scriptFor('Script'),
        _ => 'COURSE: Topology\nDESCRIPTION: d\n'
            'LESSON: Open sets\nBRIEF: b1\nLESSON: Compactness\nBRIEF: b2',
      };

  static String _allReal(String judgeUser) {
    final n = RegExp(r'^\d+\. ISSUE:', multiLine: true)
        .allMatches(judgeUser)
        .length;
    return [for (var i = 1; i <= n; i++) 'VERDICT $i: REAL - yes'].join('\n');
  }

  /// Requests (chat and batch) of one kind, in order.
  List<RecordedRequest> ofKind(String kind) =>
      [for (final r in requests) if (r.kind == kind) r];

  /// Kinds of all requests in the order they were made.
  List<String> get kinds => [for (final r in requests) r.kind];

  List<Map<String, Object?>> chatOf(String kind) =>
      [for (final b in chatBodies) if (FakeOpenRouter.kind(b) == kind) b];

  /// The batch requests submitted so far, all batches in order.
  List<Map<String, Object?>> get batchBodies => [
        for (final b in submitted)
          for (final r in b['requests'] as List)
            ((r as Map)['body'] as Map).cast<String, Object?>()
      ];

  void finish(String id) => status[id] = 'completed';
  String get lastBatchId => 'batch_$_n';
}

/// One model request as the fake saw it.
class RecordedRequest {
  RecordedRequest(this.via, this.body, {this.batchModel});

  /// 'chat' or 'batch'.
  final String via;
  final Map<String, Object?> body;

  /// The model of the enclosing batch, for batch requests.
  final String? batchModel;

  String get model => (body['model'] ?? batchModel) as String;
  String get kind => FakeOpenRouter.kind(body);

  /// The reasoning effort, or null when none was sent.
  String? get effort => (body['reasoning'] as Map?)?['effort'] as String?;
  bool get hasTemperature => body.containsKey('temperature');
}

/// Records what the keep-alive was told.
class RecordingKeepAlive implements KeepAlive {
  /// 'hold: STATUS' and 'release', in order.
  final calls = <String>[];

  @override
  Future<void> hold(String status) async => calls.add('hold: $status');

  @override
  Future<void> release() async => calls.add('release');

  /// Distinct consecutive calls, to compare without timing noise.
  List<String> get distinct {
    final out = <String>[];
    for (final c in calls) {
      if (out.isEmpty || out.last != c) out.add(c);
    }
    return out;
  }
}

class FakeRunner implements MathCheckRunner {
  FakeRunner(this.script, {this.onRun});

  /// Statuses per call; the last entry repeats when the script is used up.
  final List<List<CheckStatus>> script;
  final Future<void> Function(List<MathCheck> checks)? onRun;
  final calls = <List<MathCheck>>[];
  Object? throwOnRun;
  var disposed = false;

  @override
  Future<List<CheckOutcome>> run(List<MathCheck> checks,
      {Duration perCheckTimeout = const Duration(seconds: 20),
      void Function(int done, int total)? onProgress}) async {
    calls.add(checks);
    await onRun?.call(checks);
    final err = throwOnRun;
    if (err != null) throw err;
    final statuses = script[math.min(calls.length, script.length) - 1];
    return [
      for (var i = 0; i < checks.length; i++)
        CheckOutcome(
          title: checks[i].title,
          status: statuses[math.min(i, statuses.length - 1)],
          detail: statuses[math.min(i, statuses.length - 1)] ==
                  CheckStatus.passed
              ? null
              : 'detail ${checks[i].title}',
        ),
    ];
  }

  @override
  Future<void> dispose() async => disposed = true;
}

class FakeEngine implements TtsEngine {
  @override
  int get sampleRate => 24000;
  @override
  int get maxConcurrency => 1;
  @override
  Future<void> prepare() async {}
  @override
  Future<Int16List> synthesize(String text) async => Int16List.fromList([
        for (var i = 0; i < 2400; i++)
          (math.sin(i * 2 * math.pi * 440 / 24000) * 8000).round(),
      ]);
  @override
  Future<void> dispose() async {}
}

class RecordingNotifications extends NoNotifications {
  final ready = <({String id, String title, bool hasAudio})>[];
  final failed = <({String id, String title, String reason})>[];
  final courses = <({String id, String title, int lessons})>[];

  @override
  Future<void> courseReady(String courseId, String title, int lessons) async =>
      courses.add((id: courseId, title: title, lessons: lessons));

  @override
  Future<void> lessonReady(String lessonId, String title,
          {required bool hasAudio}) async =>
      ready.add((id: lessonId, title: title, hasAudio: hasAudio));

  @override
  Future<void> lessonFailed(
          String lessonId, String title, String reason) async =>
      failed.add((id: lessonId, title: title, reason: reason));

  /// Quiz notifications: questions for "ready", reason for "failed".
  final quizzes = <({String lessonId, int? questions, String? reason})>[];

  @override
  Future<void> quizReady(
          String lessonId, String lessonTitle, int questions) async =>
      quizzes.add((lessonId: lessonId, questions: questions, reason: null));

  @override
  Future<void> quizFailed(
          String lessonId, String lessonTitle, String reason) async =>
      quizzes.add((lessonId: lessonId, questions: null, reason: reason));
}

class RecordingBackground implements BatchBackground {
  final updates = <List<WaitingBatch>>[];
  @override
  Future<void> update(List<WaitingBatch> waiting) async =>
      updates.add(waiting);
}

class Env {
  late Database db;
  late LibraryRepository repo;
  late Directory tmp;
  late AppPaths paths;
  final fake = FakeOpenRouter();
  final notifications = RecordingNotifications();
  final background = RecordingBackground();
  final keepAlive = RecordingKeepAlive();
  final progress = <(String, String?)>[];
  FakeRunner? runner;
  AppSettings settings = const AppSettings(apiKey: 'k');
  late GenerationService service;

  /// Makes the speech engine of each recording.
  TtsEngine Function() engine = FakeEngine.new;

  static var _dbN = 0;

  Future<void> init({FakeRunner? runner, bool withRunner = true}) async {
    this.runner = runner;
    tmp = await Directory.systemTemp.createTemp('gen_test');
    paths = AppPaths(docs: '${tmp.path}/docs', support: '${tmp.path}/support');
    db = await newDatabaseFactoryMemory().openDatabase('gen${_dbN++}');
    repo = LibraryRepository(db, paths);
    service = GenerationService(
      repo: repo,
      paths: paths,
      readSettings: () => settings,
      voices: VoiceModelManager('${tmp.path}/models'),
      onProgress: (id, p) => progress.add((id, p?.label)),
      notifications: notifications,
      batchBackground: background,
      keepAlive: keepAlive,
      createCheckRunner: withRunner && runner != null ? () => runner : null,
      createClient: (k) => OpenRouterClient(apiKey: k, httpClient: fake.client),
      createEngine: (_) => engine(),
      autoPoll: false,
      quizzes: QuizStore(db),
    );
  }

  Future<void> dispose() async {
    await db.close();
    await tmp.delete(recursive: true);
  }

  Future<Lesson> lesson(String id) async => (await repo.getLesson(id))!;

  /// Runs the queue dry and lets fire-and-forget work (batch deletion) finish.
  Future<void> settle() async {
    await service.idle;
    await pumpEventQueue();
    await service.idle;
  }

  Future<String> create([String request = 'The Banach fixed-point theorem']) async {
    final id = await service.createLesson(request);
    await settle();
    return id;
  }

  /// Finishes the latest batch and lets the service collect it.
  Future<void> finishAndPoll([String? batchId]) async {
    fake.finish(batchId ?? fake.lastBatchId);
    await service.pollBatches();
    await settle();
  }

  String? lastLabel(String id) =>
      progress.lastWhere((p) => p.$1 == id, orElse: () => (id, 'none')).$2;
}

List<CheckStatus> passed(int n) => List.filled(n, CheckStatus.passed);
